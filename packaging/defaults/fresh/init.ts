// REMOVED: a startup "Toggle File Explorer" dispatch used to live here.
//
// Fresh already restores file-explorer visibility per directory natively
// (editor.restore_previous_session, default true; see
// Window::restore_file_explorer_settings / apply_fresh_session_explorer_default
// in fresh's own source). That restore runs BEFORE init.ts loads on every
// launch (main.rs: restore_active_window_on_launch at line ~893, vs.
// load_init_script_async at line ~5680) -- so an unconditional toggle here
// fires on top of an already-correct state, not on a known-closed one.
//
// The old FRESH_EXPLORER_STARTUP_FLAG guard only protected against
// `fresh --cmd init reload` re-running this script inside one already-running
// editor; it did nothing for a brand-new `fresh` process, which is what every
// Cmd+T tab launches. So the toggle ran once per process and fought a coin
// flip against whatever Fresh had just restored:
//   - restored CLOSED -> toggle opens it (looked fine, for the wrong reason)
//   - restored OPEN   -> toggle closes it (explorer vanishes on open repos)
// That produced the exact two symptoms reported: "Cmd+T sometimes shows no
// explorer" and "closing Fresh with it open loses the state next launch" --
// both were this script closing what Fresh had just correctly reopened.
//
// No replacement needed: a brand-new directory with no persisted workspace
// already defaults to the tree via apply_fresh_session_explorer_default, and
// every previously-seen directory now keeps its own real per-workspace state.

// ---------------------------------------------------------------------------
// Duplicate Line Up  ("copy line up")
//
// Fresh has `duplicate_line`, which duplicates the current line (or selected
// lines) BELOW the cursor and leaves the cursor on the lower copy. There is no
// up variant, and a keybinding cannot chain two actions -- the binding table is
// a HashMap<(key, mods), action>, so a second entry would just overwrite.
//
// This registers a real command instead. Two built-in actions, dispatched by
// ACTION NAME via `executeAction`, which is locale-independent -- unlike
// `runCommand`, whose argument is the translated palette label.
//
// Why duplicate-then-move-up is exactly "copy line up": both variants produce
// two identical lines, so the buffer content is the same either way. The only
// difference is which copy holds the cursor. `duplicate_line` puts it on the
// lower one; one `move_up` moves it to the upper one. That matters because
// typing immediately afterwards edits the upper copy rather than the lower.
//
// Cursor lands at column 0, matching `duplicate_line`'s own behaviour (it moves
// to the start of the duplicated line), so both variants feel the same.
// ---------------------------------------------------------------------------

registerHandler("duplicateLineUp", function () {
  // Order matters and is preserved: both calls are queued on the same command
  // channel, which the host drains in order -- so the cursor move lands after
  // the duplicate, not before it.
  //
  // NOTE on the return value: `executeAction` returns
  // `command_sender.send(..).is_ok()` -- i.e. "the command was QUEUED", not
  // "the action ran". An unknown action name still returns true here and is only
  // reported host-side as `Unknown action: <name>` in the log. So these returns
  // are not a correctness check; they only catch a dead channel.
  editor.executeAction("duplicate_line");
  editor.executeAction("move_up");
});

editor.registerCommand(
  "Duplicate Line Up",
  "Duplicate the current line above, cursor on the upper copy",
  "duplicateLineUp",
  null,
);

