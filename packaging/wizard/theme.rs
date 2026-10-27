//! Mash's two colour themes. Dark is what every component ships with; Light is
//! a Mash-owned light Monokai built for this switch.
//!
//! Applying a theme swaps exact shipped lines in each seeded config. A line the
//! user has changed no longer matches either side, so it is left alone, and
//! switching back restores the shipped dark values the same way.
use std::{fs, path::Path};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Theme {
    Dark,
    Light,
}

/// (config path under ~/.mash, dark line, light line). Dark lines are the
/// shipped defaults; tests keep them in step with packaging/defaults.
const SWAPS: &[(&str, &str, &str)] = &[
    (
        "config/ghostty/config",
        "theme = Monokai Cursor",
        "theme = Monokai Cursor Light",
    ),
    (
        "config/fresh/config.json",
        r#"  "theme": "https://github.com/lucasoskorep/fresh-monokai#monokai","#,
        r#"  "theme": "https://github.com/lucasoskorep/fresh-monokai#monokai-light","#,
    ),
    (
        "pi/agent/settings.json",
        r#"  "theme": "Monokai Pro (CE)","#,
        r#"  "theme": "Mash Light","#,
    ),
    (
        "config/herdr/plugins/config/persiyanov.reviewr/config.toml",
        r#"theme = "monokai""#,
        r#"theme = "one-light""#,
    ),
    // Herdr's palette is spelled out in [theme.custom].
    (
        "config/herdr/config.toml",
        r##"sidebar_bg = "#1e1f1c""##,
        r##"sidebar_bg = "#f0efe8""##,
    ),
    (
        "config/herdr/config.toml",
        r##"panel_bg = "#1e1f1c""##,
        r##"panel_bg = "#f0efe8""##,
    ),
    (
        "config/herdr/config.toml",
        r##"surface_dim = "#1e1f1c""##,
        r##"surface_dim = "#f0efe8""##,
    ),
    (
        "config/herdr/config.toml",
        r##"accent = "#cccccc""##,
        r##"accent = "#3e3d32""##,
    ),
    (
        "config/herdr/config.toml",
        r##"surface0 = "#34352f""##,
        r##"surface0 = "#e2e1d8""##,
    ),
    (
        "config/herdr/config.toml",
        r##"text = "#d6d6d4""##,
        r##"text = "#272822""##,
    ),
    (
        "config/herdr/config.toml",
        r##"subtext0 = "#ffffff""##,
        r##"subtext0 = "#000000""##,
    ),
    (
        "config/herdr/config.toml",
        r##"mauve = "#e6db74""##,
        r##"mauve = "#8a6400""##,
    ),
    (
        "config/herdr/config.toml",
        r##"overlay0 = "#999999""##,
        r##"overlay0 = "#6b6756""##,
    ),
    (
        "config/herdr/config.toml",
        r##"overlay1 = "#cccccc""##,
        r##"overlay1 = "#3e3d32""##,
    ),
    (
        "config/herdr/config.toml",
        r##"active_row_bg = "#333333""##,
        r##"active_row_bg = "#e6e4d6""##,
    ),
    (
        "config/lazydocker/config.yml",
        r##"      - "#5fd7ff""##,
        r##"      - "#00799a""##,
    ),
    (
        "config/lazydocker/config.yml",
        r##"      - "#5c6370""##,
        r##"      - "#b8b5a6""##,
    ),
    (
        "config/lazydocker/config.yml",
        r##"      - "#243d2f""##,
        r##"      - "#e6e4d6""##,
    ),
    (
        "config/lazydocker/config.yml",
        r##"      - "#61afef""##,
        r##"      - "#2c6fb0""##,
    ),
];

