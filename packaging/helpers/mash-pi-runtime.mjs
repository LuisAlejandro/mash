// Shared fixed-location Pi imports and bounded, secret-safe helper framing.
import { realpathSync } from "node:fs";
import { lstat, open } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const packageDir = join(dirname(fileURLToPath(import.meta.url)), "../node/lib/node_modules/@earendil-works/pi-coding-agent");
export const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
export const text = value => typeof value === "string" && value.length > 0 && value.length <= 4096 && !/[\x00-\x1f\x7f-\x9f]/u.test(value);
// Pi escapes a literal "$" as "$$" and a leading command "!" as "$!".
export const literal = value => value.replaceAll("$", () => "$$").replace(/^!/, () => "$!");
export const unavailable = reason => ({ version: 1, status: "unavailable", reason });

export async function safePath(path) {
  for (const p of [dirname(path), path]) {
    try { if ((await lstat(p)).isSymbolicLink()) throw new Error("unsafe_path"); }
    catch (e) { if (e.code !== "ENOENT") throw e; }
  }
}

async function readText(path, limit) {
  await safePath(path);
  let file;
  try {
    file = await open(path, "r");
    const stat = await file.stat();
    if (!stat.isFile() || stat.size > limit) throw new Error("invalid_state");
    const bytes = Buffer.alloc(stat.size + 1);
    const { bytesRead } = await file.read(bytes, 0, bytes.length, 0);
    if (bytesRead > stat.size) throw new Error("invalid_state");
    return bytes.subarray(0, bytesRead).toString("utf8");
  } catch (e) { if (e.code === "ENOENT") return undefined; throw e; }
  finally { await file?.close(); }
}

export async function readObject(path) {
  const content = await readText(path, 4 * 1024 * 1024);
  if (content === undefined) return {};
  const value = JSON.parse(content.replace(/^\uFEFF/, ""));
  if (!object(value)) throw new Error("invalid_state");
  return value;
}

export async function readHindsight(path) {
  const content = await readText(path, 1024 * 1024);
  if (content === undefined) return {};
  const values = {};
  for (const line of content.split(/\r?\n/)) {
    const match = line.match(/^\s*(?:export\s+)?(HINDSIGHT_API_LLM_(?:PROVIDER|MODEL|BASE_URL|API_KEY))\s*=\s*(.*?)\s*$/);
    if (!match) continue;
    let value = match[2];
    if (value.length >= 2 && ["'", '"'].includes(value[0]) && value.at(-1) === value[0]) value = value.slice(1, -1);
    values[match[1]] = value;
  }
  return values;
}

export async function loadRuntime(dir = packageDir) {
  const sdk = await import(pathToFileURL(join(dir, "dist/index.js")).href);
  const ai = await import(pathToFileURL(join(dir, "node_modules/@earendil-works/pi-ai/dist/index.js")).href);
  const storage = await import(pathToFileURL(join(dir, "dist/core/auth-storage.js")).href);
  const values = await import(pathToFileURL(join(dir, "dist/core/resolve-config-value.js")).href);
  if (typeof values.resolveConfigValue !== "function" || typeof sdk.ModelRuntime?.create !== "function" || typeof ai.InMemoryCredentialStore !== "function" || typeof ai.InMemoryModelsStore !== "function" || typeof storage.ReadOnlyAuthStorage !== "function") throw new Error("runtime_unavailable");
  return { ...sdk, ...ai, ...storage, ...values };
}

export async function cli(url, action, fallback = unavailable) {
  if (!process.argv[1] || pathToFileURL(realpathSync(process.argv[1])).href !== url) return;
  // Parent retains PI_OFFLINE for all catalog operations. Network entrypoints
  // use only their explicit guarded HTTP action, never Pi catalog refresh.
  process.env.PI_OFFLINE = "1";
  const abort = new AbortController();
  process.once("SIGTERM", () => abort.abort());
  let result;
  try {
    let input = "";
    process.stdin.setEncoding("utf8");
    for await (const part of process.stdin) {
      input += part;
      if (Buffer.byteLength(input) > 65536) throw new Error("input_limit");
    }
    result = await action(JSON.parse(input), { signal: abort.signal });
  } catch (error) { result = fallback(error?.message === "input_limit" ? "input_limit" : "invalid_request"); }
  let output = JSON.stringify(result);
  if (Buffer.byteLength(output) > 4 * 1024 * 1024) { result = fallback("output_limit"); output = JSON.stringify(result); }
  process.stdout.write(output + "\n");
  process.exitCode = result.status === "ok" ? 0 : 2;
}
