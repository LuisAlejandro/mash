// Pi extension UI follows MASH_LANGUAGE. Tool descriptions stay English, and
// mash-seed-sync installs the quick-reference sheet for the language, mode
// and platform.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, cpSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

delete process.env.MASH_LANGUAGE;
delete process.env.MASH_I18N_DIR;

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === "typebox") {
      return {
        url: "data:text/javascript,export const Type={Object:()=>({}),String:()=>({}),Optional:()=>({}),Number:()=>({}),Array:()=>({})}",
        shortCircuit: true,
      };
    }
    return nextResolve(specifier, context);
  },
});

const here = dirname(fileURLToPath(import.meta.url));
const packaging = join(here, "..");
const extensions = join(packaging, "defaults", "pi", "extensions");
const catalog = JSON.parse(readFileSync(join(packaging, "i18n", "messages", "pi", "it.json"), "utf8"));
const it = (key, values = {}) =>
  catalog[key].text.replace(/\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (match, name) =>
    Object.prototype.hasOwnProperty.call(values, name) ? values[name] : match,
  );

const SHOW_DESCRIPTION =
  "Show a file to the person you are working for, instead of describing it. " +
  "Text opens in the Fresh editor beside this pane with an optional note; an image opens as a vertical split with real pixels; other files are not shown. No external app is opened. " +
  "Use this whenever a task produces a report, a chart, a screenshot, a log or any other file the person should look at. " +
  "The result says where it went. Prefer this over pasting file contents into your reply.";
const SHOW_SNIPPET = "Show a result file to the person instead of describing it";
const SHOW_GUIDELINES = [
  "Call show_file with the path of a file the person should look at: a report, a chart, a screenshot, a rendered document, a log.",
  "Give `note` a short phrase naming what it is. It appears beside the file.",
  "Do not paste the file's contents into your reply after showing it. Say what it is and stop.",
  "If show_file says nothing was shown, do not describe the file or launch an external app. State briefly that it was not shown, if needed.",
];
const ASK_DESCRIPTION =
  "Ask the Herdr orchestration coordinator one question and wait for its reply. Use this only while this pane has an open Dispatch. If this pane has no Dispatch, the tool returns an error: ask the person with ask_user instead.";
const ASK_SNIPPET = "Ask the orchestration coordinator one question when this pane is a dispatched worker";
const ASK_GUIDELINES = [
  "Call ask_coordinator only from a dispatched worker pane. Ask one question per call.",
  "If ask_coordinator says this pane has no open Dispatch, ask the person with ask_user.",
  "Do not answer a coordinator question by typing into a pane with herdr agent send-keys.",
  "A pending result names a message id. Call ask_coordinator again with resume set to that id. Do not create a second question.",
];

const SHEETS = [
  "keybindings-quickref.txt",
  "keybindings-quickref.linux.txt",
  "keybindings-quickref.native.txt",
  "keybindings-quickref.native.linux.txt",
];

function sheetName(platform, native) {
  return "keybindings-quickref" + (native ? ".native" : "") + (platform === "Linux" ? ".linux.txt" : ".txt");
}