impl Theme {
    pub fn label(self) -> &'static str {
        match self {
            Theme::Dark => "Dark theme",
            Theme::Light => "Light theme",
        }
    }

    pub fn other(self) -> Self {
        match self {
            Theme::Dark => Theme::Light,
            Theme::Light => Theme::Dark,
        }
    }

    /// The theme the seeded Ghostty config currently names; a retried setup
    /// starts from it.
    pub fn current(root: &Path) -> Self {
        let light = SWAPS[0].2;
        match fs::read_to_string(root.join(SWAPS[0].0)) {
            Ok(text) if text.lines().any(|line| line == light) => Theme::Light,
            _ => Theme::Dark,
        }
    }

    /// Rewrite each seeded config under `root` (~/.mash). Missing files are
    /// skipped: a component that was never seeded has nothing to switch.
    pub fn apply(self, root: &Path) -> Result<(), String> {
        let mut paths: Vec<&str> = SWAPS.iter().map(|swap| swap.0).collect();
        paths.dedup();
        for relative in paths {
            let path = root.join(relative);
            let Ok(path) = fs::canonicalize(&path) else {
                continue;
            };
            let text = fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
            let mut changed = false;
            let lines: Vec<&str> = text
                .lines()
                .map(|line| {
                    for (file, dark, light) in SWAPS {
                        let (from, to) = match self {
                            Theme::Dark => (light, dark),
                            Theme::Light => (dark, light),
                        };
                        if *file == relative && line == *from {
                            changed = true;
                            return *to;
                        }
                    }
                    line
                })
                .collect();
            if changed {
                let mut updated = lines.join("\n");
                if text.ends_with('\n') {
                    updated.push('\n');
                }
                // Replace via rename so a failed write never truncates a config.
                let temp = path.with_extension(format!("tmp-{}", std::process::id()));
                fs::write(&temp, updated).map_err(|e| e.to_string())?;
                let permissions = fs::metadata(&path)
                    .map_err(|e| e.to_string())?
                    .permissions();
                fs::set_permissions(&temp, permissions).map_err(|e| e.to_string())?;
                fs::rename(&temp, &path).map_err(|e| e.to_string())?;
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Shipped config each swap path is seeded from (macOS variants).
    fn shipped(relative: &str) -> &'static str {
        match relative {
            "config/ghostty/config" => include_str!("../defaults/ghostty/config"),
            "config/fresh/config.json" => include_str!("../defaults/fresh/config.json"),
            "pi/agent/settings.json" => include_str!("../defaults/pi/settings.json"),
            "config/herdr/plugins/config/persiyanov.reviewr/config.toml" => {
                include_str!("../defaults/plugins/persiyanov.reviewr/config.toml")
            }
            "config/herdr/config.toml" => include_str!("../defaults/herdr/config.toml"),
            "config/lazydocker/config.yml" => include_str!("../defaults/lazydocker/config.yml"),
            other => panic!("no shipped file for {other}"),
        }
    }

    #[test]
    fn every_dark_line_is_a_shipped_line_exactly_once() {
        let linux = [
            (
                "config/ghostty/config",
                include_str!("../defaults/ghostty/config.linux"),
            ),
            (
                "config/fresh/config.json",
                include_str!("../defaults/fresh/config.linux.json"),
            ),
            (
                "config/herdr/config.toml",
                include_str!("../defaults/herdr/config.linux.toml"),
            ),
        ];
        for (relative, dark, _) in SWAPS {
            let count = shipped(relative)
                .lines()
                .filter(|line| line == dark)
                .count();
            assert_eq!(count, 1, "{relative}: {dark:?} must appear once");
            if let Some((_, text)) = linux.iter().find(|(path, _)| path == relative) {
                let count = text.lines().filter(|line| line == dark).count();
                assert_eq!(count, 1, "{relative} (linux): {dark:?} must appear once");
            }
        }
    }

    #[test]
    fn light_lines_are_distinct_so_switching_back_is_unambiguous() {
        for (index, (file, _, light)) in SWAPS.iter().enumerate() {
            for (other, _, other_light) in &SWAPS[index + 1..] {
                assert!(
                    !(file == other && light == other_light),
                    "{file}: {light:?} used twice"
                );
            }
        }
    }

    #[test]
    fn light_assets_exist_and_name_what_the_swaps_select() {
        assert!(
            include_str!("../defaults/ghostty/themes/Monokai Cursor Light")
                .contains("background = #fafaf7")
        );
        let fresh: serde_json::Value = serde_json::from_str(include_str!(
            "../defaults/fresh/themes/packages/monokai/package.json"
        ))
        .unwrap();
        assert!(fresh["fresh"]["themes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|theme| theme["name"] == "Monokai Light"));
        // Fresh keys a packaged theme as `repository#name`, lowercased with
        // spaces turned into dashes (fresh-editor-core theme/loader.rs).
        let repository = fresh["repository"].as_str().unwrap();
        for (_, dark, light) in SWAPS.iter().filter(|s| s.0 == "config/fresh/config.json") {
            for line in [dark, light] {
                let key = line.split('"').nth(3).unwrap();
                let name = key.strip_prefix(&format!("{repository}#")).unwrap();
                assert!(
                    fresh["fresh"]["themes"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .any(|theme| {
                            theme["name"]
                                .as_str()
                                .unwrap()
                                .to_lowercase()
                                .replace([' ', '_'], "-")
                                == name
                        }),
                    "{key} names no packaged Fresh theme"
                );
            }
        }
        let pi: serde_json::Value =
            serde_json::from_str(include_str!("../defaults/pi/themes/mash-light.json")).unwrap();
        assert_eq!(pi["name"], "Mash Light");
    }

    #[test]
    fn switching_round_trips_and_keeps_user_edits() {
        let root = std::env::temp_dir().join(format!("mash-theme-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let mut seen = Vec::new();
        for (relative, _, _) in SWAPS {
            if seen.contains(relative) {
                continue;
            }
            seen.push(*relative);
            let path = root.join(relative);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, shipped(relative)).unwrap();
        }
        // A user's own Herdr accent must survive both directions.
        let herdr = root.join("config/herdr/config.toml");
        let edited = fs::read_to_string(&herdr)
            .unwrap()
            .replace(r##"accent = "#cccccc""##, r##"accent = "#ff00ff""##);
        fs::write(&herdr, &edited).unwrap();

        Theme::Light.apply(&root).unwrap();
        assert_eq!(Theme::current(&root), Theme::Light);
        let ghostty = fs::read_to_string(root.join("config/ghostty/config")).unwrap();
        assert!(ghostty.lines().any(|l| l == "theme = Monokai Cursor Light"));
        let herdr_light = fs::read_to_string(&herdr).unwrap();
        assert!(herdr_light.contains(r##"panel_bg = "#f0efe8""##));
        assert!(herdr_light.contains(r##"accent = "#ff00ff""##));
        let pi = fs::read_to_string(root.join("pi/agent/settings.json")).unwrap();
        serde_json::from_str::<serde_json::Value>(&pi).expect("settings stay valid JSON");

        Theme::Dark.apply(&root).unwrap();
        assert_eq!(Theme::current(&root), Theme::Dark);
        assert_eq!(fs::read_to_string(&herdr).unwrap(), edited);
        for relative in seen {
            if relative != "config/herdr/config.toml" {
                assert_eq!(
                    fs::read_to_string(root.join(relative)).unwrap(),
                    shipped(relative)
                );
            }
        }
        fs::remove_dir_all(root).unwrap();
    }
}
