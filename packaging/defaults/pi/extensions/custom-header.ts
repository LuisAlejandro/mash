/**
 * Replaces the built-in pi header (logo + keybinding hints) with custom ASCII art.
 *
 * Art is read from `header-art.ansi` next to this file. The keybinding list is
 * `keybindings-quickref.txt` in the same directory.
 *
 * Apply with /reload; revert with /builtin-header.
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const COLOR = "accent";

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
		return readFileSync(join(here(), "keybindings-quickref.txt"), "utf8")
			.split("\n")
			.filter((line) => line.length > 0);
	} catch {
		return [];
	}
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
		description: "Restore the built-in pi header",
		handler: async (_args, ctx) => {
			ctx.ui.setHeader(undefined);
			ctx.ui.notify("Built-in header restored", "info");
		},
	});
}
