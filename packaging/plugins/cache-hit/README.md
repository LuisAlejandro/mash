# Herdr Agent Cache Hit & Expiration Plugin (`cache-hit`)

[![CI](https://github.com/e-kotov/herdr-cache-hit/actions/workflows/ci.yml/badge.svg)](https://github.com/e-kotov/herdr-cache-hit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[Website and live showcase](https://www.ekotov.pro/herdr-cache-hit/)

A high-efficiency plugin for [Herdr](https://github.com/herdrdev/herdr) that provides real-time prompt-cache HUD metrics, dynamic expiration countdowns, and declarative cache-deadline agent sorting.

Supports **Codex CLI**, **Pi**, **Claude Code**, and **OpenCode**.

[![Herdr terminal sidebar showing alarm, active, and cold prompt-cache states sorted by expiry](https://www.ekotov.pro/herdr-cache-hit/assets/herdr-expiry-agents.webp)](https://www.ekotov.pro/herdr-cache-hit/)

---

## Features

- **Live Prompt-Cache HUD**: Real-time cache hit ratios, read/cached token metrics, and estimated expiration countdowns directly in Herdr's sidebar.
- **Urgency Transitions**: Automatic visual transitions from healthy state (`+~15:44`) to expiring state (`!~15:44`) using muted dark-mode colors and normal-weight digits (configurable threshold, default ≤5m).
- **Declarative Agent Sorting**: Optionally sort active agent panes by prompt-cache expiration deadline (`cache_deadline asc`), keeping expiring agents at the top. This fork leaves sorting native by default and provides CLI control without a keybinding.
- **Bounded Rescans**: Event hooks update immediately. While any cache is active or an enabled Codex or Pi pane is present, one lightweight wake timer rescans every 15 seconds (or sooner for an expiration transition). Codex and Pi's first cache hit can appear even when the pane started with no cache record.
- **Privacy-First**: Content is processed locally only as necessary to extract usage metadata and is not intentionally extracted, retained, logged, or transmitted.

---

## Prerequisites & Compatibility

- **Operating Systems**: **macOS** and **Linux** (native). On **Windows**, use **WSL2** (Windows Subsystem for Linux). Native Windows (PowerShell / Command Prompt) is not supported as Herdr and its plugin hooks run in a POSIX shell environment.
- **Dependencies**:
  - `jq` (**Required**): Core JSON parser for state and token metadata (`brew install jq` or `sudo apt install jq`).
  - `bash` (**Required**): Standard on Linux (4.0+) and macOS (native bash 3.2 works; Homebrew bash 4.0+ is also supported).
  - `python3` 3.6+ (**Optional**): Needed for **OpenCode**, view sorting, and Codex session recovery when Herdr has no native session ID. Codex panes with a native session ID, Pi, and Claude Code need only Bash and jq.

---

## Quick Start

### 1. Install Plugin

This local fork is linked into Herdr with:

```bash
herdr plugin unlink cache-hit 2>/dev/null || true
herdr plugin link packaging/plugins/cache-hit
herdr plugin list
```

The fork keeps the upstream repository as a read-only `upstream` remote and
replaces AGY support with the Pi adapter.

### 2. Configure Herdr Sidebar

Add dynamic styling rules to `~/.config/herdr/config.toml` so Herdr colors cache states with muted dark-mode tones:

```toml
[ui.sidebar.agents]
rows = [
  [{ token = "state_icon", bold = true, dim = false }, { token = "agent", fg = "#241835", bold = true, dim = false }],
  [
    { token = "$cache", fg = "#6b7280", bold = false, dim = true, rules = [
      { starts_with = "!", bold = false, dim = true, fg = "#b56b6b" },
      { starts_with = "+", bold = false, dim = true, fg = "#6f9f72" },
      { starts_with = "-", bold = false, dim = true, fg = "#6b7280" }
    ] }
  ],
  [{ token = "workspace", fg = "#4c4669", bold = false, dim = false }, { token = "tab", fg = "#4c4669", bold = false, dim = false }]
]
```

### 3. Optional expiration sorting

Expiration sorting is optional. Run it manually when wanted:

```bash
herdr-cache-view set expiry
herdr-cache-view set native
```

No keybinding is required; `native` is the default sorting mode.

---

## Token Reference

The plugin emits the following pane tokens:

- **`$cache`**: Unified token string without middle dots (e.g. `+~11:41 99% ⇣95.4k` when healthy, `!~11:41 99% ⇣95.4k` when expiring, or `- ⇣95.4k` when cold). Percentages are omitted after expiration because they describe the last request rather than the usable cache.
- **`$cache_status`**: Expiration clock with optional symbol prefix (e.g. `+~11:41` or `!~11:41`).
- **`$cache_pct`**: Cache hit percentage (`99%`).
- **`$cache_pct_num`**: Raw integer hit percentage for native numeric rules (`99`; cleared when cold).
- **`$cache_remaining_secs`**: Seconds until estimated expiration (`240`; cleared when cold).
- **`$cache_tokens`**: Read and write token counters (`⇣95.4k`).
- **`$cache_state`**: State identifier (`hot`, `expiring`, or `cold`).
- **`cache_deadline`**: Epoch timestamp used for declarative sorting.

---

## Configuration & Documentation

For detailed information on configuring symbols, thresholds, timezones, per-agent overrides, custom declarative views, and troubleshooting, see the **[User Guide & Configuration Manual](USERGUIDE.md)**.

A ready-to-use template is available in [`config.example.json`](config.example.json).

---

## Verification & Testing

Run the test suite and static analysis:

```bash
bash -n watch.sh
shellcheck watch.sh lib/*.sh bin/herdr-cache-view
bash tests/test_watch.sh
```

---

## License

[MIT](LICENSE) © 2026 Egor Kotov
