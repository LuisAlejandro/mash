// Mash's seeded Pi extensions must load against the pinned Pi from an agent
// directory that has no node_modules of its own. Extensions import `typebox`
// and `@earendil-works/*`; Pi's extension loader aliases those to its bundled
// copies. The build used to install a second typebox into defaults/pi for
// this, which Pi never loaded; this check is what proves it is not needed.
//
//   node test_pi_extensions_load.mjs <pi-coding-agent package dir>
import assert from "node:assert/strict";
import { cpSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const pi = process.argv[2];
if (!pi) {
  console.log("skip - extension loading needs a staged pin: test_pi_runtime.sh <resource-root>");
  process.exit(77);
}
const extensions = join(dirname(fileURLToPath(import.meta.url)), "../defaults/pi/extensions");
const sdk = await import(pathToFileURL(join(pi, "dist/index.js")).href);

// A temp dir has no node_modules above it, so only Pi's aliases can resolve.
const agentDir = mkdtempSync(join(tmpdir(), "mash-pi-ext-"));
try {
  cpSync(extensions, join(agentDir, "extensions"), { recursive: true });
  writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ packages: [] }));
  const settingsManager = sdk.SettingsManager.create(agentDir, agentDir);
  const loader = new sdk.DefaultResourceLoader({ cwd: agentDir, agentDir, settingsManager });
  await loader.reload();
  const { extensions: loaded, errors } = loader.getExtensions();
  assert.deepEqual(errors, [], "every seeded extension loads");
  for (const name of ["mash-orchestration.ts", "show-file.ts"]) {
    assert.ok(loaded.some((e) => e.path.endsWith(name)), `${name} loaded (it imports typebox)`);
  }
  console.log(`ok - ${loaded.length} seeded extensions load with no agent-directory node_modules`);
} finally {
  rmSync(agentDir, { recursive: true, force: true });
}
