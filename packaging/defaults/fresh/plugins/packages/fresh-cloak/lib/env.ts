/**
 * Pure, line-local scan of the Node-compatible one-line `.env` subset.
 *
 * This module never sees editor state and never computes byte offsets: it
 * reports JavaScript string indices into the line it was handed. The Fresh
 * adapter converts those to UTF-8 byte offsets at the API boundary.
 */

export type ScanResult =
  | { kind: "mask"; start: number; end: number }
  | { kind: "unchanged" }
  | { kind: "unsupported" };

const UNCHANGED: ScanResult = { kind: "unchanged" };
const UNSUPPORTED: ScanResult = { kind: "unsupported" };

const ENV_BASE_NAME = ".env";
const EXPORT_KEYWORD = "export";

function isSpace(c: string): boolean {
  return c === " " || c === "\t";
}

function isNameStart(c: string): boolean {
  return (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || c === "_";
}

function isNameChar(c: string): boolean {
  // Node's own parser and dotenv both accept `.` and `-` in a key (dotenv's
  // scanner sets KEY_CHAR for both), and keys like `DB.PASSWORD` or
  // `API-KEY` are real secrets. Masking is render-only, so a wider key is
  // the safe direction: over-masking costs nothing, under-masking shows a
  // secret. The first-character rule stays strict, so `.KEY=` is still
  // rejected.
  return (
    isNameStart(c) ||
    (c >= "0" && c <= "9") ||
    c === "." ||
    c === "-"
  );
}

function skipSpace(line: string, from: number, end: number): number {
  let i = from;
  while (i < end && isSpace(line[i])) i++;
  return i;
}

/**
 * Index just past the content when `line` ends in a line terminator, so a
 * CRLF or bare CR/LF can never fall inside a reported span.
 */
function bodyEnd(line: string): number {
  let end = line.length;
  if (end > 0 && line[end - 1] === "\n") {
    end--;
    if (end > 0 && line[end - 1] === "\r") end--;
  } else if (end > 0 && line[end - 1] === "\r") {
    end--;
  }
  return end;
}

function isEnvBaseName(base: string): boolean {
  if (base === ENV_BASE_NAME) return true;
  if (base.startsWith(ENV_BASE_NAME + ".")) return true;
  // A `*.env` suffix needs a real name in front of the dot, so bare `env` and
  // `.env` itself do not reach here.
  return base.length > ENV_BASE_NAME.length && base.endsWith(ENV_BASE_NAME);
}

export function isEnvFileName(name: string): boolean {
  const base = name.split(/[/\\]/).pop();
  if (base === undefined) return false;
  return isEnvBaseName(base);
}

function scanQuoted(
  line: string,
  open: number,
  end: number,
  quote: string,
): ScanResult {
  // Only double quotes process backslash escapes; single-quoted content is
  // literal, so a backslash there is ordinary value content.
  const escapes = quote === '"';
  let i = open + 1;
  while (i < end) {
    const c = line[i];
    if (escapes && c === "\\") {
      i += 2;
      continue;
    }
    if (c === quote) {
      if (i === open + 1) return UNCHANGED;
      const rest = skipSpace(line, i + 1, end);
      if (rest >= end || line[rest] === "#") {
        return { kind: "mask", start: open + 1, end: i };
      }
      return UNSUPPORTED;
    }
    i++;
  }
  return UNSUPPORTED;
}

function trailingBackslashes(line: string, start: number, end: number): number {
  let count = 0;
  let i = end;
  while (i > start && line[i - 1] === "\\") {
    count++;
    i--;
  }
  return count;
}

function scanUnquoted(line: string, start: number, end: number): ScanResult {
  let stop = start;
  while (stop < end && line[stop] !== "#") stop++;

  let valueEnd = stop;
  while (valueEnd > start && isSpace(line[valueEnd - 1])) valueEnd--;
  if (valueEnd === start) return UNCHANGED;

  // An odd trailing backslash continues the value onto the next line, which
  // the one-line grammar does not cover.
  if (trailingBackslashes(line, start, valueEnd) % 2 === 1) {
    return UNSUPPORTED;
  }

  return { kind: "mask", start, end: valueEnd };
}

/**
 * A line beginning with `#` after leading space is either a prose comment
 * (`# this explains the setting below`) or a commented-out assignment
 * (`# SECRET=abc123`, `#SECRET=abc123`) -- dotenv's own convention for
 * "this var exists, disabled for now." A commented-out assignment is still a
 * real secret sitting in plain text, so it is not safe to bail out on `#`
 * before the key/value grammar runs: that was the original bug, and it made
 * every commented variable show unmasked regardless of the space after `#`.
 *
 * One leading `#` is skipped here (plus any space after it) and scanning
 * continues as if it were not a comment marker at all. If what follows is
 * not `KEY=value` shape, the normal `UNCHANGED` fall-through below still
 * applies -- so a prose comment like `# see the README` or `# TODO: rotate`
 * correctly stays unmasked (no `=` after the first "word"), while
 * `# SECRET=abc123` masks `abc123` exactly as the uncommented line would.
 * A SECOND leading `#` (`## heading`) is intentionally NOT unwrapped --
 * dotenv convention is one marker per commented line, and a double-hash is
 * far more likely to be a markdown-style heading in a comment block than a
 * commented assignment.
 */
export function scanLine(line: string): ScanResult {
  const end = bodyEnd(line);

  let i = skipSpace(line, 0, end);
  if (i >= end) return UNCHANGED;
  if (line[i] === "#") {
    i = skipSpace(line, i + 1, end);
    if (i >= end) return UNCHANGED;
  }

  if (
    line.startsWith(EXPORT_KEYWORD, i) &&
    i + EXPORT_KEYWORD.length < end &&
    isSpace(line[i + EXPORT_KEYWORD.length])
  ) {
    i = skipSpace(line, i + EXPORT_KEYWORD.length, end);
  }

  if (i >= end || !isNameStart(line[i])) return UNCHANGED;
  i++;
  while (i < end && isNameChar(line[i])) i++;

  i = skipSpace(line, i, end);
  if (i >= end || line[i] !== "=") return UNCHANGED;
  i = skipSpace(line, i + 1, end);

  if (i >= end) return UNCHANGED;
  const c = line[i];
  if (c === "#") return UNCHANGED;
  if (c === '"' || c === "'") return scanQuoted(line, i, end, c);
  return scanUnquoted(line, i, end);
}
