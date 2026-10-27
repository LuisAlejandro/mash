use crate::provider_page::{masked, write_private};
use crate::wizard_style;
use ratatui::{
    crossterm::event::{KeyCode, KeyModifiers},
    layout::{Constraint, Layout},
    style::Style,
    text::{Line, Span},
    Frame,
};
use std::{fs, path::Path};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Field {
    Programming,
    Design,
    Email,
    Password,
    Confirm,
    Autostart,
    Back,
    Save,
}

// Tab order; an index here is also the field's mouse target id.
const FIELDS: [Field; 8] = [
    Field::Programming,
    Field::Design,
    Field::Email,
    Field::Password,
    Field::Confirm,
    Field::Autostart,
    Field::Back,
    Field::Save,
];

// Opt-in switch for starting the design stack with Mash. Presence is the
// setting, so the launcher reads it without parsing anything.
fn autostart_marker(root: &Path) -> std::path::PathBuf {
    root.join("config/mash/design-autostart")
}

pub enum Decision {
    Back,
    Cancel,
    Save,
}

pub struct PenpotPage {
    email: String,
    password: String,
    confirm: String,
    programming: bool,
    design: bool,
    autostart: bool,
    focus: Field,
    error: Option<String>,
}

impl PenpotPage {
    pub fn new(email: String) -> Self {
        Self {
            email,
            password: String::new(),
            confirm: String::new(),
            programming: true,
            design: true,
            autostart: false,
            focus: Field::Programming,
            error: None,
        }
    }

    pub fn programming(&self) -> bool {
        self.programming
    }

    pub fn design(&self) -> bool {
        self.design
    }

    // Set only after all wizard pages are complete. Before this file exists,
    // launchers cannot know the choice and must seed neither optional suite.
    pub fn save_selection(&self, root: &Path) -> Result<(), String> {
        write_private(
            &root.join("setup/skills-choice"),
            &format!("programming={}\ndesign={}\n", self.programming, self.design),
        )
    }

    // The marker file is the setting: present starts the stack, absent does not.
    // Read once at startup so a page reopened later shows what is in effect.
    pub fn load_autostart(&mut self, root: &Path) {
        self.autostart = autostart_marker(root).is_file();
    }

