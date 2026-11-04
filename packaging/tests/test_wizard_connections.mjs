// Actual socket contract; no real server or account is contacted.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { createServer as createTlsServer } from "node:https";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { checkedUrl, allowedAddress, pinnedLookup, requestJson } from "../helpers/mash-pi-http.mjs";
import { connect, PRESETS } from "../helpers/mash-pi-connect.mjs";

const agentDir = await mkdtemp(join(tmpdir(), "mash-connect-"));
const seen = [];
let mode = "auto";
let beforeReply;
const server = createServer(async (req, res) => {
  let raw = "";
  for await (const c of req) raw += c;
  seen.push({ path: req.url, headers: req.headers, body: raw ? JSON.parse(raw) : undefined });
  await beforeReply?.();
  if (mode === "trickle") {
    res.writeHead(200, { "content-type": "application/json" });
    let chunks = 0;
    const timer = setInterval(() => {
      if (++chunks < 20) res.write(" ");
      else { clearInterval(timer); res.end("{}"); }
    }, 10);
    res.once("close", () => clearInterval(timer));
    return;
  }
  if (mode === "exhaust") { res.writeHead(404); res.end("{}"); }
  else if (mode === "wrong-family") { res.setHeader("content-type", "application/json"); res.end(JSON.stringify({ choices: [] })); }
  else if (mode === "error-status") { res.setHeader("content-type", "application/json"); res.end(JSON.stringify({ status: "error", message: "unsupported API family; use Responses" })); }
  else if (mode === "redirect") { res.writeHead(302, { location: "http://169.254.169.254/" }); res.end(); }
  else if (mode === "html") { res.setHeader("content-type", "text/html"); res.end("not a model API"); }
  else if (["malformed", "empty-body", "no-content", "error-body", "scalar", "null"].includes(mode)) {
    res.writeHead(mode === "no-content" ? 204 : 200, { "content-type": "application/json" });
    res.end(mode === "malformed" ? "this is not JSON" : mode === "error-body" ? '{"error":{"message":"not a model"}}' : mode === "scalar" ? '"ok"' : mode === "null" ? "null" : "");
  }
  else if (mode === "large" && req.url === "/api/tags") { res.setHeader("content-type", "application/json"); res.end(JSON.stringify({ models: Array.from({ length: 501 }, (_, index) => ({ name: `model-${String(index).padStart(4, "0")}` })) })); }
  else if (mode === "tags") { res.setHeader("content-type", "application/json"); res.end(JSON.stringify({ models: [{ name: "qwen3:8b" }, { name: "qwen3:8b" }, { name: "gpt-oss:120b-cloud", remote_host: "ollama.com" }, { name: "\u0007bad\u0000" }, { nope: 1 }] })); }
  else if (mode === "lmstudio") { res.setHeader("content-type", "application/json"); res.end(JSON.stringify({ data: [{ id: "local/chat", type: "llm" }, { id: "nomic-embed", type: "embeddings" }] })); }
  else if (mode === "empty") { res.setHeader("content-type", "application/json"); res.end(JSON.stringify({ data: [] })); }
  else if (mode === "unauthorized") { res.writeHead(401); res.end("{}"); }
  else if (mode === "show") { res.setHeader("content-type", "application/json"); res.end(JSON.stringify(req.url === "/api/show" && JSON.parse(raw).model === "qwen3:8b" ? { details: { families: ["qwen3"] }, capabilities: ["tools"] } : {})); }
  else if (mode === "absent") { res.writeHead(404); res.end("{}"); }
  else if (mode === "auto" && req.url.endsWith("chat/completions")) { res.writeHead(404); res.end(); }
  else if (mode === "auto" && req.url.endsWith("/responses")) { res.setHeader("content-type", "application/json"); res.end(JSON.stringify({ object: "response", output: [] })); }
  else { res.setHeader("content-type", "application/json"); res.end(JSON.stringify({ choices: [] })); }
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const baseUrl = `http://127.0.0.1:${server.address().port}/prefix/v1`;
const input = { version: 1, action: "probe", agentDir, provider: "custom", baseUrl, api: "auto", model: "exact/model:tag", mode: "none", nonce: "a".repeat(64), consent: true, selfHosted: true };
try {
  let r = await connect(input);
  assert.equal(r.status, "ok");
  assert.equal(r.accepted, true);
  assert.equal(r.api, "openai-responses");
  assert.deepEqual(seen.map(r => r.path), ["/prefix/v1/chat/completions", "/prefix/v1/responses"]);
  assert.equal(seen[0].body.max_tokens, 16);
  assert.equal(seen[1].body.input, "Hi");
  assert.equal(seen[0].headers.authorization, undefined, "no-auth must never inherit a hosted token");
  mode = "exhaust";
  seen.length = 0;
  r = await connect(input);
  assert.equal(seen.length, 3, "Auto may attempt each of the three families once");
  assert.equal(r.accepted, false);
  assert.equal(seen.at(-1).path, "/prefix/v1/v1/messages", "match the pinned Anthropic client's /v1/messages suffix");
  for (const bad of ["malformed", "empty-body", "no-content", "error-body", "scalar", "null"]) {
    mode = bad;
    seen.length = 0;
    const refused = await connect(input);
    assert.equal(refused.accepted, false, bad);
    assert.equal(seen.length, 3, `${bad}: Auto continues instead of accepting a bad first response`);
  }
  mode = "auto";
  mode = "html";
  assert.equal((await connect({ ...input, api: "anthropic-messages" })).accepted, false);
  assert.equal(seen.at(-1).body.max_tokens, 1);
  // A chat-shaped body is not an Anthropic or Responses receipt: the wizard
  // would persist that API family from a reply proving a different route.
  mode = "wrong-family";
  for (const api of ["anthropic-messages", "openai-responses"]) {
    const mismatch = await connect({ ...input, api });
    assert.equal(mismatch.accepted, false, api);
    assert.equal(mismatch.reason, "wrong_api", api);
  }
  assert.equal((await connect({ ...input, api: "openai-completions" })).accepted, true);
  // A 200 status:error envelope is a refusal, not the first family's success.
  mode = "error-status";
  seen.length = 0;
  const errorStatus = await connect(input);
  assert.equal(errorStatus.accepted, false);
  assert.equal(seen.length, 3, "Auto keeps trying after a status:error reply");
  mode = "success";
  mode = "redirect";
  const beforeRedirect = seen.length;
  const redirected = await connect({ ...input, api: "openai-completions" });
  assert.equal(redirected.accepted, false);
  assert.equal(redirected.reason, "redirected", "the cause survives, not just the refusal");
  assert.equal(seen.length, beforeRedirect + 1, "a redirect is never followed");
  for (const url of ["file:///tmp/keys", "http://user:key@localhost/", "http://localhost/?key=secret", "https://metadata.google.internal/"]) assert.throws(() => checkedUrl(url, true));
  for (const address of ["169.254.169.254", "::ffff:169.254.169.254", "fe80::1", "100.100.100.200", "0.0.0.0", "::"]) assert.equal(allowedAddress(address, true, true), false, address);
  assert.equal(allowedAddress("127.0.0.1", true, true), true);
  assert.equal(allowedAddress("127.0.0.1", true, false), false);
  assert.equal(allowedAddress("192.168.1.2", false, false), false);
  assert.equal(allowedAddress("192.168.1.2", true, false), true);

  // The pinned lookup is what stops a public hostname from reaching a private
  // address, so its deny branch needs its own evidence.
  const resolveTo = (...addresses) => (hostname, options, callback) => callback(null, addresses.map(address => ({ address, family: address.includes(":") ? 6 : 4 })));
  const pin = (selfHosted, loopbackTarget, resolver) => new Promise(resolve => pinnedLookup(selfHosted, loopbackTarget, resolver)("api.example.com", { all: true }, (error, rows) => resolve(error ?? rows)));
  assert.equal((await pin(false, false, resolveTo("10.0.0.5")))?.code, "EBLOCKED", "a private range behind a public name is refused");
  assert.equal((await pin(false, false, resolveTo("127.0.0.1")))?.code, "EBLOCKED", "loopback is trusted only for an explicit loopback target");
  assert.equal((await pin(false, false, resolveTo("93.184.216.34", "169.254.169.254")))?.code, "EBLOCKED", "one denied address in the answer blocks the whole pin");
  assert.deepEqual((await pin(false, false, resolveTo("93.184.216.34"))).map(row => row.address), ["93.184.216.34"], "a public address is pinned as-is");
  // Proof the gate itself refuses: the endpoint would otherwise accept.
  mode = "auto";
  const accepted = await connect({ ...input, api: "auto" });
  assert.equal(accepted.accepted, true, "the fixture accepts when consent is given");
  const beforeConsent = seen.length;
  mode = "auto";
  assert.equal((await connect({ ...input, consent: false })).reason, "consent_required");
  assert.equal(seen.length, beforeConsent, "no request may leave before consent");

  // U3: the four local routes, their metadata paths and catalog rules.
  assert.deepEqual(Object.keys(PRESETS), ["ollama", "lmstudio", "vllm", "sglang"]);
  for (const preset of Object.values(PRESETS)) assert.ok(checkedUrl(preset.baseUrl, true));
  seen.length = 0;
  mode = "tags";
  const discovery = { ...input, action: "discover", preset: "ollama" };
  r = await connect(discovery);
  assert.deepEqual(r.models, ["qwen3:8b"], "keep tags, drop duplicates, cloud rows and unsafe ids");
  assert.equal(seen.at(-1).path, "/api/tags", "native metadata route ignores the inference prefix");
  mode = "large";
  r = await connect(discovery);
  assert.equal(r.models.length, 500);
  assert.equal(r.truncated, true);
  assert.ok(!r.models.includes("model-0500"));
  assert.equal((await connect({ ...input, api: "openai-completions", model: "model-0500" })).accepted, true,
    "an exact omitted model can be verified independently of its truncated catalog");
  mode = "lmstudio";
  r = await connect({ ...discovery, preset: "lmstudio" });
  assert.deepEqual(r.models, ["local/chat"]);
  assert.equal(seen.at(-1).path, "/api/v1/models");
  mode = "empty";
  assert.equal((await connect({ ...discovery, preset: "lmstudio" })).accepted, false, "no LLM is not a usable LM Studio connection");
  r = await connect({ ...discovery, preset: "vllm" });
  assert.equal(r.accepted, true, "vLLM may still be used by exact manual entry");
  assert.equal(seen.at(-1).path, "/prefix/v1/models", "served-model routes keep the configured prefix");
  // Discovery joins our own route, so a pasted base with repeated slashes must
  // still ask for /prefix/v1/models rather than /prefix/v1////models.
  r = await connect({ ...discovery, preset: "vllm", baseUrl: `${baseUrl}///` });
  assert.equal(seen.at(-1).path, "/prefix/v1/models", "discovery trims every trailing slash");
  assert.equal(r.accepted, true);
  mode = "unauthorized";
  assert.equal((await connect({ ...discovery, preset: "ollama" })).reason, "unauthorized");
  assert.ok(!seen.some(row => /pull|create|delete|push|login/.test(row.path)), "discovery must never administer the server");

  // Hindsight discovery owns its credential, even when Pi has another one for
  // the same provider. The endpoint is an explicit loopback fixture only.
  const home = join(agentDir, "separate-credential-owner");
  const memoryAgent = join(home, "pi/agent");
  await mkdir(memoryAgent, { recursive: true });
  await mkdir(join(home, ".hindsight"));
  const piSecret = "pi-secret-must-not-cross";
  const memorySecret = "hindsight-owned-secret";
  await writeFile(join(memoryAgent, "auth.json"), JSON.stringify({ openai: { type: "api_key", key: piSecret } }));
  await writeFile(join(home, ".hindsight/embed"), `HINDSIGHT_API_LLM_PROVIDER=openai\nHINDSIGHT_API_LLM_BASE_URL='${baseUrl}'\nHINDSIGHT_API_LLM_API_KEY='${memorySecret}'\n`);
  mode = "lmstudio";
  const memory = { ...input, agentDir: memoryAgent, provider: "openai", scope: "hindsight", action: "discover", asCatalog: true, mode: "existing" };
  r = await connect(memory);
  assert.equal(r.status, "ok");
  assert.equal(r.serverVerified, false);
  assert.equal(r.auth.status, "unverified");
  assert.ok(r.models.some(model => model.id === "local/chat" && model.provider === "openai"));
  assert.equal(seen.at(-1).path, "/prefix/v1/models");
  assert.equal(seen.at(-1).headers.authorization, `Bearer ${memorySecret}`);
  assert.ok(!JSON.stringify(r).includes(memorySecret) && !JSON.stringify(r).includes(piSecret));
  const count = seen.length;
  assert.equal((await connect({ ...memory, baseUrl: baseUrl + "/changed" })).accepted, false);
  assert.equal(seen.length, count, "a changed destination must not receive Hindsight's old key");
  assert.equal((await connect({ ...memory, provider: "anthropic" })).status, "unavailable", "Hindsight owns only its own OpenAI endpoint");
  await connect({ ...memory, mode: "new", key: "new-memory-key" });
  assert.equal(seen.at(-1).headers.authorization, "Bearer new-memory-key");
  assert.ok(!seen.some(row => row.headers.authorization === `Bearer ${piSecret}`));
  console.log("ok - Hindsight catalog reuses only its own bound key, never Pi credentials, and exposes no material");

  // The accepted source must still be current when a probe result is returned.
  mode = "success";
  await writeFile(join(agentDir, "auth.json"), JSON.stringify({ custom: { type: "api_key", key: "accepted-old-key" } }));
  beforeReply = () => writeFile(join(agentDir, "auth.json"), JSON.stringify({ custom: { type: "api_key", key: "rotated-key" } }));
  r = await connect({ ...input, mode: "existing", api: "openai-completions" });
  beforeReply = undefined;
  assert.equal(r.accepted, false, "an externally rotated credential makes the receipt stale");
  assert.equal(r.reason, "stale");

  // A trickling response must not turn a per-attempt timeout into an idle timer.
  mode = "trickle";
  await assert.rejects(requestJson(baseUrl, { selfHosted: true, timeoutMs: 40 }), /timeout/);
  mode = "success";

  // TLS: a loopback HTTPS fixture, generated here and never committed.
  const openssl = spawnSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
    "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
    "-keyout", join(agentDir, "tls.key"), "-out", join(agentDir, "tls.crt")], { encoding: "utf8" });
  if (openssl.status !== 0) {
    console.log("skip - TLS fixture: openssl unavailable, HTTPS guards unproven here");
  } else {
    const tls = createTlsServer({ key: readFileSync(join(agentDir, "tls.key")), cert: readFileSync(join(agentDir, "tls.crt")) },
      (_req, res) => { res.setHeader("content-type", "application/json"); res.end("{}"); });
    await new Promise(resolve => tls.listen(0, "127.0.0.1", resolve));
    const https = `https://localhost:${tls.address().port}/v1`;
    try {
      // Verification is never relaxed: an untrusted certificate is a failure,
      // not a connection, even on loopback.
      r = await connect({ ...input, baseUrl: https, selfHosted: false });
      assert.equal(r.accepted, false);
      assert.ok(!/Connected/.test(JSON.stringify(r)));
      await assert.rejects(requestJson(https, { selfHosted: false }), /request_failed/);
      // The same fixture, trusted, proves HTTPS itself works through the guard.
      // The child owns both ends: a blocking parent would never accept the
      // connection, and a hang here would look like a helper failure.
      const trusted = spawnSync(process.execPath, ["--input-type=module", "-e", `
        const { createServer } = await import("node:https");
        const { readFileSync } = await import("node:fs");
        const { requestJson } = await import(process.env.MASH_HTTP);
        const server = createServer({ key: readFileSync(process.env.MASH_KEY), cert: readFileSync(process.env.MASH_CERT) },
          (_req, res) => { res.setHeader("content-type", "application/json"); res.end("{}"); });
        await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
        const result = await requestJson(\`https://127.0.0.1:\${server.address().port}/v1\`, { selfHosted: false });
        process.stdout.write(String(result.status) + " " + result.type);
        server.closeAllConnections();
        server.close();
      `], {
        encoding: "utf8",
        env: { ...process.env, NODE_EXTRA_CA_CERTS: join(agentDir, "tls.crt"), MASH_KEY: join(agentDir, "tls.key"), MASH_CERT: join(agentDir, "tls.crt"), MASH_HTTP: new URL("../helpers/mash-pi-http.mjs", import.meta.url).href },
      });
      assert.equal(trusted.stdout, "200 application/json", trusted.stderr);
      console.log("ok - HTTPS verification is never relaxed, and a trusted loopback certificate connects");
    } finally {
      tls.closeAllConnections();
      await new Promise(resolve => tls.close(resolve));
    }
  }
  await assert.rejects(requestJson("http://metadata.google.internal/", { selfHosted: true }));
  console.log("ok - explicit tiny probes, ordered detection, prefix handling, no-auth, MIME, redirect and IP guards");
  console.log("ok - local presets discover their own catalogs, exclude remote/non-chat rows and never administer a server");
} finally {
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
  await rm(agentDir, { recursive: true, force: true });
}
