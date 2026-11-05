//! herdr's NATIVE actions (the ones herdr itself binds, which never appear in
//! `herdr plugin action list`) — the list herdr-quick-actions surfaces. Each row
//! shows the keybinding herdr actually has for the action, resolved live by
//! `keys::Keys::shortcut`, and ends with a preview hint of the exact `herdr`
//! command it will run.

use crate::i18n::t;
use crate::keys::Keys;

/// One native action row. `key` is the config key name whose binding to render
/// (":" means "no keybinding — prompt/other"). `keywords` are extra searchable
/// terms (synonyms + the action id). `hint` is the preview strip.
#[derive(Debug, Clone)]
pub struct NativeAction {
    pub id: &'static str,
    pub title: &'static str,
    pub key: &'static str,
    pub keywords: &'static str,
    pub hint: &'static str,
}

pub const NATIVE_ACTIONS: &[NativeAction] = &[
    NativeAction {
        id: "new_tab",
        title: "New tab",
        key: "new_tab",
        keywords: "create window",
        hint: "herdr tab create --focus",
    },
    NativeAction {
        id: "new_tab_named",
        title: "New tab (named)…",
        key: ":",
        keywords: "create window label prompt",
        hint: "herdr tab create --label <name> --focus",
    },
    NativeAction {
        id: "rename_tab",
        title: "Rename tab",
        key: "rename_tab",
        keywords: "label title",
        hint: "herdr tab rename <tab> <name>",
    },
    NativeAction {
        id: "close_tab",
        title: "Close tab",
        key: "close_tab",
        keywords: "kill remove quit delete",
        hint: "herdr tab close <tab>",
    },
    NativeAction {
        id: "split_vertical",
        title: "Split pane right (vertical)",
        key: "split_vertical",
        keywords: "vsplit beside column new",
        hint: "herdr pane split <pane> --direction right --focus",
    },
    NativeAction {
        id: "split_horizontal",
        title: "Split pane down (horizontal)",
        key: "split_horizontal",
        keywords: "hsplit below row new",
        hint: "herdr pane split <pane> --direction down --focus",
    },
    NativeAction {
        id: "zoom_pane",
        title: "Toggle zoom (fullscreen pane)",
        key: "zoom",
        keywords: "maximize fullscreen big toggle",
        hint: "herdr pane zoom <pane> --toggle",
    },
    NativeAction {
        id: "close_pane",
        title: "Close pane",
        key: "close_pane",
        keywords: "kill remove quit delete",
        hint: "herdr pane close <pane>",
    },
    NativeAction {
        id: "rename_pane",
        title: "Rename pane",
        key: "rename_pane",
        keywords: "label title",
        hint: "herdr pane rename <pane> <name>",
    },
    NativeAction {
        id: "focus_left",
        title: "Focus pane left",
        key: "focus_pane_left",
        keywords: "go move navigate h",
        hint: "herdr pane focus --direction left --pane <pane>",
    },
    NativeAction {
        id: "focus_right",
        title: "Focus pane right",
        key: "focus_pane_right",
        keywords: "go move navigate l",
        hint: "herdr pane focus --direction right --pane <pane>",
    },
    NativeAction {
        id: "focus_up",
        title: "Focus pane up",
        key: "focus_pane_up",
        keywords: "go move navigate k",
        hint: "herdr pane focus --direction up --pane <pane>",
    },
    NativeAction {
        id: "focus_down",
        title: "Focus pane down",
        key: "focus_pane_down",
        keywords: "go move navigate j",
        hint: "herdr pane focus --direction down --pane <pane>",
    },
    NativeAction {
        id: "resize_left",
        title: "Resize pane left",
        key: "resize_mode",
        keywords: "grow shrink wider narrower border",
        hint: "herdr pane resize --direction left --pane <pane>",
    },
    NativeAction {
        id: "resize_right",
        title: "Resize pane right",
        key: "resize_mode",
        keywords: "grow shrink wider narrower border",
        hint: "herdr pane resize --direction right --pane <pane>",
    },
    NativeAction {
        id: "resize_up",
        title: "Resize pane up",
        key: "resize_mode",
        keywords: "grow shrink taller shorter border",
        hint: "herdr pane resize --direction up --pane <pane>",
    },
    NativeAction {
        id: "resize_down",
        title: "Resize pane down",
        key: "resize_mode",
        keywords: "grow shrink taller shorter border",
        hint: "herdr pane resize --direction down --pane <pane>",
    },
    NativeAction {
        id: "swap_left",
        title: "Swap pane with the one left",
        key: ":",
        keywords: "exchange switch rotate reorder",
        hint: "herdr pane swap --direction left --pane <pane>",
    },
    NativeAction {
        id: "swap_right",
        title: "Swap pane with the one right",
        key: ":",
        keywords: "exchange switch rotate reorder",
        hint: "herdr pane swap --direction right --pane <pane>",
    },
    NativeAction {
        id: "swap_up",
        title: "Swap pane with the one above",
        key: ":",
        keywords: "exchange switch rotate reorder",
        hint: "herdr pane swap --direction up --pane <pane>",
    },
    NativeAction {
        id: "swap_down",
        title: "Swap pane with the one below",
        key: ":",
        keywords: "exchange switch rotate reorder",
        hint: "herdr pane swap --direction down --pane <pane>",
    },
    NativeAction {
        id: "move_pane_tab",
        title: "Move pane to another tab…",
        key: ":",
        keywords: "send relocate join merge",
        hint: "herdr pane move <pane> --tab <tab> --focus",
    },
    NativeAction {
        id: "move_pane_new_tab",
        title: "Move pane out to a new tab",
        key: ":",
        keywords: "send relocate extract break out",
        hint: "herdr pane move <pane> --new-tab --focus",
    },
    NativeAction {
        id: "move_pane_new_workspace",
        title: "Move pane out to a new workspace",
        key: ":",
        keywords: "send relocate extract break out",
        hint: "herdr pane move <pane> --new-workspace --focus",
    },
    NativeAction {
        id: "start_agent",
        title: "Start an agent in a new split…",
        key: ":",
        keywords: "claude codex gemini ai launch spawn run new",
        hint: "herdr pane split + herdr agent start <name> --kind <kind>",
    },
    NativeAction {
        id: "prompt_agent",
        title: "Send a prompt to an agent…",
        key: ":",
        keywords: "ask message text tell claude ai",
        hint: "herdr agent prompt <agent> <text>",
    },
    NativeAction {
        id: "interrupt_agent",
        title: "Interrupt an agent (esc)…",
        key: ":",
        keywords: "stop cancel escape abort key",
        hint: "herdr agent send-keys <agent> esc",
    },
    NativeAction {
        id: "rename_agent",
        title: "Rename an agent…",
        key: ":",
        keywords: "label name target",
        hint: "herdr agent rename <agent> <name>",
    },
    NativeAction {
        id: "new_workspace",
        title: "New workspace",
        key: "new_workspace",
        keywords: "create project",
        hint: "herdr workspace create --focus",
    },
    NativeAction {
        id: "new_workspace_here",
        title: "New workspace here (named)…",
        key: ":",
        keywords: "create project cwd label prompt directory",
        hint: "herdr workspace create --cwd <cwd> --label <name> --focus",
    },
    NativeAction {
        id: "rename_workspace",
        title: "Rename workspace",
        key: "rename_workspace",
        keywords: "label title project",
        hint: "herdr workspace rename <workspace> <name>",
    },
    NativeAction {
        id: "close_workspace",
        title: "Close workspace",
        key: "close_workspace",
        keywords: "kill remove quit delete project",
        hint: "herdr workspace close <workspace>",
    },
    NativeAction {
        id: "new_worktree",
        title: "New worktree here",
        key: "new_worktree",
        keywords: "git branch checkout create",
        hint: "herdr worktree create --workspace <workspace> --focus",
    },
    NativeAction {
        id: "new_worktree_branch",
        title: "New worktree on a branch…",
        key: ":",
        keywords: "git checkout create base prompt",
        hint: "herdr worktree create --branch <name> [--base <ref>] --focus",
    },
    NativeAction {
        id: "remove_worktree",
        title: "Remove this worktree checkout",
        key: "remove_worktree",
        keywords: "git delete prune rm",
        hint: "herdr worktree remove --workspace <workspace>",
    },
    NativeAction {
        id: "reload_config",
        title: "Reload herdr config",
        key: "reload_config",
        keywords: "settings keys keybindings toml refresh",
        hint: "herdr server reload-config",
    },
];

