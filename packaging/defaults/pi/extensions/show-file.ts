/**
 * show_file puts a result in front of the person instead of describing it.
 *
 * A task that produces a report, a log, a chart or a screenshot used to end as
 * a paragraph of prose. This tool hands the file to whatever can actually
 * display it, and says where it went.
 *
 * Three channels, chosen by what the file is made of:
 *
 *   text  (.md, logs, source, csv, json, svg ...) -> the Fresh editor beside
 *         this pane, with an optional note attached. Fresh renders it properly:
 *         syntax, line numbers, the lot. SVG belongs here rather than with the
 *         images: it is XML, and `viu` cannot decode it.
 *
 *   image (png, jpg, gif, webp ...)           -> a vertical split beside the
 *         editor, drawn with real pixels. Fresh cannot do this -- it is a text
 *         editor, and an image opened in it is a hex dump. The split is a
 *         Herdr plugin pane running `viu`, which emits the Kitty graphics
 *         protocol and gets a real picture back.
 *
 *   anything else                             -> the desktop's own handler
 *         (`qlmanage` on macOS, `xdg-open` on Linux),
 *         which previews PDFs and everything else the terminal cannot.
 *
 * The lookup that makes this work: the Fresh pane to send to is the one beside
 * this pane. Herdr sets HERDR_PANE_ID on this process, `herdr pane layout`
 * lists the tab's panes, and the first whose foreground process is `fresh` is
 * the editor. That is the same resolution telescope-files uses for cmd+p.
 *
 * Everything here is best-effort by design. A tool that fails loudly about a
 * missing editor is worse than the prose it replaced, so each channel falls
 * back to the next and the result always says what actually happened.
 */

import { spawn } from "node:child_process";
import { existsSync, statSync } from "node:fs";
import { basename, extname, isAbsolute, resolve } from "node:path";

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

// Raster formats only. SVG is deliberately absent: it is XML, and the image
// popup decodes with `viu`, which rejects it outright
// (`Unsupported(PathExtension("svg"))`). It is listed as text below, where the
// editor shows the markup the person can actually read and edit.
const IMAGE_EXTENSIONS = new Set([
	"png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "ico", "avif",
]);

const TEXT_EXTENSIONS = new Set([
	"md", "markdown", "txt", "log", "csv", "tsv", "json", "jsonl", "yaml", "yml", "toml",
	"rs", "ts", "tsx", "js", "jsx", "py", "sh", "bash", "zsh", "go", "rb", "java", "kt",
	"c", "h", "cpp", "hpp", "css", "scss", "html", "xml", "svg", "sql", "zig", "swift", "lua",
	"diff", "patch", "ini", "cfg", "env",
]);

function textResult(text: string, isError = false) {
	return {
		content: [{ type: "text" as const, text }],
		details: { text },
		isError,
	};
}

function run(
	command: string,
	args: string[],
	opts: { cwd?: string; env?: NodeJS.ProcessEnv; timeoutMs?: number } = {},
): Promise<{ code: number; stdout: string; stderr: string }> {
	return new Promise((resolvePromise) => {
		const child = spawn(command, args, {
			cwd: opts.cwd,
			env: opts.env ?? process.env,
		});
		let stdout = "";
		let stderr = "";
		const timer = opts.timeoutMs
			? setTimeout(() => child.kill("SIGTERM"), opts.timeoutMs)
			: undefined;
		child.stdout.setEncoding("utf8");
		child.stderr.setEncoding("utf8");
		child.stdout.on("data", (c: string) => (stdout += c));
		child.stderr.on("data", (c: string) => (stderr += c));
		child.on("error", (error) => {
			if (timer) clearTimeout(timer);
			resolvePromise({ code: 127, stdout, stderr: String(error) });
		});
		child.on("close", (code) => {
			if (timer) clearTimeout(timer);
			resolvePromise({ code: code ?? 1, stdout, stderr });
		});
	});
}

function herdrBin(): string {
	return process.env.HERDR_BIN_PATH || "herdr";
}

function freshBin(): string {
	// Mash ships Fresh inside the bundle and wraps it in `fresh`, which refuses
	// to start outside Mash's environment. The wrapper is on PATH inside a pane.
	return process.env.MASH_FRESH_BIN || "fresh";
}

function selfPaneId(): string | undefined {
	const raw = process.env.HERDR_PANE_ID;
	return raw && raw.trim() ? raw.trim() : undefined;
}

