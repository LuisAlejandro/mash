#!/usr/bin/env node
// A restored pi pane must reopen its conversation.
//
// Herdr restores a pane by replaying the resume command that pane reported, and
// accepts that command only from the reporter that already holds the pane. The
// stock Herdr pi integration reported the session reference but no resume
// command, so a pi pane came back as a bare shell and pi started a new empty
// conversation while the old one sat unused on disk.
//
// herdr-agent-state.ts (Mash's patched copy) now sends the resume command after
// the state report, as `pi --session <file>`. This test pins that contract:
// the report order Herdr requires, the command shape, and the paths Herdr
// refuses.
//
//   node packaging/tests/test_pi_restore_resume.mjs
//
// Node >= 23.6 loads the TypeScript extension directly (type stripping).
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SESSION = "/Users/someone/.mash/pi/agent/sessions/--repo--/2026-01-01T00-00-00-000Z_abc.jsonl";

// The stock module reads its socket at import time, so the fake server has to
// exist before the import.
const dir = mkdtempSync(join(tmpdir(), "herdr-pi-restore-"));
const sock = join(dir, "api.sock");
const seen = [];
const server = net.createServer((conn) => {
  let buffer = "";
  conn.on("data", (chunk) => {
    buffer += chunk;
    let index;
    while ((index = buffer.indexOf("\n")) >= 0) {
      seen.push(JSON.parse(buffer.slice(0, index)));
      buffer = buffer.slice(index + 1);
      conn.write(`${JSON.stringify({ result: { type: "ok" } })}\n`);
    }
  });
});
await new Promise((resolve) => server.listen(sock, resolve));

process.env.HERDR_ENV = "1";
process.env.HERDR_SOCKET_PATH = sock;
process.env.HERDR_PANE_ID = "w5:p2";

const { default: factory } = await import(
  new URL("../defaults/pi/extensions/herdr-agent-state.ts", import.meta.url).href
);

function startSession(sessionFile) {
  seen.length = 0;
  const handlers = {};
  const events = {};
  factory({
    on: (name, handler) => { handlers[name] = handler; },
    events: { on: (name, handler) => { events[name] = handler; } },
  });
  handlers.session_start(
    { reason: "startup" },
    { mode: "tui", isIdle: () => true, sessionManager: { getSessionFile: () => sessionFile } },
  );
  return events;
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 300));

startSession(SESSION);
await settle();

const sessionReport = seen.find((r) => r.method === "pane.report_agent_session");
const stateReport = seen.find((r) => r.method === "pane.report_agent" && !r.params.resume_argv);
const resumeReport = seen.find((r) => r.method === "pane.report_agent" && r.params.resume_argv);

assert.ok(sessionReport, "the session reference must still be reported");
assert.equal(sessionReport.params.agent_session_path, SESSION);
assert.equal(sessionReport.params.resume_argv, undefined, "never on the session report");

assert.ok(stateReport, "the state report must still be sent");
assert.equal(stateReport.params.state, "idle");
assert.ok(
  seen.indexOf(stateReport) < seen.indexOf(resumeReport),
  "the state report must come first: it is what lets the reporter hold the pane",
);
assert.deepEqual(resumeReport.params.resume_argv, ["pi", "--session", SESSION]);
assert.equal(resumeReport.params.source, "herdr:pi", "the pane's own integration source");
assert.equal(resumeReport.params.pane_id, "w5:p2");
assert.ok(resumeReport.params.seq > stateReport.params.seq, "sequence must advance");
assert.deepEqual(
  seen.filter((r) => r.params.resume_argv).length,
  1,
  "exactly one resume report per state change",
);
console.log("ok - state report first, then pi --session <file> under herdr:pi");

// A blocked pane must keep its reason on the follow-up resume report; an empty
// message there would clear the label the sidebar shows.
const events = startSession(SESSION);
await settle();
events["herdr:blocked"]({ active: true, label: "Approve the command?" });
await settle();
const blockedResume = seen.filter((r) => r.params.resume_argv).at(-1);
assert.equal(blockedResume.params.state, "blocked");
assert.equal(blockedResume.params.message, "Approve the command?");
console.log("ok - the resume report keeps the blocked message");

// Herdr rejects a resume argv holding an apostrophe or control character, or
// one that is not an absolute path. None may be reported then.
for (const unsafe of ["/Users/o'brien/s.jsonl", "/Users/a\nb.jsonl", "relative/s.jsonl"]) {
  startSession(unsafe);
  await settle();
  assert.equal(
    seen.filter((r) => r.params.resume_argv).length,
    0,
    `must not report a resume command for ${JSON.stringify(unsafe)}`,
  );
}
console.log("ok - unsafe session paths are never reported as a resume command");

server.close();
rmSync(dir, { recursive: true, force: true });
