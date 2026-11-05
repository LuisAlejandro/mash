//! First wizard screen: choose the UI language before any setup choices.
use crate::{i18n, wizard_style};
use ratatui::{
    crossterm::event::{KeyCode, KeyModifiers},
    layout::{Constraint, Layout},
    style::Style,
    text::{Line, Span},
    widgets::Block,
    Frame,
};
use serde_json::Value;
use std::{path::Path, sync::OnceLock};

const LANGUAGES_JSON: &str = include_str!("../i18n/languages.json");

#[derive(Clone)]
struct Language {
    code: String,
    name: String,
    voice: String,
}

fn languages() -> &'static [Language] {
    static LANGUAGES: OnceLock<Vec<Language>> = OnceLock::new();
    LANGUAGES.get_or_init(|| {
        serde_json::from_str::<Value>(LANGUAGES_JSON)
            .expect("languages.json is valid JSON")
            .as_array()
            .expect("languages.json has a language list")
            .iter()
            .map(|row| Language {
                code: row["code"].as_str().unwrap_or("en").to_string(),
                name: row["name"].as_str().unwrap_or("English").to_string(),
                voice: row["voice"].as_str().unwrap_or("en-US").to_string(),
            })
            .collect()
    })
}

pub fn voice_language(code: &str) -> Option<&'static str> {
    languages()
        .iter()
        .find(|language| language.code == code)
        .map(|language| language.voice.as_str())
}

pub enum Decision {
    Continue,
    Cancel,
}

pub struct LanguagePage {
    selected: usize,
    focus: usize,
}

impl LanguagePage {
    pub fn new() -> Self {
        i18n::set_language("en");
        let selected = languages()
            .iter()
            .position(|language| language.code == "en")
            .expect("English is listed in languages.json");
        Self {
            selected,
            focus: selected,
        }
    }

    fn continue_id(&self) -> usize {
        languages().len()
    }

    fn select(&mut self, index: usize) {
        if index < languages().len() {
            self.selected = index;
            self.focus = index;
            i18n::set_language(&languages()[index].code);
        }
    }

    pub fn save_selection(root: &Path, code: &str) -> Result<(), String> {
        if !languages().iter().any(|language| language.code == code) {
            return Err(format!("unsupported setup language: {code}"));
        }
        crate::provider_page::write_private(
            &root.join("setup/language"),
            &format!("language={code}\n"),
        )
    }

    pub fn on_click(&mut self, id: usize) -> Option<Decision> {
        if id == self.continue_id() {
            return Some(Decision::Continue);
        }
        self.select(id);
        None
    }

    pub fn on_key(&mut self, code: KeyCode, modifiers: KeyModifiers) -> Option<Decision> {
        if modifiers.contains(KeyModifiers::CONTROL) && code == KeyCode::Char('c') {
            return Some(Decision::Cancel);
        }
        match code {
            KeyCode::Esc => Some(Decision::Cancel),
            KeyCode::Up | KeyCode::Char('k') => {
                let current = if self.focus == self.continue_id() {
                    self.selected
                } else {
                    self.focus
                };
                self.select(wizard_style::focus_step(
                    current,
                    self.continue_id(),
                    -1,
                    true,
                ));
                None
            }
            KeyCode::Down | KeyCode::Char('j') => {
                let current = if self.focus == self.continue_id() {
                    self.selected
                } else {
                    self.focus
                };
                self.select(wizard_style::focus_step(
                    current,
                    self.continue_id(),
                    1,
                    true,
                ));
                None
            }
            KeyCode::Tab => {
                self.focus = self.continue_id();
                None
            }
            KeyCode::BackTab => {
                self.focus = self.selected;
                None
            }
            KeyCode::Enter | KeyCode::Char(' ') => Some(Decision::Continue),
            _ => None,
        }
    }

    pub fn draw(&self, frame: &mut Frame) {
        wizard_style::clear_targets();
        frame.render_widget(
            Block::default().style(
                Style::default()
                    .fg(wizard_style::TEXT)
                    .bg(wizard_style::PANEL),
            ),
            frame.area(),
        );
        let parts = Layout::vertical([
            Constraint::Length(3),
            Constraint::Min(1),
            Constraint::Length(3),
        ])
        .split(frame.area());
        let title = i18n::t("wizard.language.title");
        wizard_style::header(frame, parts[0], &title);

        let body = wizard_style::section(frame, parts[1], &i18n::t("wizard.language.prompt"));
        let count = languages().len();
        let visible = body.height.max(1) as usize;
        let start = self.selected.saturating_sub(visible.saturating_sub(1));
        let start = start.min(count.saturating_sub(visible));
        let lines = languages()
            .iter()
            .enumerate()
            .skip(start)
            .take(visible)
            .map(|(index, language)| {
                let focused = self.focus == index;
                let label = format!(
                    "({}) {}",
                    if self.selected == index { "*" } else { " " },
                    language.name
                );
                (
                    Line::from(Span::raw(label)).style(if focused {
                        wizard_style::selected()
                    } else {
                        Style::default()
                    }),
                    Some(index),
                )
            })
            .collect();
        wizard_style::render_form(frame, body, lines, false);
        wizard_style::render_buttons(
            frame,
            parts[2],
            &[(
                wizard_style::button(
                    self.focus == self.continue_id(),
                    &format!(" {} ", i18n::t("wizard.language.continue")),
                ),
                Some(self.continue_id()),
            )],
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_selection_is_english_and_saving_is_explicit() {
        LanguagePage::new();
        assert_eq!(i18n::language(), "en");
        assert_eq!(voice_language("es"), Some("es-US"));
        assert!(languages().iter().any(|language| language.name == "日本語"));

        let directory = crate::test_support::TempDir::new("language-choice");
        assert!(!directory.join("setup/language").exists());
        LanguagePage::save_selection(&directory, "es").unwrap();
        assert_eq!(
            std::fs::read_to_string(directory.join("setup/language")).unwrap(),
            "language=es\n"
        );
        assert!(LanguagePage::save_selection(&directory, "unknown").is_err());
    }
}