function seededSheet(platform, language, native) {
  const dir = mkdtempSync(join(tmpdir(), "mash-quickref-"));
  try {
    const res = join(dir, "res");
    const data = join(dir, "data");
    mkdirSync(join(res, "defaults", "pi", "extensions"), { recursive: true });
    writeFileSync(join(res, "VERSION"), "1.0.0\n");
    writeFileSync(join(res, "defaults", "optional-programming.txt"), "");
    for (const name of SHEETS) {
      cpSync(join(extensions, name), join(res, "defaults", "pi", "extensions", name));
    }
    cpSync(join(packaging, "i18n"), join(res, "i18n"), { recursive: true });
    mkdirSync(join(data, "setup"), { recursive: true });
    if (language) writeFileSync(join(data, "setup", "language"), `language=${language}\n`);
    if (native) writeFileSync(join(data, "setup", "keybindings-mode"), "mode=native\n");
    const proc = spawnSync(join(packaging, "helpers", "mash-seed-sync"), [res, data], {
      env: { ...process.env, MASH_SEED_PLATFORM: platform },
      encoding: "utf8",
    });
    assert.equal(proc.status, 0, proc.stderr || proc.stdout);
    return readFileSync(join(data, "pi", "agent", "extensions", "keybindings-quickref.txt"));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const dir = mkdtempSync(join(tmpdir(), "mash-pi-i18n-"));
const saved = {
  PATH: process.env.PATH,
  HERDR_BIN_PATH: process.env.HERDR_BIN_PATH,
  HERDR_PANE_ID: process.env.HERDR_PANE_ID,
  MASH_FRESH_BIN: process.env.MASH_FRESH_BIN,
  IMAGE_OK: process.env.IMAGE_OK,
  LAYOUT_OK: process.env.LAYOUT_OK,
  DAEMON_OK: process.env.DAEMON_OK,
  OPEN_OK: process.env.OPEN_OK,
};
try {
  process.env.MASH_LANGUAGE = "it";

  const { default: registerHeader } = await import(
    new URL("../defaults/pi/extensions/custom-header.ts", import.meta.url),
  );
  let command;
  registerHeader({
    on() {},
    registerCommand(_name, spec) {
      command = spec;
    },
  });
  assert.equal(command.description, it("pi.header.restore"));
  let notified;
  await command.handler("", {
    ui: {
      setHeader() {},
      notify(message) {
        notified = message;
      },
    },
  });
  assert.equal(notified, it("pi.header.restored"));

  const image = join(dir, "chart.png");
  const report = join(dir, "notes.md");
  const other = join(dir, "notes.pdf");
  const folder = join(dir, "subdir");
  writeFileSync(image, "png");
  writeFileSync(report, "# notes\n");
  writeFileSync(other, "%PDF");
  mkdirSync(folder);
  const herdr = join(dir, "herdr");
  const fresh = join(dir, "fresh");
  writeFileSync(
    herdr,
    `#!/bin/sh
case "$1 $2" in
  "plugin pane")
    if [ "$IMAGE_OK" = 1 ]; then exit 0; fi
    echo "pane refused" >&2
    exit 1 ;;
  "pane layout")
    if [ "$LAYOUT_OK" = 1 ]; then
      echo '{"result":{"layout":{"panes":[{"pane_id":"editor"}]}}}'
      exit 0
    fi
    exit 1 ;;
  "pane process-info")
    echo '{"result":{"process_info":{"foreground_processes":[{"name":"fresh","pid":4242}]}}}'
    exit 0 ;;
esac
exit 1
`,
  );
  writeFileSync(
    fresh,
    `#!/bin/sh
if [ "$1 $2 $3" = "--cmd daemon info" ]; then
  if [ "$DAEMON_OK" = 1 ]; then echo "local-4242-real0000"; fi
  exit 0
fi
if [ "$1 $2 $3" = "--cmd daemon open-file" ]; then
  if [ "$OPEN_OK" = 1 ]; then exit 0; fi
  echo "ignored stdout"
  echo "fresh refused" >&2
  exit 1
fi
exit 1
`,
  );
  chmodSync(herdr, 0o755);
  chmodSync(fresh, 0o755);
  process.env.HERDR_BIN_PATH = herdr;
  process.env.MASH_FRESH_BIN = fresh;
  delete process.env.HERDR_PANE_ID;
  delete process.env.IMAGE_OK;
  delete process.env.LAYOUT_OK;
  delete process.env.DAEMON_OK;
  delete process.env.OPEN_OK;

  const { default: registerShow } = await import(
    new URL("../defaults/pi/extensions/show-file.ts", import.meta.url),
  );
  let show;
  registerShow({ registerTool(value) { show = value; } });
  assert.equal(show.label, it("pi.show-file.label"));
  assert.equal(show.description, SHOW_DESCRIPTION);
  assert.equal(show.promptSnippet, SHOW_SNIPPET);
  assert.deepEqual(show.promptGuidelines, SHOW_GUIDELINES);

  const body = async (params) => {
    const result = await show.execute("test", params);
    return result.content[0].text;
  };
  assert.equal(await body({ path: "  " }), it("pi.show-file.needs-path"));
  const missing = join(dir, "missing.txt");
  assert.equal(await body({ path: missing }), it("pi.show-file.no-such-file", { path: missing }));
  assert.equal(await body({ path: folder }), it("pi.show-file.is-directory", { path: folder }));
  assert.equal(await body({ path: other }), it("pi.show-file.not-shown-other", { name: "notes.pdf" }));
  assert.equal(await body({ path: image }), it("pi.show-file.not-shown-no-pane", { name: "chart.png" }));

  process.env.HERDR_PANE_ID = "pane-1";
  assert.equal(
    await body({ path: image }),
    it("pi.show-file.not-shown-herdr", { name: "chart.png", detail: "pane refused" }),
  );
  process.env.IMAGE_OK = "1";
  assert.equal(
    await body({ path: image, note: "trend" }),
    it("pi.show-file.shown-image", { name: "chart.png" }) + " (trend)",
  );

  delete process.env.IMAGE_OK;
  assert.equal(await body({ path: report }), it("pi.show-file.not-shown-no-editor", { name: "notes.md" }));
  process.env.LAYOUT_OK = "1";
  assert.equal(await body({ path: report }), it("pi.show-file.not-shown-daemon", { name: "notes.md" }));
  process.env.DAEMON_OK = "1";
  assert.equal(
    await body({ path: report }),
    it("pi.show-file.not-shown-fresh", { name: "notes.md", detail: "fresh refused" }),
  );
  process.env.OPEN_OK = "1";
  assert.equal(
    await body({ path: report, note: "bozza" }),
    it("pi.show-file.shown-text", { name: "notes.md" }) + " (bozza)",
  );

  process.env.MASH_LANGUAGE = "en";
  const { default: registerShowEn } = await import(
    new URL("../defaults/pi/extensions/show-file.ts?language=en", import.meta.url),
  );
  let showEn;
  registerShowEn({ registerTool(value) { showEn = value; } });
  assert.equal(showEn.label, "Show file to the person");
  assert.equal(showEn.description, SHOW_DESCRIPTION);
  assert.equal(showEn.promptSnippet, SHOW_SNIPPET);
  assert.notEqual(showEn.label, show.label);

  process.env.MASH_LANGUAGE = "it";
  const { default: registerAsk } = await import(
    new URL("../defaults/pi/extensions/mash-orchestration.ts", import.meta.url),
  );
  let ask;
  registerAsk({ registerTool(value) { ask = value; } });
  assert.equal(ask.label, it("pi.orchestration.label"));
  assert.equal(ask.description, ASK_DESCRIPTION);
  assert.equal(ask.promptSnippet, ASK_SNIPPET);
  assert.deepEqual(ask.promptGuidelines, ASK_GUIDELINES);
  const cancelled = await ask.execute("test", { question: "Perch\u00e9?" }, AbortSignal.abort());
  assert.equal(cancelled.isError, true);
  assert.equal(cancelled.content[0].text, it("pi.orchestration.cancelled"));

  for (const platform of ["Darwin", "Linux"]) {
    for (const native of [false, true]) {
      const name = sheetName(platform, native);
      const installed = seededSheet(platform, "uk", native);
      const expected = readFileSync(join(packaging, "i18n", "quickref", "uk", name));
      assert.deepEqual(installed, expected, `${platform} native=${native}`);
    }
  }
  const english = seededSheet("Darwin", "en", false);
  assert.deepEqual(english, readFileSync(join(extensions, "keybindings-quickref.txt")));

  console.log("pi extension i18n and quick-reference seeding: ok");
} finally {
  for (const [key, value] of Object.entries(saved)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  delete process.env.MASH_LANGUAGE;
  rmSync(dir, { recursive: true, force: true });
}
