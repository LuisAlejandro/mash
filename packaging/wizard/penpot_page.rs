use crate::provider_page::write_private;
use ratatui::{
    crossterm::event::{KeyCode, KeyModifiers},
    layout::{Alignment, Constraint, Layout},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph, Wrap},
    Frame,
};
use std::{fs, path::Path};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Field {
    Email,
    Password,
    Confirm,
    Back,
    Save,
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
    focus: Field,
    error: Option<String>,
}

impl PenpotPage {
    pub fn new(email: String) -> Self {
        Self {
            email,
            password: String::new(),
            confirm: String::new(),
            focus: Field::Email,
            error: None,
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

    fn move_focus(&mut self, direction: isize) {
        const FIELDS: [Field; 5] = [
            Field::Email,
            Field::Password,
            Field::Confirm,
            Field::Back,
            Field::Save,
        ];
        let current = FIELDS
            .iter()
            .position(|field| *field == self.focus)
            .unwrap_or(0);
        self.focus =
            FIELDS[(current as isize + direction).rem_euclid(FIELDS.len() as isize) as usize];
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
                Field::Confirm => {
                    self.focus = Field::Save;
                    None
                }
                _ => {
                    self.move_focus(1);
                    None
                }
            },
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

    pub fn show_error(&mut self, error: String) {
        self.error = Some(error);
    }

    pub fn save(&mut self, root: &Path) -> Result<(), String> {
        if !self.validate() {
            return Err(self.error.clone().unwrap_or_default());
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
        write_private(&path, &updated)
    }

    pub fn draw(&self, frame: &mut Frame) {
        let parts = Layout::vertical([
            Constraint::Length(3),
            Constraint::Min(8),
            Constraint::Length(3),
        ])
        .split(frame.area());
        frame.render_widget(
            Paragraph::new("Local Penpot account — page 3/3")
                .alignment(Alignment::Center)
                .block(Block::default().borders(Borders::ALL)),
            parts[0],
        );
        let mut lines = vec![
            Line::from("For Mash's Penpot at localhost:9001; not a penpot.app account."),
            Line::from("If Docker is unavailable, your private details are saved for later setup."),
            Line::from(""),
        ];
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
                "••••••"
            } else {
                value
            };
            lines.push(Line::from(vec![
                Span::styled(
                    if self.focus == field { "> " } else { "  " },
                    Style::default().fg(Color::Yellow),
                ),
                Span::styled(
                    format!("{label}: "),
                    Style::default().add_modifier(Modifier::BOLD),
                ),
                Span::raw(shown.to_string()),
                Span::styled(
                    if self.focus == field { "_" } else { "" },
                    Style::default().fg(Color::Yellow),
                ),
            ]));
        }
        if let Some(error) = &self.error {
            lines.push(Line::from(""));
            lines.push(Line::from(Span::styled(
                error.clone(),
                Style::default().fg(Color::Red),
            )));
        }
        frame.render_widget(
            Paragraph::new(lines)
                .wrap(Wrap { trim: true })
                .block(Block::default().borders(Borders::ALL).title("Account")),
            parts[1],
        );
        let button = |field, label| {
            let style = if self.focus == field {
                Style::default().fg(Color::Black).bg(Color::Yellow)
            } else {
                Style::default()
            };
            Span::styled(label, style.add_modifier(Modifier::BOLD))
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                button(Field::Back, " Back "),
                Span::raw("    "),
                button(Field::Save, " Save and install "),
            ]))
            .alignment(Alignment::Center)
            .block(Block::default().borders(Borders::ALL)),
            parts[2],
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
    }
}
