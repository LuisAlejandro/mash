// Conformance: a connection the wizard saves must actually carry text AND
// structured tool calls through the real pinned Pi client, not merely store a
// plausible API string. The server here is a loopback fixture that answers the
// way a local OpenAI-compatible server (Ollama, LM Studio, vLLM, SGLang) does.
// No real server, model, account or network is involved.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadRuntime } from "../helpers/mash-pi-runtime.mjs";
import { connect } from "../helpers/mash-pi-connect.mjs";

// Only the staged build gate has a real pin; ordinary `make test` has none and
// a mock would prove nothing here, so this suite states that it did not run.
const pin = process.argv[2];
if (!pin) {
  console.log("skip - Pi client conformance needs a staged pin: test_pi_runtime.sh <resource-root>");
  process.exit(77);
}

const root = await mkdtemp(join(tmpdir(), "mash-pi-client-"));
const agentDir = join(root, "agent");
await mkdir(agentDir);
const requests = [];

const sse = (lines) =>
  lines.map((line) => `data: ${JSON.stringify(line)}\n\n`).join("") + "data: [DONE]\n\n";

const server = createServer(async (req, res) => {
  let raw = "";
  for await (const chunk of req) raw += chunk;
  const body = raw ? JSON.parse(raw) : undefined;
  requests.push({ path: req.url, headers: req.headers, body });
  if (req.url.startsWith("/prefix/")) {
    // Stop the real SDK after recording its path; 401 must not retry. The
    // wizard's nonstreaming probe gets the body its own API family would send,
    // so a cross-family reply cannot be mistaken for a receipt.
    const path = req.url.split("?")[0];
    const success = path.endsWith("/messages") ? { type: "message", content: [] }
      : path.endsWith("/responses") ? { object: "response", output: [] }
      : { choices: [] };
    res.writeHead(body?.stream ? 401 : 200, { "content-type": "application/json" });
    res.end(JSON.stringify(body?.stream
      ? { type: "error", error: { type: "authentication_error", message: "fixture only" } }
      : success));
    return;
  }
  const base = { id: "1", object: "chat.completion.chunk", created: 0, model: body?.model };
  res.writeHead(200, { "content-type": "text/event-stream" });
  res.end(
    sse([
      { ...base, choices: [{ index: 0, delta: { role: "assistant", content: "Checking the clock." } }] },
      {
        ...base,
        choices: [
          {
            index: 0,
            delta: {
              tool_calls: [
                {
                  index: 0,
                  id: "call_1",
                  type: "function",
                  function: { name: "get_time", arguments: '{"zone":"UTC"}' },
                },
              ],
            },
          },
        ],
      },
      { ...base, choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }] },
    ]),
  );
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const baseUrl = `http://127.0.0.1:${server.address().port}/v1`;

