//! Layout profiles from `$HERDR_PLUGIN_CONFIG_DIR/config.yaml`.

use serde::Deserialize;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

pub const EXAMPLE_YAML: &str = include_str!("../config.example.yaml");

#[derive(Debug, Clone, Deserialize)]
pub struct PluginConfig {
    #[serde(default)]
    pub profiles: Vec<Profile>,
    /// Optional per-plugin color overrides for the profile cards.
    #[serde(default)]
    pub colors: Colors,
}

/// Card colors, independent of Herdr's theme.
///
/// By default the popup inherits Herdr's `accent` / `yellow` / `overlay`
/// tokens, which means restyling the cards would mean restyling the whole
/// Herdr UI. Each field here overrides one card color and nothing else;
/// leaving it unset keeps the inherited value.
///
/// Accepts the same syntax as Herdr's `[theme.custom]`: `#rgb`, `#rrggbb`,
/// `rgb(r, g, b)`, a named color, or `reset`.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct Colors {
    /// Border of the card under the cursor.
    #[serde(default)]
    pub card_focused: Option<String>,
    /// Border of the chosen card while focus is elsewhere.
    #[serde(default)]
    pub card_selected: Option<String>,
    /// Border of the remaining cards.
    #[serde(default)]
    pub card_idle: Option<String>,
    /// Card title text.
    #[serde(default)]
    pub card_title: Option<String>,
    /// Card description text.
    #[serde(default)]
    pub card_text: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Profile {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub tabs: Vec<TabSpec>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TabSpec {
    /// Herdr tab label. Optional: omit it (or set it empty) to leave the tab
    /// unlabeled so Herdr's own auto-naming -- or the auto-title plugin --
    /// decides the title from the tab's focused pane. A label set here is a
    /// *manual* rename as far as those are concerned, and locks them out.
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub panes: Vec<PaneSpec>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PaneSpec {
    pub id: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub split_from: Option<String>,
    #[serde(default)]
    pub direction: Option<String>,
    #[serde(default)]
    pub ratio: Option<f64>,
    #[serde(default)]
    pub command: Option<String>,
    /// Live Herdr agent name (`herdr agent start <name>`). `[a-z][a-z0-9_-]{0,31}`.
    #[serde(default)]
    pub agent: Option<String>,
    /// Herdr agent kind (`codex`, `grok`, `claude`, …). Required with `agent`.
    #[serde(default)]
    pub kind: Option<String>,
    /// Extra argv passed after `--` to `herdr agent start`.
    #[serde(default)]
    pub args: Vec<String>,
    /// Focus this pane once its agent is up, instead of leaving focus on the
    /// tab root. Agent panes only: `herdr agent start` is the readiness signal
    /// the focus waits on, so keystrokes typed the moment the layout appears
    /// cannot land in the shell the agent is starting from. See apply.rs.
    #[serde(default)]
    pub focus: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigError {
    pub message: String,
}

impl std::fmt::Display for ConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for ConfigError {}

pub fn config_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("HERDR_PLUGIN_CONFIG_DIR") {
        if !dir.is_empty() {
            return PathBuf::from(dir);
        }
    }
    PathBuf::from(".")
}

pub fn config_path() -> PathBuf {
    config_dir().join("config.yaml")
}

/// Load profiles. Seeds `config.yaml` from the bundled example when missing.
pub fn load() -> Result<PluginConfig, ConfigError> {
    let path = config_path();
    if !path.exists() {
        seed_example(&path)?;
    }
    load_from_path(&path)
}

pub fn seed_example(path: &Path) -> Result<(), ConfigError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| ConfigError {
            message: format!("create config dir: {e}"),
        })?;
    }
    fs::write(path, EXAMPLE_YAML).map_err(|e| ConfigError {
        message: format!("write {}: {e}", path.display()),
    })
}

pub fn load_from_path(path: &Path) -> Result<PluginConfig, ConfigError> {
    let raw = fs::read_to_string(path).map_err(|e| ConfigError {
        message: format!("read {}: {e}", path.display()),
    })?;
    parse_yaml(&raw)
}

