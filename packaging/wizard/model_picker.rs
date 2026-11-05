//! Searchable local-catalog picker. Identity is never parsed from its label.
use crate::i18n;
use crate::{pi_models::Model, wizard_style};
use ratatui::{
    crossterm::event::{KeyCode, KeyModifiers},
    layout::{Constraint, Layout, Rect},
    text::{Line, Span},
    widgets::Paragraph,
    Frame,
};

pub enum Action {
    Choose(Model),
    Manual,
    Back,
    Cancel,
}

pub struct ModelPicker {
    models: Vec<Model>,
    filter: String,
    selected: usize,
    focus: usize,
}

impl ModelPicker {
    pub fn new(
        mut models: Vec<Model>,
        preferred: &str,
        current: Option<&(String, String)>,
    ) -> Self {
        let subset: Vec<_> = models
            .iter()
            .filter(|m| m.provider == preferred)
            .cloned()
            .collect();
        if !subset.is_empty() {
            models = subset;
        }
        let selected = current
            .and_then(|(p, id)| models.iter().position(|m| &m.provider == p && &m.id == id))
            .unwrap_or(0);
        Self {
            models,
            filter: String::new(),
            selected,
            focus: 0,
        }
    }

    fn matching(&self) -> Vec<usize> {
        let needle = self.filter.to_lowercase();
        self.models
            .iter()
            .enumerate()
            .filter(|(_, model)| {
                format!("{} {} {}", model.provider, model.id, model.name)
                    .to_lowercase()
                    .contains(&needle)
            })
            .map(|(index, _)| index)
            .chain(std::iter::once(self.models.len()))
            .collect()
    }

    fn choose(&self) -> Action {
        self.models
            .get(self.selected)
            .cloned()
            .map_or(Action::Manual, Action::Choose)
    }

    pub fn on_click(&mut self, id: usize) -> Option<Action> {
        if id <= self.models.len() {
            self.selected = id;
            return Some(self.choose());
        }
        match id - self.models.len() {
            1 => Some(Action::Back),
            2 => Some(self.choose()),
            3 => {
                self.focus = 0;
                None
            }
            _ => None,
        }
    }

    pub fn on_key(&mut self, code: KeyCode, modifiers: KeyModifiers) -> Option<Action> {
        if code == KeyCode::Char('c') && modifiers.contains(KeyModifiers::CONTROL) {
            return Some(Action::Cancel);
        }
        match code {
            KeyCode::Esc => return Some(Action::Back),
            KeyCode::Tab | KeyCode::BackTab => {
                self.focus = wizard_style::focus_step(
                    self.focus,
                    3,
                    if code == KeyCode::Tab { 1 } else { -1 },
                    true,
                );
            }
            KeyCode::Enter => {
                return Some(match self.focus {
                    1 => Action::Back,
                    _ => self.choose(),
                })
            }
            KeyCode::Up | KeyCode::Down if self.focus == 0 => {
                let matches = self.matching();
                let at = matches
                    .iter()
                    .position(|id| *id == self.selected)
                    .unwrap_or(0);
                self.selected = matches[wizard_style::focus_step(
                    at,
                    matches.len(),
                    if code == KeyCode::Up { -1 } else { 1 },
                    false,
                )];
            }
            KeyCode::Home if self.focus == 0 => self.selected = self.matching()[0],
            KeyCode::End if self.focus == 0 => self.selected = self.models.len(),
            KeyCode::Backspace if self.focus == 0 => {
                self.filter.pop();
                self.refilter();
            }
            KeyCode::Char(c)
                if self.focus == 0
                    && !modifiers.contains(KeyModifiers::CONTROL)
                    && !c.is_control() =>
            {
                self.filter.push(c);
                self.refilter();
            }
            _ => {}
        }
        None
    }

    fn refilter(&mut self) {
        let matches = self.matching();
        if !matches.contains(&self.selected) {
            self.selected = matches[0];
        }
    }

    pub fn draw(&self, frame: &mut Frame) {
        self.draw_for(
            frame,
            &i18n::t("wizard.page.model_provider"),
            2,
            &i18n::t("wizard.model.local_catalog"),
        );
    }

