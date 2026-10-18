//! The dictation page: choose the languages you will speak to Pi in, then the
//! model to download. Last page of the first-launch wizard, so `Save` is what
//! lets the install run begin.

use crate::voice::{self, Role};
use ratatui::{
    crossterm::event::{KeyCode, KeyModifiers},
    layout::{Alignment, Constraint, Layout},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph, Wrap},
    Frame,
};

pub enum Decision {
    Back,
    Cancel,
    Save,
    /// Leave dictation unconfigured. Pi Voice's own onboarding will offer the
    /// same model the first time `/voice` runs.
    Skip,
}

struct Language {
    code: String,
    name: String,
    checked: bool,
}

pub struct VoicePage {
    languages: Vec<Language>,
    /// A flat row index: the language rows, then Best, Fast, Back, Skip, Save.
    row: usize,
    role: Role,
    pick: Option<voice::Pick>,
    skipped: bool,
}

impl VoicePage {
    pub fn new() -> Self {
        let languages = voice::offered_languages()
            .into_iter()
            .map(|(code, name)| Language {
                // English first, and preselected: it is the picker's own
                // `defaultSpokenLanguages()` fallback outside a known locale.
                checked: code == "en",
                code,
                name,
            })
            .collect();
        let mut page = Self {
            languages,
            row: 0,
            role: Role::Best,
            pick: None,
            skipped: false,
        };
        page.recompute();
        page
    }

    fn language_count(&self) -> usize {
        self.languages.len()
    }

    fn best_row(&self) -> usize {
        self.language_count()
    }

    fn fast_row(&self) -> usize {
        self.language_count() + 1
    }

    fn back_row(&self) -> usize {
        self.language_count() + 2
    }

    fn skip_row(&self) -> usize {
        self.language_count() + 3
    }

    fn save_row(&self) -> usize {
        self.language_count() + 4
    }

    fn row_count(&self) -> usize {
        self.language_count() + 5
    }

    fn language_at(&self, row: usize) -> Option<usize> {
        (row < self.language_count()).then_some(row)
    }

    pub fn selected(&self) -> Vec<String> {
        self.languages
            .iter()
            .filter(|language| language.checked)
            .map(|language| language.code.clone())
            .collect()
    }

    fn recompute(&mut self) {
        self.pick = voice::recommend(&self.selected());
    }

    /// The choice the install plan carries, or `None` when nothing is selected
    /// or the page was skipped.
    pub fn choice(&self) -> Option<voice::VoiceChoice> {
        if self.skipped {
            return None;
        }
        let pick = self.pick.as_ref()?;
        let languages = self.selected();
        if languages.is_empty() {
            return None;
        }
        let model = pick.model(self.role);
        Some(voice::VoiceChoice {
            model_id: model.id.clone(),
            languages,
            needs_detector: pick.needs_detector,
        })
    }

    pub fn validate(&self) -> bool {
        !self.selected().is_empty() && self.pick.is_some()
    }

    fn move_row(&mut self, direction: isize) {
        let count = self.row_count() as isize;
        self.row = (self.row as isize + direction).rem_euclid(count) as usize;
    }

    pub fn on_key(&mut self, code: KeyCode, modifiers: KeyModifiers) -> Option<Decision> {
        if modifiers.contains(KeyModifiers::CONTROL) && code == KeyCode::Char('c') {
            return Some(Decision::Cancel);
        }
        match code {
            KeyCode::Esc => Some(Decision::Cancel),
            KeyCode::Tab | KeyCode::Down => {
                self.move_row(1);
                None
            }
            KeyCode::BackTab | KeyCode::Up => {
                self.move_row(-1);
                None
            }
            KeyCode::Char(' ') | KeyCode::Char('x') if self.language_at(self.row).is_some() => {
                let index = self.language_at(self.row).expect("guarded above");
                self.languages[index].checked = !self.languages[index].checked;
                self.recompute();
                None
            }
            KeyCode::Enter | KeyCode::Char(' ') => {
                if self.language_at(self.row).is_some() {
                    self.move_row(1);
                    None
                } else if self.row == self.best_row() {
                    self.role = Role::Best;
                    self.move_row(1);
                    None
                } else if self.row == self.fast_row() {
                    self.role = Role::Fast;
                    self.move_row(1);
                    None
                } else if self.row == self.back_row() {
                    Some(Decision::Back)
                } else if self.row == self.skip_row() {
                    self.skipped = true;
                    Some(Decision::Skip)
                } else {
                    Some(Decision::Save)
                }
            }
            _ => None,
        }
    }