    fn save_autostart(&self, root: &Path) -> Result<(), String> {
        let marker = autostart_marker(root);
        if self.design && self.autostart {
            if marker.is_symlink() {
                return Err("Design autostart must stay inside Mash".into());
            }
            let dir = marker.parent().ok_or("design autostart path is invalid")?;
            fs::create_dir_all(dir).map_err(|e| e.to_string())?;
            fs::write(&marker, "1\n").map_err(|e| e.to_string())
        } else {
            match fs::remove_file(&marker) {
                Ok(()) => Ok(()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(e) => Err(e.to_string()),
            }
        }
    }

    fn text_mut(&mut self) -> Option<&mut String> {
        match self.focus {
            Field::Email => Some(&mut self.email),
            Field::Password => Some(&mut self.password),
            Field::Confirm => Some(&mut self.confirm),
            _ => None,
        }
    }

    /// Click target `index` into `FIELDS`: focus it; the toggle flips and the
    /// buttons act like Enter.
    pub fn on_click(&mut self, index: usize) -> Option<Decision> {
        self.focus = *FIELDS.get(index)?;
        match self.focus {
            Field::Programming | Field::Design | Field::Autostart | Field::Back | Field::Save => {
                self.on_key(KeyCode::Enter, KeyModifiers::NONE)
            }
            _ => None,
        }
    }

    fn fields(&self) -> Vec<Field> {
        FIELDS
            .iter()
            .copied()
            .filter(|field| {
                self.design
                    || !matches!(
                        field,
                        Field::Email | Field::Password | Field::Confirm | Field::Autostart
                    )
            })
            .collect()
    }

    fn move_focus(&mut self, direction: isize) {
        let fields = self.fields();
        let current = fields
            .iter()
            .position(|field| *field == self.focus)
            .unwrap_or(0);
        self.focus = fields[wizard_style::focus_step(current, fields.len(), direction, true)];
    }

    fn toggle(&mut self) {
        match self.focus {
            Field::Programming => self.programming = !self.programming,
            Field::Design => {
                self.design = !self.design;
                if !self.design {
                    self.autostart = false;
                }
            }
            Field::Autostart if self.design => self.autostart = !self.autostart,
            _ => {}
        }
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
                Field::Programming | Field::Design | Field::Autostart => {
                    self.toggle();
                    None
                }
                Field::Confirm => {
                    self.focus = Field::Save;
                    None
                }
                _ => {
                    self.move_focus(1);
                    None
                }
            },
            KeyCode::Char(' ')
                if matches!(
                    self.focus,
                    Field::Programming | Field::Design | Field::Autostart
                ) =>
            {
                self.toggle();
                None
            }
            KeyCode::Backspace => {
                if let Some(text) = self.text_mut() {
                    text.pop();
                }
                self.error = None;
                None
            }
            KeyCode::Char(c) if !modifiers.contains(KeyModifiers::CONTROL) => {
                if let Some(text) = self.text_mut() {
                    text.push(c);
                }
                self.error = None;
                None
            }
            _ => None,
        }
    }

    pub fn validate(&mut self) -> bool {
        if !self.design {
            self.error = None;
            return true;
        }
        let email = self.email.trim();
        let valid_email = email.split_once('@').is_some_and(|(local, domain)| {
            !local.is_empty()
                && local
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || "._+-".contains(c))
                && domain.split('.').count() >= 2
                && domain.split('.').all(|part| !part.is_empty())
                && domain
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '.')
        });
        // ponytail: penpot.env uses raw KEY=VALUE lines; expand the accepted
        // charset only after the stack escapes and reads those values safely.
        self.error = if !valid_email {
            Some("Enter a local Penpot email like you@example.com".into())
        } else if self.password.len() < 8
            || !self
                .password
                .chars()
                .all(|c| c.is_ascii_graphic() && !matches!(c, '$' | '#' | '\\' | '\'' | '"' | '`'))
        {
            Some(
                "Use 8+ visible characters; password cannot contain $, #, quotes or backslashes"
                    .into(),
            )
        } else if self.password != self.confirm {
            Some("Penpot passwords do not match".into())
        } else {
            None
        };
        self.error.is_none()
    }

    pub fn save(&mut self, root: &Path) -> Result<(), String> {
        if !self.validate() {
            return Err(self.error.clone().unwrap_or_default());
        }
        if !self.design {
            return self.save_autostart(root);
        }
        let stack = root.join("local/share/mash/design");
        let path = stack.join("penpot.env");
        if path.is_symlink() {
            return Err("Penpot config must stay inside Mash".into());
        }
        let original = if path.is_file() {
            fs::read_to_string(&path).map_err(|e| e.to_string())?
        } else {
            fs::read_to_string(stack.join("penpot.env.example"))
                .map_err(|e| format!("Penpot config template is missing: {e}"))?
        };
        let old_value = |name: &str| {
            original
                .lines()
                .find_map(|line| line.strip_prefix(name))
                .unwrap_or("")
        };
        let same_account = old_value("PENPOT_LOCAL_EMAIL=") == self.email.trim()
            && old_value("PENPOT_LOCAL_PASSWORD=") == self.password;
        let mut lines: Vec<&str> = original
            .lines()
            .filter(|line| {
                !line.starts_with("PENPOT_LOCAL_EMAIL=")
                    && !line.starts_with("PENPOT_LOCAL_PASSWORD=")
                    && (same_account || !line.starts_with("PENPOT_ACCESS_TOKEN="))
            })
            .collect();
        lines.push("");
        let mut updated = lines.join("\n");
        updated.push_str(&format!(
            "\nPENPOT_LOCAL_EMAIL={}\nPENPOT_LOCAL_PASSWORD={}\n",
            self.email.trim(),
            self.password
        ));
        if !same_account {
            updated.push_str("PENPOT_ACCESS_TOKEN=\n");
        }
        write_private(&path, &updated)?;
        self.save_autostart(root)
    }

    pub fn draw(&self, frame: &mut Frame) {
        let parts = Layout::vertical([
            Constraint::Length(3),
            Constraint::Min(8),
            Constraint::Length(3),
        ])
        .split(wizard_style::page_area(frame, Some(2)));
        wizard_style::header(frame, parts[0], "Skills & Penpot — page 3/5");
        let id = |field| FIELDS.iter().position(|f| *f == field);
        let checkbox = |field, label: &str, checked| {
            wizard_style::checkbox(self.focus == field, label, checked)
        };
        let mut lines: Vec<(Line<'static>, Option<usize>)> = vec![
            (
                checkbox(
                    Field::Programming,
                    "Install Programming Skills (includes Hindsight)",
                    self.programming,
                ),
                id(Field::Programming),
            ),
            (
                checkbox(
                    Field::Design,
                    "Install Design Skills (Penpot + OpenDesign)",
                    self.design,
                ),
                id(Field::Design),
            ),
            (Line::from(""), None),
        ];
        if self.design {
            lines.push((
                Line::from("Local Penpot account at localhost:9001; not penpot.app."),
                None,
            ));
            lines.push((
                Line::from("If Docker is unavailable, credentials are saved for later setup."),
                None,
            ));
            lines.push((Line::from(""), None));
            for (field, label, value, secret) in [
                (Field::Email, "Email", self.email.as_str(), false),
                (Field::Password, "Password", self.password.as_str(), true),
                (
                    Field::Confirm,
                    "Confirm password",
                    self.confirm.as_str(),
                    true,
                ),
            ] {
                let shown = if secret && !value.is_empty() {
                    masked(value)
                } else {
                    value.to_string()
                };
                lines.push((
                    wizard_style::text_field(self.focus == field, label, shown),
                    id(field),
                ));
            }
            if let Some(error) = &self.error {
                lines.push((Line::from(""), None));
                lines.push((
                    Line::from(Span::styled(
                        error.clone(),
                        Style::default().fg(wizard_style::RED),
                    )),
                    None,
                ));
            }
            lines.push((Line::from(""), None));
            lines.push((
                checkbox(
                    Field::Autostart,
                    "Start the design stack when Mash opens",
                    self.autostart,
                ),
                id(Field::Autostart),
            ));
            lines.push((Line::from(
            "    Space or click toggles. Penpot + OpenDesign start in the background; skipped while Docker is stopped.",
        ), None));
        } else {
            lines.push((
                Line::from("No Penpot account or mds is installed when Design Skills are off."),
                None,
            ));
        }
        let body = wizard_style::section(frame, parts[1], "Skills & account");
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
        os::unix::fs::PermissionsExt,
        sync::atomic::{AtomicU64, Ordering},
    };
    static ID: AtomicU64 = AtomicU64::new(0);

    fn fixture() -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!(
            "mash-penpot-test-{}-{}",
            std::process::id(),
            ID.fetch_add(1, Ordering::Relaxed)
        ));
        let stack = root.join("local/share/mash/design");
        fs::create_dir_all(&stack).unwrap();
        fs::write(
            stack.join("penpot.env.example"),
            "PENPOT_VERSION=2.16.2\nPENPOT_LOCAL_EMAIL=\nPENPOT_LOCAL_PASSWORD=\n",
        )
        .unwrap();
        root
    }

    #[test]
    fn disabling_design_skips_credentials_and_clears_autostart() {
        let root = fixture();
        fs::remove_file(root.join("local/share/mash/design/penpot.env.example")).unwrap();
        let mut page = PenpotPage::new(String::new());
        page.focus = Field::Autostart;
        page.on_key(KeyCode::Enter, KeyModifiers::NONE);
        assert!(page.autostart);
        page.focus = Field::Design;
        page.on_key(KeyCode::Char(' '), KeyModifiers::NONE);
        assert!(!page.design);
        assert!(!page.autostart);
        assert!(page.fields() == [Field::Programming, Field::Design, Field::Back, Field::Save]);
        assert!(page.validate());
        page.save_selection(&root).unwrap();
        page.save(&root).unwrap();
        assert!(!root.join("local/share/mash/design/penpot.env").exists());
        assert!(!autostart_marker(&root).exists());
        assert_eq!(
            fs::read_to_string(root.join("setup/skills-choice")).unwrap(),
            "programming=true\ndesign=false\n"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn both_suites_can_be_disabled_from_the_keyboard() {
        let mut page = PenpotPage::new(String::new());
        page.on_key(KeyCode::Char(' '), KeyModifiers::NONE);
        assert!(!page.programming());
        page.on_key(KeyCode::Tab, KeyModifiers::NONE);
        page.on_key(KeyCode::Enter, KeyModifiers::NONE);
        assert!(!page.design());
        page.on_key(KeyCode::Tab, KeyModifiers::NONE);
        assert!(matches!(
            page.on_key(KeyCode::Enter, KeyModifiers::NONE),
            Some(Decision::Back)
        ));
    }

    #[test]
    fn autostart_choice_is_written_and_can_be_turned_off() {
        let root = fixture();
        let marker = autostart_marker(&root);
        let mut page = PenpotPage::new("dev@example.com".into());
        page.password = "safe-password-12".into();
        page.confirm = page.password.clone();

        // Off is the default, so a first save writes no marker at all.
        page.save(&root).unwrap();
        assert!(!marker.exists(), "a fresh account must not opt in");

        // The toggle, once on, survives a reopened wizard page.
        page.autostart = true;
        page.save(&root).unwrap();
        assert_eq!(fs::read_to_string(&marker).unwrap(), "1\n");
        let mut reopened = PenpotPage::new("dev@example.com".into());
        reopened.load_autostart(&root);
        assert!(reopened.autostart);

        // Turning it off removes the marker instead of writing "off".
        reopened.autostart = false;
        reopened.password = "safe-password-12".into();
        reopened.confirm = reopened.password.clone();
        reopened.save(&root).unwrap();
        assert!(!marker.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn autostart_refuses_a_symlink() {
        let root = fixture();
        let marker = autostart_marker(&root);
        fs::create_dir_all(marker.parent().unwrap()).unwrap();
        let outside = root.join("outside");
        fs::write(&outside, "keep\n").unwrap();
        std::os::unix::fs::symlink(&outside, &marker).unwrap();
        let mut page = PenpotPage::new("dev@example.com".into());
        page.password = "safe-password-12".into();
        page.confirm = page.password.clone();
        page.autostart = true;
        assert!(page.save(&root).is_err());
        assert_eq!(fs::read_to_string(outside).unwrap(), "keep\n");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn space_and_enter_toggle_autostart_without_typing() {
        let mut page = PenpotPage::new("dev@example.com".into());
        page.focus = Field::Autostart;
        assert!(page
            .on_key(KeyCode::Char(' '), KeyModifiers::NONE)
            .is_none());
        assert!(page.autostart);
        assert!(page.on_key(KeyCode::Enter, KeyModifiers::NONE).is_none());
        assert!(!page.autostart);
        // A letter elsewhere must not flip it; elsewhere it reaches the text field.
        page.focus = Field::Email;
        page.on_key(KeyCode::Char('x'), KeyModifiers::NONE);
        assert!(page.email.ends_with('x'));
        assert!(!page.autostart);
    }

    #[test]
    fn saves_private_credentials_and_preserves_stack_config() {
        let root = fixture();
        let mut page = PenpotPage::new("dev@example.com".into());
        page.password = "safe-password-12".into();
        page.confirm = page.password.clone();
        assert!(page.validate());
        page.save(&root).unwrap();
        let path = root.join("local/share/mash/design/penpot.env");
        let text = fs::read_to_string(&path).unwrap();
        assert!(text.contains("PENPOT_VERSION=2.16.2"));
        assert!(text.contains("PENPOT_LOCAL_EMAIL=dev@example.com"));
        assert!(text.contains("PENPOT_LOCAL_PASSWORD=safe-password-12"));
        assert_eq!(
            fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn changed_credentials_invalidate_a_prior_access_token() {
        let root = fixture();
        let path = root.join("local/share/mash/design/penpot.env");
        fs::write(&path, "PENPOT_LOCAL_EMAIL=old@example.com\nPENPOT_LOCAL_PASSWORD=old-password\nPENPOT_ACCESS_TOKEN=old-token\n").unwrap();
        let mut page = PenpotPage::new("new@example.com".into());
        page.password = "new-password-12".into();
        page.confirm = page.password.clone();
        page.save(&root).unwrap();
        let text = fs::read_to_string(&path).unwrap();
        assert!(text.contains("PENPOT_ACCESS_TOKEN=\n"));
        assert!(!text.contains("old-token"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn rejects_bad_password_before_writing() {
        let root = fixture();
        let mut page = PenpotPage::new("dev@example.com".into());
        page.password = "short".into();
        page.confirm = page.password.clone();
        assert!(!page.validate());
        page.password = "safe-password-12".into();
        page.confirm = "different-password".into();
        assert!(!page.validate());
        page.email = "dev@@example.com".into();
        page.confirm = page.password.clone();
        assert!(!page.validate());
        assert!(!root.join("local/share/mash/design/penpot.env").exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn enter_from_confirmation_reaches_save() {
        let mut page = PenpotPage::new("dev@example.com".into());
        page.focus = Field::Confirm;
        assert!(page.on_key(KeyCode::Enter, KeyModifiers::NONE).is_none());
        assert!(matches!(
            page.on_key(KeyCode::Enter, KeyModifiers::NONE),
            Some(Decision::Save)
        ));
    }

    #[test]
    fn masks_passwords_in_terminal() {
        let mut page = PenpotPage::new("dev@example.com".into());
        page.password = "fake-secret-12".into();
        page.confirm = page.password.clone();
        let mut terminal =
            ratatui::Terminal::new(ratatui::backend::TestBackend::new(90, 24)).unwrap();
        terminal.draw(|frame| page.draw(frame)).unwrap();
        let rendered = terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect::<String>();
        assert!(rendered.contains("••••••"));
        assert!(!rendered.contains("fake-secret-12"));
        // One dot per typed character: the length is visible, the value is not.
        // A fixed run of six dots made a typo indistinguishable from a good
        // entry, which is why the count is what the field shows.
        assert!(
            rendered.contains(&"•".repeat("fake-secret-12".chars().count())),
            "expected one dot per character, got: {rendered:?}"
        );
    }

    #[test]
    fn empty_passwords_show_no_dots() {
        let page = PenpotPage::new("dev@example.com".into());
        let mut terminal =
            ratatui::Terminal::new(ratatui::backend::TestBackend::new(90, 24)).unwrap();
        terminal.draw(|frame| page.draw(frame)).unwrap();
        let rendered = terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect::<String>();
        assert!(!rendered.contains('•'));
    }

    fn render(page: &PenpotPage) -> ratatui::buffer::Buffer {
        let mut terminal =
            ratatui::Terminal::new(ratatui::backend::TestBackend::new(120, 32)).unwrap();
        terminal.draw(|frame| page.draw(frame)).unwrap();
        terminal.backend().buffer().clone()
    }

    #[test]
    fn clicks_focus_fields_toggle_autostart_and_press_buttons() {
        use wizard_style::tests::{click, find};
        let mut page = PenpotPage::new(String::new());
        let at = |page: &PenpotPage, label| {
            let (x, y) = find(&render(page), label);
            wizard_style::clicked(&click(x, y)).expect("label is clickable")
        };
        let id = at(&page, "Confirm password");
        assert!(page.on_click(id).is_none());
        assert!(page.focus == Field::Confirm);
        let id = at(&page, "Start the design stack");
        let before = page.autostart;
        assert!(page.on_click(id).is_none());
        assert_ne!(page.autostart, before);
        let id = at(&page, "Back");
        assert!(matches!(page.on_click(id), Some(Decision::Back)));
        let id = at(&page, "Save and continue");
        assert!(matches!(page.on_click(id), Some(Decision::Save)));
    }
}
