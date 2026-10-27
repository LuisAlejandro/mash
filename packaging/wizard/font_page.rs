//! Terminal font and colour theme. Font choices come from the Ghostty bundled
//! with Mash, so the list contains installed monospaced families that this
//! terminal can actually use. The theme switches every Mash component at once.
use crate::wizard_style;
use ratatui::{
    crossterm::event::{KeyCode, KeyModifiers},
    layout::{Constraint, Layout, Rect},
    style::Style,
    text::{Line, Span},
    widgets::Paragraph,
    Frame,
};
use std::{fs, path::Path, process::Command};

use crate::theme::Theme;

const DEFAULT_FONT: &str = "MesloLGS NF";
const MIN_SIZE: u8 = 6;
const MAX_SIZE: u8 = 72;
const THEME: u8 = 0;
const KEYBINDINGS: u8 = 1;
const LIST: u8 = 2;
const SIZE: u8 = 3;
const BACK: u8 = 4;
const NEXT: u8 = 5;
const FOCUS_COUNT: u8 = 6;

/// The first-launch shortcut preset. Both modes keep Mash's Herdr functions and
/// Ghostty's pass-through unbinds; they differ in whether Fresh's stock editing
/// keymap applies or Mash's Cursor-style chords override it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Keybindings {
    Mash,
    Native,
}

impl Keybindings {
    pub fn label(self) -> &'static str {
        match self {
            Self::Mash => "Mash / Cursor-style",
            Self::Native => "Native",
        }
    }

    fn value(self) -> &'static str {
        match self {
            Self::Mash => "mash",
            Self::Native => "native",
        }
    }

    fn other(self) -> Self {
        match self {
            Self::Mash => Self::Native,
            Self::Native => Self::Mash,
        }
    }

    /// A retried setup must reopen on the choice that was made before, and a
    /// first run -- no file yet -- starts on Cursor-style.
    pub fn current(root: &Path) -> Self {
        match fs::read_to_string(root.join("setup/keybindings-mode")) {
            Ok(text) if text.lines().any(|line| line == "mode=native") => Self::Native,
            _ => Self::Mash,
        }
    }
}

pub enum Decision {
    Back,
    Next,
    Cancel,
}

pub struct FontPage {
    fonts: Vec<String>,
    selected: usize,
    filter: String,
    size: u8,
    focus: u8,
    warning: Option<String>,
    pub theme: Theme,
    pub keybindings: Keybindings,
}

impl FontPage {
    pub fn new(resources: &Path, config: &Path) -> Self {
        let binary = if cfg!(target_os = "macos") {
            resources.join("Mash Terminal.app/Contents/MacOS/ghostty")
        } else {
            resources.join("bin/ghostty")
        };
        let (fonts, warning) = match Command::new(&binary).arg("+list-fonts").output() {
            Ok(output) if output.status.success() => (
                Self::parse_fonts(&String::from_utf8_lossy(&output.stdout)),
                None,
            ),
            _ => (
                vec![],
                Some("Could not list installed fonts; bundled Meslo is still available.".into()),
            ),
        };
        let mut page = Self::with_fonts(fonts, warning);
        if let Ok(current) = fs::read_to_string(config) {
            page.use_current(&current);
        }
        page
    }

    // A retried setup must start from existing user choices, not reset them.
    fn use_current(&mut self, config: &str) {
        let setting = |key| {
            config.lines().find_map(|line| {
                let (name, value) = line.split_once('=')?;
                (name.trim() == key).then_some(value.trim().trim_matches('"'))
            })
        };
        if let Some(index) = setting("font-family")
            .and_then(|name| self.fonts.iter().position(|family| family == name))
        {
            self.selected = index;
        }
        if let Some(size) = setting("font-size").and_then(|value| value.parse::<u8>().ok()) {
            if (MIN_SIZE..=MAX_SIZE).contains(&size) {
                self.size = size;
            }
        }
    }