    fn role_row(&self, role: Role) -> usize {
        match role {
            Role::Best => self.best_row(),
            Role::Fast => self.fast_row(),
        }
    }

    pub fn draw(&self, frame: &mut Frame) {
        let parts = Layout::vertical([
            Constraint::Length(3),
            Constraint::Min(6),
            Constraint::Length(7),
            Constraint::Length(3),
        ])
        .split(frame.area());

        frame.render_widget(
            Paragraph::new("Dictation — page 4/4")
                .alignment(Alignment::Center)
                .block(Block::default().borders(Borders::ALL)),
            parts[0],
        );

        self.draw_languages(frame, parts[1]);
        self.draw_pick(frame, parts[2]);

        let button = |row: usize, label: &str| {
            let style = if self.row == row {
                Style::default().fg(Color::Black).bg(Color::Yellow)
            } else {
                Style::default()
            };
            Span::styled(label.to_string(), style.add_modifier(Modifier::BOLD))
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                button(self.back_row(), " Back "),
                Span::raw("  "),
                button(self.skip_row(), " Skip dictation "),
                Span::raw("  "),
                button(self.save_row(), " Download and continue "),
            ]))
            .alignment(Alignment::Center)
            .block(Block::default().borders(Borders::ALL)),
            parts[3],
        );
    }

    fn draw_languages(&self, frame: &mut Frame, area: ratatui::layout::Rect) {
        let inner = area.height.saturating_sub(2).max(1) as usize;
        let count = self.language_count();
        // One row goes to the "more" hint when the list does not fit, so the
        // hint is never the line Paragraph clips off.
        let viewport = if count <= inner {
            inner
        } else {
            inner.saturating_sub(1).max(1)
        };
        let anchor = self.language_at(self.row).unwrap_or(count.saturating_sub(1));
        let start = if count <= viewport {
            0
        } else {
            anchor
                .saturating_sub(viewport.saturating_sub(1))
                .min(count - viewport)
        };
        let end = (start + viewport).min(count);

        let mut lines = Vec::new();
        for index in start..end {
            let language = &self.languages[index];
            let focused = self.row == index;
            let marker = if focused { ">" } else { " " };
            lines.push(Line::from(vec![
                Span::styled(marker, Style::default().fg(Color::Yellow)),
                Span::raw(format!("[{}] ", if language.checked { "x" } else { " " })),
                Span::styled(
                    language.name.clone(),
                    if focused {
                        Style::default().add_modifier(Modifier::BOLD)
                    } else {
                        Style::default()
                    },
                ),
            ]));
        }
        let hidden = count.saturating_sub(end);
        if hidden > 0 {
            lines.push(Line::from(Span::styled(
                format!("  {hidden} more — keep moving down"),
                Style::default().fg(Color::DarkGray),
            )));
        }

        frame.render_widget(
            Paragraph::new(lines).wrap(Wrap { trim: false }).block(
                Block::default()
                    .borders(Borders::ALL)
                    .title("Languages you will dictate in"),
            ),
            area,
        );
    }

    fn draw_pick(&self, frame: &mut Frame, area: ratatui::layout::Rect) {
        let mut lines = Vec::new();
        match &self.pick {
            None if self.selected().is_empty() => lines.push(Line::from(Span::styled(
                "Pick at least one language.",
                Style::default().fg(Color::Red),
            ))),
            None => lines.push(Line::from(Span::styled(
                "No model covers that combination. Remove a language.",
                Style::default().fg(Color::Red),
            ))),
            Some(pick) => {
                for role in [Role::Best, Role::Fast] {
                    let row = self.role_row(role);
                    let focused = self.row == row;
                    // A preselected role needs its own marker; the language rows
                    // above already use `>` for focus.
                    let radio = if self.role == role { "(*)" } else { "( )" };
                    let marker = if focused { ">" } else { " " };
                    lines.push(Line::from(vec![
                        Span::styled(marker, Style::default().fg(Color::Yellow)),
                        Span::raw(format!("{radio} {:<5}", role.label())),
                        Span::styled(
                            pick.model(role).row(),
                            Style::default().add_modifier(Modifier::BOLD),
                        ),
                    ]));
                    if focused {
                        lines.push(Line::from(format!("      {}", role.summary())));
                    }
                }
                if pick.same_model() {
                    lines.push(Line::from(Span::styled(
                        "  Both roles are the same model here.",
                        Style::default().fg(Color::DarkGray),
                    )));
                }
                if pick.needs_detector {
                    lines.push(Line::from(Span::styled(
                        format!(
                            "  adds the {} language detector for auto-detect",
                            voice::human_size(voice::detector_bytes())
                        ),
                        Style::default().fg(Color::DarkGray),
                    )));
                }
            }
        }
        frame.render_widget(
            Paragraph::new(lines).wrap(Wrap { trim: false }).block(
                Block::default()
                    .borders(Borders::ALL)
                    .title("Model to download"),
            ),
            area,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn english_is_preselected_and_picks_the_default_model() {
        let page = VoicePage::new();
        assert_eq!(page.selected(), vec!["en".to_string()]);
        let choice = page.choice().expect("a choice for English");
        assert_eq!(choice.model_id, "parakeet-unified-en-0.6b");
        assert!(!choice.needs_detector);
    }

    #[test]
    fn space_toggles_a_language_and_recomputes() {
        let mut page = VoicePage::new();
        page.row = 0; // English
        page.on_key(KeyCode::Char(' '), KeyModifiers::NONE);
        assert!(page.selected().is_empty());
        assert!(!page.validate());
        page.on_key(KeyCode::Char(' '), KeyModifiers::NONE);
        assert_eq!(page.selected(), vec!["en".to_string()]);
        assert!(page.validate());
    }

    #[test]
    fn focus_wraps_through_every_row() {
        let mut page = VoicePage::new();
        let count = page.row_count();
        let mut seen = vec![page.row];
        for _ in 0..count {
            page.on_key(KeyCode::Down, KeyModifiers::NONE);
            seen.push(page.row);
        }
        assert_eq!(seen.first(), seen.last());
        assert_eq!(seen.len(), count + 1);
    }

    #[test]
    fn back_and_save_are_reachable_from_the_bottom() {
        let mut page = VoicePage::new();
        page.row = page.back_row();
        assert!(matches!(
            page.on_key(KeyCode::Enter, KeyModifiers::NONE),
            Some(Decision::Back)
        ));
        page.row = page.save_row();
        assert!(matches!(
            page.on_key(KeyCode::Enter, KeyModifiers::NONE),
            Some(Decision::Save)
        ));
    }

    #[test]
    fn esc_cancels() {
        let mut page = VoicePage::new();
        assert!(matches!(
            page.on_key(KeyCode::Esc, KeyModifiers::NONE),
            Some(Decision::Cancel)
        ));
    }

    #[test]
    fn skip_leaves_dictation_unconfigured() {
        // Without a way out, a user who does not want dictation would have to
        // abort the whole wizard: Save is gated on a language.
        let mut page = VoicePage::new();
        page.row = page.skip_row();
        assert!(matches!(
            page.on_key(KeyCode::Enter, KeyModifiers::NONE),
            Some(Decision::Skip)
        ));
        assert!(page.choice().is_none());
    }

    #[test]
    fn the_fast_role_reaches_the_choice() {
        let mut page = VoicePage::new();
        page.row = page.fast_row();
        page.on_key(KeyCode::Enter, KeyModifiers::NONE);
        let choice = page.choice().expect("a choice");
        assert_eq!(choice.model_id, page.pick.as_ref().unwrap().fast.id);
    }

    #[test]
    fn renders_both_models_with_their_sizes() {
        use ratatui::{backend::TestBackend, Terminal};
        let page = VoicePage::new();
        let mut terminal = Terminal::new(TestBackend::new(100, 30)).unwrap();
        terminal.draw(|frame| page.draw(frame)).unwrap();
        let rendered = terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect::<String>();
        assert!(rendered.contains("Dictation — page 4/4"));
        assert!(rendered.contains("MiB"));
        assert!(rendered.contains("English"));
    }
}
