use ratatui::{
    crossterm::event::{KeyCode, KeyModifiers},
    layout::{Alignment, Constraint, Layout},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph, Wrap},
    Frame,
};
use serde_json::{Map, Value};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    os::unix::fs::OpenOptionsExt,
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Choice {
    Keep,
    None,
    OpenAi,
    Anthropic,
    OpenRouter,
    Compatible,
}

const PI_CHOICES: &[Choice] = &[
    Choice::Keep,
    Choice::OpenAi,
    Choice::Anthropic,
    Choice::OpenRouter,
    Choice::Compatible,
];
const HINDSIGHT_CHOICES: &[Choice] = &[
    Choice::Keep,
    Choice::None,
    Choice::OpenAi,
    Choice::Anthropic,
    Choice::OpenRouter,
    Choice::Compatible,
];

impl Choice {
    fn label(self, pi: bool) -> &'static str {
        match self {
            Choice::Keep => "Keep existing / set up later",
            Choice::None => "None (no LLM)",
            Choice::OpenAi => "OpenAI",
            Choice::Anthropic => "Anthropic",
            Choice::OpenRouter => "OpenRouter",
            Choice::Compatible if pi => "OpenAI-compatible (Responses)",
            Choice::Compatible => "OpenAI-compatible (Chat Completions)",
        }
    }

    fn provider_id(self) -> &'static str {
        match self {
            Choice::OpenAi | Choice::Compatible => "openai",
            Choice::Anthropic => "anthropic",
            Choice::OpenRouter => "openrouter",
            Choice::None => "none",
            Choice::Keep => "",
        }
    }

    fn configured(self) -> bool {
        !matches!(self, Choice::Keep | Choice::None)
    }
}

#[derive(Default)]
struct Input {
    choice: Option<Choice>,
    id: String,
    url: String,
    model: String,
    key: String,
}

