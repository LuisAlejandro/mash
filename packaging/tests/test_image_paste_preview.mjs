// The image-paste-preview extension must find image paths in the prompt editor
// and render them, because pi's own Ctrl+V paste leaves only a temp-file path
// in the editor. Two halves:
//
//   1. Path detection (always): `@` mentions, quotes, `~`, relative paths that
//      resolve against the cwd, dedupe, existence filtering.
//   2. Widget rendering (needs a staged pin): the extension imports
//      `@earendil-works/pi-tui`, which resolves through pi's loader aliases at
//      runtime and through a symlink here. Without a pin this half is skipped.
//
//   node test_image_paste_preview.mjs [<pi-coding-agent package dir>]
import assert from "node:assert/strict";
import { cpSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const extensions = join(here, "../defaults/pi/extensions");

let paths;
try {
  paths = await import(pathToFileURL(join(extensions, "lib/image-paths.ts")).href);
} catch (error) {
  // Type stripping in `.ts` imports needs node >= 24.
  console.log(`skip - cannot import the extension's .ts helper: ${error.message}`);
  process.exit(77);
}

const options = {
  cwd: "/work/project",
  home: "/home/me",
  exists: (path) =>
    ["/tmp/pi-clipboard-1.png", "/work/project/shots/a.jpg", "/home/me/pic.jpg", "/tmp/b.webp"].includes(path),
};

assert.deepEqual(
  paths.findImagePaths("what is this /tmp/pi-clipboard-1.png", options),
  ["/tmp/pi-clipboard-1.png"],
  "the path pi pastes is found",
);
assert.deepEqual(paths.findImagePaths("@shots/a.jpg please", options), ["/work/project/shots/a.jpg"], "@ mention resolves to cwd");
assert.deepEqual(paths.findImagePaths('see "~/pic.jpg"', options), ["/home/me/pic.jpg"], "quoted tilde path resolves to home");
assert.deepEqual(
  paths.findImagePaths("/tmp/pi-clipboard-1.png and /tmp/b.webp", options),
  ["/tmp/pi-clipboard-1.png", "/tmp/b.webp"],
  "multiple paths in order",
);
assert.deepEqual(paths.findImagePaths("/tmp/pi-clipboard-1.png /tmp/pi-clipboard-1.png", options), ["/tmp/pi-clipboard-1.png"], "deduped");
assert.deepEqual(paths.findImagePaths("/tmp/notes.txt and /tmp/missing.png", options), [], "non-image and missing files ignored");
assert.equal(paths.mimeTypeForPath("/a/b.JPEG"), "image/jpeg", "uppercase extension");
assert.equal(paths.mimeTypeForPath("/a/b.unknown"), "image/png", "fallback mime");
console.log("image paste preview: path detection ok");

const pi = process.argv[2];
if (!pi) {
  console.log("skip - widget rendering needs a staged pin: test_pi_runtime.sh <resource-root>");
  process.exit(0);
}

const ONE_PIXEL_PNG =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==";

const agentDir = mkdtempSync(join(tmpdir(), "mash-paste-preview-"));
try {
  cpSync(extensions, join(agentDir, "extensions"), { recursive: true });
  mkdirSync(join(agentDir, "node_modules/@earendil-works"), { recursive: true });
  symlinkSync(
    resolve(pi, "node_modules/@earendil-works/pi-tui"),
    join(agentDir, "node_modules/@earendil-works/pi-tui"),
  );

  const imagePath = join(agentDir, "pi-clipboard-fixture.png");
  writeFileSync(imagePath, Buffer.from(ONE_PIXEL_PNG, "base64"));

  const { default: imagePastePreview } = await import(pathToFileURL(join(agentDir, "extensions/image-paste-preview.ts")).href);

  const handlers = {};
  imagePastePreview({ on: (name, handler) => (handlers[name] = handler) });
  assert.ok(handlers.session_start, "registers a session_start handler");

  let widget;
  let placement;
  let editorText = "";
  const ctx = {
    mode: "tui",
    cwd: agentDir,
    ui: {
      getEditorText: () => editorText,
      setWidget: (_key, content, widgetOptions) => {
        placement = widgetOptions.placement;
        widget = content({}, { fg: (_color, text) => text });
      },
    },
  };

  // A non-TUI session must not claim the widget slot.
  const plain = { ...ctx, mode: "print", ui: { getEditorText: () => editorText, setWidget: () => assert.fail("no widget outside tui") } };
  await handlers.session_start({}, plain);

  await handlers.session_start({}, ctx);
  assert.equal(placement, "belowEditor", "widget renders below the editor");
  assert.deepEqual(widget.render(80), [], "an empty editor renders nothing");

  editorText = `what is this ${imagePath}`;
  const preview = widget.render(80);
  assert.ok(preview.length > 1, `an image path renders image rows, got ${preview.length}`);
  assert.ok(preview[0].includes("pi-clipboard-fixture.png"), "the caption names the file");

  editorText = "no image here";
  assert.deepEqual(widget.render(80), [], "the preview leaves when the path does");

  editorText = `again ${imagePath}`;
  assert.ok(widget.render(80).length > 1, "re-pasting brings the preview back");
  widget.invalidate();

  console.log("image paste preview: widget rendering ok");
} finally {
  rmSync(agentDir, { recursive: true, force: true });
}
