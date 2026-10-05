# User Guide & Configuration Manual

This guide covers full configuration, token customization, sidebar styling, and declarative view sorting for the **cache-hit** Herdr plugin.

---

## Table of Contents

1. [Architecture & How It Works](#architecture--how-it-works)
2. [Configuration Reference](#configuration-reference)
3. [Token Reference](#token-reference)
4. [Sidebar Styling & Color Rules](#sidebar-styling--color-rules)
5. [Agent Sorting & Keybindings](#agent-sorting--keybindings)
6. [Agent Adapters & Data Sources](#agent-adapters--data-sources)
7. [Troubleshooting & Diagnostics](#troubleshooting--diagnostics)

---

## Architecture & How It Works

`cache-hit` is an event-driven metadata scanner for [Herdr](https://github.com/herdrdev/herdr).
- **No Background Daemon**: Herdr events start `watch.sh`; no persistent scanner process is required.
- **Single Refresh Timer**: While at least one cache is active or an enabled Codex/Pi pane is present, one lightweight sleep process wakes at the earlier of 15 seconds or the next expiration display transition. Cold Codex and Pi panes continue refreshing so their first cache hit is detected. With no active caches and no enabled Codex/Pi panes, no periodic scan is scheduled.
- **Privacy**: Content is processed locally only as necessary to extract usage metadata and is not intentionally extracted, retained, logged, or transmitted. Only token usage counters, session identifiers, model names, and provider identifiers are tracked.

---

## Configuration Reference

Configuration is stored in `config.json` inside the plugin's configuration directory:

```bash
herdr plugin config-dir cache-hit
```

If `config.json` does not exist, safe built-in defaults are used. Changes to `config.json` take effect on the very next Herdr scan without needing a server restart.

### Global Settings

| Setting | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `hot_symbol` | string | `"+"` | Character prepended to the countdown clock while cache is healthy. |
| `expiring_symbol` | string | `"!"` | Character prepended when remaining cache lifetime is at or below `expiring_threshold_seconds`. |
| `cold_symbol` | string | `"-"` | Character shown before retained token counts when cache has expired. |
| `expiring_threshold_seconds`| integer | `300` | Expiration threshold in seconds (default 5 minutes). |
| `bold_time` | boolean | `false` | Keep countdown digits in normal weight; this fork disables bold digits. |
| `bold_threshold_seconds` | integer | `300` | Retained for compatibility; has no visible effect while `bold_time` is `false`. |
| `timezone` | string | `""` | IANA timezone name (e.g. `"Europe/Berlin"`, `"America/New_York"`). When empty, respects `HERDR_PLUGIN_TIMEZONE` or the local system timezone. |
| `display_agent` | string | `"auto"` | Controls injection of cache stats into Herdr's `--display-agent` metadata (`"auto"`, `"always"`, or `"never"`). In `"auto"` mode, stats are injected only when terminal width $\le$ `mobile_width_threshold` or under Termux, keeping desktop multi-row sidebars clean and free of duplicate badges. |
| `mobile_width_threshold` | integer | `64` | Terminal column width at or below which Herdr collapses into single-line mobile layout. |

### Per-Agent Settings

Supported agent keys: `claude` (Claude Code), `codex` (Codex CLI), `opencode` (OpenCode), `pi` (Pi coding agent).

```json
{
  "pi": {
    "enabled": true,
    "show_deadline": true,
    "show_read_tokens": true,
    "show_write_tokens": false,
    "show_percentage": true,
    "show_model": false,
    "ttl_ceiling": 3600
  }
}
```

| Field | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `enabled` | boolean | `true` | Enable cache tracking for this agent. Set `false` to clear this agent's cache token. |
| `show_deadline` | boolean | `true` | Include the estimated expiration countdown time (`~15:44`). |
| `show_read_tokens` | boolean | `true` | Include read/cached tokens counter (e.g. `⇣95.4k`). |
| `show_write_tokens`| boolean | `false` | Include cache-creation tokens counter (e.g. `⇡12.3k`). |
| `show_percentage` | boolean | Agent-dependent | Show cache hit percentage (`99%`). Defaults `true` for Codex/OpenCode/Pi, `false` for Claude. |
| `show_model` | boolean | `false` | Include model name in the token string. |
| `ttl_ceiling` | integer | `3600` | Hard upper bound in seconds on learned prompt-cache survival time. |

---

## Token Reference

The plugin emits the following pane tokens to Herdr:

| Token | Description | Example Output |
| :--- | :--- | :--- |
| **`$cache`** | **Unified string** combining status, countdown, percentage, and token counts without middle-dot separators. Cold output omits the last-request percentage. | Hot: `+~15:44 99% ⇣95.4k`<br>Expiring: `!~15:44 99% ⇣95.4k`<br>Cold: `- ⇣95.4k` |
| **`$cache_status`** | Status symbol and countdown clock. | `+~15:44`, `!~15:44`, or `-` when cold |
| **`$cache_pct`** | Formatted cache hit percentage; cleared when cold. | `99%` |
| **`$cache_pct_num`** | Raw integer hit percentage for numeric comparisons; cleared when cold. | `99` |
| **`$cache_remaining_secs`** | Seconds remaining until expiration; cleared when cold. | `240` |
| **`$cache_tokens`** | Just the read/write token counters. | `⇣95.4k` |
| **`$cache_state`** | Lifecycle state identifier. | `hot`, `expiring`, or `cold` |
| **`cache_deadline`**| Unix epoch integer timestamp of expiration. | `1788877732` (cleared when cold) |

---

## Sidebar Styling & Color Rules

Herdr's sidebar configuration (`~/.config/herdr/config.toml`) controls how tokens are rendered. Using conditional `rules` on `$cache` allows dynamic color transitions:

```toml
[ui.sidebar.agents]
rows = [
  [
    { token = "state_icon", bold = true, dim = false },
    { token = "agent", fg = "#241835", bold = true, dim = false }
  ],
  [
    { token = "$cache", fg = "#6b7280", bold = false, dim = true, rules = [
      { starts_with = "!", bold = false, dim = true, fg = "#b56b6b" }, # Expiring, muted red
      { starts_with = "+", bold = false, dim = true, fg = "#6f9f72" }, # Healthy, muted green
      { starts_with = "-", bold = false, dim = true, fg = "#6b7280" }  # Cold, muted slate
    ] }
  ],
  [
    { token = "workspace", fg = "#4c4669", bold = false, dim = false },
    { token = "tab", fg = "#4c4669", bold = false, dim = false }
  ]
]
```

---

## Agent Sorting & Keybindings

The plugin includes `bin/herdr-cache-view`, a declarative view manager that interfaces with Herdr's JSON-RPC socket API (`agent.view.set` and `agent.view.clear`).

### View Modes
1. **`expiry`**: Sorts active sessions with live prompt caches by earliest expiration deadline first (`cache_deadline asc`), keeping expiring sessions at the top. Cold sessions fall back cleanly to Herdr priority mode (`attention desc`, `state_change_seq desc`).
2. **`native`**: Herdr's default interactive sort mode.

### CLI Usage

```bash
# Toggle between expiry sorting and native sorting
herdr-cache-view toggle

# Explicitly set view
herdr-cache-view set expiry
herdr-cache-view set native

# Check current active mode
herdr-cache-view get

# Restore saved mode (run on startup)
herdr-cache-view restore
```

### Herdr Keybinding Integration

No keybinding is installed for cache sorting in this fork. Use the CLI explicitly when needed:

```bash
herdr-cache-view set expiry
herdr-cache-view set native
```

The active mode is saved in `sort_mode.json` and automatically restored whenever Herdr boots via the plugin's `[[startup]]` hook.

---

## Agent Adapters & Data Sources

| Agent | Extraction Method | Required Helper / Dependencies |
| :--- | :--- | :--- |
| **Codex CLI** | Rollout inspection from `${CODEX_HOME:-~/.codex}/sessions` | `bash` + `jq`; `python3` 3.6+ for missing-session recovery |
| **Claude Code** | Project transcript analysis (`~/.claude/projects/`) | None (pure `bash` + `jq`) |
| **OpenCode** | SQLite database (`~/.local/share/opencode/opencode.db`) | `python3` |
| **Pi** | Session JSONL usage records | `bash` + `jq` |

### Codex Session Recovery

The adapter supports both `token_usage_record.payload.usage` and
`event_msg.payload.info.last_token_usage` (`token_count`). It uses per-request
cache counts, ignores quota-only events, and reads model/provider metadata from
the preceding turn context and session metadata. `CODEX_SESSIONS_DIR` takes
precedence over `HODEX_SESSIONS_DIR`, then `CODEX_HOME`.

When Herdr has no native Codex session ID, the optional Python helper inspects
`pane process-info`. An explicit `codex resume <id>` selects that session.
Otherwise, a unique root rollout matching the process launch time and exact
directory is selected. When several roots are active, cumulative input/output
counters in the pane's terminal title can identify a unique matching rollout.
These totals are used only for session identification, never for the cache-hit
percentage. Interactive resume can fall back to a unique root with usage since
process launch in that directory only when no other Codex pane shares it; an
empty bootstrap thread is excluded when a resumed thread has real usage. Subagents and sessions
already assigned to other panes are excluded. Ambiguous matches leave the cache
blank rather than display another session's counters. This publishes only cache
metadata; it does not change Herdr's native session identity.

The fallback was informed by [herdr-agent-usage](https://github.com/senna-lang/herdr-agent-usage)'s
Codex adapter, with additional guards for same-directory panes and subagents.

### Pi adapter

Pi stores session events as JSONL under `${PI_HOME:-~/.pi}/agent/sessions/`.
Herdr supplies the exact session path in `agent_session.value`; the adapter reads
the latest assistant usage record and maps Pi's `usage.input`, `usage.cacheRead`,
and `usage.cacheWrite` fields to the plugin's input, cached-read, and cache-write
counters. Provider and model metadata come from the same record.

The adapter reads only the recent tail of the session file, ignores malformed or
non-usage lines, and keeps the session path as the pane identity so multiple Pi
sessions remain isolated.
---

## Troubleshooting & Diagnostics

### Inspect Live Tokens
Run `herdr pane list` to view the tokens currently assigned to each pane:
```bash
herdr pane list | jq '.result.panes[] | {agent, tokens}'
```

### Inspect Observations
Survival observations are stored in:
```bash
cat "${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/cache-hit/observations.json"
```

### Verify Scripts & Tests
```bash
bash -n watch.sh
shellcheck watch.sh lib/*.sh bin/herdr-cache-view scripts/*.sh
bash tests/test_watch.sh
```
