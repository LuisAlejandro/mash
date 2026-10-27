use crate::provider_page::write_private;
use crate::wizard_style;
use ratatui::{
    crossterm::event::{KeyCode, KeyModifiers},
    layout::{Constraint, Layout},
    text::{Line, Span},
    Frame,
};
use std::path::Path;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Field {
    Programming,
    Back,
    Save,
}

// Tab order; an index here is also the field's mouse target id.
const FIELDS: [Field; 3] = [Field::Programming, Field::Back, Field::Save];

pub enum Decision {
    Back,
    Cancel,
    Save,
}

pub struct SkillsPage {
    programming: bool,
    focus: Field,
}

impl SkillsPage {
    pub fn new() -> Self {
        Self {
            programming: true,
            focus: Field::Programming,
        }
    }

    pub fn programming(&self) -> bool {
        self.programming
    }

    // Set only after all wizard pages are complete. Before this file exists,
    // launchers cannot know the choice and must seed no optional suite.
    pub fn save_selection(&self, root: &Path) -> Result<(), String> {
        write_private(
            &root.join("setup/skills-choice"),
            &format!("programming={}\n", self.programming),
        )
    }

    /// Click target `index` into `FIELDS`: focus it; the toggle flips and the
    /// buttons act like Enter.
    pub fn on_click(&mut self, index: usize) -> Option<Decision> {
        self.focus = *FIELDS.get(index)?;
        match self.focus {
            Field::Programming | Field::Back | Field::Save => {
                self.on_key(KeyCode::Enter, KeyModifiers::NONE)
            }
        }
    }

    fn move_focus(&mut self, direction: isize) {
        let current = FIELDS
            .iter()
            .position(|field| *field == self.focus)
            .unwrap_or(0);
        self.focus = FIELDS[wizard_style::focus_step(current, FIELDS.len(), direction, true)];
    }

    pub fn on_key(&mut self, code: KeyCode, modifiers: KeyModifiers) -> Option<Decision> {
        if modifiers.contains(KeyModifiers::CONTROL) && code == KeyCode::Char('c') {
            return Some(Decision::Cancel);
        }
        match code {
            KeyCode::Esc => Some(Decision::Cancel),
            KeyCode::Tab | KeyCode::Down => {
                self.move_focus(1);
                None
            }
            KeyCode::BackTab | KeyCode::Up => {
                self.move_focus(-1);
                None
            }
            KeyCode::Enter => match self.focus {
                Field::Back => Some(Decision::Back),
                Field::Save => Some(Decision::Save),
                Field::Programming => {
                    self.programming = !self.programming;
                    None
                }
            },
            KeyCode::Char(' ') if matches!(self.focus, Field::Programming) => {
                self.programming = !self.programming;
                None
            }
            _ => None,
        }
    }

    pub fn draw(&self, frame: &mut Frame) {
        let parts = Layout::vertical([
            Constraint::Length(3),
            Constraint::Min(8),
            Constraint::Length(3),
        ])
        .split(wizard_style::page_area(frame, Some(2)));
        wizard_style::header(frame, parts[0], "Skills — page 3/5");
        let id = |field| FIELDS.iter().position(|f| *f == field);
        let lines: Vec<(Line<'static>, Option<usize>)> = vec![
            (
                wizard_style::checkbox(
                    self.focus == Field::Programming,
                    "Install Programming Skills (includes Hindsight)",
                    self.programming,
                ),
                id(Field::Programming),
            ),
            (Line::from(""), None),
            (
                Line::from(
                    "Brainstorm, plan, work, QA and release workflows for Pi, with local memory.",
                ),
                None,
            ),
            (
                Line::from(
                    "    Space or click toggles. Mash's terminal, editor and agent are unaffected.",
                ),
                None,
            ),
        ];
        let body = wizard_style::section(frame, parts[1], "Optional skills");
        wizard_style::render_form(frame, body, lines, true);
        wizard_style::render_buttons(
            frame,
            parts[2],
            &[
                (
                    wizard_style::button(self.focus == Field::Back, " Back "),
                    id(Field::Back),
                ),
                (Span::raw("    "), None),
                (
                    wizard_style::button(self.focus == Field::Save, " Save and continue "),
                    id(Field::Save),
                ),
            ],
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        os::unix::fs::PermissionsExt,
        sync::atomic::{AtomicU64, Ordering},
    };
    static ID: AtomicU64 = AtomicU64::new(0);

    fn fixture() -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!(
            "mash-skills-test-{}-{}",
            std::process::id(),
            ID.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(root.join("setup")).unwrap();
        root
    }

    #[test]
    fn programming_defaults_on_and_writes_the_choice() {
        let root = fixture();
        let page = SkillsPage::new();
        assert!(page.programming());
        page.save_selection(&root).unwrap();
        assert_eq!(
            fs::read_to_string(root.join("setup/skills-choice")).unwrap(),
            "programming=true\n"
        );
        let mode = fs::metadata(root.join("setup/skills-choice"))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o077, 0, "the choice file stays private");
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn the_suite_can_be_disabled_from_the_keyboard() {
        let root = fixture();
        let mut page = SkillsPage::new();
        page.on_key(KeyCode::Char(' '), KeyModifiers::NONE);
        assert!(!page.programming());
        page.save_selection(&root).unwrap();
        assert_eq!(
            fs::read_to_string(root.join("setup/skills-choice")).unwrap(),
            "programming=false\n"
        );
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn clicks_focus_the_toggle_and_press_buttons() {
        let mut page = SkillsPage::new();
        assert!(page.on_click(0).is_none());
        assert!(!page.programming(), "clicking the checkbox toggles it");
        assert!(matches!(page.on_click(1), Some(Decision::Back)));
        assert!(matches!(page.on_click(2), Some(Decision::Save)));
        assert!(page.on_click(9).is_none(), "unknown ids are ignored");
    }

    #[test]
    fn tab_wraps_through_every_field() {
        let mut page = SkillsPage::new();
        for _ in 0..FIELDS.len() {
            page.on_key(KeyCode::Tab, KeyModifiers::NONE);
        }
        assert!(
            page.focus == Field::Programming,
            "focus returns to the first field"
        );
    }

    #[test]
    fn escape_and_ctrl_c_cancel() {
        let mut page = SkillsPage::new();
        assert!(matches!(
            page.on_key(KeyCode::Esc, KeyModifiers::NONE),
            Some(Decision::Cancel)
        ));
        assert!(matches!(
            page.on_key(KeyCode::Char('c'), KeyModifiers::CONTROL),
            Some(Decision::Cancel)
        ));
    }
}
