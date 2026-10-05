/**
 * Fresh Cloak — visual masking of `.env` values.
 *
 * Every handler is wrapped in try/catch. An unhandled rejection is fatal to
 * Fresh's plugin thread, and for a masking plugin that failure is inverted
 * from the usual one: concealment silently stops being rebuilt while the user
 * keeps screen-sharing, believing values are still hidden. So the catch paths
 * fail closed rather than degrading to plaintext.
 */
import { isEnvFileName, scanLine } from "./lib/env.ts";

const editor = getEditor();

/**
 * One namespace for everything this plugin decorates. Fresh tracks it as a
 * plugin-owned resource and clears exactly it on unload/reload, and
 * clearConcealsInRangeForNamespace leaves other plugins' decorations alone.
 */
const NS = "fresh-cloak";

/**
 * Persistent on/off switch, surfaced in Settings → Plugin Settings. The
 * returned value is the effective one (a user-set value from config.json,
 * otherwise the declared default), which is why it is captured rather than
 * read back through `getPluginConfig`: that only reports user-set values and
 * returns `{}` while the default is in force.
 */
const SETTING_NAME = "enabled";

/**
 * The plugin's own name, as the host sees it.
 *
 * Fresh derives a plugin's name from its entry **file stem**, not from
 * `package.json` and not from the containing directory, and that name is what
 * scopes the plugin's settings under `config.plugins.<name>.settings`. Reading
 * it here rather than hardcoding `fresh-cloak` means the settings path stays
 * correct however the plugin is installed — `fresh-cloak.ts` in the user
 * plugins directory and `packages/fresh-cloak/fresh-cloak.ts` both resolve to
 * the same name, while an entry left as `plugin.ts` would silently scope the
 * setting to `plugins.plugin.settings` instead.
 */
const PLUGIN_NAME: string = editor.pluginName();
const SETTING_PATH = `plugins.${PLUGIN_NAME}.settings.${SETTING_NAME}`;

let cloakingEnabled: boolean = editor.defineConfigBoolean(SETTING_NAME, {
  default: true,
  description:
    "Mask .env values in the viewport. Turn off to show every value in plain text.",
});

/**
 * Re-read the setting at point of use. A `defineConfigX` call returns the
 * current effective value, so re-declaring is how the live value is obtained
 * after the user edits it in the Settings UI.
 */
function readEnabled(): boolean {
  return editor.defineConfigBoolean(SETTING_NAME, {
    default: true,
    description:
      "Mask .env values in the viewport. Turn off to show every value in plain text.",
  });
}

/** Fixed-width ASCII: reveals neither the value's length nor its charset. */
const MASK = "*".repeat(12);

/**
 * Masked unless the buffer id is in here. Absence is the default, so a buffer
 * that has never been seen is masked with no initialization step — there is
 * no window where a supported buffer starts revealed.
 */
const revealed = new Set<number>();

// Content-free by construction. A warning must never carry source text: it
// lands in status output the user may be sharing.
const WARNING_DEGRADED =
  "Fresh Cloak: could not read every line in this batch, so those lines were concealed in full. Toggle cloaking off and on to retry.";
const WARNING_UNSUPPORTED =
  "Fresh Cloak: some assignments use multiline or malformed syntax and are shown unmasked. See the plugin README for the supported subset.";
const STATUS_NOT_SUPPORTED = "Fresh Cloak: this buffer is not a .env file.";
const STATUS_ENABLED = "Fresh Cloak: on.";
const STATUS_DISABLED = "Fresh Cloak: off — values are shown in plain text.";
const WARNING_SETTING_FAILED =
  "Fresh Cloak: could not change the cloaking setting. Check the plugin log.";

interface MaskLine {
  content: string;
  byteStart: number;
  byteEnd: number;
}

type ChangedLines = HookEventMap["lines_changed"];
type ChangedLine = ChangedLines["lines"][number];

