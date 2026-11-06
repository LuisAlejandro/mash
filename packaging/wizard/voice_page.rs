//! The dictation page: choose the languages you will speak to Pi in, then the
//! model to download. Last page of the first-launch wizard, so `Save` is what
//! lets the install run begin.

use crate::{
    i18n,
    voice::{self, Role},
    wizard_style,
};
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
    /// Download the chosen model, or, with no language checked, leave
    /// dictation unconfigured: Pi Voice's own onboarding offers the same model
    /// the first time `/voice` runs.
    Save,
}

struct Language {
    code: String,
    name: String,
    checked: bool,
}

pub struct VoicePage {
    languages: Vec<Language>,
    /// A flat row index: the language rows, then Best, Fast, Back, Save.
    row: usize,
    role: Role,
    pick: Option<voice::Pick>,
}

impl VoicePage {
    pub fn new() -> Self {
        Self::for_language(i18n::language())
    }

    /// The page as it opens for a given interface language. `new` uses the
    /// current one; the wizard rebuilds the page when the language is chosen.
    pub fn for_language(ui: &str) -> Self {
        let preferred = crate::language_page::voice_language(ui)
            .and_then(|code| code.split('-').next())
            .unwrap_or("en");
        let offered = voice::offered_languages();
        let preferred = if offered.iter().any(|(code, _)| code == preferred) {
            preferred
        } else {
            "en"
        };
        let languages: Vec<Language> = offered
            .into_iter()
            .map(|(code, name)| Language {
                // English is the final fallback if the selected UI language has
                // no supported dictation model.
                checked: code == preferred,
                code,
                name,
            })
            .collect();
        let row = languages
            .iter()
            .position(|language| language.checked)
            .unwrap_or(0);
        let mut page = Self {
            languages,
            row,
            role: Role::Best,
            pick: None,
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

    fn save_row(&self) -> usize {
        self.language_count() + 3
    }

    fn row_count(&self) -> usize {
        self.language_count() + 4
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

    /// The choice the install plan carries, or `None` when no language is
    /// selected, which leaves dictation unconfigured.
    pub fn choice(&self) -> Option<voice::VoiceChoice> {
        let pick = self.pick.as_ref()?;
        let languages = self.selected();
        if languages.is_empty() {
            return None;
        }
        let model = pick.model(self.role);
        Some(voice::VoiceChoice {
            model_id: model.id.clone(),
            languages,
            needs_detector: model.needs_detector,
        })
    }

    /// No language means no dictation, which is always allowed; languages
    /// need a model that covers them.
    pub fn validate(&self) -> bool {
        self.selected().is_empty() || self.pick.is_some()
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
        .split(wizard_style::page_area(frame, Some(6)));

        wizard_style::header(
            frame,
            parts[0],
            &wizard_style::page_title(&i18n::t("wizard.voice.title"), 6),
        );

        self.draw_languages(frame, parts[1]);
        self.draw_pick(frame, parts[2]);

        wizard_style::render_buttons(
            frame,
            parts[3],
            &[
                (
                    wizard_style::button(
                        self.row == self.back_row(),
                        &format!(" {} ", i18n::t("wizard.voice.back")),
                    ),
                    Some(self.back_row()),
                ),
                (Span::raw("  "), None),
                (
                    wizard_style::button(
                        self.row == self.save_row(),
                        &format!(
                            " {} ",
                            if self.selected().is_empty() {
                                i18n::t("wizard.voice.continue_without")
                            } else {
                                i18n::t("wizard.voice.download_continue")
                            }
                        ),
                    ),
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
                    i18n::fill(
                        &i18n::t("wizard.voice.more"),
                        &[("count", &&hidden.to_string())],
                    ),
                    Style::default().fg(wizard_style::MUTED),
                )),
                None,
            ));
        }

        let body = wizard_style::section(frame, area, &i18n::t("wizard.voice.languages_section"));
        wizard_style::render_form(frame, body, lines, false);
    }

    fn draw_pick(&self, frame: &mut Frame, area: ratatui::layout::Rect) {
        let mut lines: Vec<(Line<'static>, Option<usize>)> = Vec::new();
        match &self.pick {
            None if self.selected().is_empty() => lines.push((
                Line::from(Span::styled(
                    i18n::t("wizard.voice.empty_notice"),
                    Style::default().fg(wizard_style::MUTED),
                )),
                None,
            )),
            None => lines.push((
                Line::from(Span::styled(
                    i18n::t("wizard.voice.no_match"),
                    Style::default().fg(wizard_style::RED),
                )),
                None,
            )),
            Some(pick) => {
                // Both role labels share one column, sized to the wider
                // translation plus a space, so the model name never touches it.
                let label_width = [Role::Best, Role::Fast]
                    .iter()
                    .map(|role| Line::from(role.label()).width())
                    .max()
                    .unwrap_or(0)
                    + 1;
                for role in [Role::Best, Role::Fast] {
                    let row = self.role_row(role);
                    let focused = self.row == row;
                    // (*) marks the selected model; background marks keyboard focus.
                    let radio = if self.role == role { "(*)" } else { "( )" };
                    lines.push((
                        Line::from(vec![
                            Span::raw({
                                let label = role.label();
                                let pad =
                                    label_width.saturating_sub(Line::from(label.as_str()).width());
                                format!("{radio} {label}{}", " ".repeat(pad))
                            }),
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
                            i18n::t("wizard.voice.same_model"),
                            Style::default().fg(wizard_style::MUTED),
                        )),
                        None,
                    ));
                }
                if pick.model(self.role).needs_detector {
                    lines.push((
                        Line::from(Span::styled(
                            format!(
                                "  {}",
                                i18n::fill(
                                    &i18n::t("wizard.voice.detector_notice"),
                                    &[("size", &&voice::human_size(voice::detector_bytes()),)]
                                )
                            ),
                            Style::default().fg(wizard_style::MUTED),
                        )),
                        None,
                    ));
                }
            }
        }
        let body = wizard_style::section(frame, area, &i18n::t("wizard.voice.model_section"));
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
    fn fast_multilingual_choice_installs_its_own_detector() {
        let mut page = VoicePage::new();
        for language in &mut page.languages {
            language.checked = language.code == "en" || language.code == "zh";
        }
        page.recompute();
        assert!(!page.choice().expect("Best covers en+zh").needs_detector);
        page.role = Role::Fast;
        let choice = page.choice().expect("Fast covers en+zh");
        assert_eq!(choice.model_id, "Fun-ASR-Nano-2512");
        assert!(choice.needs_detector);
    }

    #[test]
    fn space_toggles_a_language_and_recomputes() {
        let mut page = VoicePage::new();
        page.row = 0; // English
        page.on_key(KeyCode::Char(' '), KeyModifiers::NONE);
        assert!(page.selected().is_empty());
        assert!(page.choice().is_none());
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

    // Covers AE1: the dictation page pre-selects the chosen language.
    #[test]
    fn dictation_preselects_the_chosen_language() {
        assert_eq!(
            VoicePage::for_language("es").selected(),
            vec!["es".to_string()]
        );
        assert_eq!(
            VoicePage::for_language("th").selected(),
            vec!["th".to_string()]
        );
        // An unknown interface language has no dictation model: English is pre-selected.
        assert_eq!(
            VoicePage::for_language("xx").selected(),
            vec!["en".to_string()]
        );
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
    fn no_language_continues_without_dictation() {
        // With no skip button, unchecking every language is the way to finish
        // setup without dictation; the wizard must never be stuck here.
        use ratatui::{backend::TestBackend, Terminal};
        let mut page = VoicePage::new();
        page.row = 0; // English
        page.on_key(KeyCode::Char(' '), KeyModifiers::NONE);
        assert!(page.selected().is_empty());
        assert!(page.validate());
        assert!(page.choice().is_none(), "nothing is downloaded");
        let mut terminal = Terminal::new(TestBackend::new(100, 30)).unwrap();
        terminal.draw(|frame| page.draw(frame)).unwrap();
        let rendered: String = terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect();
        assert!(rendered.contains("Continue without dictation"));
        assert!(!rendered.contains("Skip dictation"));
        page.row = page.save_row();
        assert!(matches!(
            page.on_key(KeyCode::Enter, KeyModifiers::NONE),
            Some(Decision::Save)
        ));
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
        assert!(rendered.contains("Dictation — page 7/7"));
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
            page.on_click(at(&page, "Download and continue")),
            Some(Decision::Save)
        ));
    }
}