    fn parse_fonts(output: &str) -> Vec<String> {
        output
            .lines()
            .filter(|line| !line.is_empty() && line.trim_start() == *line)
            .map(str::to_owned)
            .collect()
    }

    fn with_fonts(mut fonts: Vec<String>, warning: Option<String>) -> Self {
        if !fonts.iter().any(|family| family == DEFAULT_FONT) {
            fonts.push(DEFAULT_FONT.into());
        }
        fonts.sort_unstable();
        fonts.dedup();
        let selected = fonts
            .iter()
            .position(|family| family == DEFAULT_FONT)
            .unwrap();
        Self {
            fonts,
            selected,
            filter: String::new(),
            size: 13,
            focus: LIST,
            warning,
            theme: Theme::Dark,
            keybindings: Keybindings::Mash,
        }
    }

    fn matching(&self) -> Vec<usize> {
        let needle = self.filter.to_lowercase();
        self.fonts
            .iter()
            .enumerate()
            .filter(|(_, name)| name.to_lowercase().contains(&needle))
            .map(|(index, _)| index)
            .collect()
    }

    fn filter_changed(&mut self) {
        let matches = self.matching();
        if !matches.contains(&self.selected) && !matches.is_empty() {
            self.selected = matches[0];
        }
    }

    fn move_font(&mut self, direction: isize) {
        let matches = self.matching();
        if matches.is_empty() {
            return;
        }
        let current = matches
            .iter()
            .position(|index| *index == self.selected)
            .unwrap_or(0);
        let next = (current as isize + direction).clamp(0, matches.len() as isize - 1);
        self.selected = matches[next as usize];
    }

    fn resize(&mut self, direction: isize) {
        self.size =
            (self.size as isize + direction).clamp(MIN_SIZE as isize, MAX_SIZE as isize) as u8;
    }

    pub fn on_click(&mut self, id: usize) -> Option<Decision> {
        if id < self.fonts.len() {
            self.selected = id;
            self.focus = LIST;
        } else if id == self.fonts.len() {
            self.focus = SIZE;
            self.resize(-1);
        } else if id == self.fonts.len() + 1 {
            self.focus = SIZE;
            self.resize(1);
        } else if id == self.fonts.len() + 2 {
            self.focus = BACK;
            return Some(Decision::Back);
        } else if id == self.fonts.len() + 3 {
            self.focus = NEXT;
            return Some(Decision::Next);
        } else if id == self.fonts.len() + 4 || id == self.fonts.len() + 5 {
            self.focus = THEME;
            self.theme = if id == self.fonts.len() + 4 {
                Theme::Dark
            } else {
                Theme::Light
            };
        } else if id == self.fonts.len() + 6 {
            self.focus = LIST;
        } else if id == self.fonts.len() + 7 {
            self.focus = KEYBINDINGS;
            self.keybindings = Keybindings::Mash;
        } else if id == self.fonts.len() + 8 {
            self.focus = KEYBINDINGS;
            self.keybindings = Keybindings::Native;
        }
        None
    }