/**
 * The pid of the pane's Fresh process, or undefined when Fresh is not there.
 *
 * `process-info` lists every foreground process in the pane, and a language
 * server that Fresh spawned sits in that list too — ahead of Fresh. Reading
 * the first `pid` out of the raw text therefore picked the language server and
 * then looked up a daemon named after it, which never exists. The entry has to
 * be selected by name.
 */
function freshPid(info: string): number | undefined {
	try {
		const processes = JSON.parse(info)?.result?.process_info?.foreground_processes;
		if (!Array.isArray(processes)) return undefined;
		for (const entry of processes) {
			if (entry?.name === "fresh" && typeof entry.pid === "number") return entry.pid;
		}
	} catch {
		// Not JSON: no editor to report.
	}
	return undefined;
}

/**
 * The pane id of the Fresh editor beside this one, or undefined when there is
 * none. Pane ids come from the tab's layout, which is scoped to the tab, so
 * this can never reach an editor in another tab.
 */
async function freshPaneBeside(): Promise<string | undefined> {
	const origin = selfPaneId();
	if (!origin) return undefined;

	const layout = await run(herdrBin(), ["pane", "layout", "--pane", origin], { timeoutMs: 5000 });
	if (layout.code !== 0) return undefined;

	const ids = [...layout.stdout.matchAll(/"pane_id":"([^"]+)"/g)].map((m) => m[1]);
	// The calling pane first, so a file shown from inside Fresh reuses that
	// editor instead of splitting the tab with a second one.
	const ordered = [origin, ...ids.filter((id) => id !== origin)];

	for (const id of ordered) {
		const info = await run(herdrBin(), ["pane", "process-info", "--pane", id], { timeoutMs: 5000 });
		if (info.code !== 0) continue;
		// Only a pane whose foreground process IS Fresh counts. A pane that
		// merely ran Fresh once is not an editor.
		if (freshPid(info.stdout) === undefined) continue;
		return id;
	}
	return undefined;
}

/** The Fresh daemon session for a pane's Fresh process: `local-<pid>-<hash>`. */
async function freshSessionFor(paneId: string): Promise<string | undefined> {
	const info = await run(herdrBin(), ["pane", "process-info", "--pane", paneId], { timeoutMs: 5000 });
	if (info.code !== 0) return undefined;
	const pid = freshPid(info.stdout);
	if (pid === undefined) return undefined;

	const list = await run(freshBin(), ["--cmd", "daemon", "info"], {
		env: { ...process.env, MASH_FRESH_CONFIG_DIR: process.env.MASH_FRESH_CONFIG_DIR },
		timeoutMs: 5000,
	});
	const match = new RegExp(`local-${pid}-[A-Za-z0-9]+`).exec(list.stdout);
	return match ? match[0] : undefined;
}

function classify(path: string): "image" | "text" | "other" {
	const ext = extname(path).slice(1).toLowerCase();
	if (IMAGE_EXTENSIONS.has(ext)) return "image";
	if (TEXT_EXTENSIONS.has(ext)) return "text";
	return "other";
}

/** `path:1-6@"a note"` — Fresh's own annotation syntax, which it renders as a popup. */
function freshLocation(path: string, note: string | undefined, line?: number): string {
	const where = line ? `${path}:${line}` : path;
	return note ? `${where}@"${note.replace(/"/g, "'")}"` : where;
}


/**
 * Open a file with the desktop's own handler.
 *
 * macOS has Quick Look, which previews PDFs and everything else the terminal
 * cannot; Linux has xdg-open, which hands the file to whatever the desktop
 * registered. Both are best-effort: the file path is always reported so the
 * person can open it themselves if the handler is missing.
 */
async function openWithDesktop(path: string): Promise<{ ok: boolean; how: string }> {
	if (process.platform === "darwin") {
		const ql = await run("qlmanage", ["-p", path], { timeoutMs: 5000 });
		return { ok: ql.code === 0, how: "Quick Look" };
	}
	const opener = await run("xdg-open", [path], { timeoutMs: 5000 });
	return { ok: opener.code === 0, how: "the desktop's default application" };
}

