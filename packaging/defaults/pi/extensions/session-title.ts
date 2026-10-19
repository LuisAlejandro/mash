/**
 * Session Title Extension
 *
 * Sets the terminal window/tab title from the agent's first real response,
 * so a Pi pane's title reflects what the conversation is actually about
 * instead of a static "π" placeholder. Herdr reads that title into
 * `terminal_title_stripped`, which is what herdr.auto-title's generic
 * naming path falls back to.
 *
 * Fires once per session, on the first agent_settled that has assistant text:
 *   - Not at session_start / agent_start — no assistant response exists yet.
 *   - Not on every turn_end — a single exchange can produce several
 *     intermediate turns (one per tool-call round-trip), which would flicker
 *     the title mid-task.
 *   - agent_settled fires once per finished exchange, only after Pi confirms
 *     no automatic retry, compaction or queued continuation will run.
 * A resumed session retitles from the next new exchange.
 *
 * Compression is optional. When the pi-omniroute-sync plugin is installed
 * and configured in this agent directory, the raw assistant text is sent to
 * OmniRoute for a short label (at most five words) before it becomes the
 * title. Without it, or when the gateway is unreachable, slow, or returns
 * something that fails validation, the raw text is truncated instead: a
 * title is still better than none, and this must never throw out of the
 * agent_settled handler.
 *
 * The credentials are read from the agent directory pi itself resolves
 * (getAgentDir(): ~/.mash/pi/agent inside Mash), never from ~/.pi/agent, so a
 * Mash pane can never pick up the owner's own pi configuration.
 *
 * Model: ollama-cloud/gemma4:31b — about 1.1–1.5s against this gateway, the
 * fastest and most deterministic of the candidates tried; the auto/cheap and
 * auto/fast meta-aliases routed to an unstable backend at 10–13s with
 * occasional empty replies. OMNIROUTE_TITLE_MODEL overrides it.
 *
 * Format follows Pi's own title convention, `π - <text>`, truncating the body
 * to 37 chars + "…" once it exceeds 40.
 */

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { getAgentDir, type ExtensionAPI, type SessionEntry } from "@earendil-works/pi-coding-agent";

const MAX_LABEL_WORDS = 5;
const MAX_LABEL_CHARS = 55;
const TITLE_PREFIX = "π - ";
const TITLE_TRUNCATE_AT = 40;
const TITLE_KEEP_CHARS = 37;
const COMPRESS_MODEL = process.env.OMNIROUTE_TITLE_MODEL || "ollama-cloud/gemma4:31b";
const COMPRESS_TIMEOUT_MS = 4_000;

interface OmniRouteCreds {
	serverUrl: string;
	apiKey: string;
}

function loadOmniRouteCreds(): OmniRouteCreds | undefined {
	try {
		const path = join(getAgentDir(), "extensions", "pi-omniroute-sync", "settings.json");
		const raw = JSON.parse(readFileSync(path, "utf8"));
		if (typeof raw.serverUrl !== "string" || !raw.serverUrl) return undefined;
		if (typeof raw.apiKey !== "string" || !raw.apiKey) return undefined;
		return { serverUrl: raw.serverUrl.replace(/\/+$/, ""), apiKey: raw.apiKey };
	} catch {
		return undefined; // pi-omniroute-sync not installed/configured — compression is optional
	}
}

function acceptableLabel(text: string): boolean {
	if (!text || text.length > MAX_LABEL_CHARS) return false;
	if (text.includes("?") || text.includes("\n")) return false;
	return text.split(/\s+/).length <= MAX_LABEL_WORDS;
}

async function compress(text: string, creds: OmniRouteCreds): Promise<string | undefined> {
	const controller = new AbortController();
	const timer = setTimeout(() => controller.abort(), COMPRESS_TIMEOUT_MS);
	try {
		const res = await fetch(`${creds.serverUrl}/v1/chat/completions`, {
			method: "POST",
			headers: {
				Authorization: `Bearer ${creds.apiKey}`,
				"Content-Type": "application/json",
			},
			body: JSON.stringify({
				model: COMPRESS_MODEL,
				messages: [
					{
						role: "user",
						content:
							"Compress the following into a short terminal tab title: at most " +
							`${MAX_LABEL_WORDS} words, lowercase, no punctuation, no quotes. ` +
							"Output only the compressed title, nothing else.\n\n" +
							text.slice(0, 2000),
					},
				],
				max_tokens: 20,
				stream: false,
			}),
			signal: controller.signal,
		});
		if (!res.ok) return undefined;
		const data = await res.json();
		const content = data?.choices?.[0]?.message?.content;
		if (typeof content !== "string") return undefined;
		const label = content.trim().toLowerCase().replace(/["'.]/g, "");
		return acceptableLabel(label) ? label : undefined;
	} catch {
		return undefined; // network error, timeout, malformed JSON — fall back to truncation
	} finally {
		clearTimeout(timer);
	}
}

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
		if (!text) return; // no assistant text yet (e.g. a tool-only turn) — retry next agent_settled
		titled = true; // claim the one-shot slot before the network call, not after
		const creds = loadOmniRouteCreds();
		const label = creds ? await compress(text, creds) : undefined;
		ctx.ui.setTitle(formatTitle(label ?? text));
	});
}
