//! Terminal font and colour theme. Font choices come from the Ghostty bundled
//! with Mash, so the list contains installed monospaced families that this
//! terminal can actually use. The theme switches every Mash component at once.
use crate::{i18n, wizard_style};
use ratatui::{
    crossterm::event::{KeyCode, KeyModifiers},
    layout::{Constraint, Layout, Rect},
    style::Style,
    text::{Line, Span},
    widgets::Paragraph,
    Frame,
};
use std::{
    cell::Cell,
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

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
/// Holding an arrow key would otherwise reload the terminal on every repeat.
const PREVIEW_DELAY: Duration = Duration::from_millis(150);

/// Shows the chosen font and theme in the wizard's own window while the page
/// is open.
///
/// The wizard runs straight inside Mash's terminal, which names itself in
/// MASH_TERMINAL_PID and reloads its config on SIGUSR2; a reload applies a new
/// font-size to open windows unless that window was zoomed by hand, and always
/// applies a new theme. Each preview rewrites only the font lines and a shipped
/// `theme =` line of the original file. Unless setup
/// saves the choice, the original is put back when the page goes away, so a
/// quit or failed setup leaves the config exactly as it was.
struct LivePreview {
    config: PathBuf,
    original: String,
    terminal: u32,
    /// The (family, size, theme) the terminal is showing now.
    applied: (usize, u8, Theme),
    initial: (usize, u8, Theme),
    changed_at: Option<Instant>,
    delay: Duration,
    committed: Cell<bool>,
}

impl LivePreview {
    fn reload(&self) {
        // Ask exactly the terminal that owns this window; nothing else reloads.
        let _ = Command::new("kill")
            .arg("-USR2")
            .arg(self.terminal.to_string())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}

/// The first-launch shortcut preset. Cursor-style is Mash's own keymap across
/// Herdr, Mash Terminal, Fresh and Pi. Native leaves every one of them on its own
/// stock keys -- Herdr on its Ctrl+B prefix, with Mash's extra commands on free
/// prefix keys -- and mash-seed-sync renders each config for the chosen mode.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Keybindings {
    Mash,
    Native,
}

impl Keybindings {
    pub fn label(self) -> String {
        match self {
            Self::Mash => i18n::t("wizard.font.keybindings.mash"),
            Self::Native => i18n::t("wizard.font.keybindings.native"),
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
    /// The terminal could not list its fonts, so only the default is offered.
    no_font_list: bool,
    pub theme: Theme,
    pub keybindings: Keybindings,
    live: Option<LivePreview>,
}

impl Drop for FontPage {
    fn drop(&mut self) {
        if let Some(live) = &self.live {
            if !live.committed.get() && live.applied != live.initial {
                let _ = write_config(&live.config, &live.original);
                live.reload();
            }
        }
    }
}

impl FontPage {
    pub fn new(resources: &Path, config: &Path) -> Self {
        let binary = if cfg!(target_os = "macos") {
            resources.join("../MacOS/mash-terminal")
        } else {
            resources.join("bin/mash-terminal")
        };
        let (fonts, no_font_list) = match Command::new(&binary).arg("+list-fonts").output() {
            Ok(output) if output.status.success() => (
                Self::parse_fonts(&String::from_utf8_lossy(&output.stdout)),
                false,
            ),
            _ => (vec![], true),
        };
        let mut page = Self::with_fonts(fonts, no_font_list);
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

    fn with_fonts(mut fonts: Vec<String>, no_font_list: bool) -> Self {
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
            size: if cfg!(target_os = "linux") { 10 } else { 13 },
            focus: LIST,
            no_font_list,
            theme: Theme::Dark,
            keybindings: Keybindings::Mash,
            live: None,
        }
    }

    /// Preview font changes in the window whose terminal is `terminal`. Off
    /// in `--preview`, which must not write anything, and when there is no
    /// config to preview through.
    pub fn start_live_preview(&mut self, config: &Path, terminal: u32) {
        let Ok(config) = fs::canonicalize(config) else {
            return;
        };
        let Ok(original) = fs::read_to_string(&config) else {
            return;
        };
        if terminal <= 1 {
            return;
        }
        let current = self.choice();
        self.live = Some(LivePreview {
            config,
            original,
            terminal,
            applied: current,
            initial: current,
            changed_at: None,
            delay: PREVIEW_DELAY,
            committed: Cell::new(false),
        });
    }

    fn choice(&self) -> (usize, u8, Theme) {
        (self.selected, self.size, self.theme)
    }

    /// Put the seeded bytes back before keybinding reconciliation, which would
    /// otherwise keep a previewed file as a user edit. `save` then layers the
    /// choice over the reconciled file, and nothing later restores the old one.
    pub fn retire_live_preview(&mut self) -> Result<(), String> {
        // Keep `live` on a failed restore: Drop retries it, and discarding the
        // original bytes here would leave the preview looking like a user edit.
        if let Some(live) = self.live.as_ref() {
            if live.applied != live.initial {
                write_config(&live.config, &live.original)?;
            }
        }
        self.live = None;
        Ok(())
    }

    /// True while a change waits out the delay, so the caller keeps polling.
    pub fn live_preview_pending(&self) -> bool {
        self.live
            .as_ref()
            .is_some_and(|live| live.changed_at.is_some())
    }

    /// Apply a change once it has settled.
    pub fn poll_live_preview(&mut self) {
        let choice = self.choice();
        let Some(live) = &self.live else {
            return;
        };
        let Some(changed_at) = live.changed_at else {
            return;
        };
        if changed_at.elapsed() < live.delay {
            return;
        }
        let content = self.render(&live.original);
        let config = live.config.clone();
        let live = self.live.as_mut().expect("checked above");
        live.changed_at = None;
        if choice == live.applied {
            return;
        }
        if write_config(&config, &content).is_ok() {
            live.applied = choice;
            live.reload();
        }
    }

    fn touched(&mut self, before: (usize, u8, Theme)) {
        if self.choice() != before {
            if let Some(live) = &mut self.live {
                live.changed_at = Some(Instant::now());
            }
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
        let before = self.choice();
        let decision = self.click(id);
        self.touched(before);
        decision
    }

    fn click(&mut self, id: usize) -> Option<Decision> {
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
        let before = self.choice();
        let decision = self.key(code, modifiers);
        self.touched(before);
        decision
    }

    fn key(&mut self, code: KeyCode, modifiers: KeyModifiers) -> Option<Decision> {
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
        write_config(&config, &self.render(&old))?;
        // The choice is now the user's setting; the preview must not undo it.
        if let Some(live) = &self.live {
            live.committed.set(true);
        }
        Ok(())
    }

    /// `old` with its font lines set to this page's choice; the rest untouched.
    fn render(&self, old: &str) -> String {
        let family = format!(
            "font-family = \"{}\"",
            self.fonts[self.selected]
                .replace('\\', "\\\\")
                .replace('"', "\\\"")
        );
        let size = format!("font-size = {}", self.size);
        let theme = self.theme.terminal_line();
        let mut found = [false; 2];
        let mut updated = String::with_capacity(old.len());
        for line in old.lines() {
            // Only Mash's own shipped theme lines switch; a theme the user
            // chose by hand is theirs to keep.
            if line == Theme::Dark.terminal_line() || line == Theme::Light.terminal_line() {
                updated.push_str(theme);
                updated.push('\n');
                continue;
            }
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
        updated
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
        .split(wizard_style::page_area(frame, Some(5)));
        wizard_style::header(
            frame,
            parts[0],
            &wizard_style::page_title(&i18n::t("wizard.font.title"), 5),
        );
        self.draw_theme(frame, parts[1]);
        self.draw_keybindings(frame, parts[2]);
        let parts = &parts[2..];
        let hint = wizard_style::section(frame, parts[1], &i18n::t("wizard.font.fonts_section"));
        let mut filter = wizard_style::text_field(
            self.focus == LIST,
            &i18n::t("wizard.font.filter"),
            self.filter.clone(),
        );
        filter.spans.push(Span::styled(
            format!("   {}", i18n::t("wizard.font.filter_hint")),
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
                    wizard_style::button(
                        self.focus == BACK,
                        &format!(" {} ", i18n::t("wizard.font.back")),
                    ),
                    Some(self.fonts.len() + 2),
                ),
                (Span::raw("  "), None),
                (
                    wizard_style::button(
                        self.focus == NEXT,
                        &format!(" {} ", i18n::t("wizard.font.next")),
                    ),
                    Some(self.fonts.len() + 3),
                ),
            ],
        );
    }

    fn draw_fonts(&self, frame: &mut Frame, area: Rect) {
        let body = wizard_style::section(frame, area, &i18n::t("wizard.font.family_section"));
        let matches = self.matching();
        let count = body.height.saturating_sub(u16::from(self.no_font_list)) as usize;
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
                i18n::t("wizard.font.no_fonts"),
                Style::default().fg(wizard_style::RED),
            ));
        }
        frame.render_widget(Paragraph::new(lines), body);
        if self.no_font_list {
            let row = Rect::new(body.x, body.bottom().saturating_sub(1), body.width, 1);
            frame.render_widget(
                Paragraph::new(i18n::t("wizard.font.warning_no_list"))
                    .style(Style::default().fg(wizard_style::RED)),
                row,
            );
        }
    }

    fn draw_keybindings(&self, frame: &mut Frame, area: Rect) {
        let body = wizard_style::section(frame, area, &i18n::t("wizard.font.keybindings_section"));
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
            Paragraph::new(i18n::t("wizard.font.keybindings_note"))
                .style(Style::default().fg(wizard_style::MUTED)),
            note,
        );
    }

    fn draw_theme(&self, frame: &mut Frame, area: Rect) {
        let body = wizard_style::section(frame, area, &i18n::t("wizard.font.theme_section"));
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
            i18n::t("wizard.font.theme_switch"),
            Style::default().fg(wizard_style::MUTED),
        ));
        frame.render_widget(Paragraph::new(Line::from(spans)), body);
    }

    fn draw_size(&self, frame: &mut Frame, area: Rect) {
        let body = wizard_style::section(frame, area, &i18n::t("wizard.font.size_section"));
        let controls = format!(
            "  [-]  {:>2}  [+]   {}{}",
            self.size,
            i18n::t("wizard.font.size_adjust"),
            if self.live.is_some() {
                format!(" · {}", i18n::t("wizard.font.preview_suffix"))
            } else {
                String::new()
            }
        );
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

/// Write beside the config, then rename; a failed write must not truncate the
/// user's Ghostty settings, and the file keeps its permissions.
fn write_config(config: &Path, content: &str) -> Result<(), String> {
    let temp = config.with_extension(format!("tmp-{}", std::process::id()));
    fs::write(&temp, content).map_err(|e| e.to_string())?;
    fs::set_permissions(
        &temp,
        fs::metadata(config)
            .map_err(|e| e.to_string())?
            .permissions(),
    )
    .map_err(|e| e.to_string())?;
    fs::rename(&temp, config).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TempDir;
    use ratatui::{backend::TestBackend, Terminal};
    use std::os::unix::process::ExitStatusExt;

    const ORIGINAL: &str = "command = /opt/letsmash/bin/herdr-pane\nfont-family = \"MesloLGS NF\"\nfont-size = 13\ntheme = Monokai Cursor\n";

    /// A config, a page previewing through it, and a stand-in terminal: a
    /// sleeping child, which SIGUSR2 terminates, so a test sees exactly which
    /// process was asked to reload.
    fn live_fixture(name: &str) -> (TempDir, FontPage, std::process::Child) {
        let dir = TempDir::new(&format!("live-font-{name}"));
        let config = dir.join("config");
        fs::write(&config, ORIGINAL).unwrap();
        let terminal = Command::new("sleep").arg("30").spawn().unwrap();
        let mut page =
            FontPage::with_fonts(vec!["JetBrains Mono".into(), DEFAULT_FONT.into()], false);
        page.use_current(ORIGINAL);
        page.start_live_preview(&config, terminal.id());
        page.live.as_mut().unwrap().delay = Duration::ZERO;
        (dir, page, terminal)
    }

    fn reloaded(terminal: &mut std::process::Child) -> bool {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(status) = terminal.try_wait().unwrap() {
                return status.signal().is_some_and(|signal| signal != 9);
            }
            if Instant::now() > deadline {
                let _ = terminal.kill();
                let _ = terminal.wait();
                return false;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn size_and_family_changes_preview_in_the_owning_terminal() {
        let (dir, mut page, mut terminal) = live_fixture("apply");
        page.focus = SIZE;
        page.on_key(KeyCode::Char('+'), KeyModifiers::NONE);
        page.focus = LIST;
        page.on_key(KeyCode::Up, KeyModifiers::NONE);
        assert!(page.live_preview_pending());
        page.poll_live_preview();
        assert!(!page.live_preview_pending());
        let preview = fs::read_to_string(dir.join("config")).unwrap();
        assert_eq!(
            preview,
            "command = /opt/letsmash/bin/herdr-pane\nfont-family = \"JetBrains Mono\"\nfont-size = 14\ntheme = Monokai Cursor\n"
        );
        assert!(reloaded(&mut terminal), "the terminal was asked to reload");
        drop(page);
        // Not saved, so leaving restores the user's file.
        assert_eq!(fs::read_to_string(dir.join("config")).unwrap(), ORIGINAL);
    }

    #[test]
    fn the_theme_previews_in_the_terminal_and_a_custom_theme_is_kept() {
        let (dir, mut page, mut terminal) = live_fixture("theme");
        page.focus = THEME;
        page.on_key(KeyCode::Right, KeyModifiers::NONE);
        assert_eq!(page.theme, Theme::Light);
        page.poll_live_preview();
        let preview = fs::read_to_string(dir.join("config")).unwrap();
        assert!(
            preview.ends_with("theme = Monokai Cursor Light\n"),
            "{preview}"
        );
        assert!(preview.contains("font-size = 13\n"));
        assert!(reloaded(&mut terminal));
        drop(page);
        assert_eq!(fs::read_to_string(dir.join("config")).unwrap(), ORIGINAL);

        let custom = "font-size = 13\ntheme = Dracula\n";
        let mut page = FontPage::with_fonts(vec![DEFAULT_FONT.into()], false);
        page.theme = Theme::Light;
        assert!(page.render(custom).contains("theme = Dracula\n"));
    }

    #[test]
    fn a_change_waits_for_the_key_repeat_to_settle() {
        let (dir, mut page, mut terminal) = live_fixture("settle");
        page.live.as_mut().unwrap().delay = Duration::from_secs(60);
        page.focus = SIZE;
        for _ in 0..5 {
            page.on_key(KeyCode::Right, KeyModifiers::NONE);
        }
        page.poll_live_preview();
        assert!(page.live_preview_pending());
        assert_eq!(fs::read_to_string(dir.join("config")).unwrap(), ORIGINAL);
        assert!(terminal.try_wait().unwrap().is_none(), "no reload yet");
        // Nothing was previewed, so leaving has nothing to restore or signal.
        drop(page);
        assert!(terminal.try_wait().unwrap().is_none());
        let _ = terminal.kill();
        let _ = terminal.wait();
    }

    #[test]
    fn a_saved_choice_survives_the_page_and_moves_that_end_where_they_began_do_nothing() {
        let (dir, mut page, mut terminal) = live_fixture("save");
        page.focus = SIZE;
        page.on_key(KeyCode::Right, KeyModifiers::NONE);
        page.on_key(KeyCode::Left, KeyModifiers::NONE);
        page.poll_live_preview();
        assert_eq!(fs::read_to_string(dir.join("config")).unwrap(), ORIGINAL);
        assert!(
            terminal.try_wait().unwrap().is_none(),
            "back where it began"
        );
        page.on_key(KeyCode::Right, KeyModifiers::NONE);
        page.poll_live_preview();
        assert!(reloaded(&mut terminal));
        page.save(&dir.join("config")).unwrap();
        drop(page);
        assert!(fs::read_to_string(dir.join("config"))
            .unwrap()
            .contains("font-size = 14"));
    }

    #[test]
    fn native_mode_and_appearance_survive_actual_seed_reconciliation_and_drop() {
        let packaging = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
        for platform in ["Darwin", "Linux"] {
            let (dir, mut page, mut terminal) = live_fixture(platform);
            let resources = dir.join("resources");
            let data = dir.join("home/.mash");
            fs::create_dir_all(&resources).unwrap();
            fs::create_dir_all(&data).unwrap();
            // Read-only source defaults; all generated files stay in the fixture.
            let defaults = resources.join("defaults");
            fs::create_dir(&defaults).unwrap();
            for entry in fs::read_dir(packaging.join("defaults")).unwrap() {
                let entry = entry.unwrap();
                if entry.file_name() != "optional-programming.txt" {
                    std::os::unix::fs::symlink(entry.path(), defaults.join(entry.file_name()))
                        .unwrap();
                }
            }
            fs::write(defaults.join("optional-programming.txt"), "").unwrap();
            fs::write(resources.join("VERSION"), "9.9.9\n").unwrap();
            let reconcile = || {
                let output = Command::new("/bin/bash")
                    .arg(packaging.join("helpers/mash-seed-sync"))
                    .arg(&resources)
                    .arg(&data)
                    .env("MASH_SEED_PLATFORM", platform)
                    .env("PYTHONDONTWRITEBYTECODE", "1")
                    .output()
                    .unwrap();
                assert!(
                    output.status.success(),
                    "{}",
                    String::from_utf8_lossy(&output.stderr)
                );
            };
            reconcile();
            let config = data.join("config/ghostty/config");
            let seeded = fs::read_to_string(&config).unwrap();
            page.use_current(&seeded);
            page.start_live_preview(&config, terminal.id());
            page.live.as_mut().unwrap().delay = Duration::ZERO;
            page.keybindings = Keybindings::Native;
            page.theme = Theme::Light;
            page.size += 1;
            let chosen_size = page.size;
            page.touched(page.live.as_ref().unwrap().initial);
            page.poll_live_preview();
            assert!(reloaded(&mut terminal));
            assert_ne!(fs::read_to_string(&config).unwrap(), seeded);
            page.retire_live_preview().unwrap();
            assert_eq!(fs::read_to_string(&config).unwrap(), seeded);
            page.save_mode(&data).unwrap();
            reconcile();
            page.save(&config).unwrap();
            drop(page);
            let saved = fs::read_to_string(&config).unwrap();
            assert!(
                saved.contains("mash-keybindings = native\n"),
                "{platform}: {saved}"
            );
            assert!(
                !saved.lines().any(|line| line.starts_with("keybind = ")),
                "{platform}"
            );
            assert!(
                saved.contains(&format!("font-size = {chosen_size}\n")),
                "{saved}"
            );
            assert!(saved.contains(Theme::Light.terminal_line()), "{saved}");
            reconcile();
            assert_eq!(fs::read_to_string(&config).unwrap(), saved);
        }
    }

    #[test]
    fn a_failed_restore_keeps_the_original_for_the_next_attempt() {
        let (dir, mut page, mut terminal) = live_fixture("retire-fail");
        page.focus = SIZE;
        page.on_key(KeyCode::Right, KeyModifiers::NONE);
        page.poll_live_preview();
        assert!(reloaded(&mut terminal));
        // A directory now occupies the config path, so the atomic rename cannot
        // land and the restore fails.
        let config = dir.join("config");
        fs::remove_file(&config).unwrap();
        fs::create_dir(&config).unwrap();
        assert!(page.retire_live_preview().is_err());
        assert!(
            page.live.is_some(),
            "a failed restore must stay retryable so Drop can still undo it"
        );
        fs::remove_dir(&config).unwrap();
        fs::write(&config, ORIGINAL).unwrap();
        drop(page);
        assert_eq!(fs::read_to_string(&config).unwrap(), ORIGINAL);
    }

    #[test]
    fn without_a_terminal_or_config_there_is_no_preview() {
        let mut page = FontPage::with_fonts(vec![DEFAULT_FONT.into()], false);
        page.start_live_preview(Path::new("/nonexistent/mash/ghostty/config"), 4242);
        assert!(page.live.is_none());
        let dir = TempDir::new("live-font-none");
        fs::write(dir.join("config"), ORIGINAL).unwrap();
        page.start_live_preview(&dir.join("config"), 1);
        assert!(page.live.is_none(), "pid 1 is never this window's terminal");
        page.focus = SIZE;
        page.on_key(KeyCode::Right, KeyModifiers::NONE);
        assert!(!page.live_preview_pending());
    }

    #[test]
    fn lists_only_font_families_and_selects_meslo_at_platform_default_size() {
        let fonts = FontPage::parse_fonts(
            "JetBrains Mono\n  JetBrains Mono Bold\n\nMesloLGS NF\n  MesloLGS NF Regular\n\n",
        );
        assert_eq!(fonts, ["JetBrains Mono", "MesloLGS NF"]);
        let mut page = FontPage::with_fonts(fonts, false);
        assert_eq!(page.fonts[page.selected], DEFAULT_FONT);
        assert_eq!(page.size, if cfg!(target_os = "linux") { 10 } else { 13 });
        page.use_current("font-family = \"JetBrains Mono\"\nfont-size = 17\n");
        assert_eq!(page.fonts[page.selected], "JetBrains Mono");
        assert_eq!(page.size, 17);
    }

    #[test]
    fn shipped_configs_use_platform_font_sizes() {
        let macos = include_str!("../defaults/ghostty/config");
        let linux = include_str!("../defaults/ghostty/config.linux");
        assert!(macos.lines().any(|line| line == "font-size = 13"));
        assert!(linux.lines().any(|line| line == "font-size = 10"));
    }

    #[test]
    fn filtering_and_size_pick_preserve_the_rest_of_ghostty_config() {
        let mut page = FontPage::with_fonts(vec!["JetBrains Mono".into()], false);
        for c in "jet".chars() {
            page.on_key(KeyCode::Char(c), KeyModifiers::NONE);
        }
        assert_eq!(page.fonts[page.selected], "JetBrains Mono");
        page.size = 13;
        page.focus = SIZE;
        page.on_key(KeyCode::Right, KeyModifiers::NONE);
        assert_eq!(page.size, 14);
        let dir = TempDir::new("font-test");
        let path = dir.join("config");
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
        let mut page = FontPage::with_fonts(vec!["JetBrains Mono".into()], false);
        let mut terminal = Terminal::new(TestBackend::new(80, 28)).unwrap();
        terminal.draw(|frame| page.draw(frame)).unwrap();
        let buffer = terminal.backend().buffer();
        wizard_style::tests::find(buffer, "Appearance — page 6/7");
        let default_size = if cfg!(target_os = "linux") { 10 } else { 13 };
        wizard_style::tests::find(buffer, &default_size.to_string());
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
        assert_eq!(page.size, default_size + 1);
        let (x, y) = wizard_style::tests::find(buffer, "Light");
        page.on_click(wizard_style::clicked(&wizard_style::tests::click(x, y)).unwrap());
        assert_eq!(page.theme, Theme::Light);
        page.focus = THEME;
        page.on_key(KeyCode::Left, KeyModifiers::NONE);
        assert_eq!(page.theme, Theme::Dark);
    }

    #[test]
    fn keybinding_mode_defaults_to_mash_and_changes_by_keyboard_and_click() {
        let mut page = FontPage::with_fonts(vec!["JetBrains Mono".into()], false);
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
        let dir = TempDir::new("mode-test");
        let mut page = FontPage::with_fonts(vec!["JetBrains Mono".into()], false);
        assert_eq!(Keybindings::current(&dir), Keybindings::Mash);
        page.keybindings = Keybindings::Native;
        page.save_mode(&dir).unwrap();
        assert_eq!(Keybindings::current(&dir), Keybindings::Native);
        assert_eq!(
            fs::read_to_string(dir.join("setup/keybindings-mode")).unwrap(),
            "mode=native\n"
        );
    }
}
