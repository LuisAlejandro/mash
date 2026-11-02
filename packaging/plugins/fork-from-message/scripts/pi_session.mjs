#!/usr/bin/env node
// Session storage only: never construct an agent or discover extensions/MCP.
import { linkSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

export async function loadPi(modulePath) {
  try {
    const pi = await import(pathToFileURL(resolve(modulePath)).href);
    const methods = ["createBranchedSession", "getEntry", "getEntries", "getBranch", "getHeader", "buildContextEntries"];
    if (typeof pi.SessionManager?.inMemory !== "function" || methods.some(name => typeof pi.SessionManager.prototype[name] !== "function")) {
      throw new Error("required session methods are missing");
    }
    return pi;
  } catch (error) {
    throw Object.assign(new Error(`Incompatible Pi SessionManager interface: ${error.message}`), { exitCode: 2 });
  }
}

export function readSession(pi, source) {
  // SessionManager.open can rewrite/migrate the file. Load a read-only snapshot
  // instead; Pi can migrate this copy without touching the running session.
  const entries = readFileSync(source, "utf8").split("\n").filter(line => line.trim()).map(line => JSON.parse(line));
  const header = entries[0];
  if (header?.type !== "session" || ![2, 3].includes(header.version) || !isAbsolute(header.cwd ?? "")) {
    throw new Error("Invalid or unsupported Pi session. Resume it in Pi first, then retry.");
  }
  const ids = new Set();
  for (const entry of entries.slice(1)) {
    if (!entry.id || ids.has(entry.id) || (entry.parentId !== null && !ids.has(entry.parentId))) {
      throw new Error("Invalid Pi session entry or parent chain.");
    }
    ids.add(entry.id);
  }
  return pi.SessionManager.inMemory(header.cwd, undefined, entries);
}

function userText(entry) {
  const content = entry.message.content;
  return typeof content === "string" ? content : content.filter(part => part.type === "text").map(part => part.text).join("");
}

export function listMessages(manager) {
  // File-only: this leaf is reconstructed from persisted entries. An unsaved
  // /tree move in the running Pi can differ; see ../README.md.
  const rendered = new Set(manager.buildContextEntries().map(entry => entry.id));
  let hasEarlierUser = false;
  const result = [];
  for (const entry of manager.getBranch()) {
    if (entry.type !== "message" || entry.message.role !== "user") continue;
    const text = userText(entry);
    if (rendered.has(entry.id) && text) {
      result.push({ id: entry.id, parentId: entry.parentId, text, visibility: "rendered", forkable: hasEarlierUser });
    }
    hasEarlierUser = true;
  }
  return result;
}

export function forkSession(pi, source, entryId) {
  const manager = readSession(pi, source);
  const entry = manager.getEntry(entryId);
  if (!entry) throw new Error("Selected entry not found in the source session.");
  if (entry.type !== "message" || entry.message.role !== "user") throw new Error("Select a user message to restart.");
  const branch = manager.getBranch(entryId);
  if (!branch.slice(0, -1).some(e => e.type === "message" && e.message.role === "user")) {
    throw new Error("The first user message has no earlier history to fork from.");
  }
  const selectedText = userText(entry);
  // Reuse Pi's label re-chaining and compaction handling, not a hand-rolled slice.
  manager.createBranchedSession(entry.parentId);
  const header = { ...manager.getHeader(), parentSession: resolve(source) };
  const sessionFile = join(dirname(resolve(source)), `${header.timestamp.replace(/[:.]/g, "-")}_${header.id}.jsonl`);
  const workdir = mkdtempSync(join(dirname(sessionFile), ".herdr-fork-"));
  const temporary = join(workdir, "session.jsonl");
  try {
    writeFileSync(temporary, [header, ...manager.getEntries()].map(e => JSON.stringify(e)).join("\n") + "\n", { flag: "wx", mode: 0o600 });
    // Publish only a complete file, without replacing an existing conversation.
    linkSync(temporary, sessionFile);
  } finally {
    rmSync(workdir, { recursive: true, force: true });
  }
  return { sessionFile, selectedText };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [modulePath, command, source, entryId] = process.argv.slice(2);
  try {
    if (!modulePath || !source || !["list", "fork"].includes(command)) throw new Error("Usage: pi_session.mjs <Pi module> <list|fork> <session> [entry id]");
    const pi = await loadPi(modulePath);
    const result = command === "list" ? { entries: listMessages(readSession(pi, source)) } : forkSession(pi, source, entryId);
    console.log(JSON.stringify(result));
  } catch (error) {
    console.error(`Pi session ${command ?? "helper"} failed: ${error.message}`);
    process.exitCode = error.exitCode ?? 1;
  }
}
