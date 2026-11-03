// The only outbound path. Every request is destination-checked and bounded.
import { lookup } from "node:dns";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { BlockList, isIP } from "node:net";

const MAX_BODY = 16 * 1024 * 1024;

const deny = new BlockList();
// Always denied, even for self-hosted targets: cloud metadata and link-local.
deny.addSubnet("169.254.0.0", 16);
deny.addSubnet("fe80::", 10, "ipv6");
deny.addAddress("100.100.100.200");
deny.addSubnet("0.0.0.0", 8);
deny.addAddress("::", "ipv6");

const privateRanges = new BlockList();
for (const [net, bits] of [["10.0.0.0", 8], ["172.16.0.0", 12], ["192.168.0.0", 16], ["100.64.0.0", 10], ["198.18.0.0", 15], ["192.0.0.0", 24]]) privateRanges.addSubnet(net, bits);
privateRanges.addSubnet("fc00::", 7, "ipv6");

const loopback = new BlockList();
loopback.addSubnet("127.0.0.0", 8);
loopback.addAddress("::1", "ipv6");

const check = (list, address) => {
  const family = isIP(address) === 6 ? "ipv6" : "ipv4";
  if (!isIP(address)) return false;
  // Native BlockList understands IPv4-mapped IPv6 when asked as ipv6.
  return list.check(address, family) || family === "ipv6" && /^::ffff:/i.test(address) && list.check(address.replace(/^::ffff:/i, ""), "ipv4");
};

/** Loopback is trusted only for an explicitly loopback target, never by DNS result. */
export function allowedAddress(address, selfHosted, loopbackTarget) {
  if (!isIP(address) || check(deny, address)) return false;
  if (check(loopback, address)) return loopbackTarget === true;
  if (check(privateRanges, address)) return selfHosted === true;
  return true;
}

export function checkedUrl(raw, selfHosted) {
  const url = new URL(raw);
  if (!["http:", "https:"].includes(url.protocol)) throw new Error("unsupported_scheme");
  if (url.username || url.password || url.search || url.hash) throw new Error("unsafe_url");
  if (url.protocol === "http:" && !selfHosted) throw new Error("plaintext_not_allowed");
  const host = url.hostname.replace(/\.$/, "").replace(/^\[|\]$/g, "").toLowerCase();
  if (!host || /\s/.test(host)) throw new Error("unsafe_url");
  if (["metadata.google.internal", "metadata.goog"].includes(host) || host.endsWith(".internal")) throw new Error("blocked_host");
  const loopbackTarget = host === "localhost" || host.endsWith(".localhost") || isIP(host) && check(loopback, host);
  if (isIP(host) && !allowedAddress(host, selfHosted, loopbackTarget)) throw new Error("blocked_host");
  return { url, host, loopbackTarget };
}

/** Pin the validated addresses; TLS still verifies the original hostname. */
export function pinnedLookup(selfHosted, loopbackTarget, resolver = lookup) {
  return (hostname, options, callback) => resolver(hostname, { ...options, all: true }, (error, addresses) => {
    if (error) return callback(error);
    const rows = (Array.isArray(addresses) ? addresses : [addresses]).filter(Boolean);
    if (!rows.length || rows.some(row => !allowedAddress(row.address, selfHosted, loopbackTarget))) {
      return callback(Object.assign(new Error("blocked_address"), { code: "EBLOCKED" }));
    }
    return options?.all ? callback(null, rows) : callback(null, rows[0].address, rows[0].family);
  });
}

export async function requestJson(target, { method = "GET", headers = {}, body, timeoutMs = 5000, selfHosted = false } = {}) {
  const { url, host, loopbackTarget } = checkedUrl(target, selfHosted);
  const payload = body === undefined ? undefined : Buffer.from(JSON.stringify(body));
  const send = url.protocol === "https:" ? httpsRequest : httpRequest;
  const deadline = AbortSignal.timeout(timeoutMs);
  return await new Promise((resolve, reject) => {
    const req = send(url, {
      method,
      headers: { accept: "application/json", ...payload ? { "content-type": "application/json", "content-length": payload.length } : {}, ...headers },
      lookup: pinnedLookup(selfHosted, loopbackTarget),
      servername: isIP(host) ? undefined : host,
      timeout: timeoutMs,
      signal: deadline,
    }, response => {
      // Redirects are never followed: a new destination needs new approval.
      const type = (response.headers["content-type"] ?? "").split(";")[0].trim().toLowerCase();
      const chunks = [];
      let size = 0;
      response.on("data", chunk => {
        size += chunk.length;
        if (size > MAX_BODY) { response.destroy(); req.destroy(); return reject(new Error("body_limit")); }
        chunks.push(chunk);
      });
      response.on("end", () => {
        let json;
        try { json = JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch { json = undefined; }
        resolve({ status: response.statusCode ?? 0, type, json, redirected: response.statusCode >= 300 && response.statusCode < 400 });
      });
      response.on("error", () => reject(new Error(deadline.aborted ? "timeout" : "request_failed")));
    });
    const fail = reason => { req.destroy(); reject(new Error(reason)); };
    req.on("timeout", () => fail("timeout"));
    req.on("error", error => fail(deadline.aborted ? "timeout" : error.code === "EBLOCKED" ? "blocked_address" : error.code === "ECONNREFUSED" ? "unreachable" : "request_failed"));
    if (payload) req.write(payload);
    req.end();
  });
}
