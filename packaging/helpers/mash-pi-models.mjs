#!/usr/bin/env node
// Local catalog/auth inspection only. Launch with Mash's bundled Node.
// stdin: {version:1,action:"discover"|"verify",agentDir,provider?,draft?}
// Secrets travel on stdin and in memory, never argv, output or credential files.
import { realpathSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, isAbsolute, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const MAX_INPUT = 64 * 1024;
const MAX_OUTPUT = 4 * 1024 * 1024;
const unavailable = (reason) => ({ version: 1, status: "unavailable", reason, catalogComplete: false, models: [], modelKnown: null, auth: { status: "unverified", reason }, serverVerified: false });
const object = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const text = (value) => typeof value === "string" && value.length > 0 && !/[\x00-\x1f\x7f-\x9f]/u.test(value);
const identifier = (value) => text(value) && value.length <= 1024;

async function readObject(path) {
  try {
    const value = JSON.parse(await readFile(path, "utf8"));
    if (!object(value)) throw new Error("Invalid object");
    return value;
  } catch (error) {
    if (error.code === "ENOENT") return {};
    throw error;
  }
}

async function loadRuntime(packageDir) {
  const sdk = await import(pathToFileURL(join(packageDir, "dist/index.js")).href);
  const ai = await import(pathToFileURL(join(packageDir, "node_modules/@earendil-works/pi-ai/dist/index.js")).href);
  const storage = await import(pathToFileURL(join(packageDir, "dist/core/auth-storage.js")).href);
  const values = await import(pathToFileURL(join(packageDir, "dist/core/resolve-config-value.js")).href);
  if (typeof values.resolveConfigValue !== "function" || typeof sdk.ModelRuntime?.create !== "function" || typeof ai.InMemoryCredentialStore !== "function" || typeof ai.InMemoryModelsStore !== "function" || typeof storage.ReadOnlyAuthStorage !== "function") {
    throw new Error("Incompatible Pi runtime");
  }
  return { ...sdk, ...ai, ReadOnlyAuthStorage: storage.ReadOnlyAuthStorage, resolveConfigValue: values.resolveConfigValue };
}

function validRequest(request) {
  if (!object(request) || request.version !== 1 || !["discover", "verify"].includes(request.action) || !text(request.agentDir) || !isAbsolute(request.agentDir)) return false;
  if (request.provider !== undefined && !identifier(request.provider)) return false;
  if (request.action === "discover" && !identifier(request.provider)) return false;
  if (request.draft !== undefined) {
    const draft = request.draft;
    if (request.action !== "discover" || !object(draft) || !identifier(draft.provider) || !text(draft.key) || draft.key.startsWith("!")) return false;
    if (draft.baseUrl !== undefined && !text(draft.baseUrl)) return false;
  }
  return true;
}

/** Injectable packageDir is for staged-pin tests, never a CLI argument or PATH lookup. */
export async function inspectModels(request, { packageDir = join(dirname(fileURLToPath(import.meta.url)), "../node/lib/node_modules/@earendil-works/pi-coding-agent") } = {}) {
  if (!validRequest(request)) return unavailable("invalid_request");
  let sdk;
  try {
    sdk = await loadRuntime(packageDir);
  } catch {
    return unavailable("runtime_unavailable");
  }
  try {
    const signal = AbortSignal.timeout(8000);
    const settings = request.action === "verify" ? await readObject(join(request.agentDir, "settings.json")) : {};
    const provider = request.action === "verify" ? settings.defaultProvider : request.provider;
    const model = request.action === "verify" ? settings.defaultModel : undefined;
    if (provider !== undefined && !identifier(provider) || model !== undefined && !identifier(model)) return unavailable("invalid_state");

    const saved = new sdk.ReadOnlyAuthStorage(join(request.agentDir, "auth.json"));
    const credentials = new sdk.InMemoryCredentialStore();
    for (const { providerId } of await saved.list({ signal })) {
      const credential = await saved.read(providerId, { signal });
      await credentials.modify(providerId, async () => credential, { signal });
    }
    if (request.draft) {
      const id = request.draft.provider;
      const previous = await credentials.read(id, { signal });
      // validRequest rejects commands before this shared resolver is called.
      const key = sdk.resolveConfigValue(request.draft.key, previous?.env);
      await credentials.modify(id, async () => ({ type: "api_key", key, ...(previous?.env ? { env: previous.env } : {}) }), { signal });
    }

    const runtime = await sdk.ModelRuntime.create({
      credentials,
      modelsStore: new sdk.InMemoryModelsStore(),
      modelsPath: join(request.agentDir, "models.json"),
      refreshOnCreate: false,
      allowModelNetwork: false,
      signal,
    });
    const required = ["getError", "getModels", "getAvailable", "checkAuth", "getProviders", "getProvider", "getProviderAuthStatus"];
    if (!runtime || required.some(name => typeof runtime[name] !== "function")) return unavailable("runtime_unavailable");
    if (runtime.getError()) return unavailable("invalid_state");

    const statuses = new Map();
    const rows = [];
    for (const entry of runtime.getProviders()) {
      const id = entry.id;
      const credential = await credentials.read(id, { signal });
      let reason;
      if (credential?.type === "api_key" && credential.key?.startsWith("!")) reason = "command_secret";
      else if (!credential && runtime.getProviderAuthStatus(id)?.source === "models_json_command") reason = "command_secret";
      else if (credential?.type === "oauth" && credential.expires <= Date.now()) reason = "oauth_expired";
      else if (request.draft?.provider === id && request.draft.baseUrl !== undefined && entry.baseUrl !== request.draft.baseUrl) reason = "endpoint_changed";
      if (reason) {
        statuses.set(id, { status: "unverified", reason });
        continue;
      }
      try {
        const auth = await runtime.checkAuth(id, { signal });
        statuses.set(id, auth ? { status: "ready", type: auth.type } : { status: "not_ready", reason: "credentials_not_configured" });
        if (auth && request.action === "discover") rows.push(...await runtime.getAvailable(id, { signal }));
      } catch {
        statuses.set(id, { status: "unverified", reason: "auth_unavailable" });
      }
    }
    signal.throwIfAborted();
    const models = [...new Map(rows.filter(row => identifier(row.provider) && identifier(row.id) && (!row.type || row.type === "chat")).map(row => [JSON.stringify([row.provider, row.id]), { provider: row.provider, id: row.id, name: text(row.name) ? row.name : row.id }])).values()];
    models.sort((a, b) => a.provider.localeCompare(b.provider) || a.id.localeCompare(b.id));
    const registered = provider && runtime.getProvider(provider);
    const catalog = registered ? runtime.getModels(provider) : [];
    const auth = provider ? statuses.get(provider) ?? { status: "unverified", reason: "provider_not_found" } : { status: "unverified", reason: "not_configured" };
    return {
      version: 1,
      status: "ok",
      // Membership is unverified when this provider has no local catalog.
      catalogComplete: catalog.length > 0,
      models,
      modelKnown: catalog.length && model ? catalog.some(entry => entry.id === model) : null,
      auth,
      serverVerified: false,
    };
  } catch {
    return unavailable("invalid_state");
  }
}

async function main() {
  // Do not let inherited diagnostics or model-refresh flags widen this process.
  process.env.PI_OFFLINE = "1";
  let result;
  try {
    let input = "";
    process.stdin.setEncoding("utf8");
    for await (const chunk of process.stdin) {
      input += chunk;
      if (Buffer.byteLength(input) > MAX_INPUT) {
        result = unavailable("input_limit");
        break;
      }
    }
    result ??= await inspectModels(JSON.parse(input));
  } catch {
    result = unavailable("invalid_request");
  }
  let output = JSON.stringify(result);
  if (Buffer.byteLength(output) > MAX_OUTPUT) {
    result = unavailable("output_limit");
    output = JSON.stringify(result);
  }
  process.stdout.write(`${output}\n`);
  process.exitCode = result.status === "ok" ? 0 : 2;
}

if (process.argv[1] && pathToFileURL(realpathSync(process.argv[1])).href === import.meta.url) await main();