/**
 * Convert a character offset within a line to an absolute buffer byte offset.
 * `scanLine` reports JavaScript string indices (UTF-16 code units) while every
 * editor API takes UTF-8 byte offsets, and the two diverge on any multibyte
 * character. Mirrors markdown_compose's helper of the same name.
 */
function charToByte(
  lineContent: string,
  charOffset: number,
  lineByteStart: number,
): number {
  return lineByteStart + editor.utf8ByteLength(lineContent.slice(0, charOffset));
}

/**
 * Byte offset just past a line's content, excluding its terminator.
 *
 * A conceal that covers the newline swallows the line break and renders the
 * line and its successor as one row, so whole-line conceals stop here. This is
 * used only on the fail-closed path, where the conversion helper that would
 * normally be needed may itself be what failed — a CR or LF is one UTF-8 byte,
 * so subtracting the trimmed character count is exact and cannot throw.
 */
function contentEndByte(content: string, byteEnd: number): number {
  let end = content.length;
  if (end > 0 && content[end - 1] === "\n") {
    end--;
    if (end > 0 && content[end - 1] === "\r") end--;
  } else if (end > 0 && content[end - 1] === "\r") {
    end--;
  }
  return byteEnd - (content.length - end);
}

/** Add the value conceal for one line, or report why it was not added. */
function concealValue(
  bufferId: number,
  content: string,
  byteStart: number,
): "masked" | "unchanged" | "unsupported" {
  const result = scanLine(content);
  if (result.kind !== "mask") return result.kind;

  // Both offsets are computed before either is used, so a conversion failure
  // cannot leave a half-applied conceal behind.
  const start = charToByte(content, result.start, byteStart);
  const end = charToByte(content, result.end, byteStart);
  if (end > start) editor.addConceal(bufferId, NS, start, end, MASK);
  return "masked";
}

/**
 * Rebuild this plugin's conceals for a set of lines: clear the namespace over
 * each line's range, then re-add from the current text. Clear and add are sent
 * as one batch so the line never renders unmasked for an intermediate frame.
 */
function applyMasking(bufferId: number, lines: readonly MaskLine[]): void {
  let sawUnsupported = false;
  let degraded = false;

  for (const line of lines) {
    editor.clearConcealsInRangeForNamespace(
      bufferId,
      NS,
      line.byteStart,
      line.byteEnd,
    );

    try {
      if (concealValue(bufferId, line.content, line.byteStart) === "unsupported") {
        sawUnsupported = true;
      }
    } catch {
      // Fail closed. The host supplied this line's byte range, so concealing
      // all of it needs no conversion and cannot throw a second time.
      degraded = true;
      const end = contentEndByte(line.content, line.byteEnd);
      if (end > line.byteStart) {
        editor.addConceal(bufferId, NS, line.byteStart, end, MASK);
      }
    }
  }

  // At most one warning per batch, and never more than one reason: a degraded
  // batch already says the lines were concealed, so the unsupported note would
  // only contradict it.
  if (degraded) editor.warn(WARNING_DEGRADED);
  else if (sawUnsupported) editor.warn(WARNING_UNSUPPORTED);
}

/** Split buffer text into lines with their absolute byte starts. */
function splitLines(text: string): MaskLine[] {
  const lines: MaskLine[] = [];
  let byteStart = 0;
  let start = 0;

  for (let i = 0; i < text.length; i++) {
    if (text[i] !== "\n") continue;
    const content = text.slice(start, i + 1);
    const byteEnd = byteStart + editor.utf8ByteLength(content);
    lines.push({ content, byteStart, byteEnd });
    byteStart = byteEnd;
    start = i + 1;
  }

  if (start < text.length) {
    const content = text.slice(start);
    lines.push({
      content,
      byteStart,
      byteEnd: byteStart + editor.utf8ByteLength(content),
    });
  }

  return lines;
}

/**
 * Rebuild a whole buffer from its live text, including unsaved edits. Used
 * wherever the plugin cannot wait for an incidental edit — re-masking, plugin
 * load, and a buffer that has just started matching its path.
 */
