#!/usr/bin/env node
// Explicit endpoint actions only. Discovery and probes never run implicitly.
import { credentialSnapshot, validCredentialRequest } from "./mash-pi-credentials.mjs";
import { requestJson } from "./mash-pi-http.mjs";
import { cli, object, text, unavailable } from "./mash-pi-runtime.mjs";

const APIS = ["openai-completions", "openai-responses", "anthropic-messages"];
export const PRESETS = {
  ollama: { label: "Ollama (local)", baseUrl: "http://127.0.0.1:11434/v1", metadata: "/api/tags", requireModel: true },
  lmstudio: { label: "LM Studio", baseUrl: "http://localhost:1234/v1", metadata: "/api/v1/models", requireModel: true },
  vllm: { label: "vLLM", baseUrl: "http://127.0.0.1:8000/v1", metadata: "/models", requireModel: false },
  sglang: { label: "SGLang", baseUrl: "http://127.0.0.1:30000/v1", metadata: "/models", requireModel: false },
};

const failed = (reason, extra = {}) => ({ version: 1, status: "ok", accepted: false, reason, ...extra });
const base = url => url.replace(/\/+$/, "");
const serverRoot = url => new URL(url).origin;

function validRequest(r) {
  if (!object(r) || !["discover", "probe"].includes(r.action) || !text(r.baseUrl)) return false;
  if (r.action === "probe" && !(text(r.model) && (r.api === "auto" || APIS.includes(r.api)))) return false;
  if (r.action === "discover" && !(r.preset === undefined || Object.hasOwn(PRESETS, r.preset))) return false;
  return validCredentialRequest({ ...r, action: "inspect" });
}

function probeRequest(api, baseUrl, model, auth) {
  const headers = !auth.realKey || !text(auth.key) ? {}
    : api === "anthropic-messages" ? { "x-api-key": auth.key, "anthropic-version": "2023-06-01" } : { authorization: `Bearer ${auth.key}` };
  if (api === "anthropic-messages") {
    return { url: `${/\/v1$/.test(base(baseUrl)) ? base(baseUrl) : `${base(baseUrl)}/v1`}/messages`, headers, body: { model, max_tokens: 1, messages: [{ role: "user", content: "Hi" }], stream: false } };
  }
  if (api === "openai-responses") return { url: `${base(baseUrl)}/responses`, headers, body: { model, input: "Hi", max_output_tokens: 16, stream: false } };
  return { url: `${base(baseUrl)}/chat/completions`, headers, body: { model, messages: [{ role: "user", content: "Hi" }], max_tokens: 16, stream: false } };
}

async function attempt(api, r, auth) {
  const { url, headers, body } = probeRequest(api, r.baseUrl, r.model, auth);
  try {
    const response = await requestJson(url, { method: "POST", headers, body, timeoutMs: 30000, selfHosted: r.selfHosted === true });
    if (response.redirected) return { accepted: false, reason: "redirected" };
    if (response.status < 200 || response.status >= 300) return { accepted: false, reason: response.status === 401 || response.status === 403 ? "unauthorized" : response.status === 404 ? "not_found" : "rejected", http: response.status };
    // An HTML page is a wrong-endpoint answer, never a model API success.
    if (response.type && response.type !== "application/json" && !response.type.endsWith("+json")) return { accepted: false, reason: "not_json" };
    return { accepted: true };
  } catch (error) { return { accepted: false, reason: error.message === "timeout" ? "timeout" : error.message }; }
}

async function discover(r, auth) {
  const preset = PRESETS[r.preset] ?? { metadata: "/models", requireModel: false };
  const url = preset.metadata.startsWith("/api") ? serverRoot(r.baseUrl) + preset.metadata : base(r.baseUrl) + preset.metadata;
  const headers = auth.realKey && text(auth.key) ? { authorization: `Bearer ${auth.key}` } : {};
  let response;
  try { response = await requestJson(url, { headers, timeoutMs: 5000, selfHosted: r.selfHosted === true }); }
  catch (error) { return failed(error.message === "timeout" ? "timeout" : error.message, { models: [], required: preset.requireModel }); }
  if (response.status === 401 || response.status === 403) return failed("unauthorized", { models: [], required: preset.requireModel });
  if (response.status < 200 || response.status >= 300) return failed("rejected", { http: response.status, models: [], required: preset.requireModel });
  const rows = Array.isArray(response.json?.data) ? response.json.data : Array.isArray(response.json?.models) ? response.json.models : [];
  const models = [];
  for (const row of rows) {
    const id = typeof row?.id === "string" ? row.id : typeof row?.key === "string" ? row.key : typeof row?.name === "string" ? row.name : undefined;
    // Exclude Ollama rows served from another host and non-chat LM Studio rows.
    if (!text(id) || models.includes(id)) continue;
    if (r.preset === "ollama" && typeof row?.remote_host === "string" && row.remote_host.trim()) continue;
    if (r.preset === "lmstudio" && row?.type !== undefined && row.type !== "llm") continue;
    models.push(id);
    if (models.length >= 500) break;
  }
  return { version: 1, status: "ok", accepted: models.length > 0 || !preset.requireModel, models, truncated: models.length >= 500 && rows.length > models.length, required: preset.requireModel, reason: models.length ? undefined : "no_models" };
}

export async function connect(r, options = {}) {
  if (!validRequest(r)) return unavailable("invalid_request");
  if (r.action === "probe" && r.consent !== true) return failed("consent_required");
  let auth;
  try { auth = await credentialSnapshot({ ...r, action: "inspect" }, options); }
  catch (error) { return error.message === "stale" ? failed("stale") : unavailable("credential_unavailable"); }
  if (!auth.ready && r.mode !== "none") return failed(auth.reason ?? "credentials_not_configured");
  const current = async () => {
    try { await credentialSnapshot({ ...r, revision: auth.revision }, options); return true; }
    catch { return false; }
  };
  if (r.action === "discover") {
    const result = await discover(r, auth);
    if (!await current()) return failed("stale");
    if (r.asCatalog === true) {
      const ids = Array.isArray(result.models) ? result.models : [];
      return { version: 1, status: "ok", models: ids.map(id => ({ provider: r.provider, id, name: id })),
        catalogComplete: result.accepted === true && result.truncated !== true && ids.length > 0,
        modelKnown: null, auth: { status: "unverified", reason: "not_tested" }, serverVerified: false };
    }
    return { ...result, revision: auth.revision };
  }
  let last = { reason: "rejected" };
  for (const api of r.api === "auto" ? APIS : [r.api]) {
    const result = await attempt(api, r, auth);
    if (!await current()) return failed("stale");
    if (result.accepted) return { version: 1, status: "ok", accepted: true, api, revision: auth.revision };
    last = result;
  }
  return failed(last.reason, { http: last.http });
}

await cli(import.meta.url, connect);
