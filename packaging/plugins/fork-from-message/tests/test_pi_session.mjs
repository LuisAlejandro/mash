#!/usr/bin/env node
// Exercise Pi's actual tree/compaction/branch writer, without starting an agent.
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, realpathSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { loadPi, listMessages, forkSession, readSession } from "../scripts/pi_session.mjs";

let pkg = process.argv[2];
if (!pkg) {
  for (const directory of (process.env.PATH ?? "").split(delimiter)) {
    const executable = join(directory, "pi");
    if (!existsSync(executable)) continue;
    let parent = dirname(realpathSync(executable));
    while (dirname(parent) !== parent) {
      if (existsSync(join(parent, "dist/index.js")) && existsSync(join(parent, "package.json"))) {
        pkg = parent;
        break;
      }
      parent = dirname(parent);
    }
    if (pkg) break;
  }
}
const dir = mkdtempSync(join(tmpdir(), "mash-fork-session-test-"));
try {
  const incompatible = join(dir, "bad.mjs");
  writeFileSync(incompatible, "export class SessionManager { static open() {} }\n");
  await assert.rejects(loadPi(incompatible), /incompatible.*SessionManager/i);
  console.log("ok - missing SessionManager methods fail explicitly");
  if (!pkg) {
    console.log("skip - bundled Pi absent; real session integration runs in the bundle build gate");
  } else {
    const pi = await loadPi(join(pkg, "dist/index.js"));
    const source = join(dir, "source.jsonl");
    const timestamp = "2026-11-02T00:00:00.000Z";
    const entry = (id, parentId, type, rest) => ({ id, parentId, timestamp, type, ...rest });
    const user = (id, parentId, text) => entry(id, parentId, "message", { message: { role: "user", content: text, timestamp: 1 } });
    const assistant = (id, parentId) => entry(id, parentId, "message", { message: { role: "assistant", content: [{ type: "text", text: "answer" }], timestamp: 2 } });
    const header = { type: "session", version: 3, id: "test-session", timestamp, cwd: dir };
    const text = '--dash\n  "quotes" $DOLLAR `backtick` — 🚀\n';
    const entries = [
      header,
      entry("setup", null, "model_change", { provider: "test", modelId: "test" }),
      user("u1", "setup", "first"), assistant("a1", "u1"),
      user("abandoned", "a1", "old branch"), assistant("old-answer", "abandoned"),
      user("u2", "a1", "shared opening\nsecond message"), assistant("a2", "u2"),
      entry("bookmark", "a2", "label", { targetId: "a2", label: "keep me" }),
      user("u3", "bookmark", text), assistant("a3", "u3"),
    ];
    const save = (data) => writeFileSync(source, data.map(e => JSON.stringify(e)).join("\n") + "\n");
    save(entries);
    const original = readFileSync(source);
    let rows = listMessages(readSession(pi, source));
    assert.deepEqual(rows.map(e => e.id), ["u1", "u2", "u3"]);
    assert.equal(rows[0].forkable, false, "setup parent is not conversation history");
    assert.equal(rows[1].forkable, true);
    assert.equal(rows[2].text, text);

    // Accepted file-only limit: /tree changes a live manager's leaf without
    // persisting it. A separate reader still sees the last saved branch.
    const live = readSession(pi, source);
    live.branch("a1");
    assert.deepEqual(listMessages(live).map(e => e.id), ["u1"]);
    assert.deepEqual(listMessages(readSession(pi, source)).map(e => e.id), ["u1", "u2", "u3"]);
    assert.deepEqual(readFileSync(source), original);
    console.log("ok - file-only reader follows saved leaf, not an unsaved tree move");

    const result = forkSession(pi, source, "u3");
    assert.notEqual(result.sessionFile, source);
    assert.equal(result.selectedText, text);
    const fork = readSession(pi, result.sessionFile);
    assert.equal(fork.getHeader().parentSession, source);
    assert.equal(fork.getLabel("a2"), "keep me");
    assert.deepEqual(fork.getBranch().filter(e => e.type === "message").map(e => e.id), ["u1", "a1", "u2", "a2"]);
    assert.equal(fork.getEntries().some(e => e.id === "abandoned" || e.id === "u3"), false);
    assert.deepEqual(readFileSync(source), original);
    rmSync(result.sessionFile);
    console.log("ok - exact user boundary, draft, labels, no abandoned branch, source unchanged");

    save([...entries, entry("compact", "a3", "compaction", { summary: "earlier history", firstKeptEntryId: "u3", tokensBefore: 10 })]);
    rows = listMessages(readSession(pi, source));
    assert.deepEqual(rows.map(e => e.id), ["u3"]);
    assert.equal(rows[0].forkable, true, "first visible after compaction is not the first user message");
    const compacted = forkSession(pi, source, "u3");
    assert.equal(readSession(pi, compacted.sessionFile).getEntries().some(e => e.type === "compaction"), false, "no future summary copied into an earlier fork");
    rmSync(compacted.sessionFile);
    console.log("ok - transcript-only compaction list, exact fork before summary");

    const before = readdirSync(dir).sort();
    for (const id of ["u1", "a1", "missing"]) {
      assert.throws(() => forkSession(pi, source, id), /history|user message|not found/i);
    }
    assert.deepEqual(readdirSync(dir).sort(), before, "invalid selections create no files");
    const saved = readFileSync(source);
    writeFileSync(source, saved + '{"type":"message"\n');
    assert.throws(() => readSession(pi, source), /invalid|JSON|session/i);
    assert.deepEqual(readFileSync(source), Buffer.concat([saved, Buffer.from('{"type":"message"\n')]));
    console.log("ok - invalid sessions and selections fail without writes");

    // Contract through the real subprocess interface, not just exported functions.
    save(entries);
    const cli = spawnSync(process.execPath, [new URL("../scripts/pi_session.mjs", import.meta.url).pathname, join(pkg, "dist/index.js"), "list", source], { encoding: "utf8" });
    assert.equal(cli.status, 0, cli.stderr);
    assert.deepEqual(JSON.parse(cli.stdout).entries.map(e => e.id), ["u1", "u2", "u3"]);
    const broken = spawnSync(process.execPath, [new URL("../scripts/pi_session.mjs", import.meta.url).pathname, incompatible, "list", source], { encoding: "utf8" });
    assert.equal(broken.status, 2);
    assert.match(broken.stderr, /incompatible.*SessionManager/i);
    console.log("ok - CLI JSON framing and compatibility exit code");
  }
} finally {
  rmSync(dir, { recursive: true, force: true });
}