pub fn parse_yaml(raw: &str) -> Result<PluginConfig, ConfigError> {
    let mut cfg: PluginConfig = serde_yaml::from_str(raw).map_err(|e| ConfigError {
        message: format!("parse config: {e}"),
    })?;
    normalize(&mut cfg);
    validate(&cfg)?;
    Ok(cfg)
}

fn normalize(cfg: &mut PluginConfig) {
    for profile in &mut cfg.profiles {
        profile.description = profile.description.trim().to_string();
        for tab in &mut profile.tabs {
            for pane in &mut tab.panes {
                if let Some(cmd) = pane.command.as_mut() {
                    let trimmed = cmd.trim_end().to_string();
                    if trimmed.is_empty() {
                        pane.command = None;
                    } else {
                        *cmd = trimmed;
                    }
                }
                empty_to_none(&mut pane.agent);
                empty_to_none(&mut pane.kind);
                pane.args.retain(|a| !a.is_empty());
            }
        }
    }
}

fn empty_to_none(value: &mut Option<String>) {
    if let Some(s) = value.as_mut() {
        let trimmed = s.trim().to_string();
        if trimmed.is_empty() {
            *value = None;
        } else {
            *s = trimmed;
        }
    }
}

pub fn validate(cfg: &PluginConfig) -> Result<(), ConfigError> {
    if cfg.profiles.is_empty() {
        return Err(err("no profiles defined"));
    }
    let mut ids = HashSet::new();
    for profile in &cfg.profiles {
        if profile.id.is_empty() {
            return Err(err("profile id is empty"));
        }
        if profile.name.is_empty() {
            return Err(err(&format!("profile `{}` has empty name", profile.id)));
        }
        if !ids.insert(profile.id.clone()) {
            return Err(err(&format!("duplicate profile id `{}`", profile.id)));
        }
        if profile.tabs.is_empty() {
            return Err(err(&format!("profile `{}` has no tabs", profile.id)));
        }
        for (ti, tab) in profile.tabs.iter().enumerate() {
            // An empty name is deliberate, not an error: it means "do not label
            // this tab", so Herdr auto-names it from its focused pane. Use the
            // index for error messages that would otherwise interpolate it.
            let tab_label = if tab.name.is_empty() {
                format!("{ti}")
            } else {
                tab.name.clone()
            };
            validate_tab(&profile.id, &tab_label, &tab.panes)?;
        }
    }
    Ok(())
}

fn validate_tab(profile_id: &str, tab_name: &str, panes: &[PaneSpec]) -> Result<(), ConfigError> {
    if panes.is_empty() {
        return Err(err(&format!(
            "profile `{profile_id}` tab `{tab_name}` has no panes"
        )));
    }
    let mut seen = HashSet::new();
    for (i, pane) in panes.iter().enumerate() {
        if pane.id.is_empty() {
            return Err(err(&format!(
                "profile `{profile_id}` tab `{tab_name}` pane {i} has empty id"
            )));
        }
        if !seen.insert(pane.id.clone()) {
            return Err(err(&format!(
                "profile `{profile_id}` tab `{tab_name}` duplicate pane id `{}`",
                pane.id
            )));
        }
        if i == 0 {
            if pane.split_from.is_some() {
                return Err(err(&format!(
                    "profile `{profile_id}` tab `{tab_name}` first pane `{}` must be the root (no split_from)",
                    pane.id
                )));
            }
        } else {
            let Some(from) = pane.split_from.as_deref() else {
                return Err(err(&format!(
                    "profile `{profile_id}` tab `{tab_name}` pane `{}` needs split_from",
                    pane.id
                )));
            };
            if !panes[..i].iter().any(|p| p.id == from) {
                return Err(err(&format!(
                    "profile `{profile_id}` tab `{tab_name}` pane `{}` split_from `{from}` is not an earlier pane",
                    pane.id
                )));
            }
            let dir = pane.direction.as_deref().unwrap_or("");
            if dir != "right" && dir != "down" {
                return Err(err(&format!(
                    "profile `{profile_id}` tab `{tab_name}` pane `{}` direction must be `right` or `down`",
                    pane.id
                )));
            }
        }
        if let Some(ratio) = pane.ratio {
            if !(0.0 < ratio && ratio < 1.0) {
                return Err(err(&format!(
                    "profile `{profile_id}` tab `{tab_name}` pane `{}` ratio must be between 0 and 1",
                    pane.id
                )));
            }
        }
        validate_agent(profile_id, tab_name, pane)?;
    }
    Ok(())
}

