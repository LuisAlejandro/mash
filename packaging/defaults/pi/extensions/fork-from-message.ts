// Fork from Message, finished inside the destination pane by Pi's own /fork.
//
// herdr-fork-pi opens a tab, split or workspace and starts Pi there with
//
//   pi --fork <source session> --mash-fork-into <tab|pane|workspace>:<herdr id> /mash-fork
//
// `--fork` copies the source session at its leaf into a new file, so the
// source pane and its file are never touched. /mash-fork then shows Pi's own
// "Fork from Message" selector over that copy and calls ctx.fork(), which is
// exactly what /fork does: a new session that ends before the chosen user
// message, with that message back in the editor, unsent, and Pi's
// session_before_fork hooks run.
//
// The leaf copy is only a vehicle. Once the native fork exists it is deleted,
// and the fork's header is pointed at the real source so /resume still shows
// it under the session it came from. A cancelled pick deletes the copy and
// closes the destination, leaving nothing behind.
//
// Only the flag makes a copy disposable, and only once per process: typed by
// hand, /mash-fork is an in-place /fork that deletes nothing.
import { readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { UserMessageSelectorComponent, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { t } from "./lib/mash-i18n.ts";

const FLAG = "mash-fork-into";
// Extensions are reloaded on every session replacement; the claim must outlive that.
const CLAIMED = Symbol.for("mash.fork-from-message.claimed");

/** `tab:w1:t2` -> close target, only in the exact shapes herdr-fork-pi passes. */
export function parseTarget(value: unknown): { kind: string; id: string } | undefined {
	const match = typeof value === "string" && /^(tab|pane|workspace):([A-Za-z0-9]+(?::[A-Za-z0-9]+)?)$/.exec(value);
	return match ? { kind: match[1], id: match[2] } : undefined;
}

/** Point a session file's header at `parent`, atomically. */
export function repointParent(file: string, parent: string): void {
	const text = readFileSync(file, "utf8");
	const newline = text.indexOf("\n");
	const header = JSON.parse(newline < 0 ? text : text.slice(0, newline));
	if (header?.type !== "session") throw new Error("not a Pi session header");
	header.parentSession = parent;
	const tmp = `${file}.mash-fork.tmp`;
	writeFileSync(tmp, JSON.stringify(header) + (newline < 0 ? "\n" : text.slice(newline)), { mode: 0o600 });
	// ponytail: an entry Pi appends between the read and the rename is lost. It
	// runs right after the fork, before the user can type; a Pi API to set the
	// parent would remove the window.
	renameSync(tmp, file);
}

function userText(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content.filter((part) => part?.type === "text" && typeof part.text === "string").map((part) => part.text).join("");
}

export default function (pi: ExtensionAPI) {
	pi.registerFlag(FLAG, { description: "Fork into a Herdr destination (set by Mash's fork chords)", type: "string" });

	pi.registerCommand("mash-fork", {
		description: t("pi.fork.description"),
		handler: async (_args, ctx) => {
			if (!ctx.hasUI) return;
			const globals = globalThis as Record<symbol, unknown>;
			const target = globals[CLAIMED] ? undefined : parseTarget(pi.getFlag(FLAG));
			globals[CLAIMED] = true;
			const vehicle = target ? ctx.sessionManager.getSessionFile() : undefined;
			const source = ctx.sessionManager.getHeader()?.parentSession;
			const abandon = () => {
				if (!target) return;
				if (vehicle && source && vehicle !== source) rmSync(vehicle, { force: true });
				// Closing the destination ends this Pi with it, so it runs last.
				spawnSync(process.env.HERDR_BIN_PATH || "herdr", [target.kind, "close", target.id], { stdio: "ignore" });
			};

			// The same list and selector as Pi's /fork (getUserMessagesForForking).
			const messages = ctx.sessionManager.getEntries().flatMap((entry) =>
				entry.type === "message" && entry.message.role === "user" && userText(entry.message.content)
					? [{ id: entry.id, text: userText(entry.message.content) }]
					: [],
			);
			if (messages.length === 0) {
				ctx.ui.notify(t("pi.fork.no-messages"), "warning");
				return abandon();
			}
			const chosen = await ctx.ui.custom<string | undefined>((_tui, _theme, _keybindings, done) => {
				const selector = new UserMessageSelectorComponent(messages, done, () => done(undefined), messages[messages.length - 1].id);
				const list = selector.getMessageList();
				return {
					render: (width: number) => selector.render(width),
					handleInput: (data: string) => list.handleInput(data),
					invalidate: () => selector.invalidate(),
				};
			});
			if (!chosen) return abandon();

			const result = await ctx.fork(chosen, {
				withSession: async (forked) => {
					// The copy's runtime is torn down by now, so nothing writes to it again.
					if (!vehicle || !source || vehicle === source) return;
					rmSync(vehicle, { force: true });
					// A fork before the first message is written lazily from this header.
					const header = forked.sessionManager.getHeader();
					if (header) header.parentSession = source;
					const file = forked.sessionManager.getSessionFile();
					try {
						if (file) repointParent(file, source);
					} catch {
						// Not written yet, or unreadable: lineage only, the fork is usable.
					}
				},
			});
			if (result.cancelled) abandon();
		},
	});
}
