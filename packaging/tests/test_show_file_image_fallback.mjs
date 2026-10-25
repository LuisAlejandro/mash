// When the image-popup manifest is missing, show_file must still open the image.
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { registerHooks } from "node:module";

// The tool only needs TypeBox to declare its parameter schema.
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === "typebox") {
      return {
        url: "data:text/javascript,export const Type={Object:()=>({}),String:()=>({}),Optional:()=>({}),Number:()=>({})}",
        shortCircuit: true,
      };
    }
    return nextResolve(specifier, context);
  },
});

const dir = mkdtempSync(join(tmpdir(), "mash-show-file-"));
const env = { ...process.env };
try {
  const image = join(dir, "result.png");
  const log = join(dir, "preview-path");
  const herdr = join(dir, "herdr");
  const open = join(dir, "open");
  writeFileSync(image, "test image");
  writeFileSync(herdr, '#!/bin/sh\nif [ "$1 $2 $3" = "plugin pane open" ]; then echo "plugin image-popup manifest is unavailable" >&2; fi\nexit 1\n');
  writeFileSync(open, '#!/bin/sh\n[ "$1" = "-a" ] && [ "$2" = "Preview" ] || exit 2\nprintf "%s" "$3" > "$OPEN_LOG"\nexit "${OPEN_CODE:-0}"\n');
  chmodSync(herdr, 0o755);
  chmodSync(open, 0o755);
  process.env.PATH = `${dir}:${process.env.PATH}`;
  process.env.HERDR_BIN_PATH = herdr;
  process.env.HERDR_PANE_ID = "test-pane";
  process.env.OPEN_LOG = log;

  const { default: register } = await import(new URL("../defaults/pi/extensions/show-file.ts", import.meta.url));
  let tool;
  register({ registerTool(value) { tool = value; } });
  const result = await tool.execute("test", { path: image, note: "A screenshot" });
  assert.match(result.content[0].text, /opened in Preview instead/);
  assert.equal(readFileSync(log, "utf8"), image);

  process.env.OPEN_CODE = "1";
  const failure = await tool.execute("test", { path: image });
  // The message names a path on every platform: the tool no longer assumes a
  // macOS-only opener, so the test asserts the path rather than qlmanage.
  assert.match(failure.content[0].text, /The person can open it with: \//);
  console.log("show_file image fallback: ok");
} finally {
  for (const key of ["PATH", "HERDR_BIN_PATH", "HERDR_PANE_ID", "OPEN_LOG", "OPEN_CODE"]) {
    if (env[key] === undefined) delete process.env[key];
    else process.env[key] = env[key];
  }
  rmSync(dir, { recursive: true, force: true });
}