/// Render a native action's parts for the fzf display column: the title, the
/// resolved shortcut (empty for ":" = no binding), and the plain keyword tail
/// (dimmed by the caller, but searched by fzf since it lives on the row).
pub fn row_display(a: &NativeAction, keys: &Keys) -> (String, String, String) {
    let shortcut = if a.key == ":" {
        String::new()
    } else {
        keys.shortcut(a.key, None)
    };
    let keywords = format!("{} {}", a.keywords, a.id);
    (title_text(a), shortcut, keywords)
}

/// The menu title for a native action, in the language Mash chose. The English
/// `title` field is only the fallback for an id this list does not name.
pub fn title_text(a: &NativeAction) -> String {
    match a.id {
        "new_tab" => t("plugin.telescope.native.new_tab"),
        "new_tab_named" => t("plugin.telescope.native.new_tab_named"),
        "rename_tab" => t("plugin.telescope.native.rename_tab"),
        "close_tab" => t("plugin.telescope.native.close_tab"),
        "split_vertical" => t("plugin.telescope.native.split_vertical"),
        "split_horizontal" => t("plugin.telescope.native.split_horizontal"),
        "zoom_pane" => t("plugin.telescope.native.zoom_pane"),
        "close_pane" => t("plugin.telescope.native.close_pane"),
        "rename_pane" => t("plugin.telescope.native.rename_pane"),
        "focus_left" => t("plugin.telescope.native.focus_left"),
        "focus_right" => t("plugin.telescope.native.focus_right"),
        "focus_up" => t("plugin.telescope.native.focus_up"),
        "focus_down" => t("plugin.telescope.native.focus_down"),
        "resize_left" => t("plugin.telescope.native.resize_left"),
        "resize_right" => t("plugin.telescope.native.resize_right"),
        "resize_up" => t("plugin.telescope.native.resize_up"),
        "resize_down" => t("plugin.telescope.native.resize_down"),
        "swap_left" => t("plugin.telescope.native.swap_left"),
        "swap_right" => t("plugin.telescope.native.swap_right"),
        "swap_up" => t("plugin.telescope.native.swap_up"),
        "swap_down" => t("plugin.telescope.native.swap_down"),
        "move_pane_tab" => t("plugin.telescope.native.move_pane_tab"),
        "move_pane_new_tab" => t("plugin.telescope.native.move_pane_new_tab"),
        "move_pane_new_workspace" => t("plugin.telescope.native.move_pane_new_workspace"),
        "start_agent" => t("plugin.telescope.native.start_agent"),
        "prompt_agent" => t("plugin.telescope.native.prompt_agent"),
        "interrupt_agent" => t("plugin.telescope.native.interrupt_agent"),
        "rename_agent" => t("plugin.telescope.native.rename_agent"),
        "new_workspace" => t("plugin.telescope.native.new_workspace"),
        "new_workspace_here" => t("plugin.telescope.native.new_workspace_here"),
        "rename_workspace" => t("plugin.telescope.native.rename_workspace"),
        "close_workspace" => t("plugin.telescope.native.close_workspace"),
        "new_worktree" => t("plugin.telescope.native.new_worktree"),
        "new_worktree_branch" => t("plugin.telescope.native.new_worktree_branch"),
        "remove_worktree" => t("plugin.telescope.native.remove_worktree"),
        "reload_config" => t("plugin.telescope.native.reload_config"),
        _ => a.title.to_string(),
    }
}

/// Build the final display row: `title` (+pad) `shortcut` `dim-keywords`.
/// `title_w` is the target title column width; titles longer than it just push
/// their shortcut right instead of being truncated.
pub fn build_display(title: &str, shortcut: &str, keywords: &str, title_w: usize) -> String {
    let mut s = title.to_string();
    let tlen = title.chars().count();
    if tlen < title_w {
        for _ in 0..(title_w - tlen) {
            s.push(' ');
        }
    } else {
        s.push(' '); // at least one gap when title overflows the column
    }
    s.push_str("  ");
    s.push_str(shortcut);
    s.push_str("  ");
    s.push_str(&format!("\u{1b}[2m{}\u{1b}[0m", keywords));
    s.trim_end().to_string()
}
