#!/usr/bin/env node
// Local catalog/auth inspection only. Launch with Mash's bundled Node.
// stdin: {version:1,action:"providers"|"catalog"|"discover"|"verify",agentDir?,provider?,draft?}
// providers is build-time metadata inspection only; the wizard embeds its snapshot.
// Secrets travel on stdin and in memory, never argv, output or credential files.
import { realpathSync } from "node:fs";
import { createRequire } from "node:module";
import { cli, loadRuntime, readObject } from "./mash-pi-runtime.mjs";
import { dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";

const MAX_INPUT = 64 * 1024;
const MAX_OUTPUT = 4 * 1024 * 1024;
const unavailable = (reason) => ({ version: 1, status: "unavailable", reason, catalogComplete: false, models: [], modelKnown: null, auth: { status: "unverified", reason }, serverVerified: false });
const object = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const text = (value) => typeof value === "string" && value.length > 0 && !/[\x00-\x1f\x7f-\x9f]/u.test(value);
const identifier = (value) => text(value) && value.length <= 1024;

function validRequest(request) {
  if (!object(request) || request.version !== 1) return false;
  if (request.action === "providers") return request.agentDir === undefined && request.provider === undefined && request.draft === undefined;
  if (!["catalog", "discover", "verify"].includes(request.action) || !text(request.agentDir) || !isAbsolute(request.agentDir)) return false;
  if (request.provider !== undefined && !identifier(request.provider)) return false;
  if (["catalog", "discover"].includes(request.action) && !identifier(request.provider)) return false;
  if (request.purpose !== undefined && (request.action !== "catalog" || !["search", "hindsight"].includes(request.purpose))) return false;
  if (request.draft !== undefined) {
    const draft = request.draft;
    if (request.action !== "discover" || !object(draft) || !identifier(draft.provider) || !text(draft.key) || draft.key.startsWith("!")) return false;
    if (draft.baseUrl !== undefined && !text(draft.baseUrl)) return false;
    if (draft.api !== undefined && (!["openai-completions", "openai-responses", "anthropic-messages"].includes(draft.api) || !text(draft.baseUrl))) return false;
  }
  return true;
}

async function providerCatalog(sdk, packageDir) {
  const { version: piVersion } = await readObject(join(realpathSync(packageDir), "package.json"));
  if (typeof piVersion !== "string" || !/^\d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.-]+)?$/.test(piVersion)) throw new Error("Invalid version");
  const runtime = await sdk.ModelRuntime.create({
    credentials: new sdk.InMemoryCredentialStore(),
    modelsStore: new sdk.InMemoryModelsStore(),
    modelsPath: null,
    refreshOnCreate: false,
    allowModelNetwork: false,
    signal: AbortSignal.timeout(8000),
  });
  const seen = new Set();
  const providers = runtime.getProviders().map(provider => {
    const { id, name } = provider;
    const apiKey = !!provider.auth?.apiKey;
    const keyName = apiKey ? provider.auth.apiKey.name : "";
    if (!identifier(id) || !text(name) || name.length > 256 || seen.has(id) || apiKey && (!text(keyName) || keyName.length > 256)) throw new Error("Invalid provider metadata");
    seen.add(id);
    return { id, name, chat: runtime.getModels(id).length > 0, apiKey, keyName, oauth: !!provider.auth?.oauth };
  });
  if (!providers.length) throw new Error("Empty provider catalog");
  providers.sort((a, b) => a.id.localeCompare(b.id));
  return { version: 1, status: "ok", piVersion, providers, serverVerified: false };
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
    if (request.action === "providers") return await providerCatalog(sdk, packageDir);
    if (request.action === "catalog") {
      // Deferred sign-in must not load saved auth, models.json references or
      // environment credentials. List only this built-in provider's public models.
      const runtime = await sdk.ModelRuntime.create({
        credentials: new sdk.InMemoryCredentialStore(),
        modelsStore: new sdk.InMemoryModelsStore(),
        modelsPath: null,
        refreshOnCreate: false,
        allowModelNetwork: false,
        signal: AbortSignal.timeout(8000),
      });
      if (!runtime.getProvider(request.provider)) return unavailable("provider_not_found");
      let eligible = () => true;
      if (request.purpose === "search") {
        // Reuse the exact shipped extension's native-search predicate, not a
        // second list that would offer unsupported Chat Completions models.
        const dir = realpathSync(packageDir);
        // Pi already bundles the TypeScript loader; keep its disk cache off so
        // reading this pure metadata predicate remains a no-write operation.
        const { createJiti } = createRequire(join(dir, "package.json"))("jiti");
        const loader = createJiti(import.meta.url, { fsCache: false, moduleCache: false, debug: false });
        const { getProviderKind } = await loader.import(join(dir, "../../pi-web-search/src/providers/config.ts"));
        eligible = row => getProviderKind(row) !== "unsupported";
      } else if (request.purpose === "hindsight") {
        if (!["anthropic", "openai", "openrouter"].includes(request.provider)) return unavailable("unsupported_provider");
        // These are model-ID suggestions for Hindsight, not a copy of Pi's
        // transport. Pi lists OpenAI models under Responses even when another
        // client's backend uses Chat Completions for the same model ID.
        eligible = row => request.provider === "anthropic" ? row.api === "anthropic-messages"
          : request.provider === "openai" ? ["openai-responses", "openai-completions"].includes(row.api)
          : row.api === "openai-completions";
      }
      const rows = runtime.getModels(request.provider).filter(row =>
        row.provider === request.provider && identifier(row.id) && (!row.type || row.type === "chat") && eligible(row));
      const models = [...new Map(rows.map(row => [row.id, {
        provider: request.provider, id: row.id, name: text(row.name) ? row.name : row.id,
      }])).values()].sort((a, b) => a.id.localeCompare(b.id));
      return {
        version: 1, status: "ok", catalogComplete: models.length > 0,
        models, modelKnown: null, auth: { status: "unverified", reason: "deferred" },
        serverVerified: false,
      };
    }
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

    const matchesDraft = row => request.draft?.api === undefined || row.provider !== request.draft.provider || row.api === request.draft.api && row.baseUrl === request.draft.baseUrl;
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
      else if (request.draft?.provider === id && request.draft.api !== undefined && !runtime.getModels(id).some(matchesDraft)) reason = "catalog_changed";
      if (reason) {
        statuses.set(id, { status: "unverified", reason });
        continue;
      }
      try {
        const auth = await runtime.checkAuth(id, { signal });
        statuses.set(id, auth ? { status: "ready", type: auth.type } : { status: "not_ready", reason: "credentials_not_configured" });
        if (auth && request.action === "discover") rows.push(...(await runtime.getAvailable(id, { signal })).filter(matchesDraft));
      } catch {
        statuses.set(id, { status: "unverified", reason: "auth_unavailable" });
      }
    }
    signal.throwIfAborted();
    const models = [...new Map(rows.filter(row => identifier(row.provider) && identifier(row.id) && (!row.type || row.type === "chat")).map(row => [JSON.stringify([row.provider, row.id]), { provider: row.provider, id: row.id, name: text(row.name) ? row.name : row.id }])).values()];
    models.sort((a, b) => a.provider.localeCompare(b.provider) || a.id.localeCompare(b.id));
    const registered = provider && runtime.getProvider(provider);
    const catalog = registered ? runtime.getModels(provider).filter(matchesDraft) : [];
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

await cli(import.meta.url, inspectModels, unavailable);
