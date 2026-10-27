//! The dictation page: choose the languages you will speak to Pi in, then the
//! model to download. Last page of the first-launch wizard, so `Save` is what
//! lets the install run begin.

use crate::voice::{self, Role};
use crate::wizard_style;
use ratatui::{
    crossterm::event::{KeyCode, KeyModifiers},
    layout::{Constraint, Layout},
    style::{Modifier, Style},
    text::{Line, Span},
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
        self.row = wizard_style::focus_step(self.row, self.row_count(), direction, true);
    }

    /// Click target `row`: a language toggles, a role is chosen, and the
    /// buttons act like Enter.
    pub fn on_click(&mut self, row: usize) -> Option<Decision> {
        if row >= self.row_count() {
            return None;
        }
        self.row = row;
        if let Some(index) = self.language_at(row) {
            self.languages[index].checked = !self.languages[index].checked;
            self.recompute();
            return None;
        }
        let decision = self.on_key(KeyCode::Enter, KeyModifiers::NONE);
        self.row = row; // a role click selects it without hopping to the next row
        decision
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
        .split(wizard_style::page_area(frame, Some(4)));

        wizard_style::header(frame, parts[0], "Dictation — page 5/5");

        self.draw_languages(frame, parts[1]);
        self.draw_pick(frame, parts[2]);

        wizard_style::render_buttons(
            frame,
            parts[3],
            &[
                (
                    wizard_style::button(self.row == self.back_row(), " Back "),
                    Some(self.back_row()),
                ),
                (Span::raw("  "), None),
                (
                    wizard_style::button(self.row == self.skip_row(), " Skip dictation "),
                    Some(self.skip_row()),
                ),
                (Span::raw("  "), None),
                (
                    wizard_style::button(self.row == self.save_row(), " Download and continue "),
                    Some(self.save_row()),
                ),
            ],
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
        let anchor = self
            .language_at(self.row)
            .unwrap_or(count.saturating_sub(1));
        let start = if count <= viewport {
            0
        } else {
            anchor
                .saturating_sub(viewport.saturating_sub(1))
                .min(count - viewport)
        };
        let end = (start + viewport).min(count);

        let mut lines: Vec<(Line<'static>, Option<usize>)> = Vec::new();
        for index in start..end {
            let language = &self.languages[index];
            let focused = self.row == index;
            lines.push((
                wizard_style::checkbox(focused, &language.name, language.checked),
                Some(index),
            ));
        }
        let hidden = count.saturating_sub(end);
        if hidden > 0 {
            lines.push((
                Line::from(Span::styled(
                    format!("  {hidden} more — scroll or keep moving down"),
                    Style::default().fg(wizard_style::MUTED),
                )),
                None,
            ));
        }

        let body = wizard_style::section(frame, area, "Languages you will dictate in");
        wizard_style::render_form(frame, body, lines, false);
    }

    fn draw_pick(&self, frame: &mut Frame, area: ratatui::layout::Rect) {
        let mut lines: Vec<(Line<'static>, Option<usize>)> = Vec::new();
        match &self.pick {
            None if self.selected().is_empty() => lines.push((
                Line::from(Span::styled(
                    "Pick at least one language.",
                    Style::default().fg(wizard_style::RED),
                )),
                None,
            )),
            None => lines.push((
                Line::from(Span::styled(
                    "No model covers that combination. Remove a language.",
                    Style::default().fg(wizard_style::RED),
                )),
                None,
            )),
            Some(pick) => {
                for role in [Role::Best, Role::Fast] {
                    let row = self.role_row(role);
                    let focused = self.row == row;
                    // (*) marks the selected model; background marks keyboard focus.
                    let radio = if self.role == role { "(*)" } else { "( )" };
                    lines.push((
                        Line::from(vec![
                            Span::raw(format!("{radio} {:<5}", role.label())),
                            Span::styled(
                                pick.model(role).row(),
                                Style::default().add_modifier(Modifier::BOLD),
                            ),
                        ])
                        .style(if focused {
                            wizard_style::selected()
                        } else {
                            Style::default()
                        }),
                        Some(row),
                    ));
                    if focused {
                        lines.push((Line::from(format!("      {}", role.summary())), None));
                    }
                }
                if pick.same_model() {
                    lines.push((
                        Line::from(Span::styled(
                            "  Both roles are the same model here.",
                            Style::default().fg(wizard_style::MUTED),
                        )),
                        None,
                    ));
                }
                if pick.needs_detector {
                    lines.push((
                        Line::from(Span::styled(
                            format!(
                                "  adds the {} language detector for auto-detect",
                                voice::human_size(voice::detector_bytes())
                            ),
                            Style::default().fg(wizard_style::MUTED),
                        )),
                        None,
                    ));
                }
            }
        }
        let body = wizard_style::section(frame, area, "Model to download");
        wizard_style::render_form(frame, body, lines, false);
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
        assert!(rendered.contains("Dictation — page 5/5"));
        assert!(rendered.contains("MiB"));
        assert!(rendered.contains("English"));
    }

    #[test]
    fn clicks_toggle_languages_pick_roles_and_press_buttons() {
        use wizard_style::tests::{click, find};
        let mut page = VoicePage::new();
        let render = |page: &VoicePage| {
            let mut terminal =
                ratatui::Terminal::new(ratatui::backend::TestBackend::new(120, 34)).unwrap();
            terminal.draw(|frame| page.draw(frame)).unwrap();
            terminal.backend().buffer().clone()
        };
        let at = |page: &VoicePage, label| {
            let (x, y) = find(&render(page), label);
            wizard_style::clicked(&click(x, y)).expect("label is clickable")
        };
        let name = page.languages[1].name.clone();
        let before = page.languages[1].checked;
        assert!(page.on_click(at(&page, &name)).is_none());
        assert_ne!(page.languages[1].checked, before);
        assert!(page.on_click(at(&page, "( ) ")).is_none());
        assert!(page.role == Role::Fast);
        assert_eq!(page.row, page.fast_row());
        assert!(matches!(
            page.on_click(at(&page, "Back")),
            Some(Decision::Back)
        ));
        assert!(matches!(
            page.on_click(at(&page, "Skip dictation")),
            Some(Decision::Skip)
        ));
        assert!(page.choice().is_none());
    }
}
