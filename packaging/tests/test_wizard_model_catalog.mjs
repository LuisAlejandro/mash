// The wizard inspects the pinned Pi runtime, never a host CLI or live account.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync, copyFileSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { inspectModels } from "../helpers/mash-pi-models.mjs";

const dir = mkdtempSync(join(tmpdir(), "mash-model-catalog-"));
const helper = fileURLToPath(new URL("../helpers/mash-pi-models.mjs", import.meta.url));
const secret = "sentinel-not-a-real-api-key";
const request = (agentDir, rest = {}) => ({ version: 1, action: "discover", agentDir, provider: "openai", ...rest });
const save = (path, value) => writeFileSync(path, JSON.stringify(value));
const contents = (path) => Object.fromEntries(readdirSync(path).sort().map(name => [name, readFileSync(join(path, name), "utf8")]));

async function scenarios(packageDir) {
  const agentDir = join(dir, "agent");
  mkdirSync(agentDir, { recursive: true });
  const auth = join(agentDir, "auth.json");
  const settings = join(agentDir, "settings.json");
  const models = join(agentDir, "models.json");
  save(auth, { openai: { type: "api_key", key: "!echo old-key-must-not-run", env: { PRESERVED: "yes" } } });
  save(settings, { defaultProvider: "openai", defaultModel: "gpt-4" });
  const before = contents(agentDir);
  const options = { packageDir };
  const pending = await inspectModels(request(agentDir, { draft: { provider: "openai", key: secret } }), options);
  assert.equal(pending.status, "ok", JSON.stringify(pending));
  assert.equal(pending.auth.status, "ready");
  assert.equal(pending.serverVerified, false);
  assert.ok(pending.models.some(model => model.provider === "openai" && model.id === "gpt-4"));
  assert.deepEqual(contents(agentDir), before, "inspection must not create caches or alter saved state");
  assert.equal(JSON.stringify(pending).includes(secret), false);
  console.log("ok - draft credentials, local catalog, safe JSON and no writes");

  const verify = () => inspectModels({ version: 1, action: "verify", agentDir }, options);
  assert.equal((await verify()).modelKnown, true);
  save(settings, { defaultProvider: "openai", defaultModel: "not-in-the-bundled-catalog" });
  assert.equal((await verify()).modelKnown, false);
  save(auth, {});
  let result = await verify();
  assert.equal(result.auth.status, "not_ready");
  assert.equal(result.modelKnown, false);
  save(settings, { defaultProvider: "openai", defaultModel: "gpt-4" });
  result = await verify();
  assert.equal(result.auth.status, "not_ready");
  assert.equal(result.modelKnown, true, "missing auth must not imply an unknown model");
  save(settings, { defaultProvider: "extension-only", defaultModel: "custom" });
  result = await verify();
  assert.equal(result.auth.status, "unverified");
  assert.equal(result.auth.reason, "provider_not_found");
  assert.equal(result.modelKnown, null);
  save(settings, {});
  assert.equal((await verify()).modelKnown, null);
  console.log("ok - known, unknown, missing-auth, unknown-provider and deferred setup are distinct");

  save(models, { providers: { custom: { baseUrl: "https://example.invalid/v1", api: "openai-responses", apiKey: "local-only", models: [{ id: "namespace/model", name: "Custom model" }] } } });
  save(settings, { defaultProvider: "custom", defaultModel: "namespace/model" });
  result = await verify();
  assert.equal(result.status, "ok");
  assert.equal(result.modelKnown, true);
  assert.equal(result.serverVerified, false);
  result = await inspectModels(request(agentDir, { provider: "custom", draft: { provider: "custom", key: secret, baseUrl: "https://different.invalid/v1" } }), options);
  assert.equal(result.auth.status, "unverified");
  assert.equal(result.auth.reason, "endpoint_changed");
  save(models, { providers: { custom: { baseUrl: "https://example.invalid/v1", api: "openai-responses", apiKey: "local-only", models: [] } } });
  result = await verify();
  assert.equal(result.catalogComplete, false);
  assert.equal(result.modelKnown, null, "an empty catalog is not evidence a model is unknown");
  console.log("ok - custom definitions are local only; missing catalogs stay unverified");

  save(auth, { openai: { type: "api_key", key: "!echo must-not-run" } });
  result = await inspectModels(request(agentDir), options);
  assert.equal(result.auth.status, "unverified");
  assert.equal(result.auth.reason, "command_secret");
  assert.equal(result.models.some(model => model.provider === "openai"), false);
  save(auth, {});
  save(models, { providers: { custom: { baseUrl: "https://example.invalid/v1", api: "openai-responses", apiKey: "!echo must-not-run", models: [{ id: "custom" }] } } });
  save(settings, { defaultProvider: "custom", defaultModel: "custom" });
  assert.equal((await verify()).auth.reason, "command_secret");
  save(auth, { custom: { type: "api_key", key: "explicit-key" } });
  assert.equal((await verify()).auth.status, "ready", "a stored key outranks a configured command");
  save(auth, { openai: { type: "oauth", access: secret, refresh: "not-real", expires: 1 } });
  result = await inspectModels(request(agentDir), options);
  assert.equal(result.auth.status, "unverified");
  assert.equal(result.auth.reason, "oauth_expired");
  assert.equal(readFileSync(auth, "utf8").includes(secret), true, "OAuth must not be refreshed or rewritten");
  console.log("ok - command secrets and expired OAuth stay untouched and unverified");

  save(auth, {});
  save(models, { providers: { custom: { baseUrl: "https://example.invalid/v1", api: "openai-responses", apiKey: "$MASH_TEST_UNSET_KEY", models: [{ id: "custom" }] } } });
  assert.equal((await verify()).auth.status, "not_ready");
  writeFileSync(models, `{"providers": {"${secret}":`);
  result = await verify();
  assert.equal(result.status, "unavailable");
  assert.equal(result.catalogComplete, false);
  assert.equal(result.modelKnown, null);
  assert.equal(JSON.stringify(result).includes(secret), false);
  save(models, { providers: {} });
  save(auth, {});
  result = await inspectModels(request(agentDir, { draft: { provider: "openai", key: "$MASH_TEST_UNSET_KEY" } }), options);
  assert.equal(result.auth.status, "not_ready", "draft keys must follow the same interpolation rules as saved keys");
  console.log("ok - unresolved credentials and malformed model state never leak contents");
}

