// A dev tab's Fresh attaches to the directory's shared daemon instead of running
// its own, and that daemon is named after whichever client created it -- usually
// another tab. show_file must still reach it: with no pid-named session to find,
// the pane's directory is what identifies the editor.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { registerHooks } from "node:module";

delete process.env.MASH_LANGUAGE;

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
// The daemon another tab created, so its name carries no pid from this pane.
const OTHER_TAB_PID = 7777;

const dir = mkdtempSync(join(tmpdir(), "mash-show-file-shared-"));
// The pane's directory has to exist: the fallback spawns `fresh` with it as the
// working directory, which is how the CLI resolves "this directory's daemon".
const paneCwdDir = join(dir, "shared-project");
mkdirSync(paneCwdDir);
const env = { ...process.env };
try {
  const report = join(dir, "insight.md");
  const opened = join(dir, "open-file-args");
  const herdr = join(dir, "herdr");
  const fresh = join(dir, "fresh");
  writeFileSync(report, "# Insight\n");

  const processInfo =
    `{"result":{"process_info":{"pane_id":"w1:p2","foreground_processes":` +
    `[{"name":"node","pid":999},{"name":"fresh","pid":${FRESH_PID}}]}}}`;

  writeFileSync(
    herdr,
    `#!/bin/sh
case "$1 $2" in
  "pane layout")
    echo '{"result":{"layout":{"panes":[{"pane_id":"w1:p1"},{"pane_id":"w1:p2"}]}}}' ;;
  "pane process-info")
    case "$4" in
      w1:p2) echo '${processInfo}' ;;
      *) echo '{"result":{"process_info":{"pane_id":"w1:p1","foreground_processes":[{"name":"pi","pid":111}]}}}' ;;
    esac ;;
  "pane get")
    case "$3" in
      w1:p2) echo '{"result":{"pane":{"pane_id":"w1:p2","cwd":"${paneCwdDir}"}}}' ;;
      *) exit 2 ;;
    esac ;;
  *) exit 2 ;;
esac
exit 0
`,
  );
  // The only daemon on the machine belongs to another tab. Nothing here matches
  // this pane's fresh pid, which is exactly the shared-editor case.
  writeFileSync(
    fresh,
    `#!/bin/sh
if [ "$1 $2 $3" = "--cmd daemon info" ]; then
  printf 'Running daemons:\\n  local-${OTHER_TAB_PID}-other000\\n'
  exit 0
fi
if [ "$1 $2 $3" = "--cmd daemon open-file" ]; then
  printf 'session=[%s]\\nlocation=[%s]\\ncwd=[%s]\\n' "$4" "$5" "$(pwd)" > "${opened}"
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
  const result = await tool.execute("test", { path: report });

  assert.ok(!result.isError, `reported failure: ${result.content[0].text}`);
  assert.match(result.content[0].text, /is open in the Fresh editor/);

  const recorded = readFileSync(opened, "utf8").trim();
  // An empty session name is how the CLI says "the daemon for this directory",
  // and the directory is the pane's, not this process's.
  assert.match(recorded, /^session=\[\]$/m, `used a session name: ${recorded}`);
  assert.match(recorded, new RegExp(`^location=\\[${report}\\]$`, "m"));
  // Resolved, because macOS answers `pwd` under /private/var for a /var path.
  const realCwd = realpathSync(paneCwdDir);
  assert.match(recorded, new RegExp(`^cwd=\\[${realCwd}\\]$`, "m"));
  console.log("show_file shared editor: ok");
} finally {
  for (const key of ["PATH", "HERDR_BIN_PATH", "MASH_FRESH_BIN", "HERDR_PANE_ID"]) {
    if (env[key] === undefined) delete process.env[key];
    else process.env[key] = env[key];
  }
  rmSync(dir, { recursive: true, force: true });
}
