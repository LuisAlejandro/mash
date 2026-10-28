// An SVG is XML, not a decodable image: the image popup runs `viu`, which
// rejects it (`Unsupported(PathExtension("svg"))`). show_file must therefore
// route it to the Fresh editor, where the markup is readable, and never to the
// image pane.
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

const dir = mkdtempSync(join(tmpdir(), "mash-show-file-svg-"));
const env = { ...process.env };
try {
  const svg = join(dir, "banner.svg");
  const calls = join(dir, "herdr-calls");
  const herdr = join(dir, "herdr");
  writeFileSync(svg, '<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>\n');

  // Record every herdr invocation, and answer the two lookups the text path
  // makes: the tab's pane list, and the Fresh pane's own id.
  writeFileSync(
    herdr,
    `#!/bin/sh
printf '%s\\n' "$*" >> "$HERDR_CALLS"
case "$1 $2" in
"pane layout")
  printf '{"result":{"panes":[{"pane_id":"w1:p1","foreground":"fresh"},{"pane_id":"w1:p2","foreground":"pi"}]}}'
  ;;
"pane run") exit 0 ;;
esac
exit 0
`,
  );
  chmodSync(herdr, 0o755);
  process.env.HERDR_BIN_PATH = herdr;
  process.env.HERDR_PANE_ID = "w1:p2";
  process.env.HERDR_CALLS = calls;

  const { default: register } = await import(
    new URL("../defaults/pi/extensions/show-file.ts", import.meta.url)
  );
  let tool;
  register({
    registerTool(value) {
      tool = value;
    },
  });

  const result = await tool.execute("test", { path: svg, note: "A banner" });
  const text = result.content[0].text;
  const invocations = readFileSync(calls, "utf8");

  // The image popup must never be asked to decode an SVG.
  assert.ok(
    !invocations.includes("image-popup"),
    `an SVG was sent to the image popup:\n${invocations}`,
  );
  assert.doesNotMatch(text, /image popup/i, text);

  // It belongs in the editor instead.
  assert.match(text, /Fresh|editor/i, text);

  console.log("show_file routes SVG to the editor, not the image pane: ok");
} finally {
  for (const key of ["HERDR_BIN_PATH", "HERDR_PANE_ID", "HERDR_CALLS"]) {
    if (env[key] === undefined) delete process.env[key];
    else process.env[key] = env[key];
  }
  rmSync(dir, { recursive: true, force: true });
}