fn validate_agent(profile_id: &str, tab_name: &str, pane: &PaneSpec) -> Result<(), ConfigError> {
    let loc = format!("profile `{profile_id}` tab `{tab_name}` pane `{}`", pane.id);
    if pane.focus && pane.agent.is_none() {
        return Err(err(&format!(
            "{loc} sets focus but has no agent; only agent panes can be focused, \
             because `agent start` is what reports the pane ready for input"
        )));
    }
    match (pane.agent.as_deref(), pane.kind.as_deref()) {
        (None, None) => {
            if !pane.args.is_empty() {
                return Err(err(&format!("{loc} has args but no agent")));
            }
        }
        (Some(name), Some(kind)) => {
            if !is_agent_name(name) {
                return Err(err(&format!(
                    "{loc} agent `{name}` must match [a-z][a-z0-9_-]{{0,31}}"
                )));
            }
            if kind.is_empty() {
                return Err(err(&format!("{loc} kind is empty")));
            }
            if pane.command.is_some() {
                return Err(err(&format!(
                    "{loc} cannot set both agent and command; use args for agent flags"
                )));
            }
        }
        (Some(_), None) => return Err(err(&format!("{loc} agent requires kind"))),
        (None, Some(_)) => return Err(err(&format!("{loc} kind requires agent"))),
    }
    Ok(())
}

