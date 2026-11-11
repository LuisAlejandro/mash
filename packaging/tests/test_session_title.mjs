// The session-title extension: what a tab is called before the first answer,
// and that the answer's topic survives everything pi does to the terminal title
// afterwards.
//
// The failure this pins: pi rewrites the terminal title itself (session name and
// cwd) at startup and on session_info_changed, which lands after session_start
// and used to undo the topic the extension had set. The tab then sat on
// "π - mash" — the same on every tab of a workspace — until the next exchange.
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { test } from "node:test";
import { pathToFileURL } from "node:url";

// The extension imports pi's own package for getAgentDir(). It resolves inside
// pi and not here, so the specifier is answered with a stub; a directory that
// holds no omniRoute settings is what the extension's optional compression path
// treats as "not installed".
registerHooks({
	resolve(specifier, context, nextResolve) {
		if (specifier === "@earendil-works/pi-coding-agent") {
			return {
				url: "data:text/javascript,export const getAgentDir=()=>'/nonexistent/pi-agent';",
				shortCircuit: true,
			};
		}
		return nextResolve(specifier, context);
	},
});

const extensionUrl = pathToFileURL(
	new URL("../defaults/pi/extensions/session-title.ts", import.meta.url).pathname,
);
const { default: sessionTitle } = await import(extensionUrl.href);

// A session the extension can title: one handler per event, and the titles it
// wrote, in order.
function session({ cwd = "/Users/me/mash", text } = {}) {
	const handlers = new Map();
	const titles = [];
	sessionTitle({ on: (event, handler) => handlers.set(event, handler) });
	const ctx = {
		sessionManager: {
			getCwd: () => cwd,
			getEntries: () =>
				text === undefined
					? []
					: [{ type: "message", message: { role: "assistant", content: [{ type: "text", text }] } }],
		},
		ui: { setTitle: (title) => titles.push(title) },
	};
	return {
		titles,
		emit: (event) => handlers.get(event)({}, ctx),
		say: (said) => {
			text = said;
		},
	};
}

test("the tab is named after the working directory until there is a topic", async () => {
	const s = session();
	await s.emit("session_start");
	assert.deepEqual(s.titles, ["mash"]);

	await s.emit("agent_start");
	assert.deepEqual(s.titles, ["mash", "mash"], "the seed is re-asserted on each prompt");
});

test("the first answer becomes the topic, and later prompts keep it", async () => {
	const s = session({ text: "Fixed the tab naming" });
	await s.emit("session_start");
	await s.emit("agent_settled");
	assert.deepEqual(s.titles.slice(-1), ["Fixed the tab naming"]);

	// pi sets its own title between prompts; agent_start restores the topic
	// instead of the repository name.
	s.say("An unrelated later answer");
	await s.emit("agent_start");
	await s.emit("agent_settled");
	assert.deepEqual(s.titles.slice(-2), ["Fixed the tab naming", "Fixed the tab naming"]);
});

test("a long answer is truncated to 37 characters plus an ellipsis", async () => {
	const s = session({ text: "x".repeat(80) });
	await s.emit("session_start");
	await s.emit("agent_settled");
	assert.equal(s.titles.at(-1), `${"x".repeat(37)}…`);
});

test("a tool-only turn leaves the seed alone and titles on a later turn", async () => {
	const s = session({ text: undefined });
	await s.emit("session_start");
	await s.emit("agent_settled");
	assert.deepEqual(s.titles, ["mash"], "no assistant text yet: nothing to name the tab after");

	s.say("Named after a later turn");
	await s.emit("agent_settled");
	assert.equal(s.titles.at(-1), "Named after a later turn");
});

test("a resumed session starts over rather than keeping the old topic", async () => {
	const s = session({ text: "First conversation" });
	await s.emit("session_start");
	await s.emit("agent_settled");
	assert.equal(s.titles.at(-1), "First conversation");

	s.say(undefined);
	await s.emit("session_start");
	assert.equal(s.titles.at(-1), "mash", "a new conversation has no topic yet");
});