    pub fn draw_for(&self, frame: &mut Frame, title: &str, page: usize, note: &str) {
        let parts = Layout::vertical([
            Constraint::Length(3),
            Constraint::Length(3),
            Constraint::Min(3),
            Constraint::Length(3),
        ])
        .split(wizard_style::page_area(frame, Some(page)));
        wizard_style::header(frame, parts[0], &wizard_style::page_title(title, page));
        let filter = wizard_style::section(frame, parts[1], note);
        wizard_style::render_form(
            frame,
            filter,
            vec![(
                wizard_style::text_field(
                    self.focus == 0,
                    &i18n::t("wizard.model.filter"),
                    self.filter.clone(),
                ),
                Some(self.models.len() + 3),
            )],
            false,
        );
        let body = wizard_style::section(frame, parts[2], &i18n::t("wizard.model.choose"));
        let matches: Vec<_> = self
            .matching()
            .into_iter()
            .filter(|id| *id < self.models.len())
            .collect();
        let count = body.height.saturating_sub(1) as usize;
        let cursor = matches
            .iter()
            .position(|id| *id == self.selected)
            .unwrap_or(matches.len());
        let start = cursor
            .saturating_sub(count.saturating_sub(1))
            .min(matches.len().saturating_sub(count));
        for (offset, id) in matches.into_iter().skip(start).take(count).enumerate() {
            let model = &self.models[id];
            let row = Rect::new(body.x, body.y + offset as u16, body.width, 1);
            wizard_style::target(row, id);
            let text = Line::from(format!("{} / {}", model.provider, model.id));
            frame.render_widget(
                Paragraph::new(text).style(if self.focus == 0 && self.selected == id {
                    wizard_style::selected()
                } else {
                    ratatui::style::Style::default()
                }),
                row,
            );
        }
        if body.height > 0 {
            let row = Rect::new(body.x, body.bottom() - 1, body.width, 1);
            wizard_style::target(row, self.models.len());
            frame.render_widget(
                Paragraph::new(i18n::t("wizard.model.enter_manual")).style(
                    if self.selected == self.models.len() {
                        wizard_style::selected()
                    } else {
                        ratatui::style::Style::default()
                    },
                ),
                row,
            );
        }
        wizard_style::render_buttons(
            frame,
            parts[3],
            &[
                (
                    wizard_style::button(
                        self.focus == 1,
                        &format!(" {} ", i18n::t("wizard.tools.back")),
                    ),
                    Some(self.models.len() + 1),
                ),
                (Span::raw("    "), None),
                (
                    wizard_style::button(
                        self.focus == 2,
                        &format!(" {} ", i18n::t("wizard.model.use_model")),
                    ),
                    Some(self.models.len() + 2),
                ),
            ],
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn model(provider: &str, id: &str) -> Model {
        Model {
            provider: provider.into(),
            id: id.into(),
            name: id.into(),
        }
    }

    #[test]
    fn preferred_provider_filters_with_full_catalog_fallback() {
        let rows = vec![model("openai", "a"), model("anthropic", "namespace/a")];
        let preferred = ModelPicker::new(rows.clone(), "openai", None);
        assert_eq!(preferred.models.len(), 1);
        let mut fallback = ModelPicker::new(rows, "missing", None);
        fallback.on_key(KeyCode::Down, KeyModifiers::NONE);
        assert!(
            matches!(fallback.on_key(KeyCode::Enter, KeyModifiers::NONE), Some(Action::Choose(Model {provider, id, ..})) if provider == "anthropic" && id == "namespace/a")
        );
    }

    #[test]
    fn filter_never_hides_manual_or_back_and_rendering_works_at_both_sizes() {
        let mut page = ModelPicker::new(vec![model("openai", "model")], "openai", None);
        page.on_key(KeyCode::Char('z'), KeyModifiers::NONE);
        assert!(matches!(
            page.on_key(KeyCode::Enter, KeyModifiers::NONE),
            Some(Action::Manual)
        ));
        for (width, height) in [(80, 24), (100, 30)] {
            let mut terminal =
                ratatui::Terminal::new(ratatui::backend::TestBackend::new(width, height)).unwrap();
            terminal.draw(|frame| page.draw(frame)).unwrap();
            crate::wizard_style::tests::find(terminal.backend().buffer(), "Enter manually");
            crate::wizard_style::tests::find(terminal.backend().buffer(), "Back");
        }
    }
}