fn is_agent_name(name: &str) -> bool {
    let mut chars = name.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !first.is_ascii_lowercase() {
        return false;
    }
    name.len() <= 32
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

fn err(message: &str) -> ConfigError {
    ConfigError {
        message: message.to_string(),
    }
}

impl Profile {
    /// Short lines for a profile card: tab and pane names.
    pub fn card_lines(&self) -> Vec<String> {
        let mut lines = Vec::new();
        if !self.description.is_empty() {
            lines.push(self.description.clone());
        }
        for tab in &self.tabs {
            let panes: Vec<&str> = tab
                .panes
                .iter()
                .map(|p| p.agent.as_deref().or(p.name.as_deref()).unwrap_or(&p.id))
                .collect();
            lines.push(format!("{}: {}", tab.name, panes.join(" · ")));
        }
        lines
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A `colors:` block must parse and reach the Colors struct.
    #[test]
    fn colors_block_parses() {
        let yaml = r##"
colors:
  card_focused: "#7aa2f7"
  card_selected: "#9ece6a"
  card_idle: "#555555"
  card_title: "#ffffff"
  card_text: "#999999"
profiles:
  - id: solo
    name: Solo
    tabs:
      - panes:
          - id: shell
"##;
        let cfg = parse_yaml(yaml).unwrap();
        assert_eq!(cfg.colors.card_focused.as_deref(), Some("#7aa2f7"));
        assert_eq!(cfg.colors.card_selected.as_deref(), Some("#9ece6a"));
        assert_eq!(cfg.colors.card_idle.as_deref(), Some("#555555"));
        assert_eq!(cfg.colors.card_title.as_deref(), Some("#ffffff"));
        assert_eq!(cfg.colors.card_text.as_deref(), Some("#999999"));
    }

    /// Omitting the block entirely, or any single key, is valid.
    #[test]
    fn colors_block_is_optional() {
        let cfg = parse_yaml(
            "profiles:\n  - id: solo\n    name: Solo\n    tabs:\n      - panes:\n          - id: shell\n",
        )
        .unwrap();
        assert!(cfg.colors.card_focused.is_none());
        assert!(cfg.colors.card_text.is_none());

        let partial = parse_yaml(
            "colors:\n  card_idle: \"#333\"\nprofiles:\n  - id: solo\n    name: Solo\n    tabs:\n      - panes:\n          - id: shell\n",
        )
        .unwrap();
        assert_eq!(partial.colors.card_idle.as_deref(), Some("#333"));
        assert!(partial.colors.card_focused.is_none());
    }

    #[test]
    fn example_config_parses() {
        let cfg = parse_yaml(EXAMPLE_YAML).expect("example");
        assert_eq!(cfg.profiles.len(), 3);
        assert_eq!(cfg.profiles[1].id, "pair");
        assert_eq!(
            cfg.profiles[1].tabs[0].panes[1].split_from.as_deref(),
            Some("shell")
        );
        assert_eq!(cfg.profiles[2].tabs.len(), 2);
        let pair_agent = &cfg.profiles[1].tabs[0].panes[1];
        assert_eq!(pair_agent.agent.as_deref(), Some("pair"));
        assert_eq!(pair_agent.kind.as_deref(), Some("claude"));
        assert!(pair_agent.command.is_none());
    }

    /// The profiles Mash seeds must load with this plugin's own parser, and
    /// every pi pane must take focus. A pane that does not leaves the new
    /// workspace's caret outside pi, and the first keystrokes go nowhere.
    #[test]
    fn mash_seeded_profiles_parse_and_focus_every_pi_pane() {
        let cfg = parse_yaml(include_str!(
            "../../../defaults/plugins/herdr-workspace/config.yaml"
        ))
        .expect("Mash's seeded herdr-workspace config");
        let ids: Vec<_> = cfg.profiles.iter().map(|p| p.id.as_str()).collect();
        assert_eq!(ids, ["dev", "pi", "shell"]);
        for profile in &cfg.profiles {
            for pane in profile.tabs.iter().flat_map(|t| t.panes.iter()) {
                if pane.agent.as_deref() == Some("pi") {
                    assert!(pane.focus, "profile {} leaves pi unfocused", profile.id);
                }
            }
        }
    }

    #[test]
    fn team_fixture_parses_seven_agents() {
        let cfg = parse_yaml(include_str!("../tests/fixtures/team.yaml")).expect("team yaml");
        assert_eq!(cfg.profiles.len(), 1);
        let agents: Vec<_> = cfg.profiles[0]
            .tabs
            .iter()
            .flat_map(|t| t.panes.iter())
            .filter_map(|p| p.agent.as_deref())
            .collect();
        assert_eq!(
            agents,
            [
                "leader",
                "frontend-builder",
                "background-builder",
                "reviewer",
                "research-left",
                "research-right",
                "qa",
            ]
        );
        let build = &cfg.profiles[0].tabs[2];
        assert_eq!(build.name, "build");
        assert_eq!(build.panes[0].kind.as_deref(), Some("codex"));
        assert_eq!(
            build.panes[0].args,
            vec!["-m", "gpt-5.6-luna", "-c", "model_reasoning_effort=high"]
        );
        assert_eq!(cfg.profiles[0].tabs[3].name, "review");
        assert_eq!(
            cfg.profiles[0].tabs[3].panes[0].agent.as_deref(),
            Some("reviewer")
        );
        let test = &cfg.profiles[0].tabs[5];
        assert_eq!(test.name, "test");
        assert_eq!(test.panes[0].agent.as_deref(), Some("qa"));
        assert_eq!(test.panes[0].name.as_deref(), Some("QA"));
        assert_eq!(
            test.panes[0].args,
            vec!["-m", "gpt-5.6-luna", "-c", "model_reasoning_effort=medium"]
        );
    }

    #[test]
    fn rejects_agent_without_kind() {
        let raw = r#"
profiles:
  - id: x
    name: X
    tabs:
      - name: main
        panes:
          - id: a
            agent: worker
"#;
        let err = parse_yaml(raw).unwrap_err();
        assert!(err.message.contains("kind"));
    }

    #[test]
    fn rejects_agent_and_command() {
        let raw = r#"
profiles:
  - id: x
    name: X
    tabs:
      - name: main
        panes:
          - id: a
            agent: worker
            kind: codex
            command: |
              echo hi
"#;
        let err = parse_yaml(raw).unwrap_err();
        assert!(err.message.contains("both agent and command"));
    }

    #[test]
    fn rejects_bad_agent_name() {
        let raw = r#"
profiles:
  - id: x
    name: X
    tabs:
      - name: main
        panes:
          - id: a
            agent: Worker
            kind: codex
"#;
        let err = parse_yaml(raw).unwrap_err();
        assert!(err.message.contains("must match"));
    }

    #[test]
    fn rejects_empty_profiles() {
        let err = parse_yaml("profiles: []").unwrap_err();
        assert!(err.message.contains("no profiles"));
    }

    #[test]
    fn rejects_unknown_split_from() {
        let raw = r#"
profiles:
  - id: x
    name: X
    tabs:
      - name: main
        panes:
          - id: a
          - id: b
            split_from: missing
            direction: right
"#;
        let err = parse_yaml(raw).unwrap_err();
        assert!(err.message.contains("split_from"));
    }

    #[test]
    fn rejects_bad_direction() {
        let raw = r#"
profiles:
  - id: x
    name: X
    tabs:
      - name: main
        panes:
          - id: a
          - id: b
            split_from: a
            direction: left
"#;
        let err = parse_yaml(raw).unwrap_err();
        assert!(err.message.contains("direction"));
    }

    #[test]
    fn rejects_focus_without_agent() {
        let raw = r#"
profiles:
  - id: x
    name: X
    tabs:
      - name: main
        panes:
          - id: a
          - id: b
            split_from: a
            direction: right
            focus: true
"#;
        let err = parse_yaml(raw).unwrap_err();
        assert!(
            err.message.contains("sets focus but has no agent"),
            "{}",
            err.message
        );
    }

    /// The accepted shape of the flag, on the pane every launcher uses it for.
    #[test]
    fn accepts_focus_on_an_agent_pane() {
        let raw = r#"
profiles:
  - id: x
    name: X
    tabs:
      - name: main
        panes:
          - id: fresh
          - id: pi
            split_from: fresh
            direction: right
            agent: pi
            kind: pi
            focus: true
"#;
        let cfg = parse_yaml(raw).expect("focus on an agent pane");
        assert!(cfg.profiles[0].tabs[0].panes[1].focus);
        assert!(!cfg.profiles[0].tabs[0].panes[0].focus);
    }

    #[test]
    fn multiline_command_trims_trailing_newline() {
        let raw = r#"
profiles:
  - id: x
    name: X
    tabs:
      - name: main
        panes:
          - id: a
            command: |
              printf 'hi'
"#;
        let cfg = parse_yaml(raw).unwrap();
        assert_eq!(
            cfg.profiles[0].tabs[0].panes[0].command.as_deref(),
            Some("printf 'hi'")
        );
    }

    #[test]
    fn team_style_args_keep_leading_dashes() {
        let raw = r#"
profiles:
  - id: team
    name: Team
    tabs:
      - name: build
        panes:
          - id: frontend
            agent: frontend-builder
            kind: codex
            args:
              - -m
              - gpt-5.6-luna
              - -c
              - model_reasoning_effort="high"
"#;
        let cfg = parse_yaml(raw).expect("team yaml");
        let pane = &cfg.profiles[0].tabs[0].panes[0];
        assert_eq!(
            pane.args,
            vec![
                "-m".to_string(),
                "gpt-5.6-luna".to_string(),
                "-c".to_string(),
                "model_reasoning_effort=\"high\"".to_string(),
            ]
        );
    }

    #[test]
    fn seed_and_load_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.yaml");
        seed_example(&path).unwrap();
        let cfg = load_from_path(&path).unwrap();
        assert!(!cfg.profiles.is_empty());
    }
}