async function rebuildBuffer(bufferId: number): Promise<void> {
  const text = await editor.getBufferText(bufferId);
  applyMasking(bufferId, splitLines(text));
}

function isSupported(info: BufferInfo | null): info is BufferInfo {
  // A pathless (virtual/untitled) buffer has nothing to match on.
  return info !== null && info.path !== "" && isEnvFileName(info.path);
}

function clearLines(bufferId: number, lines: readonly MaskLine[]): void {
  for (const line of lines) {
    editor.clearConcealsInRangeForNamespace(
      bufferId,
      NS,
      line.byteStart,
      line.byteEnd,
    );
  }
}

function linesOfChanged(data: ChangedLines): MaskLine[] {
  return data.lines.map((line: ChangedLine) => ({
    content: line.content,
    byteStart: line.byte_start,
    byteEnd: line.byte_end,
  }));
}

function handleLinesChanged(data: ChangedLines): void {
  try {
    const bufferId = data.buffer_id;
    // Fresh stamps the lines_changed epoch onto the coordinate-bearing
    // commands itself, so nothing here threads it.
    const info = editor.getBufferInfo(bufferId);

    if (!isSupported(info)) {
      // Clear and forget. A buffer that no longer matches must not keep stale
      // conceals, and must not keep reveal state that would suppress masking
      // if its path later matches again.
      clearLines(bufferId, linesOfChanged(data));
      revealed.delete(bufferId);
      return;
    }

    // The global switch wins over per-buffer state: when cloaking is off,
    // nothing may be masked no matter what the reveal set says.
    if (!cloakingEnabled) {
      clearLines(bufferId, linesOfChanged(data));
      return;
    }

    if (revealed.has(bufferId)) {
      clearLines(bufferId, linesOfChanged(data));
      return;
    }

    applyMasking(bufferId, linesOfChanged(data));
  } catch {
    // Nothing further can be done for this batch, and rethrowing would kill
    // the plugin thread. The next batch retries.
    editor.warn(WARNING_DEGRADED);
  }
}

function handleBufferClosed(data: HookEventMap["buffer_closed"]): void {
  try {
    revealed.delete(data.buffer_id);
  } catch {
    editor.warn(WARNING_DEGRADED);
  }
}

async function handleBufferActivated(
  data: HookEventMap["buffer_activated"],
): Promise<void> {
  try {
    const bufferId = data.buffer_id;
    // Covers save-as and rename: a buffer that starts matching only here would
    // otherwise stay unmasked until some later edit happened to refresh it.
    if (revealed.has(bufferId)) return;
    if (!isSupported(editor.getBufferInfo(bufferId))) return;
    if (!cloakingEnabled) return;
    await rebuildBuffer(bufferId);
  } catch {
    editor.warn(WARNING_DEGRADED);
  }
}

async function toggleCloaking(): Promise<void> {
  try {
    const bufferId = editor.getActiveBufferId();
    const info = editor.getBufferInfo(bufferId);
    if (!isSupported(info)) {
      editor.setStatus(STATUS_NOT_SUPPORTED);
      return;
    }

    if (revealed.has(bufferId)) {
      // Re-mask from current buffer content, so unsaved edits are covered by
      // the mask that comes back.
      revealed.delete(bufferId);
      await rebuildBuffer(bufferId);
    } else {
      revealed.add(bufferId);
      clearWholeBuffer(bufferId);
    }

    editor.refreshLines(bufferId);
  } catch {
    editor.warn(WARNING_DEGRADED);
  }
}

/**
 * Clear this plugin's conceals across a whole buffer.
 *
 * `clearConcealsInRangeForNamespace` needs a byte range, and the buffer's
 * length comes from the info snapshot; when that is unavailable the range
 * simply covers more bytes than the buffer has, which the host clamps.
 */
function clearWholeBuffer(bufferId: number): void {
  const info = editor.getBufferInfo(bufferId);
  editor.clearConcealsInRangeForNamespace(
    bufferId,
    NS,
    0,
    info?.length ?? Number.MAX_SAFE_INTEGER,
  );
}

