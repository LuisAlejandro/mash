/**
 * Path detection for the image-paste-preview extension.
 *
 * Kept out of the extension file so `packaging/tests/test_image_paste_preview.mjs`
 * can exercise it without loading pi.
 */
import { isAbsolute, join, resolve } from "node:path";

const MIME_BY_EXT: Record<string, string> = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  bmp: "image/bmp",
};

/** One whitespace-delimited token ending in a supported image extension. */
const IMAGE_TOKEN = /[^\s"'`]+\.(?:png|jpe?g|gif|webp|bmp)(?=$|[\s"'`),;:])/gi;

export interface FindImagePathsOptions {
  cwd: string;
  home: string;
  /** Injected so the check does not touch the filesystem. */
  exists: (path: string) => boolean;
}

export function mimeTypeForPath(path: string): string {
  const ext = path.slice(path.lastIndexOf(".") + 1).toLowerCase();
  return MIME_BY_EXT[ext] ?? "image/png";
}

/** Absolute paths of existing image files mentioned in the editor text, in order, deduped. */
export function findImagePaths(text: string, options: FindImagePathsOptions): string[] {
  const found: string[] = [];
  for (const match of text.matchAll(IMAGE_TOKEN)) {
    // `@` is pi's file-mention syntax; the path after it is what matters.
    const raw = match[0].replace(/^[@]/, "");
    if (!raw) continue;
    const absolute = raw.startsWith("~/")
      ? join(options.home, raw.slice(2))
      : isAbsolute(raw)
        ? raw
        : resolve(options.cwd, raw);
    if (found.includes(absolute)) continue;
    if (options.exists(absolute)) found.push(absolute);
  }
  return found;
}