    pub fn on_key(&mut self, code: KeyCode, modifiers: KeyModifiers) -> Option<Decision> {
        if modifiers.contains(KeyModifiers::CONTROL) && code == KeyCode::Char('c') {
            return Some(Decision::Cancel);
        }
        match code {
            KeyCode::Esc => Some(Decision::Cancel),
            KeyCode::Tab => {
                self.focus =
                    wizard_style::focus_step(self.focus as usize, FOCUS_COUNT as usize, 1, true)
                        as u8;
                None
            }
            KeyCode::BackTab => {
                self.focus =
                    wizard_style::focus_step(self.focus as usize, FOCUS_COUNT as usize, -1, true)
                        as u8;
                None
            }
            KeyCode::Up | KeyCode::Down if self.focus == LIST => {
                self.move_font(if code == KeyCode::Down { 1 } else { -1 });
                None
            }
            KeyCode::Up => {
                self.focus =
                    wizard_style::focus_step(self.focus as usize, FOCUS_COUNT as usize, -1, false)
                        as u8;
                None
            }
            KeyCode::Down => {
                self.focus =
                    wizard_style::focus_step(self.focus as usize, FOCUS_COUNT as usize, 1, false)
                        as u8;
                None
            }
            KeyCode::Left | KeyCode::Right | KeyCode::Char(' ') if self.focus == KEYBINDINGS => {
                self.keybindings = self.keybindings.other();
                None
            }
            KeyCode::Left | KeyCode::Right | KeyCode::Char(' ') if self.focus == THEME => {
                self.theme = self.theme.other();
                None
            }
            KeyCode::Left | KeyCode::Char('-') if self.focus == SIZE => {
                self.resize(-1);
                None
            }
            KeyCode::Right | KeyCode::Char('+') if self.focus == SIZE => {
                self.resize(1);
                None
            }
            KeyCode::Backspace if self.focus == LIST => {
                self.filter.pop();
                self.filter_changed();
                None
            }
            KeyCode::Char(c)
                if self.focus == LIST && !modifiers.contains(KeyModifiers::CONTROL) =>
            {
                self.filter.push(c);
                self.filter_changed();
                None
            }
            KeyCode::Enter | KeyCode::Char(' ') => match self.focus {
                THEME => {
                    self.focus = KEYBINDINGS;
                    None
                }
                KEYBINDINGS => {
                    self.keybindings = self.keybindings.other();
                    None
                }
                LIST => {
                    self.focus = SIZE;
                    None
                }
                SIZE => {
                    self.focus = NEXT;
                    None
                }
                BACK => Some(Decision::Back),
                _ => Some(Decision::Next),
            },
            _ => None,
        }
    }

    /// Written with the rest of the setup, so a cancelled or failed run leaves
    /// no mode behind and the next launch seeds the Cursor-style defaults.
    pub fn save_mode(&self, root: &Path) -> Result<(), String> {
        crate::provider_page::write_private(
            &root.join("setup/keybindings-mode"),
            &format!("mode={}\n", self.keybindings.value()),
        )
    }

    pub fn save(&self, config: &Path) -> Result<(), String> {
        // Follow a user-provided symlink instead of replacing it with a file.
        let config = fs::canonicalize(config).map_err(|e| format!("{}: {e}", config.display()))?;
        let old = fs::read_to_string(&config).map_err(|e| e.to_string())?;
        let family = format!(
            "font-family = \"{}\"",
            self.fonts[self.selected]
                .replace('\\', "\\\\")
                .replace('"', "\\\"")
        );
        let size = format!("font-size = {}", self.size);
        let mut found = [false; 2];
        let mut updated = String::with_capacity(old.len());
        for line in old.lines() {
            let replacement = match line.split_once('=').map(|(key, _)| key.trim()) {
                Some("font-family") if !found[0] => {
                    found[0] = true;
                    &family
                }
                Some("font-size") if !found[1] => {
                    found[1] = true;
                    &size
                }
                _ => line,
            };
            updated.push_str(replacement);
            updated.push('\n');
        }
        if !found[0] {
            updated.push_str(&family);
            updated.push('\n');
        }
        if !found[1] {
            updated.push_str(&size);
            updated.push('\n');
        }
        // Write beside the config, then rename; failed writes must not truncate
        // a user's existing Ghostty settings.
        let temp = config.with_extension(format!("tmp-{}", std::process::id()));
        fs::write(&temp, updated).map_err(|e| e.to_string())?;
        fs::set_permissions(
            &temp,
            fs::metadata(&config)
                .map_err(|e| e.to_string())?
                .permissions(),
        )
        .map_err(|e| e.to_string())?;
        fs::rename(&temp, config).map_err(|e| e.to_string())
    }