/** Rebuild every open supported buffer, so a global change applies everywhere. */
async function refreshAllBuffers(): Promise<void> {
  for (const info of editor.listBuffers()) {
    if (!isSupported(info)) continue;
    if (!cloakingEnabled || revealed.has(info.id)) {
      clearWholeBuffer(info.id);
      continue;
    }
    await rebuildBuffer(info.id);
  }
}

/**
 * Apply the current setting to everything already open, then refresh the
 * active buffer so the change is visible at once rather than on next edit.
 *
 * Turning the global switch off discards the per-buffer reveal set. That set
 * is invisible while cloaking is off, so letting it survive an off/on cycle
 * would leave a buffer rendering plaintext while the user believes cloaking
 * is on — the exact confusion this plugin exists to prevent. Re-enabling
 * therefore starts fully masked, and a deliberate per-buffer reveal is one
 * keypress to redo.
 */
async function applyEnabledState(): Promise<void> {
  if (!cloakingEnabled) revealed.clear();
  await refreshAllBuffers();
  const active = editor.getActiveBufferId();
  if (editor.getBufferInfo(active) !== null) editor.refreshLines(active);
}

/**
 * The keybindable on/off switch.
 *
 * This writes the setting rather than keeping its own flag, so the Settings
 * UI checkbox and every later read of the setting agree with the keypress. A
 * refused write is reported instead of being papered over: the user would
 * otherwise be told cloaking is off while it is still masking.
 */
async function toggleCloakingSetting(): Promise<void> {
  try {
    const next = !readEnabled();
    const queued = editor.setSetting(SETTING_PATH, next);
    if (queued !== true) {
      editor.warn(WARNING_SETTING_FAILED);
      return;
    }
    cloakingEnabled = next;
    await applyEnabledState();
    editor.setStatus(next ? STATUS_ENABLED : STATUS_DISABLED);
  } catch {
    editor.warn(WARNING_SETTING_FAILED);
  }
}

/**
 * A Settings UI edit lands as a config change. `setSetting` does not fire
 * this for the plugin's own writes, so reaching here means the user changed
 * it outside the key toggle.
 */
async function handleConfigChanged(): Promise<void> {
  try {
    cloakingEnabled = readEnabled();
    await applyEnabledState();
  } catch {
    editor.warn(WARNING_DEGRADED);
  }
}

/** Mask every already-open supported buffer. */
async function initialize(): Promise<void> {
  try {
    for (const info of editor.listBuffers()) {
      if (!cloakingEnabled) return;
      if (revealed.has(info.id)) continue;
      if (!isSupported(info)) continue;
      await rebuildBuffer(info.id);
    }
  } catch {
    editor.warn(WARNING_DEGRADED);
  }
}

registerHandler("freshCloakLinesChanged", handleLinesChanged);
registerHandler("freshCloakBufferClosed", handleBufferClosed);
registerHandler("freshCloakBufferActivated", handleBufferActivated);
registerHandler("freshCloakToggle", toggleCloaking);
registerHandler("freshCloakToggleSetting", toggleCloakingSetting);
registerHandler("freshCloakConfigChanged", handleConfigChanged);

editor.on("lines_changed", "freshCloakLinesChanged");
editor.on("buffer_closed", "freshCloakBufferClosed");
editor.on("buffer_activated", "freshCloakBufferActivated");
editor.on("config_changed", "freshCloakConfigChanged");

editor.registerCommand(
  "Toggle .env value cloaking",
  "Show or hide .env values in the active buffer",
  "freshCloakToggle",
  null,
);

// The keybindable global switch. Unlike the per-buffer command above, this
// changes the setting itself, so it survives for the rest of the session and
// shows up in Settings → Plugin Settings.
editor.registerCommand(
  "Toggle .env value cloaking (setting)",
  "Turn Fresh Cloak on or off for every buffer",
  "freshCloakToggleSetting",
  null,
);

// Fire-and-forget by design: the host is not awaiting plugin load, so this
// cannot be returned. `initialize` catches everything internally.
void initialize();
