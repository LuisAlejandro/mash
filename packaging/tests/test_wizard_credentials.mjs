// Source/revision tests use only temporary stores and fake credentials.
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";
import { spawnSync } from "node:child_process";
import { copyFile, symlink as link } from "node:fs/promises";
import { stat, readdir } from "node:fs/promises";
import { applyCredential, credentialSnapshot, inspectCredential } from "../helpers/mash-pi-credentials.mjs";

const root = await mkdtemp(join(tmpdir(), "mash-credentials-"));
const agentDir = join(root, "agent");
await mkdir(agentDir);
const secret = "fixture-secret-never-output";
const request = { version: 1, action: "inspect", agentDir, provider: "custom", nonce: "a".repeat(64), baseUrl: "https://example.invalid/v1", mode: "existing" };
const save2 = (path, value) => writeFile(path, JSON.stringify(value));
const save = (file, value) => save2(join(agentDir, file), value);
try {
  await save("models.json", { providers: { custom: { api: "openai-completions", baseUrl: request.baseUrl, apiKey: "fallback" } } });
  await save("auth.json", { custom: { type: "api_key", key: secret, env: { KEEP: "yes" } }, other: { type: "api_key", key: "other" } });
  const before = await readFile(join(agentDir, "auth.json"), "utf8");
  const report = await inspectCredential(request);
  assert.equal(report.status, "ok");
  assert.equal(report.ready, true);
  assert.equal(report.source, "saved");
  assert.ok(/^[a-f0-9]{64}$/.test(report.revision));
  assert.ok(!JSON.stringify(report).includes(secret));
  const snap = await credentialSnapshot({ ...request, revision: report.revision });
  assert.equal(snap.key, secret);
  await save("auth.json", { custom: { type: "api_key", key: secret, env: { KEEP: "yes" } }, other: { type: "api_key", key: "changed" } });
  assert.equal((await inspectCredential(request)).revision, report.revision, "unrelated owners must not invalidate selection");
  await save("auth.json", { custom: { type: "api_key", key: "rotated" } });
  await assert.rejects(credentialSnapshot({ ...request, revision: report.revision }), /stale/);
  await writeFile(join(agentDir, "auth.json"), before);
  const none = await credentialSnapshot({ ...request, mode: "none" });
  assert.equal(none.key, "mash-local");
  assert.equal(none.realKey, false);
  await save("auth.json", { custom: { type: "api_key", key: "!touch must-not-run" } });
  assert.equal((await inspectCredential(request)).ready, false);
  await save("auth.json", { custom: { type: "oauth", access: secret, refresh: "never-refresh", expires: 1 } });
  assert.equal((await inspectCredential(request)).reason, "oauth_expired");
  await rm(join(agentDir, "auth.json"));
  await symlink(join(root, "outside"), join(agentDir, "auth.json"));
  assert.equal((await inspectCredential(request)).status, "unavailable");
  console.log("ok - saved precedence, opaque revisions, stale rejection, no-auth, commands and symlinks");

  // U4: apply writes only the accepted material, under Pi's own lock. The real
  // pin is proven by the staged gate; this fixture records the lock contract.
  const pkg = join(root, "pi");
  const locks = join(root, "locks.log");
  await mkdir(join(pkg, "node_modules/proper-lockfile"), { recursive: true });
  await save2(join(pkg, "package.json"), { name: "pi", version: "1.1.0" });
  await save2(join(pkg, "node_modules/proper-lockfile/package.json"), { name: "proper-lockfile", main: "index.js" });
  await writeFile(join(pkg, "node_modules/proper-lockfile/index.js"), `const fs=require("fs");exports.lock=async(path,options)=>{if(options.realpath!==false)throw new Error("Pi locks without realpath");fs.appendFileSync(${JSON.stringify(locks)},path+"\\n");fs.mkdirSync(path+".lock");return async()=>fs.rmdirSync(path+".lock");};\n`);
  // With a real pin (the staged gate), the actual lock and resolver are used.
  const pin = process.argv[2];
  const options = { packageDir: pin ?? pkg };
  await rm(join(agentDir, "auth.json"));
  await save("auth.json", { other: { type: "api_key", key: "other" } });
  const reuse = { ...request, provider: "other", mode: "existing" };
  const unchanged = await readFile(join(agentDir, "auth.json"), "utf8");
  const kept = await applyCredential({ ...reuse, revision: (await inspectCredential(reuse)).revision }, options);
  assert.equal(kept.status, "ok");
  assert.equal(kept.wrote, false, "reusing a saved credential must not write auth");
  assert.equal(await readFile(join(agentDir, "auth.json"), "utf8"), unchanged);
  for (const credential of [
    { type: "oauth", access: "expired-fixture", refresh: "never-refresh", expires: 1 },
    { type: "api_key", key: "!touch must-not-run" },
  ]) {
    const data = JSON.parse(await readFile(join(agentDir, "auth.json"), "utf8"));
    data.other = credential;
    await save("auth.json", data);
    const bytes = await readFile(join(agentDir, "auth.json"), "utf8");
    const snapshot = await inspectCredential(reuse, options);
    assert.equal(snapshot.ready, false);
    const result = await applyCredential({ ...reuse, revision: snapshot.revision }, options);
    assert.equal(result.wrote, false, "unchanged saved reuse is independent of readiness");
    assert.equal(await readFile(join(agentDir, "auth.json"), "utf8"), bytes);
  }
  await save("auth.json", { other: { type: "api_key", key: "other" } });
  // A credential bound to another endpoint is not "Pi owns it": applying it
  // would save a provider whose saved key cannot serve the configured route.
  const mismatched = { ...request, mode: "existing", baseUrl: `${request.baseUrl}/elsewhere` };
  await save("models.json", { providers: { custom: { api: "openai-completions", baseUrl: request.baseUrl, apiKey: "fallback" } } });
  await save("auth.json", { custom: { type: "api_key", key: "endpoint-bound-key" } });
  const boundBytes = await readFile(join(agentDir, "auth.json"), "utf8");
  const bound = await inspectCredential(mismatched, options);
  assert.equal(bound.ready, false);
  assert.equal(bound.reason, "endpoint_changed");
  await assert.rejects(
    applyCredential({ ...mismatched, revision: bound.revision }, options),
    /endpoint_changed/,
    "a credential bound to another endpoint must still refuse at apply",
  );
  assert.equal(await readFile(join(agentDir, "auth.json"), "utf8"), boundBytes);
  await save("models.json", { providers: { custom: { api: "openai-completions", baseUrl: request.baseUrl, apiKey: "fallback" } } });
  await save("auth.json", { other: { type: "api_key", key: "other" } });
  const fresh = { ...request, mode: "new", key: "$literal!value" };
  const applied = await applyCredential({ ...fresh, revision: (await inspectCredential(fresh)).revision }, options);
  assert.equal(applied.wrote, true);
  const saved = JSON.parse(await readFile(join(agentDir, "auth.json"), "utf8"));
  assert.equal(saved.other.key, "other", "unrelated owners survive the merge");
  assert.equal(saved.custom.type, "api_key");
  // Pi reads "$$" as a literal "$"; the staged gate resolves it with the real pin.
  assert.equal(saved.custom.key, "$$literal!value", "stored keys are escaped, never reinterpreted");
  assert.equal((await stat(join(agentDir, "auth.json"))).mode & 0o777, 0o600);
  if (pin) {
    assert.equal((await credentialSnapshot({ ...request, mode: "existing" }, options)).key, "$literal!value", "the real pin resolves the escape back exactly");
  }
  await assert.rejects(applyCredential({ ...fresh, revision: "b".repeat(64) }, options), /stale/);
  await assert.rejects(applyCredential({ ...request, mode: "none" }, options), /stale/, "no-auth must use a separate owner rather than overwrite a real key");
  const local = { ...request, provider: "local-alias", mode: "none" };
  const cleared = await applyCredential({ ...local, revision: (await inspectCredential(local)).revision }, options);
  if (!pin) assert.equal(await readFile(locks, "utf8"), `${join(agentDir, "auth.json")}\n`.repeat(2), "every write takes Pi's lock; reuse takes none");
  assert.equal(cleared.wrote, true);
  const owners = JSON.parse(await readFile(join(agentDir, "auth.json"), "utf8"));
  assert.equal(owners["local-alias"].key, "mash-local", "no-auth gets a non-secret Pi readiness marker");
  assert.equal(owners.custom.key, "$$literal!value", "the old real credential is preserved under its old owner");
  assert.deepEqual((await readdir(agentDir)).filter(f => f !== "auth.json" && f !== "models.json"), [], "no leftover temporary or lock");
  console.log(`ok - saved reuse writes nothing; accepted material merges privately at 0600 with ${pin ? "the real Pi lock and resolver" : "Pi's lock"}`);

  if (pin) {
    const locking = createRequire(join(pin, "package.json"))("proper-lockfile");
    const path = join(agentDir, "auth.json");
    let release = await locking.lock(path, { realpath: false, stale: 10000, update: 2000 });
    const concurrent = { ...request, mode: "new", key: "accepted-new-key" };
    const pending = applyCredential(concurrent, options);
    await new Promise(resolve => setTimeout(resolve, 30));
    const latest = JSON.parse(await readFile(path, "utf8"));
    latest.concurrent = { type: "api_key", key: "concurrent-owner" };
    await writeFile(path, JSON.stringify(latest));
    await release();
    await pending;
    assert.equal(JSON.parse(await readFile(path, "utf8")).concurrent.key, "concurrent-owner");

    const revision = (await inspectCredential(concurrent, options)).revision;
    release = await locking.lock(path, { realpath: false, stale: 10000, update: 2000 });
    const stale = assert.rejects(applyCredential({ ...concurrent, revision }, options), /stale/);
    await new Promise(resolve => setTimeout(resolve, 30));
    const rotated = JSON.parse(await readFile(path, "utf8"));
    rotated.custom.key = "externally-rotated";
    await writeFile(path, JSON.stringify(rotated));
    await release();
    await stale;
    assert.equal(JSON.parse(await readFile(path, "utf8")).custom.key, "externally-rotated");
    const abort = new AbortController();
    abort.abort();
    await assert.rejects(applyCredential(concurrent, { ...options, signal: abort.signal }), { name: "AbortError" });
    assert.deepEqual((await readdir(agentDir)).filter(name => name.endsWith(".tmp") || name.endsWith(".lock")), []);
    console.log("ok - actual Pi lock preserves concurrent unrelated owners, rejects relevant rotation and cleans aborts");
    const oldEnvironment = process.env.GEMINI_API_KEY;
    process.env.GEMINI_API_KEY = "$literal-environment-key";
    try {
      const ambient = { ...request, provider: "google", mode: "existing", baseUrl: undefined };
      const source = await inspectCredential(ambient, options);
      assert.equal(source.source, "environment");
      assert.equal(source.ready, true);
      assert.ok(!JSON.stringify(source).includes("$literal-environment-key"));
      await applyCredential({ ...ambient, revision: source.revision }, options);
      assert.equal((await credentialSnapshot(ambient, options)).key, "$literal-environment-key");
      assert.equal(JSON.parse(await readFile(path, "utf8")).google.key, "$$literal-environment-key");
    } finally {
      if (oldEnvironment === undefined) delete process.env.GEMINI_API_KEY;
      else process.env.GEMINI_API_KEY = oldEnvironment;
    }
    console.log("ok - an accepted environment key is persisted as a private literal without output disclosure");
  }

  // CLI staging: no PATH SDK, credential argv, stdout material or writing store
  // outside the explicitly selected temporary agent directory.
  const payload = join(root, "payload with spaces");
  const sdkDir = join(payload, "node/lib/node_modules/@earendil-works");
  await mkdir(sdkDir, { recursive: true });
  await mkdir(join(payload, "bin"));
  await link(pin ?? pkg, join(sdkDir, "pi-coding-agent"));
  for (const helper of ["mash-pi-credentials.mjs", "mash-pi-runtime.mjs"]) {
    await copyFile(new URL(`../helpers/${helper}`, import.meta.url), join(payload, "bin", helper));
  }
  const response = spawnSync(process.execPath, [join(payload, "bin/mash-pi-credentials.mjs")], {
    input: JSON.stringify({ ...request, action: "apply", mode: "new", key: "stdin-only-key" }),
    encoding: "utf8", timeout: 15000, env: { HOME: root, PATH: "/usr/bin:/bin", PI_OFFLINE: "1" },
  });
  assert.equal(response.status, 0, response.stderr + response.stdout);
  assert.equal(JSON.parse(response.stdout).wrote, true);
  assert.equal(response.stderr, "");
  assert.ok(!response.stdout.includes("stdin-only-key"));
  assert.equal(JSON.parse(await readFile(join(agentDir, "auth.json"), "utf8")).custom.key, "stdin-only-key");
  console.log("ok - staged credential apply uses fixed imports, private stdin and sanitized output");
} finally { await rm(root, { recursive: true, force: true }); }
