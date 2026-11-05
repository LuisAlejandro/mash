/**
 * Replaces the built-in pi header (logo + keybinding hints) with custom ASCII art.
 *
 * Art is read from `header-art.ansi` next to this file. The keybinding list is
 * `keybindings-quickref.txt` in the same directory.
 *
 * Apply with /reload; revert with /builtin-header.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const COLOR = "muted";

const ART = ["[MASH]"];

const ART_FILE = "header-art.ansi";

function here(): string {
	return dirname(fileURLToPath(import.meta.url));
}

function loadArt(): string[] {
	try {
		const lines = readFileSync(join(here(), ART_FILE), "utf8")
			.split("\n")
			.filter((line) => line.length > 0);
		return lines.length > 0 ? lines : ART;
	} catch {
		return ART;
	}
}

function loadQuickref(): string[] {
	try {
		// mash-seed-sync writes this pane's language, mode and platform into this file.
		return readFileSync(join(here(), "keybindings-quickref.txt"), "utf8")
			.split("\n")
			.filter((line) => line.length > 0);
	} catch {
		return [];
	}
}

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

export default function (pi: ExtensionAPI) {
	pi.on("session_start", async (_event, ctx) => {
		if (ctx.mode !== "tui") return;
		ctx.ui.setHeader((_tui, theme) => {
			const art = loadArt();
			const quickref = loadQuickref();
			return {
				render(_width: number): string[] {
					return [...art, ...quickref].map((line) =>
						line.includes("\x1b") ? line : theme.fg(COLOR, line),
					);
				},
				invalidate() {},
			};
		});
	});

	pi.registerCommand("builtin-header", {
		description: t("pi.header.restore"),
		handler: async (_args, ctx) => {
			ctx.ui.setHeader(undefined);
			ctx.ui.notify(t("pi.header.restored"), "info");
		},
	});
}