try {
  // Exactly what the wizard writes for a local preset: Chat Completions, the
  // preset endpoint, the exact namespaced/tagged model ID and a non-secret key.
  await writeFile(
    join(agentDir, "models.json"),
    JSON.stringify({
      providers: {
        ollama: { baseUrl, api: "openai-completions", models: [{ id: "qwen3:8b" }] },
      },
    }),
  );
  await writeFile(
    join(agentDir, "auth.json"),
    JSON.stringify({ ollama: { type: "api_key", key: "mash-local" } }),
  );

  const sdk = await loadRuntime(pin);
  const saved = new sdk.ReadOnlyAuthStorage(join(agentDir, "auth.json"));
  const credentials = new sdk.InMemoryCredentialStore();
  for (const { providerId } of await saved.list()) {
    await credentials.modify(providerId, async () => await saved.read(providerId));
  }
  const runtime = await sdk.ModelRuntime.create({
    credentials,
    modelsStore: new sdk.InMemoryModelsStore(),
    modelsPath: join(agentDir, "models.json"),
    refreshOnCreate: false,
    allowModelNetwork: false,
  });
  assert.equal(runtime.getError(), undefined);

  const model = runtime.getModel("ollama", "qwen3:8b");
  assert.ok(model, "the saved definition must load as a model in the real pin");
  assert.equal(model.api, "openai-completions");

  const message = await runtime.complete(
    model,
    {
      systemPrompt: "You are a fixture.",
      messages: [{ role: "user", content: "What time is it?" }],
      tools: [
        {
          name: "get_time",
          description: "Return the current time.",
          parameters: {
            type: "object",
            properties: { zone: { type: "string" } },
            required: ["zone"],
            additionalProperties: false,
          },
        },
      ],
    },
    { signal: AbortSignal.timeout(20000) },
  );

  const text = message.content.filter((part) => part.type === "text").map((part) => part.text).join("");
  const calls = message.content.filter((part) => part.type === "toolCall");
  assert.equal(text, "Checking the clock.", "text content must survive the adapter");
  assert.equal(calls.length, 1, "the tool call must survive the adapter");
  assert.equal(calls[0].name, "get_time");
  assert.deepEqual(calls[0].arguments, { zone: "UTC" });

  // The client must send the exact saved identity, the declared tool and the
  // configured path prefix, so a conforming local server sees a valid request.
  assert.equal(requests.length, 1);
  const [sent] = requests;
  assert.equal(sent.path, "/v1/chat/completions");
  assert.equal(sent.body.model, "qwen3:8b", "the exact tag must not be rewritten");
  assert.equal(sent.body.tools[0].function.name, "get_time");
  assert.equal(sent.body.tools[0].function.parameters.required[0], "zone");
  assert.equal(sent.headers.authorization, "Bearer mash-local");
  console.log("ok - a saved local connection carries text and structured tool calls through the real Pi client");

  // Anthropic's pinned SDK appends /v1/messages even when the supplied base
  // already ends in /v1. Certify the persisted route, not a friendlier probe URL.
  for (const tail of ["/prefix/v1", "/prefix/v1///"]) {
    for (const [api, route] of [["anthropic-messages", "/v1/messages"],
      ["openai-completions", "/chat/completions"], ["openai-responses", "/responses"]]) {
      const fixtureBase = baseUrl.replace(/\/v1$/, tail);
      const probe = await connect({ version: 1, action: "probe", agentDir,
        provider: "fixture-api", baseUrl: fixtureBase, api,
        model: "fixture-model", mode: "none", nonce: "a".repeat(64), consent: true, selfHosted: true },
        { packageDir: pin });
      assert.equal(probe.accepted, true);
      const probePath = requests.at(-1).path;
      await writeFile(join(agentDir, "models.json"), JSON.stringify({ providers: {
        "fixture-api": { baseUrl: fixtureBase, api: probe.api, models: [{ id: "fixture-model" }] },
      } }));
      await credentials.modify("fixture-api", async () => ({ type: "api_key", key: "fixture-only-key" }));
      const client = await sdk.ModelRuntime.create({ credentials, modelsStore: new sdk.InMemoryModelsStore(),
        modelsPath: join(agentDir, "models.json"), refreshOnCreate: false, allowModelNetwork: false });
      const configured = client.getModel("fixture-api", "fixture-model");
      assert.ok(configured, client.getError());
      const beforeRequest = requests.length;
      await client.complete(configured, { messages: [{ role: "user", content: "Hi" }] },
        { signal: AbortSignal.timeout(20000) });
      assert.equal(requests.length, beforeRequest + 1, "the real SDK must send a request");
      assert.equal(probePath, tail.replace(/\/$/, "") + route);
      assert.equal(requests.at(-1).path.split("?")[0], probePath,
        `${api}: wizard and pinned client must use the exact same saved base path`);
    }
  }
  console.log("ok - all three probes match real pinned SDK paths, including prefixed /v1 and repeated trailing slashes");
} finally {
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
  await rm(root, { recursive: true, force: true });
}
