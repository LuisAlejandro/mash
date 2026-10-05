/**
 * Session Title Extension
 *
 * Sets the terminal window/tab title from the agent's first real response,
 * so a Pi pane's title reflects what the conversation is actually about
 * instead of a static "π" placeholder. Herdr reads that title into
 * `terminal_title_stripped`, which is what herdr.auto-title's generic
 * naming path falls back to.
 *
 * Fires once per session, on the first agent_settled that has assistant text.
 * A resumed session retitles from the next new exchange.
 *
 * The title is the assistant text, truncated. There is no model call.
 */

import type { ExtensionAPI, SessionEntry } from "@earendil-works/pi-coding-agent";

const TITLE_PREFIX = "π - ";
const TITLE_TRUNCATE_AT = 40;
const TITLE_KEEP_CHARS = 37;

function lastAssistantText(entries: readonly SessionEntry[]): string | undefined {
	for (let i = entries.length - 1; i >= 0; i--) {
		const entry = entries[i];
		if (entry.type !== "message" || entry.message.role !== "assistant") continue;
		const text = entry.message.content
			.filter((part): part is { type: "text"; text: string } => part.type === "text")
			.map((part) => part.text)
			.join(" ")
			.replace(/\s+/g, " ")
			.trim();
		if (text) return text;
	}
	return undefined;
}

function formatTitle(text: string): string {
	const body = text.length > TITLE_TRUNCATE_AT ? `${text.slice(0, TITLE_KEEP_CHARS)}…` : text;
	return `${TITLE_PREFIX}${body}`;
}

export default function (pi: ExtensionAPI) {
	let titled = false;

	pi.on("session_start", async () => {
		titled = false;
	});

	pi.on("agent_settled", async (_event, ctx) => {
		if (titled) return;
		const text = lastAssistantText(ctx.sessionManager.getEntries());
		if (!text) return;
		titled = true;
		ctx.ui.setTitle(formatTitle(text));
	});
}