impl Input {
    fn choice(&self) -> Choice {
        self.choice.unwrap_or(Choice::Keep)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Field {
    PiProvider,
    PiId,
    PiUrl,
    PiModel,
    PiKey,
    HindsightProvider,
    HindsightUrl,
    HindsightModel,
    HindsightKey,
    Back,
    Save,
}

pub enum Decision {
    Back,
    Cancel,
    Save,
}

pub struct ProviderPage {
    pi: Input,
    hindsight: Input,
    focus: Field,
    error: Option<String>,
}

impl ProviderPage {
    pub fn new() -> Self {
        Self {
            pi: Input::default(),
            hindsight: Input::default(),
            focus: Field::PiProvider,
            error: None,
        }
    }

    fn fields(&self) -> Vec<Field> {
        let mut fields = vec![Field::PiProvider];
        if self.pi.choice() == Choice::Compatible {
            fields.extend([Field::PiId, Field::PiUrl]);
        }
        if self.pi.choice().configured() {
            fields.extend([Field::PiModel, Field::PiKey]);
        }
        fields.push(Field::HindsightProvider);
        if self.hindsight.choice() == Choice::Compatible {
            fields.push(Field::HindsightUrl);
        }
        if self.hindsight.choice().configured() {
            fields.extend([Field::HindsightModel, Field::HindsightKey]);
        }
        fields.extend([Field::Back, Field::Save]);
        fields
    }

    fn move_focus(&mut self, direction: isize) {
        let fields = self.fields();
        let current = fields
            .iter()
            .position(|field| *field == self.focus)
            .unwrap_or(0);
        self.focus =
            fields[(current as isize + direction).rem_euclid(fields.len() as isize) as usize];
    }

    fn cycle(&mut self, pi: bool, direction: isize) {
        let choices = if pi { PI_CHOICES } else { HINDSIGHT_CHOICES };
        let input = if pi {
            &mut self.pi
        } else {
            &mut self.hindsight
        };
        let current = choices
            .iter()
            .position(|choice| *choice == input.choice())
            .unwrap_or(0);
        let next =
            choices[(current as isize + direction).rem_euclid(choices.len() as isize) as usize];
        if next != input.choice() {
            input.choice = Some(next);
            input.model.clear();
            input.key.clear();
        }
    }

    fn text_mut(&mut self) -> Option<&mut String> {
        match self.focus {
            Field::PiId => Some(&mut self.pi.id),
            Field::PiUrl => Some(&mut self.pi.url),
            Field::PiModel => Some(&mut self.pi.model),
            Field::PiKey => Some(&mut self.pi.key),
            Field::HindsightUrl => Some(&mut self.hindsight.url),
            Field::HindsightModel => Some(&mut self.hindsight.model),
            Field::HindsightKey => Some(&mut self.hindsight.key),
            _ => None,
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
                _ => {
                    self.move_focus(1);
                    None
                }
            },
            KeyCode::Left | KeyCode::Right | KeyCode::Char(' ')
                if matches!(self.focus, Field::PiProvider | Field::HindsightProvider) =>
            {
                self.cycle(
                    self.focus == Field::PiProvider,
                    if code == KeyCode::Left { -1 } else { 1 },
                );
                self.error = None;
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
        let result =
            validate_input(&self.pi, true).and_then(|()| validate_input(&self.hindsight, false));
        self.error = result.err();
        self.error.is_none()
    }

    pub fn save(&self, root: &Path) -> Result<(), String> {
        validate_input(&self.pi, true)?;
        validate_input(&self.hindsight, false)?;
        if self.pi.choice().configured() {
            let id = if self.pi.choice() == Choice::Compatible {
                self.pi.id.trim().to_ascii_lowercase()
            } else {
                self.pi.choice().provider_id().into()
            };
            let agent = root.join("pi/agent");
            let mut settings = read_json_object(&agent.join("settings.json"))?;
            let models = if self.pi.choice() == Choice::Compatible {
                let mut models = read_json_object(&agent.join("models.json"))?;
                let providers = models
                    .entry("providers")
                    .or_insert_with(|| Value::Object(Map::new()))
                    .as_object_mut()
                    .ok_or("Pi models.json has an invalid providers object")?;
                providers.insert(
                    id.clone(),
                    serde_json::json!({
                        "baseUrl": self.pi.url.trim(),
                        "api": "openai-responses",
                        "models": [{"id": self.pi.model.trim()}]
                    }),
                );
                Some(models)
            } else {
                None
            };
            let mut auth = read_json_object(&agent.join("auth.json"))?;
            auth.insert(
                id.clone(),
                serde_json::json!({"type": "api_key", "key": self.pi.key.trim()}),
            );
            settings.insert("defaultProvider".into(), Value::String(id));
            settings.insert(
                "defaultModel".into(),
                Value::String(self.pi.model.trim().into()),
            );
            settings.insert(
                "defaultThinkingLevel".into(),
                Value::String("medium".into()),
            );

            save_json(&agent.join("auth.json"), &auth)?;
            if let Some(models) = models {
                save_json(&agent.join("models.json"), &models)?;
            }
            save_json(&agent.join("settings.json"), &settings)?;
        }

        if self.hindsight.choice() != Choice::Keep {
            let choice = self.hindsight.choice();
            let model = choice.configured().then_some(self.hindsight.model.trim());
            let url = (choice == Choice::Compatible).then_some(self.hindsight.url.trim());
            let key = if choice == Choice::None {
                "unused"
            } else {
                self.hindsight.key.trim()
            };
            save_hindsight(
                &root.join(".hindsight/embed"),
                choice.provider_id(),
                model,
                url,
                key,
            )?;
        }
        Ok(())
    }

    pub fn draw(&self, frame: &mut Frame) {
        let parts = Layout::vertical([
            Constraint::Length(3),
            Constraint::Min(10),
            Constraint::Length(3),
        ])
        .split(frame.area());
        frame.render_widget(
            Paragraph::new("Mash provider setup — page 2/3")
                .alignment(Alignment::Center)
                .block(Block::default().borders(Borders::ALL)),
            parts[0],
        );
        let mut lines = vec![
            Line::from("API keys stay in private Mash files. Tab moves, arrows change providers."),
            Line::from(""),
            Line::from(Span::styled(
                "Pi",
                Style::default().add_modifier(Modifier::BOLD),
            )),
        ];
        for field in self.fields() {
            if matches!(field, Field::Back | Field::Save) {
                continue;
            }
            if field == Field::HindsightProvider {
                lines.push(Line::from(""));
                lines.push(Line::from(Span::styled(
                    "Hindsight",
                    Style::default().add_modifier(Modifier::BOLD),
                )));
            }
            let (label, value, secret) = match field {
                Field::PiProvider => ("Provider", self.pi.choice().label(true), false),
                Field::PiId => ("Provider ID", self.pi.id.as_str(), false),
                Field::PiUrl => ("Base URL", self.pi.url.as_str(), false),
                Field::PiModel => ("Model ID", self.pi.model.as_str(), false),
                Field::PiKey => ("API key", self.pi.key.as_str(), true),
                Field::HindsightProvider => {
                    ("Provider", self.hindsight.choice().label(false), false)
                }
                Field::HindsightUrl => ("Base URL", self.hindsight.url.as_str(), false),
                Field::HindsightModel => ("Model ID", self.hindsight.model.as_str(), false),
                Field::HindsightKey => ("API key", self.hindsight.key.as_str(), true),
                _ => unreachable!(),
            };
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
                .block(Block::default().borders(Borders::ALL).title("Providers")),
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
                button(Field::Save, " Next — Penpot account "),
            ]))
            .alignment(Alignment::Center)
            .block(Block::default().borders(Borders::ALL)),
            parts[2],
        );
    }
}

