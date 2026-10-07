/**
 * ask_coordinator delivers a worker question to the Herdr orchestration inbox.
 *
 * Herdr's own agent prompt only pastes text. The reply has to come back as
 * this tool's result. While the call is open, herdr:blocked is the same event
 * herdr-agent-state.ts already turns into a blocked pane. A pane with no open
 * Dispatch is the coordinator: ask_user still talks to the person there.
 */

import { spawn } from "node:child_process";

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const DEFAULT_TIMEOUT_MS = 600_000;

function orchestrationBin(): string {
	return process.env.HERDR_ORCHESTRATION_BIN || "herdr-orchestration";
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
		label: "Ask coordinator",
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
				return textResult("The question was cancelled.", true);
			}
			let lookup;
			try {
				lookup = await runCli(["dispatch-for-pane"], signal);
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				return textResult(
					`herdr-orchestration is not available (${message}). Ask the person with ask_user.`,
					true,
				);
			}
			const found = parseJson(lookup.stdout);
			if (lookup.code !== 0 || !found) {
				const err = parseJson(lookup.stderr);
				const message = typeof err?.error === "string" ? err.error : lookup.stderr.trim();
				return textResult(message || "Could not look up the Dispatch.", true);
			}
			if (!found.dispatch) {
				return textResult(
					"No open Dispatch for this pane. Ask the person with ask_user.",
					true,
				);
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
				pi.events.emit("herdr:blocked", { active: true, label: "Waiting for coordinator" });
				announced = true;
				const result = await runCli(args, signal);
				if (signal?.aborted) {
					return textResult("The question was cancelled.", true);
				}
				const body = parseJson(result.code === 0 ? result.stdout : result.stderr);
				if (result.code !== 0 || !body) {
					const message = typeof body?.error === "string" ? body.error : result.stderr.trim();
					return textResult(message || "The coordinator question failed.", true);
				}
				if (body.status === "answered") {
					return textResult(`Coordinator answered: ${String(body.reply ?? "")}`);
				}
				return textResult(
					`Question ${String(body.id)} is still pending. Call ask_coordinator again with resume set to that id.`,
				);
			} finally {
				if (announced) {
					pi.events.emit("herdr:blocked", { active: false });
				}
			}
		},
	});
}