export default function (pi: ExtensionAPI) {
	pi.registerTool({
		name: "show_file",
		label: "Show file to the person",
		description:
			"Show a file to the person you are working for, instead of describing it. " +
			"Text opens in the Fresh editor beside this pane with an optional note; an image opens as a vertical split with real pixels; anything else opens in the desktop's default application. " +
			"Use this whenever a task produces a report, a chart, a screenshot, a log or any other file the person should look at. " +
			"The result says where it went. Prefer this over pasting file contents into your reply.",
		promptSnippet: "Show a result file to the person instead of describing it",
		promptGuidelines: [
			"Call show_file with the path of a file the person should look at: a report, a chart, a screenshot, a rendered document, a log.",
			"Give `note` a short phrase naming what it is. It appears beside the file.",
			"Do not paste the file's contents into your reply after showing it. Say what it is and stop.",
			"If show_file says nothing could be shown, fall back to describing the result.",
		],
		executionMode: "sequential",
		parameters: Type.Object({
			path: Type.String({ description: "Absolute path of the file to show" }),
			note: Type.Optional(
				Type.String({ description: "Short phrase naming what this is, e.g. 'Login flow, 3 of 3 checks pass'" }),
			),
			line: Type.Optional(
				Type.Number({ description: "Line to scroll to, for text files" }),
			),
		}),

		async execute(_toolCallId, params) {
			const raw = typeof params.path === "string" ? params.path.trim() : "";
			if (!raw) return textResult("show_file needs a path.", true);

			const path = isAbsolute(raw) ? raw : resolve(process.cwd(), raw);
			if (!existsSync(path)) return textResult(`No such file: ${path}`, true);
			if (statSync(path).isDirectory()) return textResult(`${path} is a directory, not a file.`, true);

			const kind = classify(path);
			const name = basename(path);

			// --- images: a vertical split with real pixels -------------------
			// Fresh cannot render these, so there is no point looking for an
			// editor. The popup plugin draws the picture in its own pane.
			if (kind === "image") {
				const target = (await freshPaneBeside()) || selfPaneId();
				if (!target) {
					return textResult(
						`Could not find a pane to show ${name} in. The person can open it with: ${path}`,
					);
				}
				const opened = await run(herdrBin(), [
					"plugin", "pane", "open",
					"--plugin", "image-popup",
					"--entrypoint", "view",
					"--placement", "split",
					"--target-pane", target,
					"--direction", "right",
					"--env", `IMAGE_POPUP_FILE=${path}`,
					"--focus",
				], { timeoutMs: 10_000 });
				if (opened.code !== 0) {
					const detail = opened.stderr.trim() || opened.stdout.trim();
					// Preview is a macOS application. Elsewhere the desktop's own
					// handler is the equivalent, and openWithDesktop already knows
					// which one that is.
					const preview =
						process.platform === "darwin"
							? await run("open", ["-a", "Preview", path], { timeoutMs: 5000 })
							: await run("xdg-open", [path], { timeoutMs: 5000 });
					if (preview.code === 0) {
						const where = process.platform === "darwin" ? "Preview" : "the desktop's default application";
						return textResult(
							`Image popup unavailable (${detail || "no reason given"}). ${name} opened in ${where} instead.` +
								(params.note ? ` (${params.note})` : ""),
						);
					}
					return textResult(
						`Could not open the image popup (${detail || "no reason given"}). ` +
							`The person can open it with: ${path}`,
					);
				}
				return textResult(
					`Shown: ${name} is open in a vertical split beside the editor, at real resolution.` +
						(params.note ? ` (${params.note})` : ""),
				);
			}

			// --- text: the Fresh editor beside this pane --------------------
			if (kind === "text") {
				const pane = await freshPaneBeside();
				if (!pane) {
					// No editor in this tab. The desktop handler still shows the
					// file, which beats a description in prose.
					const desktop = await openWithDesktop(path);
					return textResult(
						desktop.ok
							? `No Fresh editor in this tab, so ${name} opened in ${desktop.how} instead.`
							: `No Fresh editor in this tab and ${desktop.how} failed. The person can open it with: ${path}`,
					);
				}
				const session = await freshSessionFor(pane);
				if (!session) {
					return textResult(
						`Found the Fresh pane but not its daemon. The person can open ${name} from the editor's file explorer.`,
					);
				}
				const opened = await run(freshBin(), [
					"--cmd", "daemon", "open-file", session, freshLocation(path, params.note, params.line),
				], {
					env: process.env,
					timeoutMs: 10_000,
				});
				if (opened.code !== 0) {
					return textResult(
						`Could not open ${name} in Fresh (${opened.stderr.trim() || "no reason given"}).`,
					);
				}
				return textResult(
					`Shown: ${name} is open in the Fresh editor beside this pane.` +
						(params.note ? ` (${params.note})` : ""),
				);
			}

			// --- anything else: the desktop's own handler --------------------
			const desktop = await openWithDesktop(path);
			if (desktop.ok) {
				return textResult(`Shown: ${name} opened in ${desktop.how}. (${params.note ?? kind})`);
			}
			return textResult(
				`Could not preview ${name}. The person can open it with: ${path}`,
			);
		},
	});
}