fn validate_input(input: &Input, pi: bool) -> Result<(), String> {
    let label = if pi { "Pi" } else { "Hindsight" };
    let choice = input.choice();
    if !choice.configured() {
        return Ok(());
    }
    if choice == Choice::Compatible {
        if pi {
            let id = input.id.trim();
            if !id.starts_with(|c: char| c.is_ascii_lowercase())
                || !id
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_')
                || ["openai", "anthropic", "openrouter", "azure", "none"].contains(&id)
            {
                return Err("Pi: use a unique lowercase provider ID (e.g. omniroute)".into());
            }
        }
        let url = input.url.trim();
        if !url.starts_with("https://")
            || url[8..]
                .split(['/', '?'])
                .next()
                .is_none_or(|host| host.is_empty() || host.contains('@'))
            || url.contains(['#', '\\'])
            || url.chars().any(|c| c.is_whitespace() || c.is_control())
        {
            return Err(format!(
                "{label}: enter an HTTPS base URL without credentials"
            ));
        }
    }
    if input.model.trim().is_empty() || input.model.contains(['\n', '\r']) {
        return Err(format!("{label}: enter an exact model ID"));
    }
    if input.key.is_empty() || !input.key.chars().all(|c| c.is_ascii_graphic()) {
        return Err(format!(
            "{label}: enter an API key without spaces or control characters"
        ));
    }
    Ok(())
}

fn read_json_object(path: &Path) -> Result<Map<String, Value>, String> {
    if path.is_symlink() {
        return Err(format!("refusing a symlink at {}", path.display()));
    }
    if !path.exists() {
        return Ok(Map::new());
    }
    let text = fs::read_to_string(path).map_err(|e| e.to_string())?;
    serde_json::from_str::<Value>(&text)
        .map_err(|e| format!("invalid JSON in {}: {e}", path.display()))?
        .as_object()
        .cloned()
        .ok_or_else(|| format!("expected JSON object in {}", path.display()))
}

fn save_json(path: &Path, data: &Map<String, Value>) -> Result<(), String> {
    let text = serde_json::to_string_pretty(data).map_err(|e| e.to_string())? + "\n";
    write_private(path, &text)
}