// ---------------------------------------------------------------------------
// Herdr Annotate handoff
// ---------------------------------------------------------------------------
//
// PROBLEM: cmd+k (Herdr's `annotate.capture`) shows nothing for a Fresh
// selection, but works if you press cmd+c first.
//
// WHY: Fresh enables mouse reporting (DECSET ?1002h/?1006h), so Herdr forwards
// drag events INTO Fresh and Fresh paints its own selection. Herdr never sees
// a selection for this pane, so `capture` walks its fallback chain and lands on
// the clipboard:
//
//   rust/src/cli.rs:70-76
//     1. HERDR_PLUGIN_CONTEXT_JSON `selected_text`  -> empty in a Fresh pane
//     2. handoff file                               -> nothing writes it
//     3. read_clipboard()                          -> what you see today
//
// Cmd+C "fixes" it precisely because it pre-loads fallback #3.
//
// FIX: write the selection to the handoff file `capture` reads as step 2.
// Path must match the plugin's rust/src/handoff.rs exactly:
//
//   std::env::temp_dir() / herdr-annotate-<uid> / selection
//
// Herdr's cmd+k binding stays untouched -- this only pre-stages the text.
//
// CAVEAT: handoff.rs ignores a file older than HANDOFF_MAX_AGE (15s), judging
// it by mtime. The poll rewrites while a selection is live, so the window stays
// armed for as long as the selection does -- a long pause before cmd+k is fine.

const HERDR_ANNOTATE = {
  uid: null as string | null,
  // Whether the previous tick saw a live selection, so the file is removed on
  // collapse and never on a run of empty ticks.
  active: false,
};

function herdrAnnotateDir(): string | null {
  if (!HERDR_ANNOTATE.uid) return null;
  const raw =
    editor.getEnv("TMPDIR") || editor.getEnv("TMP") || editor.getEnv("TEMP") || "/tmp";
  const base = raw.endsWith("/") ? raw.slice(0, -1) : raw;
  return base + "/herdr-annotate-" + HERDR_ANNOTATE.uid;
}

/**
 * Mirror the current selection into the plugin's handoff file.
 *
 * Rewrites on every tick while a selection exists -- deliberately, with no
 * dedup guard. `handoff.rs` accepts the file only while its mtime is within
 * HANDOFF_MAX_AGE (15s), so re-writing is what keeps the handoff armed; a
 * "skip if unchanged" optimisation would leave a stale mtime and send cmd+k
 * back to the clipboard. The payload is a few dozen bytes, and only runs while
 * text is actually selected.
 *
 * Removes the file when the selection collapses, so a stale selection can never
 * be picked up. Every path is wrapped: an unhandled rejection is fatal to
 * Fresh's plugin thread.
 */
async function herdrAnnotateSyncSelection() {
  try {
    const dir = herdrAnnotateDir();
    if (!dir) return;
    const path = dir + "/selection";

    const cursor = editor.getPrimaryCursor();
    const selection = cursor ? cursor.selection : null;
    const start = selection ? Math.min(selection.start, selection.end) : 0;
    const end = selection ? Math.max(selection.start, selection.end) : 0;

    if (!selection || end <= start) {
      if (HERDR_ANNOTATE.active) {
        HERDR_ANNOTATE.active = false;
        editor.removePath(path);
      }
      return;
    }

    const text = await editor.getBufferText(editor.getActiveBufferId(), start, end);
    if (!text || !text.trim()) return;

    if (editor.writeFile(path, text)) {
      HERDR_ANNOTATE.active = true;
    }
  } catch (error) {
    // Never let the handoff mirror take down the plugin thread.
  }
}

registerHandler("herdrAnnotateSyncSelection", herdrAnnotateSyncSelection);
// A poll, not an event. Verified on this build: `cursor_moved` fires when the
// cursor moves with no selection (plain Left fires it) but NOT when a selection
// is created (shift+Home/shift+End fire nothing), and `mouse_click` fires only
// on press, before the drag that makes the selection. A drag therefore has no
// event that reports its result, so the only reliable trigger is to look.
// `editor.setInterval` takes a NAMED handler -- the QuickJS global setInterval
// is not the API here, and a bare global call fails silently.
editor.setInterval(250, "herdrAnnotateSyncSelection");

// The plugin names the directory with the real uid, which is not exported to
// the environment, so ask `id -u` once and cache it.
editor.on("ready", function () {
  try {
    editor
      .spawnProcess("id", ["-u"])
      .result.then(function (result) {
        const uid = (result.stdout || "").trim();
        if (uid) HERDR_ANNOTATE.uid = uid;
      })
      .catch(function () {});
  } catch (error) {
    // Leave uid unset; the mirror stays inert rather than guessing a path.
  }
});
