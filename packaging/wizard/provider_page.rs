use crate::wizard_style;
use ratatui::{
    crossterm::event::{KeyCode, KeyModifiers},
    layout::{Constraint, Layout},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Paragraph, Wrap},
    Frame,
};
use serde_json::{Map, Value};
use std::{
    collections::HashSet,
    fs::{self, OpenOptions},
    io::Write,
    os::unix::fs::OpenOptionsExt,
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Choice {
    Keep,
    None,
    OpenAi,
    Anthropic,
    OpenRouter,
    Compatible,
}

/// One dot per typed character, so the field shows how long a secret is
/// without revealing it. A fixed run of dots told the user nothing: they could
/// not tell a typo from a correct entry, and could not see whether the value
/// was still there after editing another field. The count is what matters.
/// Length is mildly sensitive for a password, and the terminal already shows
/// the value as it is typed in the owner's own shell, so this leaks less than
/// the input echo in most terminals.
pub fn masked(value: &str) -> String {
    "•".repeat(value.chars().count())
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

// Web search picks only from the providers pi-web-search can actually drive.
// Its getProviderKind() accepts google, xai, the Responses APIs (openai,
// openai-codex, azure-openai-responses, and github-copilot, opencode and
// opencode-go models on openai-responses) and anthropic-messages. OpenRouter
// and openai-completions are absent on purpose: writing one here would save a
// config that fails on the first search instead of on the screen that made it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SearchChoice {
    Keep,
    Google,
    OpenAi,
    Anthropic,
    Xai,
    OpenAiCodex,
    Azure,
    Copilot,
    OpenCode,
    OpenCodeGo,
}

const SEARCH_CHOICES: &[SearchChoice] = &[
    SearchChoice::Keep,
    SearchChoice::Google,
    SearchChoice::OpenAi,
    SearchChoice::Anthropic,
    SearchChoice::Xai,
    SearchChoice::OpenAiCodex,
    SearchChoice::Azure,
    SearchChoice::Copilot,
    SearchChoice::OpenCode,
    SearchChoice::OpenCodeGo,
];

impl SearchChoice {
    fn label(self) -> &'static str {
        match self {
            SearchChoice::Keep => "Keep existing / use the chat model",
            SearchChoice::Google => "Google Gemini",
            SearchChoice::OpenAi => "OpenAI",
            SearchChoice::Anthropic => "Anthropic",
            SearchChoice::Xai => "xAI Grok",
            SearchChoice::OpenAiCodex => "OpenAI Codex",
            SearchChoice::Azure => "Azure OpenAI",
            SearchChoice::Copilot => "GitHub Copilot",
            SearchChoice::OpenCode => "OpenCode Zen",
            SearchChoice::OpenCodeGo => "OpenCode Go",
        }
    }

    fn provider_id(self) -> &'static str {
        match self {
            SearchChoice::Keep => "",
            SearchChoice::Google => "google",
            SearchChoice::OpenAi => "openai",
            SearchChoice::Anthropic => "anthropic",
            SearchChoice::Xai => "xai",
            SearchChoice::OpenAiCodex => "openai-codex",
            SearchChoice::Azure => "azure",
            SearchChoice::Copilot => "github-copilot",
            SearchChoice::OpenCode => "opencode",
            SearchChoice::OpenCodeGo => "opencode-go",
        }
    }

    fn configured(self) -> bool {
        !matches!(self, SearchChoice::Keep)
    }

    fn accepts_key(self) -> bool {
        !matches!(
            self,
            SearchChoice::Keep | SearchChoice::OpenAiCodex | SearchChoice::Copilot
        )
    }
}

// pi-web-search holds no key of its own: it reads the Pi credential and the
// provider environment. So this section only ever names a provider and a model.
#[derive(Default)]
struct SearchInput {
    choice: Option<SearchChoice>,
    model: String,
    key: String,
    endpoint: String,
}

