// Mash's fork chords finish inside the new pane with Pi's own fork. This drives
// the real path against the pinned Pi, headless: `pi --fork` makes the leaf copy
// (SessionManager.forkFrom), the fork-from-message extension runs /mash-fork
// with the --mash-fork-into flag, and Pi's AgentSessionRuntime does the fork.
// Only the selector's answer is scripted.
//
// What must hold, in the order a user would notice it going wrong:
//   - the source session file is byte-identical afterwards
//   - the fork ends before the chosen message, which comes back unsent
//   - the leaf copy is gone and the fork's parent is the real source
//   - a cancel deletes the copy and closes exactly the destination it was given
//   - typed by hand (no flag), /mash-fork deletes nothing and closes nothing
//
//   node test_fork_from_message.mjs [<pi-coding-agent package dir>]
import assert from "node:assert/strict";
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

// The pin when given; else the Pi beside this node, which is how Mash ships them.
const beside = join(dirname(process.execPath), "../lib/node_modules/@earendil-works/pi-coding-agent");
const pi = process.argv[2] || (existsSync(join(beside, "dist/index.js")) ? beside : undefined);
if (!pi) {
	console.log("skip - the fork needs a staged pin: test_pi_runtime.sh <resource-root>");
	process.exit(77);
}
const sdk = await import(pathToFileURL(join(pi, "dist/index.js")).href);
// Interactive mode loads the theme before any selector draws; so does this.
sdk.initTheme();
const extensions = join(dirname(fileURLToPath(import.meta.url)), "../defaults/pi/extensions");
const extension = join(extensions, "fork-from-message.ts");

const root = mkdtempSync(join(tmpdir(), "mash-fork-"));
// Pi's loader aliases its own package for extensions. A direct import of the
// helpers finds it through a node_modules beside the copy instead.
mkdirSync(join(root, "node_modules/@earendil-works"), { recursive: true });
symlinkSync(pi, join(root, "node_modules/@earendil-works/pi-coding-agent"));
cpSync(extension, join(root, "fork-from-message.ts"));
cpSync(join(extensions, "lib"), join(root, "lib"), { recursive: true });
const helpers = await import(pathToFileURL(join(root, "fork-from-message.ts")).href);
const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const header = (file) => JSON.parse(readFileSync(file, "utf8").split("\n")[0]);
const userTexts = (file) =>
	readFileSync(file, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line))
		.filter((e) => e.type === "message" && e.message.role === "user").map((e) => e.message.content[0].text);

// A herdr stand-in that only records `<kind> close <id>`.
const herdr = join(root, "herdr");
const closes = join(root, "closes");
writeFileSync(herdr, `#!/bin/sh\necho "$@" >> '${closes}'\n`);
chmodSync(herdr, 0o755);
process.env.HERDR_BIN_PATH = herdr;
const closed = () => (existsSync(closes) ? readFileSync(closes, "utf8").trim().split("\n") : []);

const sessions = join(root, "sessions");
const agentDir = join(root, "agent");
cpSync(extension, join(agentDir, "extensions", "fork-from-message.ts"));
cpSync(join(extensions, "lib"), join(agentDir, "extensions", "lib"), { recursive: true });
writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ packages: [] }));

const source = (() => {
	const sm = sdk.SessionManager.create(root, sessions);
	for (const n of ["first", "second", "third"]) {
		sm.appendMessage({ role: "user", content: [{ type: "text", text: `${n} question` }], timestamp: Date.now() });
		sm.appendMessage({ role: "assistant", content: [{ type: "text", text: `${n} answer` }], api: "x", provider: "x", model: "x", usage, stopReason: "stop", timestamp: Date.now() });
	}
	return sm.getSessionFile();
})();
const sourceBytes = readFileSync(source);

/**
 * One Pi, as herdr-fork-pi starts it (`flag` set) or as a user runs it (unset).
 * `pick` answers the selector: an index into the listed messages, or undefined.
 */
