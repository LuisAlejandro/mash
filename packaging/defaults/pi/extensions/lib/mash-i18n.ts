// Mash's message catalogs for its Pi extensions.
//
// Lives in a subdirectory without an index.ts, so Pi does not load it as an
// extension of its own; the extensions beside it import it.
//
// The catalogs are found through MASH_I18N_DIR, which mash_isolate in lib.sh
// always sets to the staged tree, and, in the source tree, beside this file.
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const PLACEHOLDER = /\{([A-Za-z_][A-Za-z0-9_]*)\}/g;
const catalogs = new Map<string, Record<string, unknown>>();

function i18nDirectories(): string[] {
	const dirs: string[] = [];
	const configured = (process.env.MASH_I18N_DIR || "").trim();
	if (configured) dirs.push(configured);
	// packaging/defaults/pi/extensions/lib -> packaging/i18n
	const beside = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "..", "i18n");
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

/** The message for `key` in MASH_LANGUAGE, else English, else the key itself. */
export function t(key: string, values: Record<string, string> = {}): string {
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