fn save_hindsight(
    path: &Path,
    provider: &str,
    model: Option<&str>,
    url: Option<&str>,
    key: &str,
) -> Result<(), String> {
    if path.is_symlink() {
        return Err("refusing a symlink in Hindsight config".into());
    }
    let original = fs::read_to_string(path).map_err(|e| format!("Hindsight config: {e}"))?;
    let values = [
        ("HINDSIGHT_API_LLM_PROVIDER", Some(provider)),
        ("HINDSIGHT_API_LLM_MODEL", model),
        ("HINDSIGHT_API_LLM_BASE_URL", url),
        ("HINDSIGHT_API_LLM_API_KEY", Some(key)),
    ];
    let mut result = String::new();
    let mut seen = [false; 4];
    for line in original.lines() {
        if let Some(index) = values.iter().position(|(name, _)| {
            line.split_once('=')
                .is_some_and(|(key, _)| key.trim() == *name)
        }) {
            if !seen[index] {
                if let Some(value) = values[index].1 {
                    result.push_str(&format!("{}={value}\n", values[index].0));
                }
                seen[index] = true;
            }
        } else {
            result.push_str(line);
            result.push('\n');
        }
    }
    for (index, (name, value)) in values.iter().enumerate() {
        if !seen[index] {
            if let Some(value) = value {
                result.push_str(&format!("{name}={value}\n"));
            }
        }
    }
    write_private(path, &result)
}