try {
  if (process.argv[2] === "--real") {
    // This mode runs only in a sterile child process, never with the owner's env.
    let networkAttempts = 0;
    globalThis.fetch = () => { networkAttempts++; throw new Error("No network during wizard inspection"); };
    await scenarios(process.argv[3]);
    assert.equal(networkAttempts, 0, "inspection must not even attempt a fetch");
    const payload = join(dir, "real payload with spaces");
    const sdkDir = join(payload, "node/lib/node_modules/@earendil-works");
    mkdirSync(sdkDir, { recursive: true });
    mkdirSync(join(payload, "bin"), { recursive: true });
    symlinkSync(resolve(process.argv[3]), join(sdkDir, "pi-coding-agent"));
    copyFileSync(helper, join(payload, "bin/mash-pi-models.mjs"));
    const guard = join(dir, "no-network.mjs");
    writeFileSync(guard, 'globalThis.fetch = () => { process.stderr.write("unexpected network attempt"); throw new Error("network forbidden"); };\n');
    const agentDir = join(dir, "agent");
    save(join(agentDir, "settings.json"), { defaultProvider: "openai", defaultModel: "gpt-4" });
    save(join(agentDir, "auth.json"), { openai: { type: "api_key", key: secret } });
    const before = contents(agentDir);
    const result = spawnSync(process.execPath, ["--import", guard, join(payload, "bin/mash-pi-models.mjs")], {
      input: JSON.stringify({ version: 1, action: "verify", agentDir }), encoding: "utf8", timeout: 15000,
      env: { HOME: dir, PATH: "/usr/bin:/bin", PI_OFFLINE: "1" },
    });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    const output = JSON.parse(result.stdout);
    assert.equal(output.auth.status, "ready");
    assert.equal(output.modelKnown, true);
    assert.equal(output.serverVerified, false);
    assert.equal(result.stderr, "");
    assert.equal(result.stdout.includes(secret), false);
    assert.deepEqual(contents(agentDir), before);
    console.log("ok - real staged CLI, resource paths with spaces, local-only checks and no writes");
  } else {
    // A tiny fake SDK proves draft precedence and contract/error paths without
    // a dependency install. The build gate repeats them against the real pin.
    const pkg = join(dir, "fake resource root with spaces/node/lib/node_modules/@earendil-works/pi-coding-agent");
    mkdirSync(join(pkg, "dist/core"), { recursive: true });
    const ai = join(pkg, "node_modules/@earendil-works/pi-ai");
    mkdirSync(join(ai, "dist"), { recursive: true });
    save(join(pkg, "package.json"), { type: "module" });
    save(join(ai, "package.json"), { type: "module", exports: "./dist/index.js" });
    writeFileSync(join(ai, "dist/index.js"), `
export class InMemoryCredentialStore {
  data = new Map();
  async read(id) { return this.data.get(id); }
  async list() { return [...this.data].map(([providerId, c]) => ({ providerId, type: c.type })); }
  async modify(id, fn) { const c = await fn(this.data.get(id)); if (c) this.data.set(id, c); return c; }
}
export class InMemoryModelsStore {}
`);
    writeFileSync(join(pkg, "dist/core/auth-storage.js"), `
import { readFile } from "node:fs/promises";
export class ReadOnlyAuthStorage {
  constructor(path) { this.path = path; }
  async data() { try { return JSON.parse(await readFile(this.path, "utf8")); } catch (e) { if (e.code === "ENOENT") return {}; throw e; } }
  async list() { return Object.entries(await this.data()).map(([providerId, c]) => ({ providerId, type: c.type })); }
  async read(id) { return (await this.data())[id]; }
}
`);
    writeFileSync(join(pkg, "dist/core/resolve-config-value.js"), `
export function resolveConfigValue(key, env) {
  return key.startsWith("$") ? (env?.[key.slice(1)] ?? process.env[key.slice(1)]) : key;
}
`);
    writeFileSync(join(pkg, "dist/index.js"), `
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
export class ModelRuntime {
  static async create(options) {
    assert.equal(options.allowModelNetwork, false);
    assert.equal(options.refreshOnCreate, false);
    assert.ok(options.modelsStore);
    let config;
    try { config = JSON.parse(await readFile(options.modelsPath, "utf8")); }
    catch (e) { if (e.code !== "ENOENT") return { getError: () => e.message }; }
    return new ModelRuntime(options.credentials, config?.providers ?? {});
  }
  constructor(credentials, config) { this.credentials = credentials; this.config = config; }
  getError() { return undefined; }
  getProviders() { return [...new Set(["openai", ...Object.keys(this.config)])].map(id => ({ id })); }
  getProvider(id) { return this.getProviders().find(p => p.id === id); }
  getModels(id) {
    const rows = [{provider:"openai", id:"gpt-4", name:"GPT-4"}, ...Object.entries(this.config).flatMap(([provider,c]) => (c.models ?? []).map(m => ({...m,provider})))];
    return id ? rows.filter(m => m.provider === id) : rows;
  }
  getProviderAuthStatus(id) { return {source: this.config[id]?.apiKey?.startsWith("!") ? "models_json_command" : "models_json"}; }
  async checkAuth(id) {
    const c = await this.credentials.read(id);
    if (c?.key) {
      if (c.key === ${JSON.stringify(secret)}) assert.equal(c.env.PRESERVED, "yes", "draft overlay dropped provider env");
      return {type:"api_key"};
    }
    const key = this.config[id]?.apiKey;
    return key && !key.startsWith("$") ? {type:"api_key"} : undefined;
  }
  async getAvailable(id) { return (await this.checkAuth(id)) ? this.getModels(id) : []; }
}
`);
    await scenarios(pkg);
    const invalid = await inspectModels(request("relative/path"), { packageDir: pkg });
    assert.equal(invalid.status, "unavailable");
    assert.equal(invalid.reason, "invalid_request");
    const missing = await inspectModels(request(join(dir, "missing")), { packageDir: join(dir, "missing-pi") });
    assert.equal(missing.status, "unavailable");
    assert.equal(missing.reason, "runtime_unavailable");

    // macOS uses an allowlist; Linux copies helpers through the real stager.
    assert.ok(/^  mash-pi-models\.mjs$/m.test(readFileSync(new URL("../build.sh", import.meta.url), "utf8")), "macOS must ship the model helper");
    const root = join(pkg, "../../../../..");
    const fixture = join(dir, "staging source");
    mkdirSync(join(fixture, "packaging/helpers"), { recursive: true });
    copyFileSync(helper, join(fixture, "packaging/helpers/mash-pi-models.mjs"));
    writeFileSync(join(fixture, "VERSION"), "0.0.0\n");
    for (const file of ["assets.json", "assets.py"]) writeFileSync(join(fixture, "packaging", file), "unused fixture\n");
    const stage = spawnSync("/bin/bash", ["-c", 'set -e; source "$1"; root="$2"; mash_portable_scripts() { :; }; mash_stage_portable_payload "$3" linux-amd64', "stage", fileURLToPath(new URL("../build-common.sh", import.meta.url)), fixture, root], { encoding: "utf8" });
    assert.equal(stage.status, 0, stage.stderr);
    assert.equal(readFileSync(join(root, "bin/mash-pi-models.mjs"), "utf8"), readFileSync(helper, "utf8"));

    // CLI resolution uses the staged location only, regardless of PATH/PI_HOME.
    const cli = (input) => spawnSync(process.execPath, [join(root, "bin/mash-pi-models.mjs")], {
      input, encoding: "utf8", cwd: dir, timeout: 10000,
      env: { HOME: dir, PATH: "/usr/bin:/bin", PI_HOME: join(dir, "not-pi-home"), PI_CODING_AGENT_DIR: join(dir, "not-agent-dir") },
    });
    save(join(dir, "agent/auth.json"), {});
    save(join(dir, "agent/models.json"), { providers: {} });
    const response = cli(JSON.stringify(request(join(dir, "agent"))));
    assert.equal(response.status, 0, response.stderr);
    assert.equal(JSON.parse(response.stdout).version, 1);
    assert.equal(response.stderr, "");
    const broken = cli(`{"secret":"${secret}"`);
    assert.equal(broken.status, 2);
    assert.equal(JSON.parse(broken.stdout).status, "unavailable");
    assert.equal((broken.stdout + broken.stderr).includes(secret), false);
    const oversized = cli(" ".repeat(65537));
    assert.equal(oversized.status, 2);
    assert.equal(JSON.parse(oversized.stdout).reason, "input_limit");
    writeFileSync(join(pkg, "dist/index.js"), "export class ModelRuntime {}\n");
    const incompatible = cli(JSON.stringify(request(join(dir, "agent"))));
    assert.equal(incompatible.status, 2);
    assert.equal(JSON.parse(incompatible.stdout).reason, "runtime_unavailable");
    console.log("ok - stdin protocol, pinned SDK compatibility and sanitized input failures");

    if (process.argv[2]) {
      const smoke = spawnSync(process.execPath, [fileURLToPath(import.meta.url), "--real", process.argv[2]], {
        env: { HOME: dir, PATH: "/usr/bin:/bin", PI_OFFLINE: "1" },
        encoding: "utf8", timeout: 20000,
      });
      assert.equal(smoke.status, 0, smoke.stdout + smoke.stderr);
      process.stdout.write(smoke.stdout);
      console.log("ok - staged Pi model/auth runtime contract");
    }
  }
} finally {
  rmSync(dir, { recursive: true, force: true });
}
