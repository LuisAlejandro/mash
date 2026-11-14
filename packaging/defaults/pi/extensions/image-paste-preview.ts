/**
 * Image Paste Preview
 *
 * Pi's clipboard paste never shows a thumbnail: `Ctrl+V` writes the clipboard
 * image to `$TMPDIR/pi-clipboard-<uuid>.png` and inserts that path as plain
 * text into the prompt editor. Images render only in the transcript, as image
 * content blocks (after the model reads the file).
 *
 * This widget closes that gap. It sits below the editor, reads
 * `ctx.ui.getEditorText()` on every frame, and renders any image path it finds
 * through the TUI `Image` component, so a paste shows pixels immediately.
 *
 * Why a widget and not a custom editor: `setEditorComponent` replaces the whole
 * editor component, which has to be chained carefully to coexist with any other
 * extension that replaces it. A widget composes and renders nothing while the
 * editor holds no image path.
 *
 * Rendering runs every frame, so the per-path cache matters: a file's bytes are
 * read once per mtime and the `Image` instance is reused, which keeps its
 * already-uploaded kitty graphics payload from being re-sent on each redraw.
 */
import { existsSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename } from "node:path";

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Image } from "@earendil-works/pi-tui";

import { findImagePaths, mimeTypeForPath } from "./lib/image-paths.ts";

const WIDGET_KEY = "image-paste-preview";
/** A paste is normally one image; cap what a hand-typed wall of paths can draw. */
const MAX_PREVIEWS = 3;
const MAX_WIDTH_CELLS = 48;
const MAX_HEIGHT_CELLS = 12;

interface CachedImage {
  mtimeMs: number;
  image: Image;
}

export default function imagePastePreview(pi: ExtensionAPI) {
  pi.on("session_start", async (_event, ctx) => {
    if (ctx.mode !== "tui") return;

    ctx.ui.setWidget(
      WIDGET_KEY,
      (_tui, theme) => {
        const cache = new Map<string, CachedImage>();

        return {
          render(width: number): string[] {
            const paths = findImagePaths(ctx.ui.getEditorText(), {
              cwd: ctx.cwd,
              home: homedir(),
              exists: existsSync,
            }).slice(0, MAX_PREVIEWS);

            const lines: string[] = [];
            for (const path of paths) {
              let mtimeMs: number;
              try {
                mtimeMs = statSync(path).mtimeMs;
              } catch {
                continue;
              }
              let cached = cache.get(path);
              if (!cached || cached.mtimeMs !== mtimeMs) {
                try {
                  cached = {
                    mtimeMs,
                    image: new Image(
                      readFileSync(path).toString("base64"),
                      mimeTypeForPath(path),
                      { fallbackColor: (text: string) => theme.fg("dim", text) },
                      {
                        maxWidthCells: MAX_WIDTH_CELLS,
                        maxHeightCells: MAX_HEIGHT_CELLS,
                        filename: basename(path),
                      },
                    ),
                  };
                  cache.set(path, cached);
                } catch {
                  continue;
                }
              }
              lines.push(theme.fg("dim", ` ${basename(path)}`));
              lines.push(...cached.image.render(width));
            }

            // Drop images whose path left the editor, so the cache follows the text.
            for (const path of cache.keys()) {
              if (!paths.includes(path)) cache.delete(path);
            }

            return lines;
          },

          invalidate() {
            for (const cached of cache.values()) cached.image.invalidate();
          },
        };
      },
      { placement: "belowEditor" },
    );
  });
}