pub(crate) fn write_private(path: &Path, text: &str) -> Result<(), String> {
    if path.is_symlink() {
        return Err(format!("refusing a symlink at {}", path.display()));
    }
    let parent = path.parent().ok_or("missing config directory")?;
    fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let temp = parent.join(format!(".mash-wizard-{}-{stamp}", std::process::id()));
    let result = (|| -> Result<(), String> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temp)
            .map_err(|e| e.to_string())?;
        file.write_all(text.as_bytes()).map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        fs::rename(&temp, path).map_err(|e| e.to_string())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        os::unix::fs::PermissionsExt,
        sync::atomic::{AtomicU64, Ordering},
    };

    static FIXTURE_ID: AtomicU64 = AtomicU64::new(0);

    fn root() -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!(
            "mash-provider-test-{}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            FIXTURE_ID.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(path.join("pi/agent")).unwrap();
        fs::create_dir_all(path.join(".hindsight")).unwrap();
        path
    }

    #[test]
    fn custom_pi_responses_and_hindsight_chat_preserve_settings_and_private_keys() {
        let root = root();
        let agent = root.join("pi/agent");
        fs::write(
            agent.join("settings.json"),
            r#"{"packages":["npm:pi-subagents"]}"#,
        )
        .unwrap();
        fs::write(
            agent.join("auth.json"),
            r#"{"anthropic":{"type":"api_key","key":"existing"}}"#,
        )
        .unwrap();
        fs::write(root.join(".hindsight/embed"), "HINDSIGHT_API_PORT=8998\nHINDSIGHT_API_LLM_PROVIDER=none\nHINDSIGHT_API_LLM_API_KEY=unused\n").unwrap();
        let mut page = ProviderPage::new();
        page.pi.choice = Some(Choice::Compatible);
        page.pi.id = "omniroute".into();
        page.pi.url = "https://example.invalid/v1".into();
        page.pi.model = "route-model".into();
        page.pi.key = "secret-pi".into();
        page.hindsight.choice = Some(Choice::Compatible);
        page.hindsight.url = "https://example.invalid/v1".into();
        page.hindsight.model = "route-model".into();
        page.hindsight.key = "secret-hindsight".into();
        assert!(page.validate(), "{:?}", page.error);
        page.save(&root).unwrap();
        let settings = read_json_object(&agent.join("settings.json")).unwrap();
        assert_eq!(
            settings["packages"],
            serde_json::json!(["npm:pi-subagents"])
        );
        assert_eq!(settings["defaultProvider"], "omniroute");
        assert_eq!(settings["defaultThinkingLevel"], "medium");
        let models = read_json_object(&agent.join("models.json")).unwrap();
        assert_eq!(models["providers"]["omniroute"]["api"], "openai-responses");
        let auth = read_json_object(&agent.join("auth.json")).unwrap();
        assert_eq!(auth["anthropic"]["key"], "existing");
        assert_eq!(auth["omniroute"]["key"], "secret-pi");
        let embed = fs::read_to_string(root.join(".hindsight/embed")).unwrap();
        assert!(embed.contains("HINDSIGHT_API_PORT=8998"));
        assert!(embed.contains("HINDSIGHT_API_LLM_PROVIDER=openai"));
        assert!(embed.contains("HINDSIGHT_API_LLM_BASE_URL=https://example.invalid/v1"));
        assert!(embed.contains("HINDSIGHT_API_LLM_API_KEY=secret-hindsight"));
        for file in [agent.join("auth.json"), root.join(".hindsight/embed")] {
            assert_eq!(
                fs::metadata(file).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn none_removes_old_hindsight_endpoint_without_touching_pi() {
        let root = root();
        fs::write(root.join(".hindsight/embed"), "HINDSIGHT_API_PORT=8998\nHINDSIGHT_API_LLM_PROVIDER=openai\nHINDSIGHT_API_LLM_BASE_URL=https://old.invalid/v1\nHINDSIGHT_API_LLM_MODEL=old\nHINDSIGHT_API_LLM_API_KEY=old\n").unwrap();
        let mut page = ProviderPage::new();
        page.hindsight.choice = Some(Choice::None);
        assert!(page.validate());
        page.save(&root).unwrap();
        let text = fs::read_to_string(root.join(".hindsight/embed")).unwrap();
        assert!(text.contains("HINDSIGHT_API_LLM_PROVIDER=none"));
        assert!(text.contains("HINDSIGHT_API_LLM_API_KEY=unused"));
        assert!(!text.contains("old.invalid"));
        assert!(!root.join("pi/agent/auth.json").exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn invalid_or_missing_credentials_never_get_saved() {
        let root = root();
        let mut page = ProviderPage::new();
        page.pi.choice = Some(Choice::Compatible);
        page.pi.id = "omniroute".into();
        page.pi.url = "http://external.invalid/v1".into();
        page.pi.model = "model".into();
        page.pi.key = "some-key".into();
        assert!(!page.validate());
        assert!(!root.join("pi/agent/auth.json").exists());
        page.pi.url = "https://example.invalid/v1".into();
        page.pi.key = "key\nleak".into();
        assert!(!page.validate());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn invalid_existing_json_does_not_store_a_key() {
        let root = root();
        fs::write(root.join("pi/agent/settings.json"), "not JSON").unwrap();
        let mut page = ProviderPage::new();
        page.pi.choice = Some(Choice::OpenAi);
        page.pi.model = "model".into();
        page.pi.key = "secret".into();
        assert!(page.save(&root).is_err());
        assert!(!root.join("pi/agent/auth.json").exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn selected_provider_fields_are_visible_and_key_is_masked() {
        let mut page = ProviderPage::new();
        assert_eq!(
            page.fields(),
            vec![
                Field::PiProvider,
                Field::HindsightProvider,
                Field::Back,
                Field::Save
            ]
        );
        page.cycle(true, 4);
        page.pi.key = "secret".into();
        assert!(page.fields().contains(&Field::PiUrl));
        assert!(page.fields().contains(&Field::PiKey));
        assert_eq!(page.focus, Field::PiProvider);
        page.move_focus(1);
        assert_eq!(page.focus, Field::PiId);
        let mut terminal =
            ratatui::Terminal::new(ratatui::backend::TestBackend::new(100, 30)).unwrap();
        terminal.draw(|frame| page.draw(frame)).unwrap();
        let rendered = terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect::<String>();
        assert!(rendered.contains("••••••"));
        assert!(!rendered.contains("secret"));
    }
}