async function run({ flag, pick, sessionManager, sameProcess = false }) {
	// Each run stands for its own Pi process unless told otherwise.
	if (!sameProcess) delete globalThis[Symbol.for("mash.fork-from-message.claimed")];
	const flags = new Map(flag ? [["mash-fork-into", flag]] : []);
	let editor = "";
	let listed;
	const createRuntime = async ({ cwd, sessionManager, sessionStartEvent }) => {
		const services = await sdk.createAgentSessionServices({ cwd, agentDir, extensionFlagValues: flags });
		assert.deepEqual(services.diagnostics.filter((d) => d.type === "error"), [], "the extension and its flag load");
		return { ...(await sdk.createAgentSessionFromServices({ services, sessionManager, sessionStartEvent })), services, diagnostics: services.diagnostics };
	};
	const runtime = await sdk.createAgentSessionRuntime(createRuntime, { cwd: root, agentDir, sessionManager });
	const ui = {
		notify() {},
		// The selector component is what `custom` renders; pull its list straight out.
		custom: async (factory) => {
			let answer;
			const component = factory({}, {}, {}, (value) => (answer = value));
			listed = component.render(200).join("\n");
			const ids = runtime.session.sessionManager.getEntries()
				.filter((e) => e.type === "message" && e.message.role === "user").map((e) => e.id);
			answer = pick === undefined ? undefined : ids[pick];
			return answer;
		},
	};
	const bind = () =>
		runtime.session.bindExtensions({
			uiContext: new Proxy(ui, { get: (target, key) => target[key] ?? (() => undefined) }),
			mode: "tui",
			onError: (error) => assert.fail(`/mash-fork threw: ${error.error}`),
			commandContextActions: {
				waitForIdle: () => runtime.session.waitForIdle(),
				fork: async (entryId, options) => {
					// What interactive mode does around runtimeHost.fork().
					const result = await runtime.fork(entryId, { ...options, withSession: async (ctx) => { await bind(); await options?.withSession?.(ctx); } });
					if (!result.cancelled) editor = result.selectedText ?? "";
					return { cancelled: result.cancelled };
				},
				newSession: (o) => runtime.newSession(o),
				switchSession: (p, o) => runtime.switchSession(p, o),
				navigateTree: async () => ({ cancelled: false }),
				reload: async () => {},
			},
		});
	await bind();
	const start = runtime.session.sessionFile;
	await runtime.session.prompt("/mash-fork");
	const result = { start, end: runtime.session.sessionFile, editor, listed };
	await runtime.dispose();
	return result;
}

try {
	assert.deepEqual(helpers.parseTarget("tab:w1:t2"), { kind: "tab", id: "w1:t2" });
	assert.deepEqual(helpers.parseTarget("workspace:w9"), { kind: "workspace", id: "w9" });
	for (const bad of [undefined, "", "tab", "tab:", "window:w1", "tab:w1;rm -rf", "tab:w1:t2 extra"]) {
		assert.equal(helpers.parseTarget(bad), undefined, `${bad} is refused`);
	}

	// --- the chord: fork before the second message into a fresh tab ---------
	const leaf = () => sdk.SessionManager.forkFrom(source, root, sessions);
	const picked = await run({ flag: "tab:w1:t2", pick: 1, sessionManager: leaf() });
	assert.match(picked.listed, /Fork from Message/, "Pi's own selector is shown");
	assert.match(picked.listed, /first question[\s\S]*second question[\s\S]*third question/);
	assert.ok(!existsSync(picked.start), "the leaf copy is deleted");
	assert.deepEqual(userTexts(picked.end), ["first question"], "the fork ends before the chosen message");
	assert.equal(picked.editor, "second question", "the chosen message comes back, unsent");
	assert.equal(header(picked.end).parentSession, source, "the fork descends from the real source");
	assert.deepEqual(closed(), [], "a completed fork closes nothing");

	// The flag outlives the fork's extension reload. A second /mash-fork typed
	// in that same Pi must not treat the user's new fork as disposable.
	const again = await run({ flag: "tab:w1:t2", pick: undefined, sameProcess: true, sessionManager: sdk.SessionManager.open(picked.end, sessions) });
	assert.ok(existsSync(again.start), "the fork survives a later cancelled /mash-fork");
	assert.deepEqual(closed(), [], "and its tab stays open");

	// --- cancel: nothing is left behind -------------------------------------
	const cancelled = await run({ flag: "pane:w1:p7", pick: undefined, sessionManager: leaf() });
	assert.ok(!existsSync(cancelled.start), "a cancel deletes the leaf copy");
	assert.deepEqual(closed(), ["pane close w1:p7"], "and closes the destination it was given");

	// --- by hand: the session belongs to the user ---------------------------
	const own = sdk.SessionManager.forkFrom(source, root, sessions);
	const ownFile = own.getSessionFile();
	const byHand = await run({ pick: undefined, sessionManager: own });
	assert.ok(existsSync(ownFile), "a hand-typed /mash-fork deletes nothing on cancel");
	assert.deepEqual(closed(), ["pane close w1:p7"], "and closes nothing");
	const byHandPick = await run({ pick: 2, sessionManager: sdk.SessionManager.open(ownFile, sessions) });
	assert.ok(existsSync(ownFile), "or after a fork");
	assert.equal(byHandPick.editor, "third question");
	void byHand;

	assert.deepEqual(readFileSync(source), sourceBytes, "the source session is never written");
	const left = readdirSync(sessions).filter((name) => name.includes(".mash-fork.tmp"));
	assert.deepEqual(left, [], "no temporary header file is left");
	console.log("ok - fork chords finish with Pi's own fork: before the message, unsent, source untouched, cancel leaves nothing");
} finally {
	rmSync(root, { recursive: true, force: true });
}
