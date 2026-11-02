# Fork from Message

Fork the focused Pi session into a new tab, split pane, or workspace.
Select a user message to restart: the fork keeps history immediately before that message and restores its text into the new editor, **unsent**.
The source session file is never rewritten.

## Picker and startup

The picker reconstructs the compaction-aware branch from the saved session file, omitting compacted-away and abandoned-branch messages.
The first user message is displayed but unavailable because there is no earlier user-message history to retain.
Messages have multi-line previews; the newest message is selected initially.

A storage-only helper uses the bundled Pi's `SessionManager` instead of starting extra Pi agents to list or fork messages.
The destination becomes visible before Pi finishes starting.
Draft restoration waits for interactive readiness and verification of the fork's session identity; a paste failure leaves the usable fork open with a warning.

## Known limitation: unsaved `/tree` navigation

**This plugin is intentionally file-only; it cannot inspect the running Pi process's in-memory branch position.**
After navigating with `/tree` without appending another session entry, Pi can display a different branch or point than the last one saved in the file.
During that interval, the picker follows the saved branch, so its message list can differ from the source pane.
Appending an entry on the navigated branch makes that position reconstructable from the file again.
Check the picker's message text rather than assuming its row positions match an unsaved `/tree` view.

This limitation is accepted for the file-only implementation; the plugin does not extend the Pi–Herdr integration, alter the source session, or send a message merely to synchronize that position.
Regardless of this limitation, the chosen entry ID determines the fork boundary, not a row number or message-text match.

Restored drafts contain message text; original image attachments are not automatically reattached.
Storage-only branching does not run source-side extension fork hooks; the new interactive Pi starts with its normal extensions.

## Checks

From the repository root:

```sh
bash packaging/plugins/fork-from-message/scripts/check.sh
make test
make release-preflight
```

The helper integration suite uses the installed Pi when available.
The bundle's runtime gate also runs it against the freshly staged Pi, catching incompatible session API changes during a build.
