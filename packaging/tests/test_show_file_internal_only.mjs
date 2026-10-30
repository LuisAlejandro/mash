// show_file only opens internal Fresh or Herdr surfaces; never a desktop app.
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { registerHooks } from "node:module";

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
  const report = join(dir, "report.md");
  const pdf = join(dir, "report.pdf");
  const log = join(dir, "external-opener");
  const herdr = join(dir, "herdr");
  for (const path of [image, report, pdf]) writeFileSync(path, "test file");
  writeFileSync(herdr, `#!/bin/sh
if [ "$1 $2 $3" = "plugin pane open" ] && [ "${'${IMAGE_POPUP_OK:-0}'}" = 1 ]; then exit 0; fi
echo "Herdr pane unavailable" >&2
exit 1
`);
  chmodSync(herdr, 0o755);
  // A successful external opener makes any accidental fallback visible to the test.
  for (const command of ["open", "qlmanage", "xdg-open"]) {
    const path = join(dir, command);
    writeFileSync(path, '#!/bin/sh\nprintf "%s\\n" "$0 $*" >> "$OPEN_LOG"\n');
    chmodSync(path, 0o755);
  }
  process.env.PATH = `${dir}:${process.env.PATH}`;
  process.env.HERDR_BIN_PATH = herdr;
  process.env.HERDR_PANE_ID = "test-pane";
  process.env.OPEN_LOG = log;

  const { default: register } = await import(
    process.env.MASH_SHOW_FILE_EXTENSION ?? new URL("../defaults/pi/extensions/show-file.ts", import.meta.url)
  );
  let tool;
  register({ registerTool(value) { tool = value; } });
  assert.match(tool.description, /No external app is opened/);
  assert.ok(tool.promptGuidelines.some((guideline) => guideline.includes("do not describe the file")));
  for (const path of [image, report, pdf]) {
    const result = await tool.execute("test", { path });
    assert.equal(result.isError, true, `should not claim to show ${path}`);
    assert.match(result.content[0].text, /Not shown:/);
    assert.equal(existsSync(log), false, `opened a desktop app for ${path}`);
  }

  // The internal image viewer still works when available.
  process.env.IMAGE_POPUP_OK = "1";
  const shown = await tool.execute("test", { path: image });
  assert.equal(shown.isError, false);
  assert.match(shown.content[0].text, /Shown:/);
  assert.equal(existsSync(log), false);
  console.log("show_file internal-only image/text/other paths: ok");
} finally {
  for (const key of ["PATH", "HERDR_BIN_PATH", "HERDR_PANE_ID", "OPEN_LOG", "IMAGE_POPUP_OK"]) {
    if (env[key] === undefined) delete process.env[key];
    else process.env[key] = env[key];
  }
  rmSync(dir, { recursive: true, force: true });
}