    pub fn draw(&self, frame: &mut Frame) {
        let parts = Layout::vertical([
            Constraint::Length(3),
            Constraint::Length(3),
            Constraint::Length(4),
            Constraint::Length(3),
            Constraint::Min(3),
            Constraint::Length(3),
            Constraint::Length(3),
        ])
        .split(wizard_style::page_area(frame, Some(3)));
        wizard_style::header(frame, parts[0], "Appearance — page 4/5");
        self.draw_theme(frame, parts[1]);
        self.draw_keybindings(frame, parts[2]);
        let parts = &parts[2..];
        let hint = wizard_style::section(frame, parts[1], "Fonts on this computer");
        let mut filter =
            wizard_style::text_field(self.focus == LIST, "Filter fonts", self.filter.clone());
        filter.spans.push(Span::styled(
            "   ↑/↓ fonts · Tab to size",
            Style::default().fg(wizard_style::MUTED),
        ));
        wizard_style::render_form(
            frame,
            hint,
            vec![(filter, Some(self.fonts.len() + 6))],
            false,
        );
        self.draw_fonts(frame, parts[2]);
        self.draw_size(frame, parts[3]);

        wizard_style::render_buttons(
            frame,
            parts[4],
            &[
                (
                    wizard_style::button(self.focus == BACK, " Back "),
                    Some(self.fonts.len() + 2),
                ),
                (Span::raw("  "), None),
                (
                    wizard_style::button(self.focus == NEXT, " Continue to dictation "),
                    Some(self.fonts.len() + 3),
                ),
            ],
        );
    }

    fn draw_fonts(&self, frame: &mut Frame, area: Rect) {
        let body = wizard_style::section(frame, area, "Font family (Meslo is bundled)");
        let matches = self.matching();
        let count = body
            .height
            .saturating_sub(u16::from(self.warning.is_some())) as usize;
        let cursor = matches
            .iter()
            .position(|index| *index == self.selected)
            .unwrap_or(0);
        let start = cursor
            .saturating_sub(count.saturating_sub(1))
            .min(matches.len().saturating_sub(count));
        let mut lines = Vec::new();
        for (row, &index) in matches.iter().skip(start).take(count).enumerate() {
            let name = &self.fonts[index];
            let focused = self.focus == LIST && self.selected == index;
            let row_area = Rect::new(body.x, body.y + row as u16, body.width, 1);
            if focused {
                wizard_style::highlight(frame, row_area);
            }
            lines.push(Line::styled(
                format!("{} {name}", if self.selected == index { "●" } else { " " }),
                if focused {
                    wizard_style::selected()
                } else {
                    Style::default()
                },
            ));
            wizard_style::target(row_area, index);
        }
        if lines.is_empty() {
            lines.push(Line::styled(
                "No matching fonts — Backspace to broaden the search",
                Style::default().fg(wizard_style::RED),
            ));
        }
        frame.render_widget(Paragraph::new(lines), body);
        if let Some(warning) = &self.warning {
            let row = Rect::new(body.x, body.bottom().saturating_sub(1), body.width, 1);
            frame.render_widget(
                Paragraph::new(warning.as_str()).style(Style::default().fg(wizard_style::RED)),
                row,
            );
        }
    }

    fn draw_keybindings(&self, frame: &mut Frame, area: Rect) {
        let body =
            wizard_style::section(frame, area, "Keybindings (permanent once setup completes)");
        let mut x = body.x + 2;
        let mut spans = vec![Span::raw("  ")];
        for (index, mode) in [Keybindings::Mash, Keybindings::Native]
            .into_iter()
            .enumerate()
        {
            let label = format!(
                "({}) {}",
                if self.keybindings == mode { "*" } else { " " },
                mode.label()
            );
            let width = label.chars().count() as u16;
            wizard_style::target(Rect::new(x, body.y, width, 1), self.fonts.len() + 7 + index);
            x += width + 4;
            let style = if self.focus == KEYBINDINGS && self.keybindings == mode {
                wizard_style::selected()
            } else {
                Style::default()
            };
            spans.push(Span::styled(label, style));
            spans.push(Span::raw("    "));
        }
        spans.push(Span::styled(
            "←/→",
            Style::default().fg(wizard_style::MUTED),
        ));
        frame.render_widget(Paragraph::new(Line::from(spans)), body);
        let note = Rect::new(body.x + 2, body.y + 1, body.width.saturating_sub(2), 1);
        frame.render_widget(
            Paragraph::new("Cursor's chords, or each app's own keys.")
                .style(Style::default().fg(wizard_style::MUTED)),
            note,
        );
    }

