/**
 * ask_coordinator delivers a worker question to the Herdr orchestration inbox.
 *
 * Herdr's own agent prompt only pastes text. The reply has to come back as
 * this tool's result. While the call is open, herdr:blocked is the same event
 * herdr-agent-state.ts already turns into a blocked pane. A pane with no open
 * Dispatch is the coordinator: ask_user still talks to the person there.
 */

import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const PLACEHOLDER = /\{([A-Za-z_][A-Za-z0-9_]*)\}/g;
const catalogs = new Map<string, Record<string, unknown>>();

function i18nDirectories(): string[] {
	const dirs: string[] = [];
	const configured = (process.env.MASH_I18N_DIR || "").trim();
	if (configured) dirs.push(configured);
	const beside = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "i18n");
	if (!dirs.includes(beside) && existsSync(join(beside, "languages.json"))) dirs.push(beside);
	return dirs;
}

function catalog(dir: string, code: string): Record<string, unknown> {
	const cacheKey = `${dir}\0${code}`;
	const cached = catalogs.get(cacheKey);
	if (cached) return cached;
	let data: Record<string, unknown> = {};
	try {
		const loaded = JSON.parse(readFileSync(join(dir, "messages", "pi", `${code}.json`), "utf8"));
		if (loaded && typeof loaded === "object") data = loaded;
	} catch {
		data = {};
	}
	catalogs.set(cacheKey, data);
	return data;
}

function entryText(entry: unknown): string | undefined {
	if (typeof entry === "string" && entry) return entry;
	if (entry && typeof entry === "object" && "text" in entry) {
		const text = (entry as { text?: unknown }).text;
		if (typeof text === "string" && text) return text;
	}
	return undefined;
}

function t(key: string, values: Record<string, string> = {}): string {
	const language = (process.env.MASH_LANGUAGE || "en").trim() || "en";
	const codes = language === "en" ? ["en"] : [language, "en"];
	let text: string | undefined;
	for (const code of codes) {
		for (const dir of i18nDirectories()) {
			text = entryText(catalog(dir, code)[key]);
			if (text) break;
		}
		if (text) break;
	}
	if (!text) return key;
	return text.replace(PLACEHOLDER, (match, name: string) =>
		Object.prototype.hasOwnProperty.call(values, name) ? values[name] : match,
	);
}

const DEFAULT_TIMEOUT_MS = 600_000;

function orchestrationBin(): string {
	return process.env.MASH_ORCHESTRATION_BIN || "mash-orchestration";
}

function runCli(
	args: string[],
	signal: AbortSignal | undefined,
): Promise<{ code: number; stdout: string; stderr: string }> {
	return new Promise((resolve, reject) => {
		const child = spawn(orchestrationBin(), args, { env: process.env });
		let stdout = "";
		let stderr = "";
		const onAbort = () => child.kill("SIGTERM");
		signal?.addEventListener("abort", onAbort);
		child.stdout.setEncoding("utf8");
		child.stderr.setEncoding("utf8");
		child.stdout.on("data", (chunk: string) => {
			stdout += chunk;
		});
		child.stderr.on("data", (chunk: string) => {
			stderr += chunk;
		});
		child.on("error", (error) => {
			signal?.removeEventListener("abort", onAbort);
			reject(error);
		});
		child.on("close", (code) => {
			signal?.removeEventListener("abort", onAbort);
			resolve({ code: code ?? 1, stdout, stderr });
		});
	});
}

function textResult(text: string, isError = false) {
	return {
		content: [{ type: "text" as const, text }],
		details: { text },
		isError,
	};
}

function parseJson(raw: string): Record<string, unknown> | undefined {
	try {
		const parsed = JSON.parse(raw);
		return parsed && typeof parsed === "object" ? (parsed as Record<string, unknown>) : undefined;
	} catch {
		return undefined;
	}
}

export default function (pi: ExtensionAPI) {
	pi.registerTool({
		name: "ask_coordinator",
		label: t("pi.orchestration.label"),
		description:
			"Ask the Herdr orchestration coordinator one question and wait for its reply. Use this only while this pane has an open Dispatch. If this pane has no Dispatch, the tool returns an error: ask the person with ask_user instead.",
		promptSnippet:
			"Ask the orchestration coordinator one question when this pane is a dispatched worker",
		promptGuidelines: [
			"Call ask_coordinator only from a dispatched worker pane. Ask one question per call.",
			"If ask_coordinator says this pane has no open Dispatch, ask the person with ask_user.",
			"Do not answer a coordinator question by typing into a pane with herdr agent send-keys.",
			"A pending result names a message id. Call ask_coordinator again with resume set to that id. Do not create a second question.",
		],
		executionMode: "sequential",
		parameters: Type.Object({
			question: Type.String({ description: "The question the coordinator must answer" }),
			options: Type.Optional(
				Type.Array(Type.String(), { description: "Choices the coordinator may pick from" }),
			),
			resume: Type.Optional(
				Type.String({ description: "Message id of a question that is already pending" }),
			),
			timeoutMs: Type.Optional(
				Type.Number({ description: "How long to wait for a reply before returning pending" }),
			),
		}),
		async execute(_toolCallId, params, signal, _onUpdate, _ctx) {
			if (signal?.aborted) {
				return textResult(t("pi.orchestration.cancelled"), true);
			}
			let lookup;
			try {
				lookup = await runCli(["dispatch-for-pane"], signal);
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				return textResult(t("pi.orchestration.unavailable", { message }), true);
			}
			const found = parseJson(lookup.stdout);
			if (lookup.code !== 0 || !found) {
				const err = parseJson(lookup.stderr);
				const message = typeof err?.error === "string" ? err.error : lookup.stderr.trim();
				return textResult(message || t("pi.orchestration.lookup-failed"), true);
			}
			if (!found.dispatch) {
				return textResult(t("pi.orchestration.no-dispatch"), true);
			}

			const args = ["ask", "--question", params.question];
			if (params.options && params.options.length > 0) {
				args.push("--options-json", JSON.stringify(params.options));
			}
			if (params.resume) {
				args.push("--resume", params.resume);
			}
			const timeout = params.timeoutMs ?? DEFAULT_TIMEOUT_MS;
			args.push("--timeout-ms", String(timeout));

			let announced = false;
			try {
				pi.events.emit("herdr:blocked", { active: true, label: t("pi.orchestration.waiting") });
				announced = true;
				const result = await runCli(args, signal);
				if (signal?.aborted) {
					return textResult(t("pi.orchestration.cancelled"), true);
				}
				const body = parseJson(result.code === 0 ? result.stdout : result.stderr);
				if (result.code !== 0 || !body) {
					const message = typeof body?.error === "string" ? body.error : result.stderr.trim();
					return textResult(message || t("pi.orchestration.failed"), true);
				}
				if (body.status === "answered") {
					return textResult(t("pi.orchestration.answered", { reply: String(body.reply ?? "") }));
				}
				return textResult(t("pi.orchestration.pending", { id: String(body.id) }));
			} finally {
				if (announced) {
					pi.events.emit("herdr:blocked", { active: false });
				}
			}
		},
	});
}
