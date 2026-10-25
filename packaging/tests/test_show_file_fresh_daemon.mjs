// show_file must resolve the daemon of the pane's Fresh process, not the pid of
// a language server Fresh happened to spawn first in that pane.
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync, chmodSync } from "node:fs";
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

const FRESH_PID = 4242;
const LSP_PID = 999;

const dir = mkdtempSync(join(tmpdir(), "mash-show-file-"));
const env = { ...process.env };
try {
  const report = join(dir, "insight.md");
  const opened = join(dir, "open-file-args");
  const herdr = join(dir, "herdr");
  const fresh = join(dir, "fresh");
  writeFileSync(report, "# Insight\n");

  const processInfo = (pane, processes) =>
    `{"result":{"process_info":{"pane_id":"${pane}","foreground_processes":${JSON.stringify(processes)}}}}`;

  writeFileSync(
    herdr,
    `#!/bin/sh
case "$1 $2" in
  "pane layout")
    echo '{"result":{"layout":{"panes":[{"pane_id":"w1:p1"},{"pane_id":"w1:p2"}]}}}' ;;
  "pane process-info")
    case "$4" in
      w1:p2) echo '${processInfo("w1:p2", [
        { name: "node", pid: LSP_PID },
        { name: "fresh", pid: FRESH_PID },
      ])}' ;;
      *) echo '${processInfo("w1:p1", [{ name: "pi", pid: 111 }])}' ;;
    esac ;;
  *) exit 2 ;;
esac
exit 0
`,
  );
  // The decoy daemon carries the language server's pid: resolving it would
  // open the file in the wrong editor, so the assertion below can tell.
  writeFileSync(
    fresh,
    `#!/bin/sh
if [ "$1 $2 $3" = "--cmd daemon info" ]; then
  printf 'Running daemons:\\n  local-${LSP_PID}-decoy000\\n  local-${FRESH_PID}-real0000\\n'
  exit 0
fi
if [ "$1 $2 $3" = "--cmd daemon open-file" ]; then
  printf '%s\\n%s\\n' "$4" "$5" > "${opened}"
  exit 0
fi
exit 2
`,
  );
  chmodSync(herdr, 0o755);
  chmodSync(fresh, 0o755);

  process.env.PATH = `${dir}:${process.env.PATH}`;
  process.env.HERDR_BIN_PATH = herdr;
  process.env.MASH_FRESH_BIN = fresh;
  process.env.HERDR_PANE_ID = "w1:p1";

  const { default: register } = await import(
    new URL("../defaults/pi/extensions/show-file.ts", import.meta.url)
  );
  let tool;
  register({ registerTool(value) { tool = value; } });
  const result = await tool.execute("test", { path: report, note: "New insight" });
  assert.match(result.content[0].text, /is open in the Fresh editor beside this pane/);

  const [session, location] = readFileSync(opened, "utf8").trim().split("\n");
  assert.equal(session, `local-${FRESH_PID}-real0000`, "opened the language server's daemon");
  assert.equal(location, `${report}@"New insight"`);
  console.log("show_file fresh daemon: ok");
} finally {
  for (const key of ["PATH", "HERDR_BIN_PATH", "MASH_FRESH_BIN", "HERDR_PANE_ID"]) {
    if (env[key] === undefined) delete process.env[key];
    else process.env[key] = env[key];
  }
  rmSync(dir, { recursive: true, force: true });
}