impl SearchInput {
    fn choice(&self) -> SearchChoice {
        self.choice.unwrap_or(SearchChoice::Keep)
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
    WebSearchProvider,
    WebSearchModel,
    WebSearchKey,
    WebSearchEndpoint,
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

const MENU_BASE: usize = 100; // distinct from field indices and sidebar targets
const MENU_ROWS: usize = 6;

#[derive(Clone, Copy)]
struct Dropdown {
    field: Field,
    highlighted: usize,
}

pub struct ProviderPage {
    pi: Input,
    search: SearchInput,
    hindsight: Input,
    focus: Field,
    error: Option<String>,
    dropdown: Option<Dropdown>,
    saved_auth: HashSet<String>,
}

impl ProviderPage {
    pub fn new() -> Self {
        Self {
            pi: Input::default(),
            search: SearchInput::default(),
            hindsight: Input::default(),
            focus: Field::PiProvider,
            error: None,
            dropdown: None,
            saved_auth: HashSet::new(),
        }
    }

    // Keep only provider names, never credential values, in wizard state.
    pub fn load_existing_auth(&mut self, agent: &Path) {
        if let Ok(auth) = read_json_object(&agent.join("auth.json")) {
            self.saved_auth = auth
                .into_iter()
                .filter_map(|(id, entry)| {
                    let credential = entry.as_object()?;
                    let has_key = credential
                        .get("key")
                        .and_then(Value::as_str)
                        .is_some_and(|key| !key.is_empty());
                    let oauth = credential.get("type").and_then(Value::as_str) == Some("oauth");
                    (has_key || oauth).then_some(id)
                })
                .collect();
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
        fields.push(Field::WebSearchProvider);
        if self.search.choice().configured() {
            fields.push(Field::WebSearchModel);
            if self.search.choice().accepts_key() && !self.search_uses_pi_key() {
                fields.push(Field::WebSearchKey);
            }
            if self.search.choice() == SearchChoice::Azure {
                fields.push(Field::WebSearchEndpoint);
            }
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

    fn search_uses_pi_key(&self) -> bool {
        matches!(
            (self.pi.choice(), self.search.choice()),
            (Choice::OpenAi, SearchChoice::OpenAi) | (Choice::Anthropic, SearchChoice::Anthropic)
        )
    }

    fn move_focus(&mut self, direction: isize) {
        let fields = self.fields();
        let current = fields
            .iter()
            .position(|field| *field == self.focus)
            .unwrap_or(0);
        self.focus = fields[wizard_style::focus_step(current, fields.len(), direction, true)];
    }

    fn is_selector(field: Field) -> bool {
        matches!(
            field,
            Field::PiProvider | Field::WebSearchProvider | Field::HindsightProvider
        )
    }

    fn options(field: Field) -> Vec<&'static str> {
        match field {
            Field::PiProvider => PI_CHOICES.iter().map(|choice| choice.label(true)).collect(),
            Field::WebSearchProvider => {
                SEARCH_CHOICES.iter().map(|choice| choice.label()).collect()
            }
            Field::HindsightProvider => HINDSIGHT_CHOICES
                .iter()
                .map(|choice| choice.label(false))
                .collect(),
            _ => Vec::new(),
        }
    }

    fn open_menu(&mut self, field: Field) {
        let highlighted = match field {
            Field::PiProvider => PI_CHOICES
                .iter()
                .position(|choice| *choice == self.pi.choice()),
            Field::WebSearchProvider => SEARCH_CHOICES
                .iter()
                .position(|choice| *choice == self.search.choice()),
            Field::HindsightProvider => HINDSIGHT_CHOICES
                .iter()
                .position(|choice| *choice == self.hindsight.choice()),
            _ => None,
        };
        if let Some(highlighted) = highlighted {
            self.focus = field;
            self.dropdown = Some(Dropdown { field, highlighted });
        }
    }

    fn commit_option(&mut self, field: Field, index: usize) {
        match field {
            Field::PiProvider => {
                if let Some(&choice) = PI_CHOICES.get(index) {
                    if choice != self.pi.choice() {
                        self.pi.choice = Some(choice);
                        self.pi.model.clear();
                        self.pi.key.clear();
                    }
                }
            }
            Field::WebSearchProvider => {
                if let Some(&choice) = SEARCH_CHOICES.get(index) {
                    if choice != self.search.choice() {
                        self.search.choice = Some(choice);
                        self.search.model.clear();
                        self.search.key.clear();
                        self.search.endpoint.clear();
                    }
                }
            }
            Field::HindsightProvider => {
                if let Some(&choice) = HINDSIGHT_CHOICES.get(index) {
                    if choice != self.hindsight.choice() {
                        self.hindsight.choice = Some(choice);
                        self.hindsight.model.clear();
                        self.hindsight.key.clear();
                    }
                }
            }
            _ => {}
        }
        self.dropdown = None;
        self.error = None;
    }

    pub fn menu_open(&self) -> bool {
        self.dropdown.is_some()
    }

    pub fn close_menu(&mut self) {
        self.dropdown = None;
    }

    fn text_mut(&mut self) -> Option<&mut String> {
        match self.focus {
            Field::PiId => Some(&mut self.pi.id),
            Field::PiUrl => Some(&mut self.pi.url),
            Field::PiModel => Some(&mut self.pi.model),
            Field::PiKey => Some(&mut self.pi.key),
            Field::WebSearchModel => Some(&mut self.search.model),
            Field::WebSearchKey => Some(&mut self.search.key),
            Field::WebSearchEndpoint => Some(&mut self.search.endpoint),
            Field::HindsightUrl => Some(&mut self.hindsight.url),
            Field::HindsightModel => Some(&mut self.hindsight.model),
            Field::HindsightKey => Some(&mut self.hindsight.key),
            _ => None,
        }
    }

    /// Field clicks open a selector; menu clicks commit the highlighted value.
    pub fn on_click(&mut self, index: usize) -> Option<Decision> {
        if let Some(menu) = self.dropdown {
            if index >= MENU_BASE {
                let option = index - MENU_BASE;
                if option < Self::options(menu.field).len() {
                    self.commit_option(menu.field, option);
                }
                return None;
            }
            self.dropdown = None; // click outside the menu discards its highlight
            if self.fields().get(index) == Some(&menu.field) {
                return None; // clicking the same selector toggles the menu closed
            }
        }
        let field = *self.fields().get(index)?;
        self.focus = field;
        match field {
            Field::Back => Some(Decision::Back),
            Field::Save => Some(Decision::Save),
            field if Self::is_selector(field) => {
                self.open_menu(field);
                None
            }
            _ => None,
        }
    }

    pub fn on_key(&mut self, code: KeyCode, modifiers: KeyModifiers) -> Option<Decision> {
        if modifiers.contains(KeyModifiers::CONTROL) && code == KeyCode::Char('c') {
            return Some(Decision::Cancel);
        }
        if let Some(menu) = self.dropdown {
            let count = Self::options(menu.field).len();
            match code {
                KeyCode::Esc => self.dropdown = None,
                KeyCode::Up | KeyCode::Left | KeyCode::Down | KeyCode::Right => {
                    let direction = if matches!(code, KeyCode::Up | KeyCode::Left) {
                        -1
                    } else {
                        1
                    };
                    self.dropdown = Some(Dropdown {
                        highlighted: wizard_style::focus_step(
                            menu.highlighted,
                            count,
                            direction,
                            false,
                        ),
                        ..menu
                    });
                }
                KeyCode::Home => {
                    self.dropdown = Some(Dropdown {
                        highlighted: 0,
                        ..menu
                    })
                }
                KeyCode::End => {
                    self.dropdown = Some(Dropdown {
                        highlighted: count - 1,
                        ..menu
                    })
                }
                KeyCode::Enter | KeyCode::Char(' ') => {
                    self.commit_option(menu.field, menu.highlighted)
                }
                KeyCode::Tab | KeyCode::BackTab => {
                    self.dropdown = None;
                    self.move_focus(if code == KeyCode::Tab { 1 } else { -1 });
                }
                _ => {}
            }
            return None;
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
            KeyCode::Enter if Self::is_selector(self.focus) => {
                self.open_menu(self.focus);
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
                if Self::is_selector(self.focus) =>
            {
                self.open_menu(self.focus);
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
        let result = validate_input(&self.pi, true)
            .and_then(|()| validate_input(&self.hindsight, false))
            .and_then(|()| validate_search(&self.search, self.search_uses_pi_key()));
        self.error = result.err();
        self.error.is_none()
    }

    fn save_search_auth(&self, agent: &Path) -> Result<(), String> {
        let choice = self.search.choice();
        let key = self.search.key.trim();
        if !choice.accepts_key() || self.search_uses_pi_key() || key.is_empty() {
            return Ok(()); // Keep existing credentials or authenticate later in Pi.
        }
        let path = agent.join("auth.json");
        let mut auth = read_json_object(&path)?;
        let provider = choice.provider_id();
        let mut entry = match auth.get(provider) {
            Some(Value::Object(entry)) => entry.clone(),
            Some(_) => return Err("Web search: existing Pi credential is invalid".into()),
            None => Map::new(),
        };
        if entry.get("type").and_then(Value::as_str) == Some("oauth") {
            return Err(
                "Web search: an OAuth credential already exists; manage it through Pi /login"
                    .into(),
            );
        }
        entry.insert("type".into(), Value::String("api_key".into()));
        entry.insert("key".into(), Value::String(key.into()));
        if choice == SearchChoice::Azure && !self.search.endpoint.trim().is_empty() {
            let env = entry
                .entry("env")
                .or_insert_with(|| Value::Object(Map::new()))
                .as_object_mut()
                .ok_or("Web search: existing Azure credential has invalid env")?;
            env.insert(
                "AZURE_OPENAI_BASE_URL".into(),
                Value::String(self.search.endpoint.trim().into()),
            );
        }
        auth.insert(provider.into(), Value::Object(entry));
        save_json(&path, &auth)
    }

    pub fn save(&self, root: &Path) -> Result<(), String> {
        validate_input(&self.pi, true)?;
        validate_input(&self.hindsight, false)?;
        validate_search(&self.search, self.search_uses_pi_key())?;
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

        if self.search.choice().configured() {
            self.save_search_auth(&root.join("pi/agent"))?;
            // The agent directory may not exist yet when Pi itself was left
            // alone, and an existing file may carry keys this page never shows.
            let path = root.join("pi/agent/web-search.json");
            let mut config = read_json_object(&path)?;
            config.insert(
                "provider".into(),
                Value::String(self.search.choice().provider_id().into()),
            );
            config.insert(
                "model".into(),
                Value::String(self.search.model.trim().into()),
            );
            // pi-web-search accepts `modelId` as an alias, but leaving both
            // would let a later hand-edit of one silently disagree with the other.
            config.remove("modelId");
            save_json(&path, &config)?;
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
        .split(wizard_style::page_area(frame, Some(1)));
        wizard_style::header(frame, parts[0], "Mash provider setup — page 2/5");
        let mut lines: Vec<(Line<'static>, Option<usize>)> = vec![
            (
                Line::from(
                    "API keys stay private. Enter or click opens a provider menu; Esc closes it.",
                ),
                None,
            ),
            (Line::from(""), None),
            (
                Line::from(Span::styled(
                    "Pi",
                    Style::default().add_modifier(Modifier::BOLD),
                )),
                None,
            ),
        ];
        let fields = self.fields();
        let mut menu_after = None;
        for (index, &field) in fields.iter().enumerate() {
            if matches!(field, Field::Back | Field::Save) {
                continue;
            }
            if field == Field::HindsightProvider || field == Field::WebSearchProvider {
                lines.push((Line::from(""), None));
                lines.push((
                    Line::from(Span::styled(
                        if field == Field::WebSearchProvider {
                            "Web search"
                        } else {
                            "Hindsight"
                        },
                        Style::default().add_modifier(Modifier::BOLD),
                    )),
                    None,
                ));
            }
            let (label, value, secret) = match field {
                Field::PiProvider => ("Provider", self.pi.choice().label(true), false),
                Field::PiId => ("Provider ID", self.pi.id.as_str(), false),
                Field::PiUrl => ("Base URL", self.pi.url.as_str(), false),
                Field::PiModel => ("Model ID", self.pi.model.as_str(), false),
                Field::PiKey => ("API key", self.pi.key.as_str(), true),
                Field::WebSearchProvider => ("Provider", self.search.choice().label(), false),
                Field::WebSearchModel => ("Model ID", self.search.model.as_str(), false),
                Field::WebSearchKey => ("API key", self.search.key.as_str(), true),
                Field::WebSearchEndpoint => {
                    ("Azure base URL", self.search.endpoint.as_str(), false)
                }
                Field::HindsightProvider => {
                    ("Provider", self.hindsight.choice().label(false), false)
                }
                Field::HindsightUrl => ("Base URL", self.hindsight.url.as_str(), false),
                Field::HindsightModel => ("Model ID", self.hindsight.model.as_str(), false),
                Field::HindsightKey => ("API key", self.hindsight.key.as_str(), true),
                _ => unreachable!(),
            };
            let shown = if secret && !value.is_empty() {
                masked(value)
            } else {
                value.to_string()
            };
            lines.push((
                if Self::is_selector(field) {
                    wizard_style::selector(self.focus == field, label, &shown)
                } else {
                    wizard_style::text_field(self.focus == field, label, shown)
                },
                Some(index),
            ));
            match field {
                Field::WebSearchModel if self.search_uses_pi_key() => lines.push((
                    Line::from("  Uses the Pi credential selected above."), None,
                )),
                Field::WebSearchKey => lines.push((
                    Line::from(if self.saved_auth.contains(self.search.choice().provider_id()) {
                        "  Saved Pi credential found. Leave blank to reuse; a new key replaces it."
                    } else {
                        "  No saved Pi credential found. Enter a key, or use Pi /login after setup."
                    }), None,
                )),
                Field::WebSearchEndpoint => lines.push((
                    Line::from("  Azure requires an HTTPS endpoint; enter one with a key or configure it later in Pi."), None,
                )),
                Field::WebSearchProvider if self.search.choice() == SearchChoice::OpenAiCodex => lines.push((
                    Line::from(if self.saved_auth.contains("openai-codex") {
                        "  Saved Pi login found for OpenAI Codex."
                    } else {
                        "  After setup, open Pi and run /login → OpenAI Codex."
                    }), None,
                )),
                Field::WebSearchProvider if self.search.choice() == SearchChoice::Copilot => lines.push((
                    Line::from(if self.saved_auth.contains("github-copilot") {
                        "  Saved Pi login found for GitHub Copilot."
                    } else {
                        "  After setup, open Pi and run /login → GitHub Copilot."
                    }), None,
                )),
                _ => {}
            }
            if self.dropdown.is_some_and(|menu| menu.field == field) {
                menu_after = Some(lines.len());
            }
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
        let body = wizard_style::section(frame, parts[1], "Providers");
        if let Some((menu, at)) = self.dropdown.zip(menu_after) {
            let options = Self::options(menu.field);
            // Expand in the flow instead of covering the next provider. Keep a
            // viewport on short terminals; arrows scroll the highlighted row.
            let used: usize = lines
                .iter()
                .map(|(line, _)| {
                    Paragraph::new(line.clone())
                        .wrap(Wrap { trim: true })
                        .line_count(body.width)
                        .max(1)
                })
                .sum();
            let spare = (body.height as usize).saturating_sub(used).max(1);
            let visible = options.len().min(MENU_ROWS).min(spare);
            let start = menu
                .highlighted
                .saturating_sub(visible - 1)
                .min(options.len() - visible);
            let selected = match menu.field {
                Field::PiProvider => PI_CHOICES
                    .iter()
                    .position(|choice| *choice == self.pi.choice()),
                Field::WebSearchProvider => SEARCH_CHOICES
                    .iter()
                    .position(|choice| *choice == self.search.choice()),
                Field::HindsightProvider => HINDSIGHT_CHOICES
                    .iter()
                    .position(|choice| *choice == self.hindsight.choice()),
                _ => None,
            };
            let rows = (start..start + visible).map(|index| {
                let style = if index == menu.highlighted {
                    wizard_style::selected()
                } else {
                    Style::default()
                        .fg(wizard_style::TEXT)
                        .bg(wizard_style::SURFACE)
                };
                (
                    Line::styled(
                        format!(
                            "  {} {}",
                            if selected == Some(index) { "●" } else { " " },
                            options[index]
                        ),
                        style,
                    ),
                    Some(MENU_BASE + index),
                )
            });
            lines.splice(at..at, rows);
        }
        wizard_style::render_form(frame, body, lines, true);
        let position = |field| fields.iter().position(|f| *f == field);
        wizard_style::render_buttons(
            frame,
            parts[2],
            &[
                (
                    wizard_style::button(self.focus == Field::Back, " Back "),
                    position(Field::Back),
                ),
                (Span::raw("    "), None),
                (
                    wizard_style::button(self.focus == Field::Save, " Next — Penpot account "),
                    position(Field::Save),
                ),
            ],
        );
    }
}

fn validate_search(input: &SearchInput, uses_pi_key: bool) -> Result<(), String> {
    if !input.choice().configured() {
        return Ok(());
    }
    if input.model.trim().is_empty() || input.model.contains(['\n', '\r']) {
        return Err("Web search: enter an exact model ID".into());
    }
    if input.choice().accepts_key()
        && !uses_pi_key
        && !input.key.is_empty()
        && !input.key.chars().all(|c| c.is_ascii_graphic())
    {
        return Err("Web search: enter an API key without spaces or control characters".into());
    }
    if input.choice() == SearchChoice::Azure && !input.endpoint.trim().is_empty() {
        if !valid_https_url(input.endpoint.trim()) {
            return Err("Web search: enter an HTTPS Azure base URL without credentials".into());
        }
        if input.key.is_empty() {
            return Err("Web search: enter an API key with the Azure base URL, or configure both later in Pi".into());
        }
    }
    Ok(())
}

fn valid_https_url(url: &str) -> bool {
    url.starts_with("https://")
        && url[8..]
            .split(['/', '?'])
            .next()
            .is_some_and(|host| !host.is_empty() && !host.contains('@'))
        && !url.contains(['#', '\\'])
        && !url.chars().any(|c| c.is_whitespace() || c.is_control())
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
        if !valid_https_url(input.url.trim()) {
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
                Field::WebSearchProvider,
                Field::HindsightProvider,
                Field::Back,
                Field::Save
            ]
        );
        page.commit_option(Field::PiProvider, 4);
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
        // One dot per typed character, so the field shows how long the key is
        // without revealing it. Six fixed dots made a truncated or mistyped key
        // look like a correct one.
        assert!(
            rendered.contains(&"•".repeat("secret".chars().count())),
            "expected one dot per character, got: {rendered:?}"
        );
    }

    #[test]
    fn web_search_dropdown_commits_only_after_confirmation() {
        let mut page = ProviderPage::new();
        assert!(!page.fields().contains(&Field::WebSearchModel));
        page.focus = Field::WebSearchProvider;
        page.on_key(KeyCode::Right, KeyModifiers::NONE);
        assert!(page.menu_open());
        page.on_key(KeyCode::Down, KeyModifiers::NONE);
        assert_eq!(page.search.choice(), SearchChoice::Keep);
        page.on_key(KeyCode::Esc, KeyModifiers::NONE);
        assert!(!page.menu_open());
        assert_eq!(page.search.choice(), SearchChoice::Keep);
        page.on_key(KeyCode::Enter, KeyModifiers::NONE);
        page.on_key(KeyCode::Down, KeyModifiers::NONE);
        page.on_key(KeyCode::Enter, KeyModifiers::NONE);
        assert_eq!(page.search.choice(), SearchChoice::Google);
        assert!(page.fields().contains(&Field::WebSearchModel));
        page.on_key(KeyCode::Char(' '), KeyModifiers::NONE);
        page.on_key(KeyCode::Home, KeyModifiers::NONE);
        page.on_key(KeyCode::Enter, KeyModifiers::NONE);
        assert_eq!(page.search.choice(), SearchChoice::Keep);
        assert!(!page.fields().contains(&Field::WebSearchModel));
    }

    #[test]
    fn changing_web_search_provider_clears_model_only_on_commit() {
        let mut page = ProviderPage::new();
        page.search.choice = Some(SearchChoice::OpenAi);
        page.search.model = "gpt-5.1".into();
        page.search.key = "old-key".into();
        page.search.endpoint = "https://old.invalid".into();
        page.focus = Field::WebSearchProvider;
        page.on_key(KeyCode::Enter, KeyModifiers::NONE);
        page.on_key(KeyCode::Down, KeyModifiers::NONE);
        assert_eq!(page.search.model, "gpt-5.1");
        page.on_key(KeyCode::Esc, KeyModifiers::NONE);
        assert_eq!(page.search.model, "gpt-5.1");
        page.on_key(KeyCode::Enter, KeyModifiers::NONE);
        page.on_key(KeyCode::Down, KeyModifiers::NONE);
        page.on_key(KeyCode::Enter, KeyModifiers::NONE);
        assert_eq!(page.search.choice(), SearchChoice::Anthropic);
        assert!(page.search.model.is_empty());
        assert!(page.search.key.is_empty());
        assert!(page.search.endpoint.is_empty());
    }

    #[test]
    fn pi_and_hindsight_dropdowns_keep_values_until_commit() {
        let mut page = ProviderPage::new();
        page.pi.model = "keep-me".into();
        page.pi.key = "secret".into();
        page.focus = Field::PiProvider;
        page.on_key(KeyCode::Enter, KeyModifiers::NONE);
        page.on_key(KeyCode::Down, KeyModifiers::NONE);
        page.on_key(KeyCode::Esc, KeyModifiers::NONE);
        assert_eq!(page.pi.choice(), Choice::Keep);
        assert_eq!(page.pi.key, "secret");
        page.on_key(KeyCode::Enter, KeyModifiers::NONE);
        page.on_key(KeyCode::Down, KeyModifiers::NONE);
        page.on_key(KeyCode::Enter, KeyModifiers::NONE);
        assert_eq!(page.pi.choice(), Choice::OpenAi);
        assert!(page.pi.key.is_empty());
        assert!(page.fields().contains(&Field::PiModel));

        page.focus = Field::HindsightProvider;
        page.on_key(KeyCode::Char(' '), KeyModifiers::NONE);
        page.on_key(KeyCode::Down, KeyModifiers::NONE);
        assert_eq!(page.hindsight.choice(), Choice::Keep);
        page.on_key(KeyCode::Enter, KeyModifiers::NONE);
        assert_eq!(page.hindsight.choice(), Choice::None);
    }

    #[test]
    fn opening_menu_pushes_following_provider_sections_down() {
        use wizard_style::tests::{click, find};
        let mut page = ProviderPage::new();
        let render = |page: &ProviderPage| {
            let mut terminal =
                ratatui::Terminal::new(ratatui::backend::TestBackend::new(120, 34)).unwrap();
            terminal.draw(|frame| page.draw(frame)).unwrap();
            terminal.backend().buffer().clone()
        };
        let closed = render(&page);
        let (_, web_closed) = find(&closed, "Web search");
        let (_, hindsight_closed) = find(&closed, "Hindsight");
        page.on_key(KeyCode::Enter, KeyModifiers::NONE);
        let open = render(&page);
        let (x, option_y) = find(&open, "OpenAI");
        let (_, web_open) = find(&open, "Web search");
        let (_, hindsight_open) = find(&open, "Hindsight");
        assert_eq!(web_open, web_closed + PI_CHOICES.len() as u16);
        assert_eq!(hindsight_open, hindsight_closed + PI_CHOICES.len() as u16);
        assert!(option_y < web_open);
        assert_eq!(
            wizard_style::clicked(&click(x, option_y)),
            Some(MENU_BASE + 1)
        );
    }

    #[test]
    fn long_menu_scrolls_inside_a_short_terminal_and_clicks_the_visible_option() {
        use wizard_style::tests::{click, find};
        let mut page = ProviderPage::new();
        page.focus = Field::WebSearchProvider;
        page.on_key(KeyCode::Enter, KeyModifiers::NONE);
        page.on_key(KeyCode::End, KeyModifiers::NONE);
        let mut terminal =
            ratatui::Terminal::new(ratatui::backend::TestBackend::new(120, 18)).unwrap();
        terminal.draw(|frame| page.draw(frame)).unwrap();
        let buffer = terminal.backend().buffer();
        let (x, y) = find(buffer, "OpenCode Go");
        assert_eq!(wizard_style::clicked(&click(x, y)), Some(MENU_BASE + 9));
        assert_eq!(buffer[(x, y)].bg, wizard_style::selected().bg.unwrap());
        assert_eq!(buffer[(118, y)].bg, wizard_style::selected().bg.unwrap());
        page.on_click(MENU_BASE + 9);
        assert_eq!(page.search.choice(), SearchChoice::OpenCodeGo);
    }

    #[test]
    fn every_web_search_choice_maps_to_a_distinct_pi_provider() {
        // A duplicate id would silently write the wrong provider, and an empty
        // one would write a config pi-web-search rejects.
        let mut ids = Vec::new();
        for choice in SEARCH_CHOICES.iter().filter(|c| c.configured()) {
            let id = choice.provider_id();
            assert!(!id.is_empty(), "{choice:?} has no provider id");
            assert!(!ids.contains(&id), "{id} is offered twice: {choice:?}");
            ids.push(id);
        }
    }

    #[test]
    fn web_search_saves_provider_and_model_without_dropping_other_keys() {
        let root = root();
        let path = root.join("pi/agent/web-search.json");
        fs::write(&path, r#"{"modelId":"old-alias","temperature":0.2}"#).unwrap();
        let mut page = ProviderPage::new();
        page.search.choice = Some(SearchChoice::OpenAiCodex);
        page.search.model = "gpt-5.6-sol".into();
        assert!(page.validate(), "{:?}", page.error);
        page.save(&root).unwrap();
        let config = read_json_object(&path).unwrap();
        assert_eq!(config["provider"], "openai-codex");
        assert_eq!(config["model"], "gpt-5.6-sol");
        // The alias is folded into `model` so the two cannot disagree later.
        assert!(config.get("modelId").is_none());
        assert_eq!(config["temperature"], 0.2);
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn keeping_the_existing_web_search_config_writes_nothing() {
        let root = root();
        let mut page = ProviderPage::new();
        assert!(page.validate());
        page.save(&root).unwrap();
        assert!(!root.join("pi/agent/web-search.json").exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn key_based_search_masks_input_and_saves_only_to_private_pi_auth() {
        let root = root();
        let agent = root.join("pi/agent");
        fs::write(
            agent.join("auth.json"),
            r#"{"google":{"type":"api_key","key":"existing"}}"#,
        )
        .unwrap();
        let mut page = ProviderPage::new();
        page.search.choice = Some(SearchChoice::Xai);
        page.search.model = "grok-model".into();
        page.search.key = "search-secret".into();
        assert!(page.fields().contains(&Field::WebSearchKey));
        let mut terminal =
            ratatui::Terminal::new(ratatui::backend::TestBackend::new(120, 34)).unwrap();
        terminal.draw(|frame| page.draw(frame)).unwrap();
        let rendered = terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect::<String>();
        assert!(rendered.contains(&"•".repeat(page.search.key.len())));
        assert!(!rendered.contains("search-secret"));
        page.save(&root).unwrap();
        let auth = read_json_object(&agent.join("auth.json")).unwrap();
        assert_eq!(auth["google"]["key"], "existing");
        assert_eq!(auth["xai"]["key"], "search-secret");
        assert_eq!(
            fs::metadata(agent.join("auth.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        let config = fs::read_to_string(agent.join("web-search.json")).unwrap();
        assert!(!config.contains("search-secret"));
        assert!(config.contains("grok-model"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn blank_search_key_reuses_saved_google_credential_without_displaying_it() {
        let root = root();
        let agent = root.join("pi/agent");
        fs::write(
            agent.join("auth.json"),
            r#"{"google":{"type":"api_key","key":"existing-secret"}}"#,
        )
        .unwrap();
        let mut page = ProviderPage::new();
        page.load_existing_auth(&agent);
        page.search.choice = Some(SearchChoice::Google);
        page.search.model = "gemini-3.1-flash-lite".into();
        let mut terminal =
            ratatui::Terminal::new(ratatui::backend::TestBackend::new(120, 34)).unwrap();
        terminal.draw(|frame| page.draw(frame)).unwrap();
        let rendered = terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect::<String>();
        assert!(rendered.contains("Saved Pi credential found"));
        assert!(!rendered.contains("existing-secret"));
        page.save(&root).unwrap();
        let auth = read_json_object(&agent.join("auth.json")).unwrap();
        assert_eq!(auth["google"]["key"], "existing-secret");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn oauth_search_shows_login_guidance_without_an_api_key_field() {
        for choice in [SearchChoice::OpenAiCodex, SearchChoice::Copilot] {
            let root = root();
            let mut page = ProviderPage::new();
            page.search.choice = Some(choice);
            page.search.model = "search-model".into();
            assert!(!page.fields().contains(&Field::WebSearchKey));
            let mut terminal =
                ratatui::Terminal::new(ratatui::backend::TestBackend::new(120, 34)).unwrap();
            terminal.draw(|frame| page.draw(frame)).unwrap();
            let rendered = terminal
                .backend()
                .buffer()
                .content()
                .iter()
                .map(|cell| cell.symbol())
                .collect::<String>();
            assert!(rendered.contains("/login"));
            page.save(&root).unwrap();
            assert!(!root.join("pi/agent/auth.json").exists());
            fs::remove_dir_all(root).unwrap();
        }
    }

    #[test]
    fn web_search_reuses_the_chat_provider_credential() {
        let root = root();
        let mut page = ProviderPage::new();
        page.pi.choice = Some(Choice::OpenAi);
        page.pi.model = "chat-model".into();
        page.pi.key = "shared-secret".into();
        page.search.choice = Some(SearchChoice::OpenAi);
        page.search.model = "search-model".into();
        assert!(!page.fields().contains(&Field::WebSearchKey));
        assert!(page.validate());
        page.save(&root).unwrap();
        let auth = read_json_object(&root.join("pi/agent/auth.json")).unwrap();
        assert_eq!(auth["openai"]["key"], "shared-secret");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn azure_search_saves_endpoint_with_its_key_without_losing_other_auth() {
        let root = root();
        let agent = root.join("pi/agent");
        fs::write(
            agent.join("auth.json"),
            r#"{"azure":{"type":"api_key","key":"old","env":{"OTHER":"keep"}}}"#,
        )
        .unwrap();
        let mut page = ProviderPage::new();
        page.search.choice = Some(SearchChoice::Azure);
        page.search.model = "deployment-name".into();
        page.search.key = "azure-secret".into();
        page.search.endpoint = "https://example.azure.com".into();
        assert_eq!(page.search.choice().provider_id(), "azure");
        assert!(page.fields().contains(&Field::WebSearchEndpoint));
        assert!(page.validate());
        page.save(&root).unwrap();
        let auth = read_json_object(&agent.join("auth.json")).unwrap();
        assert_eq!(auth["azure"]["key"], "azure-secret");
        assert_eq!(auth["azure"]["env"]["OTHER"], "keep");
        assert_eq!(
            auth["azure"]["env"]["AZURE_OPENAI_BASE_URL"],
            "https://example.azure.com"
        );
        let config = fs::read_to_string(agent.join("web-search.json")).unwrap();
        assert!(!config.contains("azure-secret"));
        page.search.endpoint = "http://insecure.invalid".into();
        assert!(!page.validate());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn web_search_refuses_to_replace_an_oauth_credential_with_a_key() {
        let root = root();
        let agent = root.join("pi/agent");
        fs::write(
            agent.join("auth.json"),
            r#"{"openai":{"type":"oauth","access":"existing"}}"#,
        )
        .unwrap();
        let mut page = ProviderPage::new();
        page.search.choice = Some(SearchChoice::OpenAi);
        page.search.model = "search-model".into();
        page.search.key = "replacement".into();
        assert!(page.save(&root).is_err());
        assert_eq!(
            read_json_object(&agent.join("auth.json")).unwrap()["openai"]["type"],
            "oauth"
        );
        assert!(!agent.join("web-search.json").exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn only_key_based_search_choices_offer_a_key_field() {
        for choice in SEARCH_CHOICES {
            let mut page = ProviderPage::new();
            page.search.choice = Some(*choice);
            assert_eq!(
                page.fields().contains(&Field::WebSearchKey),
                choice.accepts_key()
            );
        }
    }

    #[test]
    fn web_search_needs_an_exact_model_id() {
        let mut page = ProviderPage::new();
        page.search.choice = Some(SearchChoice::Google);
        assert!(!page.validate());
        assert!(page
            .error
            .as_deref()
            .unwrap_or_default()
            .contains("Web search"));
        page.search.model = "gemini-3.1-flash-lite".into();
        assert!(page.validate());
        page.search.key = "bad\nkey".into();
        assert!(!page.validate());
        page.search.key.clear();
        page.search.model = "two\nlines".into();
        assert!(!page.validate());
    }

    #[test]
    fn web_search_refuses_a_symlinked_auth_file() {
        let root = root();
        let agent = root.join("pi/agent");
        let outside = root.join("outside");
        fs::write(&outside, "keep\n").unwrap();
        std::os::unix::fs::symlink(&outside, agent.join("auth.json")).unwrap();
        let mut page = ProviderPage::new();
        page.search.choice = Some(SearchChoice::Google);
        page.search.model = "gemini-3.1-flash-lite".into();
        page.search.key = "test-key".into();
        assert!(page.save(&root).is_err());
        assert_eq!(fs::read_to_string(outside).unwrap(), "keep\n");
        assert!(!agent.join("web-search.json").exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn web_search_refuses_a_symlinked_config() {
        let root = root();
        let path = root.join("pi/agent/web-search.json");
        std::os::unix::fs::symlink(root.join("pi/agent/auth.json"), &path).unwrap();
        let mut page = ProviderPage::new();
        page.search.choice = Some(SearchChoice::Anthropic);
        page.search.model = "claude-sonnet-4-5".into();
        assert!(page.save(&root).is_err());
        assert!(!root.join("pi/agent/auth.json").exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn web_search_section_is_labelled_on_page_two() {
        let mut page = ProviderPage::new();
        page.search.choice = Some(SearchChoice::Copilot);
        page.search.model = "gpt-5.6-sol".into();
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
        assert!(rendered.contains("Web search"));
        assert!(rendered.contains("GitHub Copilot"));
    }

    #[test]
    fn clicks_open_a_menu_select_an_option_and_press_buttons() {
        use wizard_style::tests::{click, find};
        let mut page = ProviderPage::new();
        let render = |page: &ProviderPage| {
            let mut terminal =
                ratatui::Terminal::new(ratatui::backend::TestBackend::new(120, 34)).unwrap();
            terminal.draw(|frame| page.draw(frame)).unwrap();
            terminal.backend().buffer().clone()
        };
        let at = |page: &ProviderPage, label| {
            let (x, y) = find(&render(page), label);
            wizard_style::clicked(&click(x, y)).expect("label is clickable")
        };
        // The heading is not a target; the provider row drawn under it is.
        let (x, y) = find(&render(&page), "Web search");
        assert!(wizard_style::clicked(&click(x, y)).is_none());
        let search = wizard_style::clicked(&click(x, y + 1)).expect("provider row");
        assert!(page.fields()[search] == Field::WebSearchProvider);
        assert!(page.on_click(search).is_none());
        assert!(page.menu_open());
        assert_eq!(page.search.choice(), SearchChoice::Keep);
        let option = at(&page, "Google Gemini");
        assert_eq!(option, MENU_BASE + 1);
        assert!(page.on_click(option).is_none());
        assert!(!page.menu_open());
        assert_eq!(page.search.choice(), SearchChoice::Google);
        let search = page
            .fields()
            .iter()
            .position(|field| *field == Field::WebSearchProvider)
            .unwrap();
        page.on_click(search);
        assert!(page.menu_open());
        page.on_click(search);
        assert!(!page.menu_open());
        assert_eq!(page.search.choice(), SearchChoice::Google);
        assert!(matches!(
            page.on_click(at(&page, "Back")),
            Some(Decision::Back)
        ));
        assert!(matches!(
            page.on_click(at(&page, "Next — Penpot")),
            Some(Decision::Save)
        ));
    }
}
