#!/usr/bin/env node
// Detected material stays inside this process. Only source/revision leave it.
import { createHmac, randomBytes } from "node:crypto";
import { createRequire } from "node:module";
import { open, rename, unlink } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { cli, literal, loadRuntime, object, packageDir, readHindsight, readObject, safePath, text, unavailable } from "./mash-pi-runtime.mjs";

export function validCredentialRequest(r) {
  return object(r) && r.version === 1 && text(r.agentDir) && isAbsolute(r.agentDir) && text(r.provider)
    && typeof r.nonce === "string" && /^[a-f0-9]{64}$/.test(r.nonce)
    && ["existing", "new", "none"].includes(r.mode)
    && (r.baseUrl === undefined || text(r.baseUrl))
    && (r.mode !== "new" || text(r.key))
    && (r.env === undefined || object(r.env) && Object.entries(r.env).every(([name, value]) => name === "AZURE_OPENAI_BASE_URL" && r.provider === "azure" && text(value)));
}

function command(value) {
  if (typeof value === "string") return value.startsWith("!");
  if (Array.isArray(value)) return value.some(command);
  return object(value) && Object.values(value).some(command);
}

const failure = reason => { throw new Error(reason); };

/** Internal only: contains material that must NEVER be returned in a response. */
export async function credentialSnapshot(r, options = {}) {
  if (!validCredentialRequest(r)) failure("invalid_request");
  if (r.scope === "hindsight") {
    // Hindsight's custom OpenAI endpoint owns its key; never look in Pi auth.
    if (r.provider !== "openai" || !text(r.baseUrl) || !["existing", "new"].includes(r.mode)) failure("invalid_request");
    const config = r.mode === "existing" ? await readHindsight(join(r.agentDir, "../../.hindsight/embed")) : {};
    const key = r.mode === "new" ? r.key : config.HINDSIGHT_API_LLM_API_KEY;
    const owned = r.mode === "new" || config.HINDSIGHT_API_LLM_PROVIDER === "openai"
      && config.HINDSIGHT_API_LLM_BASE_URL?.replace(/\/+$/, "") === r.baseUrl.replace(/\/+$/, "");
    const ready = owned && text(key) && key !== "unused"
      && (r.mode === "new" || !key.startsWith("!") && !/[$`]/.test(key));
    const revision = createHmac("sha256", r.nonce).update(JSON.stringify({ base: r.baseUrl, mode: r.mode, config, key })).digest("hex");
    if (r.revision && r.revision !== revision) failure("stale");
    return { key, source: "hindsight", type: "api_key", ready, realKey: ready,
      reason: owned ? "credential_unavailable" : "endpoint_changed", revision };
  }
  if (r.scope !== undefined) failure("invalid_request");
  const auth = await readObject(join(r.agentDir, "auth.json"));
  const models = await readObject(join(r.agentDir, "models.json"));
  const saved = auth[r.provider];
  const config = models.providers?.[r.provider];
  let key, source, type = "api_key", ready = true, reason, envName;
  const env = object(saved?.env) ? saved.env : {};
  const dir = options.packageDir ?? packageDir;
  if (r.mode === "none") { key = "mash-local"; source = "none"; }
  else if (r.mode === "new") { key = r.key; source = "new"; }
  else if (command(saved?.key) || command(config?.apiKey) || command(config?.headers) || command(config?.models?.map(m => m.headers))) {
    ready = false; reason = "command_secret"; source = "saved";
  } else if (saved?.type === "oauth") {
    source = "saved"; type = "oauth";
    if (!text(saved.access) || !text(saved.refresh) || !Number.isFinite(saved.expires) || saved.expires <= Date.now()) { ready = false; reason = "oauth_expired"; }
    else key = saved.access;
  } else {
    const raw = saved?.key ?? config?.apiKey;
    if (raw !== undefined && typeof raw !== "string") failure("invalid_state");
    if (typeof raw === "string") {
      source = saved?.key !== undefined ? "saved" : "models";
      // Commands were rejected above. This resolver handles Pi's literal escapes
      // and provider-scoped environment; do not interpret its result a second time.
      if (!raw.includes("$")) key = raw;
      else key = (await loadRuntime(dir)).resolveConfigValue(raw, env);
    } else {
      // Ask the pinned provider's own resolver, not a duplicated env-var table.
      // Ambient cloud identity can cause request-time work: leave it to Pi.
      if (["amazon-bedrock", "google-vertex", "azure", "cloudflare-ai-gateway", "cloudflare-workers-ai"].includes(r.provider)) {
        source = "handoff"; ready = false; reason = "additional_setup";
      } else {
        const sdk = await loadRuntime(dir);
        const runtime = await sdk.ModelRuntime.create({ credentials: new sdk.InMemoryCredentialStore(), modelsStore: new sdk.InMemoryModelsStore(), modelsPath: null, refreshOnCreate: false, allowModelNetwork: false });
        const provider = runtime.getProvider(r.provider);
        if (provider?.auth?.apiKey) {
          const resolved = await provider.auth.apiKey.resolve({ ctx: { env: async name => process.env[name], fileExists: async () => false }, credential: undefined, signal: options.signal ?? AbortSignal.timeout(5000) });
          key = resolved?.auth?.apiKey;
          envName = resolved?.source;
        }
        source = "environment";
      }
    }
    if (!text(key)) { ready = false; reason ??= "credentials_not_configured"; }
  }
  if (r.mode === "existing" && config?.baseUrl && r.baseUrl && config.baseUrl.replace(/\/$/, "") !== r.baseUrl.replace(/\/$/, "")) { ready = false; reason = "endpoint_changed"; }
  if (r.mode === "existing" && ["azure", "cloudflare-ai-gateway", "cloudflare-workers-ai"].includes(r.provider)) {
    const merged = { ...process.env, ...env };
    if (r.provider === "azure" ? !config?.baseUrl && !merged.AZURE_OPENAI_BASE_URL && !merged.AZURE_OPENAI_RESOURCE_NAME
      : !merged.CLOUDFLARE_ACCOUNT_ID || r.provider === "cloudflare-ai-gateway" && !merged.CLOUDFLARE_GATEWAY_ID) { ready = false; reason = "additional_setup"; }
  }
  const revision = createHmac("sha256", r.nonce).update(JSON.stringify({ provider: r.provider, base: r.baseUrl, mode: r.mode, saved, config, source, key, type, ready, envPatch: r.env })).digest("hex");
  if (r.revision && r.revision !== revision) failure("stale");
  return { key, source, type, revision, ready, reason, realKey: ready && r.mode !== "none", envName, saved, config };
}

export async function inspectCredential(r, options = {}) {
  try {
    const s = await credentialSnapshot(r, options);
    const again = await credentialSnapshot(r, options);
    if (s.revision !== again.revision) return { version: 1, status: "ok", ready: false, reason: "stale" };
    const label = s.source === "environment" ? `Environment${typeof s.envName === "string" && /^[A-Z][A-Z0-9_]*$/.test(s.envName) ? ` (${s.envName})` : ""}; accepted key is saved privately on Apply`
      : s.source === "models" ? "Existing provider configuration" : s.source === "saved" ? `Saved Pi ${s.type === "oauth" ? "login" : "credential"}` : s.source === "none" ? "No real key (local marker)" : "New key";
    return { version: 1, status: "ok", ready: s.ready, reason: s.reason, source: s.source, type: s.type, label, revision: s.revision };
  } catch (e) { return e.message === "stale" ? { version: 1, status: "ok", ready: false, reason: "stale" } : unavailable("credential_unavailable"); }
}

/** Persist only after the accepted source is still the current one. */
export async function applyCredential(r, options = {}) {
  if (r.scope !== undefined) failure("invalid_request");
  const dir = options.packageDir ?? packageDir;
  const before = await credentialSnapshot(r, options);
  options.signal?.throwIfAborted();
  // Reuse is a no-write decision, not a readiness check — but only for entries
  // Pi still owns: an expired login, or a key supplied by a command. Those
  // stay untouched and unexecuted; inspect reports their limit. A credential
  // bound to another endpoint, or one missing required setup, must still
  // refuse: applying it would save settings the saved key cannot serve.
  const pi_owned = before.reason === "oauth_expired" || before.reason === "command_secret";
  if (r.mode === "existing" && pi_owned && ["saved", "models"].includes(before.source)) return { version: 1, status: "ok", wrote: false, source: before.source, revision: before.revision };
  if (!before.ready) failure(before.reason ?? "credentials_not_configured");
  if (r.mode === "none") {
    if (before.saved && (before.saved.type !== "api_key" || before.saved.key !== "mash-local")) failure("stale");
    if (before.config?.apiKey !== undefined || before.config?.headers !== undefined
      || before.config?.models?.some(row => row.id === r.model && row.headers !== undefined)) failure("stale");
  }
  options.signal?.throwIfAborted();
  // An accepted ambient environment key is copied privately so it survives
  // the launcher; other unchanged sources do not write.
  if (r.mode === "existing" && before.source !== "environment") return { version: 1, status: "ok", wrote: false, source: before.source, revision: before.revision };
  const path = join(r.agentDir, "auth.json");
  await safePath(path);
  const lock = createRequire(join(dir, "package.json"))("proper-lockfile");
  // Pi's own protocol: same `.lock` path and options, so writers interlock.
  const release = await lock.lock(path, { realpath: false, retries: { retries: 5, minTimeout: 50, maxTimeout: 500 }, stale: 10000, update: 2000 });
  const temp = `${path}.${randomBytes(6).toString("hex")}.tmp`;
  let file;
  try {
    options.signal?.throwIfAborted();
    await credentialSnapshot({ ...r, revision: before.revision }, options);
    const data = await readObject(path);
    const key = r.mode === "none" ? "mash-local" : before.key;
    const env = { ...object(data[r.provider]?.env) ? data[r.provider].env : {}, ...r.env };
    data[r.provider] = { type: "api_key", key: literal(key), ...Object.keys(env).length ? { env } : {} };
    file = await open(temp, "wx", 0o600);
    await file.writeFile(JSON.stringify(data, null, 2) + "\n");
    await file.sync();
    await file.close();
    file = undefined;
    options.signal?.throwIfAborted();
    await rename(temp, path);
    return { version: 1, status: "ok", wrote: true, source: r.mode === "none" ? "none" : "new" };
  } finally {
    await file?.close();
    await unlink(temp).catch(() => {});
    await release().catch(() => {});
  }
}

await cli(import.meta.url, (r, options) => (object(r) && r.action === "apply" ? applyCredential(r, options) : inspectCredential(r, options)));