    fn draw_theme(&self, frame: &mut Frame, area: Rect) {
        let body = wizard_style::section(frame, area, "Theme (Herdr, Ghostty, Fresh, Pi, reviewr)");
        let mut x = body.x + 2;
        let mut spans = vec![Span::raw("  ")];
        for (index, theme) in [Theme::Dark, Theme::Light].into_iter().enumerate() {
            let label = format!(
                "({}) {}",
                if self.theme == theme { "*" } else { " " },
                theme.label()
            );
            let width = label.chars().count() as u16;
            wizard_style::target(Rect::new(x, body.y, width, 1), self.fonts.len() + 4 + index);
            x += width + 4;
            let style = if self.focus == THEME && self.theme == theme {
                wizard_style::selected()
            } else {
                Style::default()
            };
            spans.push(Span::styled(label, style));
            spans.push(Span::raw("    "));
        }
        spans.push(Span::styled(
            "←/→ switch",
            Style::default().fg(wizard_style::MUTED),
        ));
        frame.render_widget(Paragraph::new(Line::from(spans)), body);
    }

    fn draw_size(&self, frame: &mut Frame, area: Rect) {
        let body = wizard_style::section(frame, area, "Font size (points)");
        let controls = format!("  [-]  {:>2}  [+]   ←/→ adjust (6–72)", self.size);
        wizard_style::target(Rect::new(body.x + 2, body.y, 3, 1), self.fonts.len());
        wizard_style::target(
            Rect::new(body.x + controls.find("[+]").unwrap() as u16, body.y, 3, 1),
            self.fonts.len() + 1,
        );
        frame.render_widget(
            Paragraph::new(controls).style(if self.focus == SIZE {
                wizard_style::selected()
            } else {
                Style::default()
            }),
            body,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::{backend::TestBackend, Terminal};

    #[test]
    fn lists_only_font_families_and_selects_meslo_at_size_thirteen() {
        let fonts = FontPage::parse_fonts(
            "JetBrains Mono\n  JetBrains Mono Bold\n\nMesloLGS NF\n  MesloLGS NF Regular\n\n",
        );
        assert_eq!(fonts, ["JetBrains Mono", "MesloLGS NF"]);
        let mut page = FontPage::with_fonts(fonts, None);
        assert_eq!(page.fonts[page.selected], DEFAULT_FONT);
        assert_eq!(page.size, 13);
        page.use_current("font-family = \"JetBrains Mono\"\nfont-size = 17\n");
        assert_eq!(page.fonts[page.selected], "JetBrains Mono");
        assert_eq!(page.size, 17);
    }

    #[test]
    fn both_shipped_configs_default_to_thirteen() {
        for config in [
            include_str!("../defaults/ghostty/config"),
            include_str!("../defaults/ghostty/config.linux"),
        ] {
            assert!(config.lines().any(|line| line == "font-size = 13"));
        }
    }

    #[test]
    fn filtering_and_size_pick_preserve_the_rest_of_ghostty_config() {
        let mut page = FontPage::with_fonts(vec!["JetBrains Mono".into()], None);
        for c in "jet".chars() {
            page.on_key(KeyCode::Char(c), KeyModifiers::NONE);
        }
        assert_eq!(page.fonts[page.selected], "JetBrains Mono");
        page.focus = SIZE;
        page.on_key(KeyCode::Right, KeyModifiers::NONE);
        assert_eq!(page.size, 14);
        let path = std::env::temp_dir().join(format!("mash-font-test-{}", std::process::id()));
        fs::write(&path, "command = /opt/letsmash/bin/herdr-pane\nfont-family = \"MesloLGS NF\"\nfont-size = 14\nauto-update = off\n").unwrap();
        page.save(&path).unwrap();
        let saved = fs::read_to_string(&path).unwrap();
        assert!(saved.contains("font-family = \"JetBrains Mono\"\nfont-size = 14"));
        assert!(saved.contains("command = /opt/letsmash/bin/herdr-pane\n"));
        assert!(saved.contains("auto-update = off\n"));
        fs::remove_file(&path).unwrap();
    }

    #[test]
    fn font_rows_and_size_controls_are_clickable() {
        let mut page = FontPage::with_fonts(vec!["JetBrains Mono".into()], None);
        let mut terminal = Terminal::new(TestBackend::new(80, 28)).unwrap();
        terminal.draw(|frame| page.draw(frame)).unwrap();
        let buffer = terminal.backend().buffer();
        wizard_style::tests::find(buffer, "Appearance — page 4/5");
        wizard_style::tests::find(buffer, "13");
        let (x, y) = wizard_style::tests::find(buffer, "Filter fonts");
        page.focus = SIZE;
        page.on_click(wizard_style::clicked(&wizard_style::tests::click(x, y)).unwrap());
        assert_eq!(page.focus, LIST);
        page.on_key(KeyCode::Char('j'), KeyModifiers::NONE);
        assert_eq!(page.filter, "j");
        let (x, y) = wizard_style::tests::find(buffer, "JetBrains Mono");
        assert_eq!(
            wizard_style::clicked(&wizard_style::tests::click(x, y)),
            Some(0)
        );
        page.on_click(0);
        let (x, y) = wizard_style::tests::find(buffer, "[+]");
        page.on_click(wizard_style::clicked(&wizard_style::tests::click(x, y)).unwrap());
        assert_eq!(page.size, 14);
        let (x, y) = wizard_style::tests::find(buffer, "Light");
        page.on_click(wizard_style::clicked(&wizard_style::tests::click(x, y)).unwrap());
        assert_eq!(page.theme, Theme::Light);
        page.focus = THEME;
        page.on_key(KeyCode::Left, KeyModifiers::NONE);
        assert_eq!(page.theme, Theme::Dark);
    }

    #[test]
    fn keybinding_mode_defaults_to_mash_and_changes_by_keyboard_and_click() {
        let mut page = FontPage::with_fonts(vec!["JetBrains Mono".into()], None);
        assert_eq!(page.keybindings, Keybindings::Mash);
        let mut terminal = Terminal::new(TestBackend::new(80, 28)).unwrap();
        terminal.draw(|frame| page.draw(frame)).unwrap();
        let buffer = terminal.backend().buffer();
        wizard_style::tests::find(buffer, "Mash / Cursor-style");
        wizard_style::tests::find(buffer, "permanent");
        let (x, y) = wizard_style::tests::find(buffer, "Native");
        page.on_click(wizard_style::clicked(&wizard_style::tests::click(x, y)).unwrap());
        assert_eq!(page.keybindings, Keybindings::Native);
        page.focus = KEYBINDINGS;
        page.on_key(KeyCode::Left, KeyModifiers::NONE);
        assert_eq!(page.keybindings, Keybindings::Mash);
    }

    #[test]
    fn mode_is_absent_until_written_and_a_retry_reads_it_back() {
        let dir = std::env::temp_dir().join(format!("mash-mode-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let mut page = FontPage::with_fonts(vec!["JetBrains Mono".into()], None);
        assert_eq!(Keybindings::current(&dir), Keybindings::Mash);
        page.keybindings = Keybindings::Native;
        page.save_mode(&dir).unwrap();
        assert_eq!(Keybindings::current(&dir), Keybindings::Native);
        assert_eq!(
            fs::read_to_string(dir.join("setup/keybindings-mode")).unwrap(),
            "mode=native\n"
        );
        let _ = fs::remove_dir_all(&dir);
    }
}
