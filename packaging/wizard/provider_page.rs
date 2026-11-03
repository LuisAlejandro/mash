use crate::{
    model_picker::{Action, ModelPicker},
    pi_connection::{self, Connection, Mode, Outcome, Preset},
    pi_models::{Job, Model, Report},
    pi_providers, wizard_style,
};
use ratatui::{
    crossterm::event::{KeyCode, KeyModifiers},
    layout::{Alignment, Constraint, Layout, Rect},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{List, ListItem, ListState, Paragraph, Wrap},
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
    Builtin(&'static pi_providers::Provider),
    Local(&'static Preset),
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

fn pi_choices() -> &'static [Choice] {
    static CHOICES: std::sync::OnceLock<Vec<Choice>> = std::sync::OnceLock::new();
    CHOICES.get_or_init(|| {
        let mut choices: Vec<_> = pi_providers::all()
            .iter()
            .filter(|provider| provider.chat)
            .map(|provider| match provider.id.as_str() {
                "openai" => Choice::OpenAi,
                "anthropic" => Choice::Anthropic,
                "openrouter" => Choice::OpenRouter,
                _ => Choice::Builtin(provider),
            })
            .chain(pi_connection::PRESETS.iter().map(Choice::Local))
            .collect();
        let rank = |choice: Choice| pi_providers::rank(choice.provider_id());
        choices.sort_by(|a, b| {
            rank(*a)
                .cmp(&rank(*b))
                .then_with(|| {
                    a.label(true)
                        .to_lowercase()
                        .cmp(&b.label(true).to_lowercase())
                })
                .then_with(|| a.provider_id().cmp(b.provider_id()))
        });
        choices.splice(0..0, [Choice::Keep, Choice::Compatible]);
        choices
    })
}
const HINDSIGHT_CHOICES: &[Choice] = &[
    Choice::Keep,
    Choice::None,
    Choice::OpenAi,
    Choice::Anthropic,
    Choice::OpenRouter,
    Choice::Compatible,
];

impl Choice {
    fn pi_provider(self) -> Option<&'static pi_providers::Provider> {
        match self {
            Choice::Builtin(provider) => Some(provider),
            Choice::OpenAi | Choice::Anthropic | Choice::OpenRouter => {
                pi_providers::get(self.provider_id())
            }
            _ => None,
        }
    }

    fn label(self, pi: bool) -> &'static str {
        if pi {
            if let Some(provider) = self.pi_provider() {
                return &provider.name;
            }
        }
        match self {
            Choice::Keep => "Keep existing / set up later",
            Choice::None => "None (no LLM)",
            Choice::OpenAi => "OpenAI",
            Choice::Anthropic => "Anthropic",
            Choice::OpenRouter => "OpenRouter",
            Choice::Compatible if pi => "Custom provider",
            Choice::Compatible => "OpenAI-compatible (Chat Completions)",
            Choice::Builtin(provider) => &provider.name,
            Choice::Local(preset) => preset.name,
        }
    }

    fn provider_id(self) -> &'static str {
        match self {
            Choice::OpenAi | Choice::Compatible => "openai",
            Choice::Anthropic => "anthropic",
            Choice::OpenRouter => "openrouter",
            Choice::None => "none",
            Choice::Keep => "",
            Choice::Builtin(provider) => &provider.id,
            Choice::Local(preset) => preset.id,
        }
    }

    fn configured(self) -> bool {
        match self {
            Choice::Keep | Choice::None => false,
            // A model can be selected before its provider is authenticated.
            Choice::Builtin(provider) => provider.chat,
            _ => true,
        }
    }

    /// Both kinds save their own provider definition in `models.json`.
    fn endpoint(self) -> bool {
        matches!(self, Choice::Compatible | Choice::Local(_))
    }

    fn preset(self) -> Option<&'static Preset> {
        match self {
            Choice::Local(preset) => Some(preset),
            _ => None,
        }
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
    Chat,
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
    SearchChoice::Chat,
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
            SearchChoice::Keep => "Keep existing search configuration",
            SearchChoice::Chat => "Use chat model",
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
            SearchChoice::Keep | SearchChoice::Chat => "",
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
        !matches!(self, SearchChoice::Keep | SearchChoice::Chat)
    }

    fn accepts_key(self) -> bool {
        !matches!(
            self,
            SearchChoice::Keep
                | SearchChoice::Chat
                | SearchChoice::OpenAiCodex
                | SearchChoice::Copilot
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
    PiApi,
    PiModel,
    PiSource,
    PiKey,
    PiTest,
    WebSearchProvider,
    WebSearchModel,
    WebSearchSource,
    WebSearchKey,
    WebSearchEndpoint,
    HindsightProvider,
    HindsightUrl,
    HindsightModel,
    HindsightSource,
    HindsightKey,
    ChooseServiceModel,
    Back,
    Save,
}

pub enum Decision {
    Back,
    Cancel,
    Save,
}

const AUTO_API: &str = "Auto (detect when tested)";
const MENU_BASE: usize = 100; // distinct from field indices and sidebar targets
const MENU_ROWS: usize = 6;
const PROVIDER_BASE: usize = 200; // radio rows, separate from fields and menus

#[derive(Clone, Copy)]
struct Dropdown {
    field: Field,
    highlighted: usize,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Page {
    Model,
    WebSearch,
    Hindsight,
}

impl Page {
    fn index(self) -> usize {
        self as usize + 2
    }

    fn title(self) -> &'static str {
        wizard_style::PAGES[self.index()]
    }

    fn provider_field(self) -> Field {
        match self {
            Self::Model => Field::PiProvider,
            Self::WebSearch => Field::WebSearchProvider,
            Self::Hindsight => Field::HindsightProvider,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ServiceSource {
    Chat,
    Saved,
    New,
    Later,
}

struct SavedHindsight {
    provider: String,
    model: String,
    base_url: String,
    has_key: bool,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ModelStep {
    Credentials,
    Loading,
    Picker,
    Manual,
}

pub struct ProviderPage {
    pi: Input,
    /// `None` is Auto: the probe decides which family this endpoint speaks.
    pi_api: Option<pi_providers::Api>,
    pi_source: Option<Mode>,
    search: SearchInput,
    search_source: Option<ServiceSource>,
    current_search: Option<(String, String)>,
    search_config_present: bool,
    hindsight: Input,
    hindsight_source: Option<ServiceSource>,
    current_hindsight: Option<SavedHindsight>,
    choose_service_model: bool,
    focus: Field,
    provider_rows: [usize; 3],
    error: Option<String>,
    dropdown: Option<Dropdown>,
    saved_auth: HashSet<String>,
    page: Page,
    current: Option<(String, String)>,
    selected_model: Option<(String, String)>,
    model_step: ModelStep,
    picker: Option<ModelPicker>,
    model_job: Option<(u64, Job)>,
    generation: u64,
    models_cached: bool,
    connection: Connection,
    connection_status: Option<String>,
    accepted_api: Option<String>,
    probe_revision: Option<String>,
    source_revision: Option<String>,
    local_models: Vec<String>,
    nonce: String,
    test_requested: bool,
    inspected: Option<u64>,
}

impl ProviderPage {
    pub fn new() -> Self {
        Self {
            pi: Input::default(),
            pi_api: Some(pi_providers::Api::default()),
            pi_source: None,
            search: SearchInput::default(),
            search_source: None,
            current_search: None,
            search_config_present: false,
            hindsight: Input::default(),
            hindsight_source: None,
            current_hindsight: None,
            choose_service_model: false,
            focus: Field::PiProvider,
            provider_rows: [0; 3],
            error: None,
            dropdown: None,
            saved_auth: HashSet::new(),
            page: Page::Model,
            current: None,
            selected_model: None,
            model_step: ModelStep::Credentials,
            picker: None,
            model_job: None,
            generation: 0,
            models_cached: false,
            connection: Connection::new(),
            connection_status: None,
            accepted_api: None,
            probe_revision: None,
            source_revision: None,
            local_models: Vec::new(),
            nonce: session_nonce(),
            test_requested: false,
            inspected: None,
        }
    }

    /// All three pages share drafts so Pi credential reuse stays consistent.
    pub fn set_page(&mut self, page: Page) {
        if self.page != page {
            self.reset_picker();
            self.connection.cancel();
            self.page = page;
            self.dropdown = None;
            self.error = None;
            self.focus = page.provider_field();
        }
    }

    fn provider_row(&self) -> usize {
        self.provider_rows[self.page as usize]
    }

    fn selected_provider_row(&self) -> usize {
        match self.page {
            Page::Model => pi_choices()
                .iter()
                .position(|choice| *choice == self.pi.choice()),
            Page::WebSearch => SEARCH_CHOICES
                .iter()
                .position(|choice| *choice == self.search.choice()),
            Page::Hindsight => HINDSIGHT_CHOICES
                .iter()
                .position(|choice| *choice == self.hindsight.choice()),
        }
        .unwrap_or(0)
    }

    fn configured_provider(&self) -> String {
        if self.pi.choice() == Choice::Compatible
            || self.pi.choice().endpoint() && !self.pi.id.trim().is_empty()
        {
            self.pi.id.trim().to_string()
        } else {
            self.pi.choice().provider_id().into()
        }
    }

    /// Resolve the final credential owner before approval or a network request.
    /// Existing endpoints/auth/header bindings are preserved under their old IDs.
    fn resolve_connection_id(&mut self, agent: &Path) -> Result<(), String> {
        if !self.pi.choice().endpoint() {
            return Ok(());
        }
        let base = self.configured_provider();
        if !valid_identity(&base) {
            return Err("Enter a provider ID first.".into());
        }
        let models = read_json_object(&agent.join("models.json"))?;
        let auth = read_json_object(&agent.join("auth.json"))?;
        let providers = models.get("providers").and_then(Value::as_object);
        let url = self.endpoint_url();
        let api = if self.pi.choice().preset().is_some() {
            Some(pi_providers::Api::Chat.id())
        } else {
            self.pi_api.map(|api| api.id())
        };
        let mut suffix = 1;
        let id = loop {
            let id = if suffix == 1 {
                base.clone()
            } else {
                format!("{base}-{suffix}")
            };
            let definition = providers.and_then(|providers| providers.get(&id));
            if !pi_providers::reserved(&id)
                && endpoint_slot_available(
                    definition,
                    auth.get(&id),
                    (&url, api, self.pi.model.trim()),
                    self.source() == Mode::None,
                )
            {
                break id;
            }
            suffix += 1;
        };
        if id != base {
            self.invalidate_models();
            self.pi.id = id;
        }
        Ok(())
    }

    /// The endpoint this draft would save: a preset default unless edited.
    fn endpoint_url(&self) -> String {
        let typed = self.pi.url.trim();
        match self.pi.choice().preset() {
            Some(preset) if typed.is_empty() => preset.base_url.into(),
            _ => typed.into(),
        }
    }

    /// Where this connection's credential comes from, in the order offered.
    fn source_choices(&self) -> Vec<Mode> {
        let mut modes = Vec::new();
        // A local server defaults to no key: an old hosted token for the same
        // provider ID must not be sent to it just because it exists.
        if self.pi.choice().preset().is_some() {
            modes.push(Mode::None);
        }
        if self.saved_auth.contains(&self.configured_provider()) {
            modes.push(Mode::Existing);
        }
        if let Some(provider) = self.pi.choice().pi_provider() {
            if provider.can_configure() {
                modes.push(Mode::New);
            }
            modes.push(Mode::Later);
        } else {
            // Custom connections retain their probe gate; local no-key is not
            // the same thing as postponing a hosted provider's login.
            modes.push(Mode::New);
        }
        modes
    }

    /// The chosen source, or the first offered one: reuse, then local no-key.
    fn source(&self) -> Mode {
        let choices = self.source_choices();
        self.pi_source
            .filter(|mode| choices.contains(mode))
            .unwrap_or(choices[0])
    }

    fn source_index(&self) -> usize {
        let source = self.source();
        self.source_choices()
            .iter()
            .position(|mode| *mode == source)
            .unwrap_or(0)
    }

    fn api_index(&self) -> usize {
        self.pi_api.map_or(0, |api| {
            pi_providers::Api::ALL
                .iter()
                .position(|candidate| *candidate == api)
                .map_or(0, |position| position + 1)
        })
    }

    fn api_label(&self) -> &'static str {
        self.pi_api.map_or(AUTO_API, |api| api.label())
    }

    fn target(&self) -> pi_connection::Target {
        pi_connection::Target {
            provider: self.configured_provider(),
            base_url: self.endpoint_url(),
            mode: self.source(),
            nonce: self.nonce.clone(),
            key: self.pi.key.clone(),
            self_hosted: self.pi.choice().preset().is_some(),
        }
    }

    fn reuses_saved_credential(&self) -> bool {
        self.source() == Mode::Existing
    }

    pub fn login_later_hint(&self) -> Option<String> {
        if self.source() != Mode::Later {
            return None;
        }
        self.pi
            .choice()
            .pi_provider()
            .map(|provider| provider.login_guidance())
    }

    /// A new generic custom endpoint must answer a real request before it is saved.
    fn needs_probe(&self) -> bool {
        self.pi.choice() == Choice::Compatible && self.accepted_api.is_none()
    }

    fn reset_picker(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.model_job = None;
        self.picker = None;
        self.models_cached = false;
        self.model_step = ModelStep::Credentials;
        self.choose_service_model = false;
    }

    fn invalidate_models(&mut self) {
        self.reset_picker();
        self.connection.cancel();
        self.connection_status = None;
        self.accepted_api = None;
        self.probe_revision = None;
        self.source_revision = None;
        self.local_models.clear();
        self.selected_model = None;
    }

    pub fn is_loading(&self) -> bool {
        self.model_step == ModelStep::Loading
    }

    pub fn has_model_step(&self) -> bool {
        self.model_step != ModelStep::Credentials
    }

    pub fn cancel_loading(&mut self) {
        if self.model_job.is_some() {
            self.reset_picker();
        }
    }

    /// Run the action the Test control asks for: list local models, or probe.
    fn start_connection(&mut self, resources: &Path, agent: &Path, preview: bool) {
        if preview {
            self.connection_status =
                Some("Preview only: no request is sent and nothing is saved.".into());
            return;
        }
        if let Err(message) = self
            .resolve_connection_id(agent)
            .and_then(|()| validate_credentials(&self.pi, true, self.source() == Mode::New))
        {
            self.error = Some(message);
            return;
        }
        self.error = None;
        self.accepted_api = None;
        self.probe_revision = None;
        let target = self.target();
        let model = self.pi.model.trim().to_string();
        let result = match self.pi.choice().preset() {
            Some(preset)
                if model.is_empty()
                    || preset.requires_model
                        && !self.local_models.iter().any(|id| id == &model) =>
            {
                self.connection
                    .discover(resources, agent, self.generation, &target, preset.id)
            }
            preset => self.connection.probe(
                resources,
                agent,
                self.generation,
                &target,
                if preset.is_some() {
                    Some(pi_providers::Api::Chat.id())
                } else {
                    self.pi_api.map(|api| api.id())
                },
                &model,
            ),
        };
        match result {
            Ok(()) => {
                self.connection_status =
                    Some("Testing the connection... one short request is sent.".into())
            }
            Err(message) => self.connection_status = Some(message),
        }
    }

    pub fn poll_connection(&mut self) {
        let Some(result) = self.connection.poll(self.generation) else {
            return;
        };
        self.connection_status = Some(match result {
            Ok(Outcome::Accepted { api, revision }) => {
                self.probe_revision = revision;
                let label = pi_providers::Api::ALL
                    .iter()
                    .find(|candidate| candidate.id() == api)
                    .map_or(api.clone(), |candidate| candidate.label().into());
                self.accepted_api = Some(api);
                format!("Connected: the endpoint answered on {label}.")
            }
            Ok(Outcome::Models { ids, revision }) if !ids.is_empty() => {
                self.source_revision = revision;
                self.local_models = ids;
                self.model_step = ModelStep::Picker;
                self.picker = Some(ModelPicker::new(
                    self.local_models
                        .iter()
                        .map(|id| Model {
                            provider: self.configured_provider(),
                            id: id.clone(),
                            name: id.clone(),
                        })
                        .collect(),
                    &self.configured_provider(),
                    self.current.as_ref(),
                ));
                format!(
                    "{} models reported by this server.",
                    self.local_models.len()
                )
            }
            Ok(Outcome::Models { .. }) => "The server answered but reported no chat model.".into(),
            Ok(Outcome::Source {
                label,
                ready: true,
                revision,
                ..
            }) => {
                self.source_revision = Some(revision);
                format!("Credential: {label}")
            }
            Ok(Outcome::Source {
                reason: Some(reason),
                ..
            }) => format!(
                "Credential unusable: {}",
                pi_connection::explain_saved(&reason)
            ),
            Ok(Outcome::Source { label, .. }) => format!("Credential unusable: {label}"),
            Ok(Outcome::Refused { message }) | Err(message) => message,
        });
    }

    pub fn poll_models(&mut self) {
        let Some((generation, job)) = self.model_job.as_mut() else {
            return;
        };
        let generation = *generation;
        let Some(result) = job.poll() else {
            return;
        };
        self.model_job = None;
        if generation == self.generation {
            self.receive_models(result);
        }
    }

    fn receive_models(&mut self, result: Result<Report, String>) {
        self.models_cached = true;
        let preferred = self.picker_provider();
        let current = match self.page {
            Page::Model => self.current.clone(),
            Page::WebSearch => Some((preferred.clone(), self.search.model.clone())),
            Page::Hindsight => Some((preferred.clone(), self.hindsight.model.clone())),
        };
        match result {
            Ok(report) if !report.models.is_empty() => {
                let models = if self.page == Page::Model && !self.pi.choice().endpoint() {
                    report.models
                } else {
                    report
                        .models
                        .into_iter()
                        .filter(|model| model.provider == preferred)
                        .collect()
                };
                self.picker = Some(ModelPicker::new(models, &preferred, current.as_ref()));
                self.model_step = ModelStep::Picker;
                self.error = None;
            }
            _ => {
                self.model_step = ModelStep::Manual;
                self.focus = self.model_field();
                self.error = Some("Model list unavailable or empty. Enter the exact model ID; it remains unverified.".into());
            }
        }
    }

    fn accept_model(&mut self, model: Model) {
        match self.page {
            Page::Model => {
                if self.pi.choice().endpoint() {
                    if model.provider != self.configured_provider() {
                        self.error = Some(
                            "Choose a model from this endpoint, or enter its exact ID.".into(),
                        );
                        return;
                    }
                    if model.id != self.pi.model {
                        self.connection.cancel();
                        self.accepted_api = None;
                        self.probe_revision = None;
                        self.connection_status = None;
                    }
                }
                if model.provider == self.configured_provider() {
                    self.pi.model = model.id.clone();
                }
                self.selected_model = Some((model.provider, model.id));
            }
            Page::WebSearch => self.search.model = model.id,
            Page::Hindsight => self.hindsight.model = model.id,
        }
        self.model_step = ModelStep::Credentials;
        self.picker = None;
        self.error = None;
    }

    fn picker_action(&mut self, action: Option<Action>) -> Option<Decision> {
        match action? {
            Action::Choose(model) => {
                self.accept_model(model);
                Some(Decision::Save)
            }
            Action::Manual => {
                if self.page == Page::Model {
                    self.selected_model = None;
                }
                self.model_step = ModelStep::Manual;
                self.focus = self.model_field();
                None
            }
            Action::Back => {
                self.model_step = ModelStep::Credentials;
                if self.page == Page::Model {
                    self.selected_model = None;
                }
                self.focus = self.page.provider_field();
                self.error = None;
                None
            }
            Action::Cancel => Some(Decision::Cancel),
        }
    }

    /// Credential confirmation is the only discovery trigger. Keep/preview never runs Pi.
    pub fn advance(&mut self, resources: &Path, agent: &Path, preview: bool) -> bool {
        if self.page != Page::Model {
            return preview || self.validate();
        }
        if !preview {
            if let Err(error) = self.resolve_connection_id(agent) {
                self.error = Some(error);
                return false;
            }
        }
        if !self.pi.choice().configured() {
            return true;
        }
        if self.selected_model.is_some() {
            return preview || self.validate();
        }
        if self.model_step == ModelStep::Manual {
            if !preview && !self.validate() {
                return false;
            }
            self.selected_model = Some((self.configured_provider(), self.pi.model.trim().into()));
            return true;
        }
        if !preview
            && self
                .pi
                .choice()
                .preset()
                .is_some_and(|preset| preset.requires_model)
            && !self
                .local_models
                .iter()
                .any(|model| model == self.pi.model.trim())
        {
            self.error = Some("Fetch the server's model list before choosing its model.".into());
            return false;
        }
        if self.model_step != ModelStep::Credentials {
            return false;
        }
        if !preview {
            self.error = validate_credentials(&self.pi, true, self.source() == Mode::New).err();
            if self.error.is_some() {
                return false;
            }
        }
        if self.models_cached {
            self.model_step = if self.picker.is_some() {
                ModelStep::Picker
            } else {
                ModelStep::Manual
            };
            self.focus = Field::PiModel;
            return false;
        }
        if preview {
            self.picker = Some(ModelPicker::new(
                vec![Model {
                    provider: self.configured_provider(),
                    id: "preview-model".into(),
                    name: "Preview model".into(),
                }],
                &self.configured_provider(),
                None,
            ));
            self.model_step = ModelStep::Picker;
            return false;
        }
        let provider = self.configured_provider();
        let request = if self.source() == Mode::Later {
            // Public, bundled models only: no auth.json, credential resolution,
            // model refresh, endpoint request, or unrelated provider fallback.
            serde_json::json!({"version":1,"action":"catalog","agentDir":agent,"provider":provider})
        } else {
            let mut request = serde_json::json!({"version":1,"action":"discover","agentDir":agent,"provider":provider});
            if self.source() == Mode::New || self.pi.choice().endpoint() {
                let mut draft = serde_json::json!({"provider":provider,"key":self.pi.key});
                if self.pi.choice().endpoint() {
                    draft["baseUrl"] = Value::String(self.endpoint_url());
                    if let Some(api) = self.pi_api {
                        draft["api"] = Value::String(api.id().into());
                    }
                }
                request["draft"] = draft;
            }
            request
        };
        match Job::start(resources, request) {
            Ok(job) => {
                self.model_job = Some((self.generation, job));
                self.model_step = ModelStep::Loading;
            }
            Err(error) => self.receive_models(Err(error)),
        }
        false
    }

    fn validate_pi(&self) -> Result<(), String> {
        let result = if self.selected_model.is_some() {
            validate_credentials(&self.pi, true, self.source() == Mode::New)
        } else {
            validate_input(&self.pi, true, self.source() == Mode::New)
        };
        result?;
        if let Some(preset) = self
            .pi
            .choice()
            .preset()
            .filter(|preset| preset.requires_model)
        {
            if !self
                .local_models
                .iter()
                .any(|model| model == self.pi.model.trim())
            {
                return Err(format!(
                    "{}: fetch the server's models and choose one it actually reported.",
                    preset.name
                ));
            }
        }
        if self.needs_probe() {
            return Err(
                "Pi: test this custom connection first; only an accepted request can be saved."
                    .into(),
            );
        }
        Ok(())
    }

    // Keep only provider names, never credential values, in wizard state.
    pub fn load_existing_auth(&mut self, agent: &Path) {
        self.current = read_json_object(&agent.join("settings.json"))
            .ok()
            .and_then(|settings| {
                let provider = settings.get("defaultProvider")?.as_str()?.trim();
                let model = settings.get("defaultModel")?.as_str()?.trim();
                (!provider.is_empty() && !model.is_empty())
                    .then(|| (provider.to_string(), model.to_string()))
            });
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
        self.search_config_present =
            agent.join("web-search.json").exists() || agent.join("web-search.json").is_symlink();
        self.current_search = read_json_object(&agent.join("web-search.json"))
            .ok()
            .and_then(|config| {
                let provider = config.get("provider")?.as_str()?;
                let model = config
                    .get("model")
                    .or_else(|| config.get("modelId"))?
                    .as_str()?;
                valid_identity(provider).then_some(())?;
                valid_identity(model).then(|| (provider.into(), model.into()))
            });
        let path = agent
            .parent()
            .and_then(Path::parent)
            .map(|root| root.join(".hindsight/embed"));
        self.current_hindsight = path
            .and_then(|path| read_hindsight_values(&path).ok())
            .and_then(|values| {
                let provider = values.get("HINDSIGHT_API_LLM_PROVIDER")?.as_str()?;
                let model = values
                    .get("HINDSIGHT_API_LLM_MODEL")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let base_url = values
                    .get("HINDSIGHT_API_LLM_BASE_URL")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let key = values
                    .get("HINDSIGHT_API_LLM_API_KEY")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if !valid_identity(provider)
                    || (!model.is_empty() && !valid_identity(model))
                    || base_url.chars().any(char::is_control)
                {
                    return None;
                }
                Some(SavedHindsight {
                    provider: provider.into(),
                    model: model.into(),
                    base_url: base_url.into(),
                    has_key: !key.is_empty()
                        && key != "unused"
                        && !key.starts_with('!')
                        && !key.contains(['$', '`'])
                        && !key.chars().any(char::is_control),
                })
            });
    }

    /// No live stores are read for UI feedback: metadata and catalogs are simulated.
    pub fn load_preview_defaults(&mut self) {
        self.current = Some(("openai".into(), "preview-chat-model".into()));
        self.current_search = Some(("google".into(), "preview-search-model".into()));
        self.search_config_present = true;
        self.saved_auth.extend(["openai".into(), "google".into()]);
        self.current_hindsight = Some(SavedHindsight {
            provider: "openai".into(),
            model: "preview-memory-model".into(),
            base_url: "https://preview.invalid/v1".into(),
            has_key: true,
        });
    }

    fn fields(&self) -> Vec<Field> {
        let mut fields = Vec::new();
        if self.page == Page::Model {
            if self.model_step == ModelStep::Manual {
                return vec![Field::PiModel, Field::Back, Field::Save];
            }
            fields.push(Field::PiProvider);
            if self.pi.choice() == Choice::Compatible {
                fields.extend([Field::PiId, Field::PiUrl, Field::PiApi, Field::PiModel]);
            }
            if self.pi.choice().preset().is_some() {
                if !self.pi.id.is_empty() {
                    fields.push(Field::PiId);
                }
                fields.extend([Field::PiUrl, Field::PiModel]);
            }
            if self.pi.choice().configured() {
                // One row names where the credential comes from; the key field
                // appears only when a new one is actually being entered.
                if self.pi.choice().pi_provider().is_some() || self.source_choices().len() > 1 {
                    fields.push(Field::PiSource);
                }
                if self.source() == Mode::New {
                    fields.push(Field::PiKey);
                }
            }
            if self.pi.choice().endpoint() {
                fields.push(Field::PiTest);
            }
            fields.extend([Field::Back, Field::Save]);
            return fields;
        }
        if self.page == Page::WebSearch {
            fields.push(Field::WebSearchProvider);
            if self.search.choice().configured() {
                fields.extend([Field::WebSearchModel, Field::WebSearchSource]);
                if self.service_source() == ServiceSource::New {
                    fields.push(Field::WebSearchKey);
                    if self.search.choice() == SearchChoice::Azure {
                        fields.push(Field::WebSearchEndpoint);
                    }
                }
                fields.push(Field::ChooseServiceModel);
            }
        } else {
            fields.push(Field::HindsightProvider);
            if self.hindsight.choice().configured() {
                if self.hindsight.choice() == Choice::Compatible {
                    fields.push(Field::HindsightUrl);
                }
                fields.push(Field::HindsightSource);
                if self.service_source() != ServiceSource::Later {
                    fields.push(Field::HindsightModel);
                    if self.service_source() == ServiceSource::New {
                        fields.push(Field::HindsightKey);
                    }
                    fields.push(Field::ChooseServiceModel);
                }
            }
        }
        fields.extend([Field::Back, Field::Save]);
        fields
    }

    fn chat_model(&self) -> Option<(String, String)> {
        if self.pi.choice() == Choice::Keep {
            self.current.clone()
        } else {
            self.selected_model.clone().or_else(|| {
                (!self.pi.model.trim().is_empty())
                    .then(|| (self.configured_provider(), self.pi.model.trim().into()))
            })
        }
    }

    fn can_share_chat_credentials(&self) -> bool {
        self.chat_model()
            .is_some_and(|(provider, _)| provider == self.search.choice().provider_id())
    }

    fn saved_hindsight_matches(&self) -> bool {
        self.current_hindsight.as_ref().is_some_and(|saved| {
            saved.has_key
                && saved.provider == self.hindsight.choice().provider_id()
                && saved.base_url.trim_end_matches('/')
                    == self.hindsight.url.trim().trim_end_matches('/')
        })
    }

    fn service_sources_for(&self, page: Page) -> Vec<ServiceSource> {
        let mut sources = Vec::new();
        match page {
            Page::WebSearch => {
                if self.can_share_chat_credentials() {
                    sources.push(ServiceSource::Chat);
                }
                if self.saved_auth.contains(self.search.choice().provider_id()) {
                    sources.push(ServiceSource::Saved);
                }
                if self.search.choice().accepts_key() {
                    sources.push(ServiceSource::New);
                }
            }
            Page::Hindsight => {
                if self.saved_hindsight_matches() {
                    sources.push(ServiceSource::Saved);
                }
                sources.push(ServiceSource::New);
            }
            Page::Model => return sources,
        }
        sources.push(ServiceSource::Later);
        sources
    }

    fn service_sources(&self) -> Vec<ServiceSource> {
        self.service_sources_for(self.page)
    }

    fn service_source_for(&self, page: Page) -> ServiceSource {
        let sources = self.service_sources_for(page);
        let selected = if page == Page::Hindsight {
            self.hindsight_source
        } else {
            self.search_source
        };
        selected
            .filter(|source| sources.contains(source))
            .unwrap_or_else(|| sources.first().copied().unwrap_or(ServiceSource::Later))
    }

    fn service_source(&self) -> ServiceSource {
        self.service_source_for(self.page)
    }

    fn service_source_label(&self, source: ServiceSource) -> &'static str {
        match (self.page, source) {
            (_, ServiceSource::Chat) => "Use chat provider credentials",
            (Page::Hindsight, ServiceSource::Saved) => "Keep saved memory key",
            (_, ServiceSource::Saved) => "Use saved Pi credentials",
            (_, ServiceSource::New) => "Enter a new API key",
            (Page::Hindsight, ServiceSource::Later) => "Configure later (keep existing)",
            (_, ServiceSource::Later) => "Sign in later in Pi",
        }
    }

    fn search_label(&self, choice: SearchChoice) -> String {
        match choice {
            SearchChoice::Keep => self.current_search.as_ref().map_or_else(
                || {
                    if self.search_config_present {
                        "Keep existing search configuration (unreadable)".into()
                    } else {
                        "Keep current: uses chat model".into()
                    }
                },
                |(provider, model)| format!("Keep current: {provider}/{model}"),
            ),
            SearchChoice::Chat => self.chat_model().map_or_else(
                || "Use chat model (not configured yet)".into(),
                |(provider, model)| format!("Use chat model: {provider}/{model}"),
            ),
            _ => choice.label().into(),
        }
    }

    fn hindsight_label(&self, choice: Choice) -> String {
        if choice != Choice::Keep {
            return choice.label(false).into();
        }
        self.current_hindsight.as_ref().map_or_else(
            || "Keep existing / set up later".into(),
            |saved| {
                let provider = if saved.base_url.is_empty() {
                    saved.provider.as_str()
                } else {
                    "Custom endpoint"
                };
                if saved.model.is_empty() {
                    format!("Keep current: {provider}")
                } else {
                    format!("Keep current: {provider}/{}", saved.model)
                }
            },
        )
    }

    fn picker_provider(&self) -> String {
        match self.page {
            Page::Model => self.configured_provider(),
            Page::WebSearch => self.search.choice().provider_id().into(),
            Page::Hindsight => self.hindsight.choice().provider_id().into(),
        }
    }

    fn model_field(&self) -> Field {
        match self.page {
            Page::Model => Field::PiModel,
            Page::WebSearch => Field::WebSearchModel,
            Page::Hindsight => Field::HindsightModel,
        }
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
            Field::PiApi | Field::PiSource | Field::WebSearchSource | Field::HindsightSource
        )
    }

    fn pi_label(&self, choice: Choice) -> String {
        if choice == Choice::Keep {
            return self.current.as_ref().map_or_else(
                || "Set up later".into(),
                |(provider, model)| {
                    format!("Keep current: {provider}/{model}")
                        .chars()
                        .filter(|c| !c.is_control())
                        .collect()
                },
            );
        }
        let mut label = choice.label(true).to_string();
        if choice != Choice::Compatible
            && self
                .current
                .as_ref()
                .is_some_and(|(id, _)| id == choice.provider_id())
        {
            label.push_str(" (currently configured)");
        }
        label
    }

    fn options(&self, field: Field) -> Vec<String> {
        match field {
            Field::PiProvider => pi_choices()
                .iter()
                .map(|choice| self.pi_label(*choice))
                .collect(),
            Field::PiApi => std::iter::once(AUTO_API.to_string())
                .chain(pi_providers::Api::ALL.iter().map(|api| api.label().into()))
                .collect(),
            Field::PiSource => self
                .source_choices()
                .iter()
                .map(|mode| mode.label().to_string())
                .collect(),
            Field::WebSearchProvider => SEARCH_CHOICES
                .iter()
                .map(|choice| self.search_label(*choice))
                .collect(),
            Field::HindsightProvider => HINDSIGHT_CHOICES
                .iter()
                .map(|choice| self.hindsight_label(*choice))
                .collect(),
            Field::WebSearchSource | Field::HindsightSource => self
                .service_sources()
                .into_iter()
                .map(|source| self.service_source_label(source).into())
                .collect(),
            _ => Vec::new(),
        }
    }

    fn open_menu(&mut self, field: Field) {
        let highlighted = match field {
            Field::PiApi => Some(self.api_index()),
            Field::PiSource => Some(self.source_index()),
            Field::WebSearchSource | Field::HindsightSource => self
                .service_sources()
                .iter()
                .position(|source| *source == self.service_source()),
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
                if let Some(&choice) = pi_choices().get(index) {
                    self.provider_rows[Page::Model as usize] = index;
                    if choice != self.pi.choice() {
                        self.invalidate_models();
                        self.pi.choice = Some(choice);
                        self.pi_api = Some(pi_providers::Api::default());
                        self.pi_source = None;
                        self.pi.model.clear();
                        self.pi.key.clear();
                        self.pi.id.clear();
                        self.pi.url.clear();
                    }
                }
            }
            Field::PiApi => {
                let api = index
                    .checked_sub(1)
                    .map(|position| pi_providers::Api::ALL.get(position).copied());
                // Index 0 is Auto; anything past the list is not a choice at all.
                if let Some(api) = api
                    .unwrap_or(None)
                    .map(Some)
                    .or(Some(None))
                    .filter(|_| index == 0 || pi_providers::Api::ALL.len() + 1 > index)
                {
                    if api != self.pi_api {
                        self.invalidate_models();
                        self.pi.model.clear();
                        self.pi_api = api;
                    }
                }
            }
            Field::PiSource => {
                if let Some(&mode) = self.source_choices().get(index) {
                    if mode != self.source() {
                        self.invalidate_models();
                        self.pi.key.clear();
                        self.pi_source = Some(mode);
                    }
                }
            }
            Field::WebSearchSource | Field::HindsightSource => {
                if let Some(source) = self.service_sources().get(index).copied() {
                    if source != self.service_source() {
                        self.reset_picker();
                        if field == Field::WebSearchSource {
                            self.search_source = Some(source);
                            self.search.key.clear();
                            self.search.endpoint.clear();
                        } else {
                            self.hindsight_source = Some(source);
                            self.hindsight.key.clear();
                        }
                    }
                }
            }
            Field::WebSearchProvider => {
                if let Some(&choice) = SEARCH_CHOICES.get(index) {
                    self.provider_rows[Page::WebSearch as usize] = index;
                    if choice != self.search.choice() {
                        self.reset_picker();
                        self.search.choice = Some(choice);
                        self.search_source = None;
                        self.search.model = self
                            .current_search
                            .as_ref()
                            .filter(|(provider, _)| provider == choice.provider_id())
                            .map_or_else(String::new, |(_, model)| model.clone());
                        self.search.key.clear();
                        self.search.endpoint.clear();
                    }
                }
            }
            Field::HindsightProvider => {
                if let Some(&choice) = HINDSIGHT_CHOICES.get(index) {
                    self.provider_rows[Page::Hindsight as usize] = index;
                    if choice != self.hindsight.choice() {
                        self.reset_picker();
                        self.hindsight.choice = Some(choice);
                        self.hindsight_source = None;
                        self.hindsight.model.clear();
                        self.hindsight.url.clear();
                        if let Some(saved) = self.current_hindsight.as_ref().filter(|saved| {
                            saved.provider == choice.provider_id()
                                && (choice == Choice::Compatible) == !saved.base_url.is_empty()
                        }) {
                            self.hindsight.model = saved.model.clone();
                            self.hindsight.url = saved.base_url.clone();
                        }
                        self.hindsight.key.clear();
                    }
                }
            }
            _ => {}
        }
        self.dropdown = None;
        self.error = None;
    }

    /// Arrow/wheel navigation belongs to this list, including in preview.
    pub fn browsing_providers(&self) -> bool {
        (self.page != Page::Model || self.model_step == ModelStep::Credentials)
            && self.focus == self.page.provider_field()
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
        if self.model_step == ModelStep::Picker {
            let action = self.picker.as_mut()?.on_click(index);
            return self.picker_action(action);
        }
        if self.is_loading() {
            self.cancel_loading();
            return None;
        }
        if self.model_step == ModelStep::Manual && self.fields().get(index) == Some(&Field::Back) {
            self.model_step = ModelStep::Credentials;
            if self.page == Page::Model {
                self.selected_model = None;
            }
            self.focus = self.page.provider_field();
            self.error = None;
            return None;
        }
        if (self.page != Page::Model || self.model_step == ModelStep::Credentials)
            && (PROVIDER_BASE..PROVIDER_BASE + self.options(self.page.provider_field()).len())
                .contains(&index)
        {
            self.focus = self.page.provider_field();
            self.commit_option(self.page.provider_field(), index - PROVIDER_BASE);
            return None;
        }
        if let Some(menu) = self.dropdown {
            if index >= MENU_BASE {
                let option = index - MENU_BASE;
                if option < self.options(menu.field).len() {
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
            Field::PiTest => {
                self.test_requested = true;
                None
            }
            Field::ChooseServiceModel => {
                self.choose_service_model = true;
                None
            }
            field if Self::is_selector(field) => {
                self.open_menu(field);
                None
            }
            _ => None,
        }
    }

    pub fn on_key(&mut self, code: KeyCode, modifiers: KeyModifiers) -> Option<Decision> {
        if modifiers.contains(KeyModifiers::CONTROL) && code == KeyCode::Char('c') {
            self.cancel_loading();
            return Some(Decision::Cancel);
        }
        if self.model_step == ModelStep::Picker {
            let action = self.picker.as_mut()?.on_key(code, modifiers);
            return self.picker_action(action);
        }
        if self.is_loading() {
            if code == KeyCode::Esc || code == KeyCode::Enter {
                self.cancel_loading();
            }
            return None;
        }
        if self.model_step == ModelStep::Manual
            && (code == KeyCode::Esc || code == KeyCode::Enter && self.focus == Field::Back)
        {
            self.model_step = ModelStep::Credentials;
            if self.page == Page::Model {
                self.selected_model = None;
            }
            self.focus = self.page.provider_field();
            self.error = None;
            return None;
        }
        if matches!(code, KeyCode::Backspace | KeyCode::Char(_))
            && matches!(self.focus, Field::PiId | Field::PiUrl | Field::PiKey)
        {
            self.invalidate_models();
        }
        if matches!(code, KeyCode::Backspace | KeyCode::Char(_)) && self.focus == Field::PiModel {
            self.connection.cancel();
            self.connection_status = None;
            self.accepted_api = None;
            self.probe_revision = None;
            self.selected_model = None;
        }
        if self.browsing_providers() && self.dropdown.is_none() {
            let count = self.options(self.page.provider_field()).len();
            match code {
                KeyCode::Up | KeyCode::Down | KeyCode::PageUp | KeyCode::PageDown => {
                    let direction = match code {
                        KeyCode::Up => -1,
                        KeyCode::Down => 1,
                        KeyCode::PageUp => -10,
                        _ => 10,
                    };
                    self.provider_rows[self.page as usize] =
                        wizard_style::focus_step(self.provider_row(), count, direction, false);
                    return None;
                }
                KeyCode::Home | KeyCode::End => {
                    self.provider_rows[self.page as usize] =
                        if code == KeyCode::Home { 0 } else { count - 1 };
                    return None;
                }
                KeyCode::Enter | KeyCode::Char(' ') => {
                    self.commit_option(self.page.provider_field(), self.provider_row());
                    if code == KeyCode::Enter {
                        self.move_focus(1);
                    }
                    return None;
                }
                _ => {}
            }
        }
        if let Some(menu) = self.dropdown {
            let count = self.options(menu.field).len();
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
                Field::PiTest => {
                    self.test_requested = true;
                    None
                }
                Field::ChooseServiceModel => {
                    self.choose_service_model = true;
                    None
                }
                _ => {
                    self.move_focus(1);
                    None
                }
            },
            KeyCode::Char(' ') if self.focus == Field::PiTest => {
                self.test_requested = true;
                None
            }
            KeyCode::Char(' ') if self.focus == Field::ChooseServiceModel => {
                self.choose_service_model = true;
                None
            }
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

    pub fn connection_busy(&self) -> bool {
        self.connection.busy()
    }

    fn start_service_models(&mut self, resources: &Path, agent: &Path, preview: bool) {
        if self.page == Page::Model {
            return;
        }
        let provider = self.picker_provider();
        if provider.is_empty()
            || self.page == Page::Hindsight && self.service_source() == ServiceSource::Later
        {
            return;
        }
        self.reset_picker();
        if preview {
            let kind = if self.page == Page::WebSearch {
                "search"
            } else {
                "memory"
            };
            self.picker = Some(ModelPicker::new(
                vec![
                    Model {
                        provider: provider.clone(),
                        id: format!("preview-{kind}-model"),
                        name: "Preview model".into(),
                    },
                    Model {
                        provider: provider.clone(),
                        id: format!("preview-{kind}-model-small"),
                        name: "Preview small model".into(),
                    },
                ],
                &provider,
                None,
            ));
            self.model_step = ModelStep::Picker;
            return;
        }
        let result = if self.page == Page::Hindsight
            && self.hindsight.choice() == Choice::Compatible
        {
            if !valid_https_url(self.hindsight.url.trim()) {
                self.error = Some("Memory: enter the endpoint URL before fetching models.".into());
                return;
            }
            let mode = if self.service_source() == ServiceSource::Saved {
                "existing"
            } else {
                "new"
            };
            let request = serde_json::json!({"version":1,"action":"discover","asCatalog":true,
                "scope":"hindsight","agentDir":agent,"provider":"openai",
                "baseUrl":self.hindsight.url.trim(),"mode":mode,"key":self.hindsight.key,
                "nonce":self.nonce,"selfHosted":false});
            Job::start_helper(
                resources,
                "bin/mash-pi-connect.mjs",
                request,
                std::time::Duration::from_secs(15),
            )
        } else {
            let purpose = if self.page == Page::WebSearch {
                "search"
            } else {
                "hindsight"
            };
            Job::start(
                resources,
                serde_json::json!({"version":1,"action":"catalog",
                "agentDir":agent,"provider":provider,"purpose":purpose}),
            )
        };
        match result {
            Ok(job) => {
                self.model_job = Some((self.generation, job));
                self.model_step = ModelStep::Loading;
            }
            Err(error) => self.receive_models(Err(error)),
        }
    }

    /// Explicit actions only; preview supplies canned metadata and never runs a helper.
    pub fn service_connection(&mut self, resources: &Path, agent: &Path, preview: bool) {
        if std::mem::take(&mut self.choose_service_model) {
            self.start_service_models(resources, agent, preview);
        }
        if self.page != Page::Model {
            return;
        }
        if std::mem::take(&mut self.test_requested) {
            self.start_connection(resources, agent, preview);
        }
        if preview {
            return;
        }
        // Name the credential the saved provider would actually use, once per draft.
        if !self.connection.busy()
            && self.inspected != Some(self.generation)
            && self.reuses_saved_credential()
        {
            self.inspected = Some(self.generation);
            let target = self.target();
            let _ = self
                .connection
                .inspect(resources, agent, self.generation, &target);
        }
        self.poll_connection();
    }

    fn validate_search_draft(&self) -> Result<(), String> {
        if self.search.choice() == SearchChoice::Chat {
            let (provider, _) = self
                .chat_model()
                .ok_or("Web search: configure a chat model first")?;
            if !SEARCH_CHOICES
                .iter()
                .any(|choice| choice.configured() && choice.provider_id() == provider)
            {
                return Err("This chat provider is not offered for native web search. Choose a dedicated search provider.".into());
            }
            return Ok(());
        }
        let needs_key = self.service_source_for(Page::WebSearch) == ServiceSource::New;
        if self.search.choice().configured() && needs_key && self.search.key.trim().is_empty() {
            return Err("Web search: enter a key or select Sign in later in Pi".into());
        }
        validate_search(&self.search, !needs_key)
    }

    fn validate_hindsight_draft(&self) -> Result<(), String> {
        if self.service_source_for(Page::Hindsight) == ServiceSource::Later {
            return Ok(());
        }
        validate_input(
            &self.hindsight,
            false,
            self.service_source_for(Page::Hindsight) == ServiceSource::New,
        )
    }

    pub fn validate(&mut self) -> bool {
        let result = match self.page {
            Page::Model => self.validate_pi(),
            Page::WebSearch => self.validate_search_draft(),
            Page::Hindsight => self.validate_hindsight_draft(),
        };
        self.error = result.err();
        self.error.is_none()
    }

    fn save_search_auth(&self, agent: &Path) -> Result<(), String> {
        let choice = self.search.choice();
        let key = self.search.key.trim();
        if !choice.accepts_key()
            || self.service_source_for(Page::WebSearch) != ServiceSource::New
            || key.is_empty()
        {
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
        entry.insert("key".into(), Value::String(literal_key(key)));
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

    /// This draft would write a Pi credential rather than reuse one.
    fn writes_pi_credential(&self) -> bool {
        self.pi.choice().configured() && matches!(self.source(), Mode::New | Mode::None)
    }

    /// This draft would write a web-search credential of its own.
    fn writes_search_credential(&self) -> bool {
        self.search.choice().configured()
            && self.service_source_for(Page::WebSearch) == ServiceSource::New
    }

    /// One `auth.json` slot belongs to one page. Two pages writing the same
    /// provider would silently discard the credential the user typed first.
    fn refuse_shared_credential(&self) -> Result<(), String> {
        let shared = self.writes_pi_credential()
            && self.writes_search_credential()
            && self.search.choice().provider_id() == self.configured_provider();
        shared.then_some(()).map_or(Ok(()), |()| {
            Err(
                "Web search: this provider's credential is set on the Model provider page. Use the chat model's credential here, or choose a different search provider."
                    .into(),
            )
        })
    }

    /// A `/login` credential is material the wizard refuses to replace with a
    /// typed key; the web-search page already holds this same line.
    fn refuse_oauth_replacement(&self, agent: &Path) -> Result<(), String> {
        if !self.writes_pi_credential() {
            return Ok(());
        }
        let auth = read_json_object(&agent.join("auth.json"))?;
        let saved = auth
            .get(&self.configured_provider())
            .and_then(|entry| entry.get("type"))
            .and_then(Value::as_str);
        (saved != Some("oauth")).then_some(()).map_or_else(
            || {
                Err(
                    "Pi: this provider is signed in through Pi /login. Keep the saved credential, or sign in again in Pi instead of replacing it."
                        .into(),
                )
            },
            Ok,
        )
    }

    /// The shipped apply path always uses Pi's shared lock and private writer.
    pub fn save_with_runtime(&self, root: &Path, resources: &Path) -> Result<(), String> {
        self.validate_pi()?;
        self.validate_search_draft()?;
        if programming_enabled(root) {
            self.validate_hindsight_draft()?;
        }
        let agent = root.join("pi/agent");
        self.refuse_shared_credential()?;
        self.refuse_oauth_replacement(&agent)?;
        read_json_object(&agent.join("settings.json"))?;
        if self.pi.choice().endpoint() {
            read_json_object(&agent.join("models.json"))?;
        }
        fs::create_dir_all(&agent).map_err(|_| "Pi credential directory unavailable")?;
        let requests = [
            self.pi_credential_request(&agent)?,
            self.search_credential_request(&agent)?,
        ];
        for request in requests.into_iter().flatten() {
            apply_credential_request(resources, request)?;
        }
        self.save_files(root, true)
    }

    fn pi_credential_request(&self, agent: &Path) -> Result<Option<Value>, String> {
        if !self.pi.choice().configured() {
            return Ok(None);
        }
        let Some(mode) = self.source().id() else {
            return Ok(None);
        };
        if self.pi.choice() == Choice::Compatible && self.probe_revision.is_none() {
            return Err(
                "Test this custom connection again before applying its credentials.".into(),
            );
        }
        let mut request = serde_json::json!({"version":1,"action":"apply","agentDir":agent,
            "provider":self.configured_provider(),"mode":mode,"key":self.pi.key,"nonce":self.nonce,
            "model":self.pi.model.trim(),
            "revision":self.probe_revision.as_ref().or(self.source_revision.as_ref())});
        if self.pi.choice().endpoint() {
            request["baseUrl"] = Value::String(self.endpoint_url());
        }
        Ok(Some(request))
    }

    fn search_credential_request(&self, agent: &Path) -> Result<Option<Value>, String> {
        if !self.search.choice().configured()
            || self.service_source_for(Page::WebSearch) != ServiceSource::New
        {
            return Ok(None);
        }
        let auth = read_json_object(&agent.join("auth.json"))?;
        if auth
            .get(self.search.choice().provider_id())
            .and_then(|entry| entry.get("type"))
            .and_then(Value::as_str)
            == Some("oauth")
        {
            return Err(
                "Web search: manage the existing OAuth credential through Pi /login".into(),
            );
        }
        let mut request = serde_json::json!({"version":1,"action":"apply","agentDir":agent,
            "provider":self.search.choice().provider_id(),"mode":"new","key":self.search.key,"nonce":self.nonce});
        if self.search.choice() == SearchChoice::Azure && !self.search.endpoint.trim().is_empty() {
            request["env"] =
                serde_json::json!({"AZURE_OPENAI_BASE_URL":self.search.endpoint.trim()});
        }
        Ok(Some(request))
    }

    // Filesystem-only unit fixtures exercise page merges independently from the
    // real pinned writer, which the staged runtime gate verifies separately.
    #[cfg(test)]
    fn save(&self, root: &Path) -> Result<(), String> {
        self.save_files(root, false)
    }

    fn save_files(&self, root: &Path, auth_prepared: bool) -> Result<(), String> {
        // The final skills choice also governs seeding: an opt-out (or no
        // choice yet) must neither require nor modify Hindsight's config.
        let programming = programming_enabled(root);
        self.validate_pi()?;
        if programming {
            self.validate_hindsight_draft()?;
        }
        self.validate_search_draft()?;
        self.refuse_shared_credential()?;
        self.refuse_oauth_replacement(&root.join("pi/agent"))?;
        if self.pi.choice().configured() {
            let id = self.configured_provider();
            let agent = root.join("pi/agent");
            let mut settings = read_json_object(&agent.join("settings.json"))?;
            let models = if self.pi.choice().endpoint() {
                let mut models = read_json_object(&agent.join("models.json"))?;
                let providers = models
                    .entry("providers")
                    .or_insert_with(|| Value::Object(Map::new()))
                    .as_object_mut()
                    .ok_or("Pi models.json has an invalid providers object")?;
                let mut model_definitions = providers
                    .get(&id)
                    .and_then(|p| p.get("models"))
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                let selected = self.pi.model.trim();
                if !selected.is_empty()
                    && !model_definitions
                        .iter()
                        .any(|model| model["id"] == selected)
                {
                    model_definitions.push(serde_json::json!({"id": selected}));
                }
                // A local server speaks Chat Completions; only a custom
                // provider chooses, and only an accepted probe decides.
                let api = match (self.pi.choice().preset(), &self.accepted_api) {
                    (Some(_), _) => pi_providers::Api::Chat.id().to_string(),
                    (None, Some(accepted)) => accepted.clone(),
                    // Auto never persists as "auto"; the save gate needs a probe.
                    (None, None) => self
                        .pi_api
                        .ok_or("Pi: test the connection so its API type is known")?
                        .id()
                        .to_string(),
                };
                let mut definition = providers
                    .get(&id)
                    .and_then(Value::as_object)
                    .cloned()
                    .unwrap_or_default();
                definition.insert("baseUrl".into(), Value::String(self.endpoint_url()));
                definition.insert("api".into(), Value::String(api));
                definition.insert("models".into(), Value::Array(model_definitions));
                providers.insert(id.clone(), Value::Object(definition));
                Some(models)
            } else {
                None
            };
            let auth = if auth_prepared {
                None
            } else {
                match self.source() {
                    // Reuse and defer must neither resolve nor rewrite credentials.
                    Mode::Existing | Mode::Later => None,
                    mode => {
                        let mut auth = read_json_object(&agent.join("auth.json"))?;
                        let key = if mode == Mode::None {
                            "mash-local"
                        } else {
                            self.pi.key.trim()
                        };
                        let mut credential =
                            serde_json::json!({"type": "api_key", "key": literal_key(key)});
                        if let Some(env) = auth.get(&id).and_then(|entry| entry.get("env")) {
                            if !env.is_object() {
                                return Err("Pi: existing provider environment is invalid".into());
                            }
                            credential["env"] = env.clone();
                        }
                        auth.insert(id.clone(), credential);
                        Some(auth)
                    }
                }
            };
            let (model_provider, model_id) = self
                .selected_model
                .clone()
                .unwrap_or_else(|| (id, self.pi.model.trim().into()));
            settings.insert("defaultProvider".into(), Value::String(model_provider));
            settings.insert("defaultModel".into(), Value::String(model_id));
            settings.insert(
                "defaultThinkingLevel".into(),
                Value::String("medium".into()),
            );

            if let Some(auth) = auth {
                save_json(&agent.join("auth.json"), &auth)?;
            }
            if let Some(models) = models {
                save_json(&agent.join("models.json"), &models)?;
            }
            save_json(&agent.join("settings.json"), &settings)?;
        }

        if self.search.choice() == SearchChoice::Chat {
            // The extension uses the conversation model only when the override
            // file is absent. Choosing this is distinct from keeping that file.
            let path = root.join("pi/agent/web-search.json");
            if path.is_symlink() {
                return Err("Web search: refusing a symlinked configuration".into());
            }
            match fs::remove_file(&path) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(_) => {
                    return Err("Web search: could not remove the dedicated-model override".into())
                }
            }
        } else if self.search.choice().configured() {
            if !auth_prepared {
                self.save_search_auth(&root.join("pi/agent"))?;
            }
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

        if programming
            && self.hindsight.choice() != Choice::Keep
            && self.service_source_for(Page::Hindsight) != ServiceSource::Later
        {
            let choice = self.hindsight.choice();
            if self.service_source_for(Page::Hindsight) == ServiceSource::Saved {
                let values = read_hindsight_values(&root.join(".hindsight/embed"))?;
                let provider = values
                    .get("HINDSIGHT_API_LLM_PROVIDER")
                    .and_then(Value::as_str);
                let base = values
                    .get("HINDSIGHT_API_LLM_BASE_URL")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if provider != Some(choice.provider_id())
                    || base.trim_end_matches('/') != self.hindsight.url.trim_end_matches('/')
                {
                    return Err("Memory: the saved credential's provider or endpoint changed; choose its source again".into());
                }
                let key = values
                    .get("HINDSIGHT_API_LLM_API_KEY")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if key.is_empty() || key == "unused" {
                    return Err(
                        "Memory: the saved key is unavailable; choose its source again".into(),
                    );
                }
            }
            let model = choice.configured().then_some(self.hindsight.model.trim());
            let url = (choice == Choice::Compatible).then_some(self.hindsight.url.trim());
            let key = if choice == Choice::None {
                Some("unused")
            } else if self.service_source_for(Page::Hindsight) == ServiceSource::Saved {
                None
            } else {
                Some(self.hindsight.key.trim())
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

    fn draw_providers(&self, frame: &mut Frame, area: Rect) {
        let title = match self.page {
            Page::Model => "Model providers",
            Page::WebSearch => "Web search providers",
            Page::Hindsight => "Memory providers",
        };
        let body = wizard_style::section(frame, area, title);
        let list_area = Rect::new(body.x, body.y, body.width, body.height.saturating_sub(1));
        let options = self.options(self.page.provider_field());
        let selected = self.selected_provider_row();
        let items: Vec<_> = options
            .iter()
            .enumerate()
            .map(|(index, label)| {
                let radio = if index == selected { "(*)" } else { "( )" };
                ListItem::new(format!("{radio} {label}"))
            })
            .collect();
        let mut state = ListState::default().with_selected(Some(self.provider_row()));
        frame.render_stateful_widget(
            List::new(items).highlight_style(if self.browsing_providers() {
                wizard_style::selected()
            } else {
                Style::default()
            }),
            list_area,
            &mut state,
        );
        // Ratatui owns the scroll offset. Register exactly the rows it displayed.
        for (row, index) in (state.offset()..options.len())
            .take(list_area.height as usize)
            .enumerate()
        {
            wizard_style::target(
                Rect::new(list_area.x, list_area.y + row as u16, list_area.width, 1),
                PROVIDER_BASE + index,
            );
        }
        if body.height > 0 {
            frame.render_widget(
                Paragraph::new(format!(
                    "↑/↓ browse · Space select · Tab details  {}/{}",
                    self.provider_row() + 1,
                    options.len()
                ))
                .style(Style::default().fg(wizard_style::MUTED)),
                Rect::new(body.x, body.bottom() - 1, body.width, 1),
            );
        }
    }

    fn connection_inputs(&self) -> Vec<(Field, &'static str, String, &'static str)> {
        self.fields()
            .into_iter()
            .filter_map(|field| {
                let (label, value, hint) = match field {
                    Field::PiId => ("Provider ID:", self.pi.id.clone(), "e.g. omniroute"),
                    Field::PiUrl => ("Base URL:", self.endpoint_url(), "API base URL"),
                    Field::PiApi => ("API type:", self.api_label().to_string(), "API family"),
                    Field::PiModel => ("Model ID:", self.pi.model.clone(), "Exact model ID"),
                    Field::PiSource => (
                        "Credential:",
                        self.source().label().to_string(),
                        if self.source() == Mode::Later {
                            "Use /login in Pi"
                        } else {
                            "Saved or new"
                        },
                    ),
                    Field::PiKey => (
                        "API key:",
                        masked(&self.pi.key),
                        self.pi
                            .choice()
                            .pi_provider()
                            .map_or("Kept private", |provider| provider.key_label()),
                    ),
                    Field::WebSearchModel => {
                        ("Model ID:", self.search.model.clone(), "Pick or enter ID")
                    }
                    Field::WebSearchSource => (
                        "Credential:",
                        self.service_source_label(self.service_source()).into(),
                        "Stored in Pi",
                    ),
                    Field::WebSearchKey => ("API key:", masked(&self.search.key), "Stored in Pi"),
                    Field::WebSearchEndpoint => {
                        ("Base URL:", self.search.endpoint.clone(), "Azure endpoint")
                    }
                    Field::HindsightUrl => {
                        ("Base URL:", self.hindsight.url.clone(), "Chat Completions")
                    }
                    Field::HindsightModel => (
                        "Model ID:",
                        self.hindsight.model.clone(),
                        "Pick or enter ID",
                    ),
                    Field::HindsightSource => (
                        "Credential:",
                        self.service_source_label(self.service_source()).into(),
                        "Memory only",
                    ),
                    Field::HindsightKey => ("API key:", masked(&self.hindsight.key), "Memory only"),
                    _ => return None,
                };
                Some((field, label, value, hint))
            })
            .collect()
    }

    fn details_hint(&self) -> Option<String> {
        match self.page {
            Page::Model => self.login_later_hint()
                .or_else(|| self.pi.choice().pi_provider().and_then(|provider| provider.guidance()))
                .or_else(|| (self.pi.choice() == Choice::Keep)
                    .then(|| "Current provider settings stay unchanged.".into())),
            Page::WebSearch => {
                let choice = self.search.choice();
                if choice == SearchChoice::Keep {
                    return Some("Keeps the existing search configuration and credentials unchanged.".into());
                }
                if choice == SearchChoice::Chat {
                    return Some("Removes the dedicated search override and follows your conversation model. That model must support native search; there is no automatic fallback.".into());
                }
                let id = choice.provider_id();
                Some(match self.service_source() {
                    ServiceSource::Chat => "Shares this provider's Pi credentials with chat; no key is copied to another provider.".into(),
                    ServiceSource::Saved => "Uses this provider's saved Pi credentials unchanged. Selecting another model does not replace the key.".into(),
                    ServiceSource::New => "The new key is saved in Pi on final apply. The catalog lists native-search models, not every chat model.".into(),
                    ServiceSource::Later => format!("Model configured without changing credentials. After setup, run /login {id} in Pi.{}",
                        if choice == SearchChoice::Azure { " Azure also needs its endpoint configured." } else { "" }),
                })
            }
            Page::Hindsight => Some(match self.hindsight.choice() {
                Choice::Keep => "Existing memory configuration stays unchanged.",
                Choice::None => "Memory will not use an LLM.",
                _ => match self.service_source() {
                    ServiceSource::Saved => "Keeps memory's saved key for this provider and endpoint. Model-only edits preserve it.",
                    ServiceSource::Later => "Memory configuration is deferred. Existing settings and credentials stay unchanged; Pi /login does not authenticate memory.",
                    _ => "Memory uses its own key, never a Pi login. Model suggestions are not a memory compatibility guarantee.",
                },
            }.into()),
        }
    }

    fn draw_connection_details(&self, frame: &mut Frame, area: Rect) {
        let body = wizard_style::section(frame, area, "Connection details");
        if body.height == 0 || body.width == 0 {
            return;
        }
        let fields = self.connection_inputs();
        let has_test = self.fields().contains(&Field::PiTest);
        let has_picker = self.fields().contains(&Field::ChooseServiceModel);
        let hint = self.details_hint();
        let status = (self.page == Page::Model)
            .then_some(self.connection_status.as_deref())
            .flatten();
        let note = self.error.as_deref().or(status).or(hint.as_deref());
        let action_height = if has_test || has_picker {
            // A short panel still owes one row to the focused field.
            4.min(body.height.saturating_sub(u16::from(!fields.is_empty())))
        } else if fields.is_empty() {
            0
        } else {
            note.map_or(0, |text| {
                Paragraph::new(text)
                    .wrap(Wrap { trim: true })
                    .line_count(body.width)
                    .max(1)
                    .min(body.height.saturating_sub(1) as usize) as u16
            })
        };
        let form = Rect::new(body.x, body.y, body.width, body.height - action_height);
        // Match Identity: aligned labels, filled inputs, a separate muted help
        // column, blank rows between fields, and horizontal scrolling in inputs.
        let label_width = 13.min(form.width);
        let input_width = fields
            .iter()
            .map(|(_, _, value, _)| Line::from(value.clone()).width() + 3)
            .max()
            .unwrap_or(0)
            .max(32)
            .min(form.width.saturating_sub(label_width + 11) as usize)
            as u16;
        let help_x = form.x + label_width + input_width + 3;
        let help_width = form.right().saturating_sub(help_x);
        let mut row = 0;
        let rows: Vec<_> = fields
            .iter()
            .map(|(field, _, _, hint)| {
                let height = Paragraph::new(*hint)
                    .wrap(Wrap { trim: true })
                    .line_count(help_width.max(1))
                    .max(1) as u16;
                let menu_height = if self.dropdown.is_some_and(|menu| menu.field == *field) {
                    self.options(*field)
                        .len()
                        .min(MENU_ROWS)
                        .min(form.height.saturating_sub(1) as usize) as u16
                } else {
                    0
                };
                let start = row;
                row += height + menu_height + 1;
                (start, height, menu_height)
            })
            .collect();
        let focus_index = fields
            .iter()
            .position(|(field, _, _, _)| self.focus == *field)
            .unwrap_or(if matches!(self.focus, Field::PiTest | Field::Save) {
                fields.len().saturating_sub(1)
            } else {
                0
            });
        let focus_end = rows
            .get(focus_index)
            .map_or(0, |(row, height, menu)| row + height + menu);
        let focus_row = rows.get(focus_index).map_or(0, |(row, _, _)| *row);
        let scroll = rows
            .iter()
            .map(|(row, _, _)| *row)
            .find(|row| focus_end.saturating_sub(*row) <= form.height)
            .unwrap_or(focus_row)
            // An open menu lengthens the focused block; it must never scroll
            // its own field out of view and keep receiving keystrokes.
            .min(focus_row);
        let field_ids = self.fields();
        for ((field, label, value, hint), (row, height, menu_height)) in fields.iter().zip(rows) {
            if row < scroll || row - scroll >= form.height {
                continue;
            }
            let y = form.y + row - scroll;
            let focused = self.focus == *field;
            let input = Rect::new(form.x + label_width, y, input_width, 1);
            frame.render_widget(
                Paragraph::new(*label).style(Style::default().add_modifier(Modifier::BOLD)),
                Rect::new(form.x, y, label_width, 1),
            );
            let selector = Self::is_selector(*field);
            let text = Line::from(vec![
                Span::raw(" "),
                Span::raw(value.clone()),
                Span::styled(
                    if selector {
                        " ▾"
                    } else if focused {
                        "_"
                    } else {
                        " "
                    },
                    Style::default().fg(wizard_style::YELLOW),
                ),
                Span::raw(" "),
            ]);
            let horizontal_scroll = if focused {
                text.width().saturating_sub(input_width as usize)
            } else {
                0
            };
            frame.render_widget(
                Paragraph::new(text)
                    .style(if focused {
                        wizard_style::selected()
                    } else {
                        Style::default()
                            .fg(wizard_style::TEXT)
                            .bg(wizard_style::SURFACE)
                    })
                    .scroll((0, horizontal_scroll.min(u16::MAX as usize) as u16)),
                input,
            );
            if let Some(id) = field_ids.iter().position(|candidate| candidate == field) {
                wizard_style::target(Rect::new(form.x, y, label_width + input_width, 1), id);
            }
            frame.render_widget(
                Paragraph::new(*hint)
                    .wrap(Wrap { trim: true })
                    .style(Style::default().fg(wizard_style::MUTED)),
                Rect::new(help_x, y, help_width, height.min(form.bottom() - y)),
            );
            if let Some(menu) = self.dropdown.filter(|menu| menu.field == *field) {
                let options = self.options(*field);
                let visible =
                    (menu_height as usize).min(form.bottom().saturating_sub(y + 1) as usize);
                let start = menu.highlighted.saturating_sub(visible.saturating_sub(1));
                for (offset, index) in (start..options.len()).take(visible).enumerate() {
                    let rect = Rect::new(input.x, y + 1 + offset as u16, input.width, 1);
                    frame.render_widget(
                        Paragraph::new(format!(" {}", options[index])).style(
                            if index == menu.highlighted {
                                wizard_style::selected()
                            } else {
                                Style::default()
                                    .fg(wizard_style::TEXT)
                                    .bg(wizard_style::SURFACE)
                            },
                        ),
                        rect,
                    );
                    wizard_style::target(rect, MENU_BASE + index);
                }
            }
        }
        if fields.is_empty() {
            frame.render_widget(
                Paragraph::new(note.unwrap_or("No additional configuration needed."))
                    .wrap(Wrap { trim: true })
                    .style(Style::default().fg(if self.error.is_some() {
                        wizard_style::RED
                    } else {
                        wizard_style::MUTED
                    })),
                form,
            );
        }
        if has_test || has_picker {
            // Exactly the GitHub sign-in treatment: filled even when unfocused,
            // with status beside the button, never an editable instruction row.
            let button = Rect::new(body.x, body.bottom() - action_height, 23.min(body.width), 1);
            frame.render_widget(
                Paragraph::new(if has_picker {
                    if self.page == Page::Hindsight && self.hindsight.choice() == Choice::Compatible
                    {
                        "Fetch models"
                    } else {
                        "Choose model"
                    }
                } else if self.connection.busy() {
                    "Testing..."
                } else {
                    "Test connection"
                })
                .alignment(Alignment::Center)
                .style(
                    if self.focus == Field::PiTest || self.focus == Field::ChooseServiceModel {
                        wizard_style::selected().add_modifier(Modifier::BOLD)
                    } else {
                        wizard_style::selected()
                    },
                ),
                button,
            );
            if let Some(id) = field_ids.iter().position(|field| {
                *field
                    == if has_picker {
                        Field::ChooseServiceModel
                    } else {
                        Field::PiTest
                    }
            }) {
                wizard_style::target(button, id);
            }
            let note_x = button.right() + 3;
            let note = self
                .error
                .as_deref()
                .or(if has_picker {
                    hint.as_deref()
                } else {
                    self.connection_status.as_deref()
                })
                .unwrap_or("Not tested");
            let color = if self.error.is_some() {
                wizard_style::RED
            } else if self.connection.busy() {
                wizard_style::YELLOW
            } else if self.accepted_api.is_some() {
                wizard_style::GREEN
            } else {
                wizard_style::MUTED
            };
            frame.render_widget(
                Paragraph::new(note)
                    .wrap(Wrap { trim: true })
                    .style(Style::default().fg(color)),
                Rect::new(
                    note_x,
                    button.y,
                    body.right().saturating_sub(note_x),
                    action_height.min(2),
                ),
            );
            if action_height >= 3 {
                let summary = if has_picker {
                    if self.page == Page::Hindsight && self.hindsight.choice() == Choice::Compatible
                    {
                        "Lists endpoint models; no inference or memory writes."
                    } else {
                        "Browse suggestions or enter an exact model ID."
                    }
                } else {
                    "Sends a short request; provider charges may apply."
                };
                frame.render_widget(
                    Paragraph::new(summary).style(Style::default().fg(wizard_style::MUTED)),
                    Rect::new(body.x, button.y + 2, body.width, 1),
                );
            }
        } else if let Some(note) = note.filter(|_| !fields.is_empty()) {
            frame.render_widget(
                Paragraph::new(note)
                    .wrap(Wrap { trim: true })
                    .style(Style::default().fg(if self.error.is_some() {
                        wizard_style::RED
                    } else {
                        wizard_style::MUTED
                    })),
                Rect::new(
                    body.x,
                    body.bottom() - action_height,
                    body.width,
                    action_height,
                ),
            );
        }
    }

    fn draw_setup(&self, frame: &mut Frame) {
        let area = wizard_style::page_area(frame, Some(self.page.index()));
        let show_providers = self.page != Page::Model || self.model_step == ModelStep::Credentials;
        let parts = if show_providers {
            let desired = (self.connection_inputs().len() * 2
                + 2
                + if self.fields().contains(&Field::PiTest)
                    || self.fields().contains(&Field::ChooseServiceModel)
                {
                    4
                } else if self.details_hint().is_some() {
                    3
                } else {
                    0
                })
            .max(5);
            Layout::vertical([
                Constraint::Length(3),
                Constraint::Min(6),
                // A short terminal keeps one usable detail row: a panel that
                // collapses to zero height hides fields and click targets.
                Constraint::Length(
                    desired
                        .min(area.height.saturating_sub(12) as usize)
                        .max(7.min(area.height.saturating_sub(9) as usize))
                        as u16,
                ),
                Constraint::Length(3),
            ])
            .split(area)
        } else {
            Layout::vertical([
                Constraint::Length(3),
                Constraint::Min(6),
                Constraint::Length(3),
            ])
            .split(area)
        };
        wizard_style::header(
            frame,
            parts[0],
            &wizard_style::page_title(self.page.title(), self.page.index()),
        );
        if show_providers {
            self.draw_providers(frame, parts[1]);
        }
        self.draw_connection_details(frame, parts[if show_providers { 2 } else { 1 }]);
        let fields = self.fields();
        let position = |field| fields.iter().position(|candidate| *candidate == field);
        wizard_style::render_buttons(
            frame,
            *parts.last().expect("page footer"),
            &[
                (
                    wizard_style::button(self.focus == Field::Back, " Back "),
                    position(Field::Back),
                ),
                (Span::raw("    "), None),
                (
                    wizard_style::button(
                        self.focus == Field::Save,
                        match self.page {
                            Page::Model if show_providers && self.pi.choice().configured() => {
                                " Choose model "
                            }
                            Page::Model => " Next — Web search ",
                            Page::WebSearch => " Next — Memory ",
                            Page::Hindsight => " Next — Appearance ",
                        },
                    ),
                    position(Field::Save),
                ),
            ],
        );
    }

    pub fn draw(&self, frame: &mut Frame) {
        if self.model_step == ModelStep::Picker {
            if let Some(picker) = &self.picker {
                if self.page == Page::Model {
                    picker.draw(frame);
                } else {
                    picker.draw_for(
                        frame,
                        self.page.title(),
                        self.page.index(),
                        if self.page == Page::WebSearch {
                            "Native-search catalog; availability is not verified"
                        } else {
                            "Model suggestions; memory compatibility is not verified"
                        },
                    );
                }
                return;
            }
        }
        if self.is_loading() {
            let parts = Layout::vertical([
                Constraint::Length(3),
                Constraint::Min(3),
                Constraint::Length(3),
            ])
            .split(wizard_style::page_area(frame, Some(self.page.index())));
            wizard_style::header(
                frame,
                parts[0],
                &wizard_style::page_title(self.page.title(), self.page.index()),
            );
            let body = wizard_style::section(
                frame,
                parts[1],
                if self.page == Page::Hindsight && self.hindsight.choice() == Choice::Compatible {
                    "Fetching models from the selected endpoint..."
                } else {
                    "Loading the local model catalog..."
                },
            );
            frame.render_widget(
                Paragraph::new(
                    "No server authentication or account entitlement check is performed.",
                ),
                body,
            );
            wizard_style::render_buttons(
                frame,
                parts[2],
                &[(wizard_style::button(true, " Back "), Some(0))],
            );
            return;
        }
        self.draw_setup(frame);
    }
}

fn endpoint_slot_available(
    definition: Option<&Value>,
    credential: Option<&Value>,
    target: (&str, Option<&str>, &str),
    no_auth: bool,
) -> bool {
    if no_auth
        && credential
            .is_some_and(|entry| entry["key"] != "mash-local" || entry["type"] != "api_key")
    {
        return false;
    }
    let Some(definition) = definition else {
        return credential.is_none();
    };
    endpoint_binding_matches(definition, target.0, target.1, target.2)
}

/// Auto has not probed yet, so an existing known family is still this draft;
/// that is what stops a re-run from minting a new alias every time.
fn speaks_api(saved: Option<&str>, draft: Option<&str>) -> bool {
    draft.map_or_else(
        || saved.is_some_and(|id| pi_providers::Api::ALL.iter().any(|known| known.id() == id)),
        |api| saved == Some(api),
    )
}

fn model_row_matches(row: &Value, url: &str, api: Option<&str>) -> bool {
    row.get("headers").is_none()
        && row["api"]
            .as_str()
            .is_none_or(|saved| speaks_api(Some(saved), api))
        && row["baseUrl"]
            .as_str()
            .is_none_or(|value| value.trim_end_matches('/') == url.trim_end_matches('/'))
}

fn endpoint_binding_matches(definition: &Value, url: &str, api: Option<&str>, model: &str) -> bool {
    if definition["baseUrl"]
        .as_str()
        .map(|value| value.trim_end_matches('/'))
        != Some(url.trim_end_matches('/'))
        || !speaks_api(definition["api"].as_str(), api)
        || definition.get("apiKey").is_some()
        || definition.get("headers").is_some()
    {
        return false;
    }
    definition["models"]
        .as_array()
        .and_then(|models| models.iter().find(|row| row["id"] == model))
        .is_none_or(|row| model_row_matches(row, url, api))
}

fn programming_enabled(root: &Path) -> bool {
    fs::read_to_string(root.join("setup/skills-choice"))
        .unwrap_or_default()
        .lines()
        .any(|line| line == "programming=true")
}

fn apply_credential_request(resources: &Path, request: Value) -> Result<(), String> {
    let mut job = Job::start_helper(
        resources,
        "bin/mash-pi-credentials.mjs",
        request,
        std::time::Duration::from_secs(12),
    )?;
    loop {
        if let Some(result) = job.poll_json() {
            let value = result?;
            if value["version"] != 1
                || value["status"] != "ok"
                || value["wrote"].as_bool().is_none()
            {
                return Err("Pi credentials changed or could not be saved. Review the selected source and test custom connections again.".into());
            }
            return Ok(());
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
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

/// A loopback preset may be plain HTTP; anything else must be HTTPS.
fn validate_endpoint(input: &Input, url: &str) -> Result<(), String> {
    if input.choice().preset().is_some() {
        let local = url
            .strip_prefix("http://")
            .and_then(|rest| rest.split(['/', ':', '?']).next())
            .is_some_and(|host| {
                host == "localhost" || host == "127.0.0.1" || host.starts_with("192.168.")
            });
        if local && !url.chars().any(|c| c.is_whitespace() || c.is_control()) {
            return Ok(());
        }
    }
    valid_https_url(url)
        .then_some(())
        .ok_or_else(|| "Pi: enter an HTTPS base URL, or a local server address".into())
}

/// Pi reads "$" as a reference and a leading "!" as a command; escape both.
fn literal_key(key: &str) -> String {
    let escaped = key.replace('$', "$$");
    match escaped.strip_prefix('!') {
        Some(rest) => format!("$!{rest}"),
        None => escaped,
    }
}

fn session_nonce() -> String {
    use std::io::Read;
    let mut bytes = [0u8; 32];
    if fs::File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut bytes))
        .is_err()
    {
        // Empty fails helper validation; do not fall back to a predictable HMAC key.
        return String::new();
    }
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn validate_input(input: &Input, pi: bool, needs_key: bool) -> Result<(), String> {
    validate_credentials(input, pi, needs_key)?;
    if input.choice().configured()
        && (input.model.trim().is_empty() || input.model.chars().any(char::is_control))
    {
        return Err(format!(
            "{}: enter an exact model ID",
            if pi { "Pi" } else { "Memory" }
        ));
    }
    Ok(())
}

/// `needs_key` is the credential source: only a new key must be typed here.
/// The endpoint and its identity are checked whatever the source is.
fn validate_credentials(input: &Input, pi: bool, needs_key: bool) -> Result<(), String> {
    let label = if pi { "Pi" } else { "Memory" };
    let choice = input.choice();
    if !choice.configured() {
        return Ok(());
    }
    if let Some(preset) = choice.preset() {
        validate_endpoint(input, {
            let typed = input.url.trim();
            if typed.is_empty() {
                preset.base_url
            } else {
                typed
            }
        })?;
    }
    if pi && choice.endpoint() && (choice == Choice::Compatible || !input.id.is_empty()) {
        let id = input.id.trim();
        if !id.starts_with(|c: char| c.is_ascii_lowercase())
            || !id
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_')
            || pi_providers::reserved(id)
        {
            return Err("Pi: use a unique lowercase provider ID (e.g. omniroute)".into());
        }
    }
    if choice == Choice::Compatible && !valid_https_url(input.url.trim()) {
        return Err(format!(
            "{label}: enter an HTTPS base URL without credentials"
        ));
    }
    if needs_key && (input.key.is_empty() || !input.key.chars().all(|c| c.is_ascii_graphic())) {
        return Err(format!(
            "{label}: enter an API key without spaces or control characters"
        ));
    }
    Ok(())
}

fn valid_identity(value: &str) -> bool {
    !value.is_empty() && value.len() <= 4096 && !value.chars().any(char::is_control)
}

/// Parse only the four literal dotenv settings we own, without sourcing a shell
/// or evaluating references. The caller keeps metadata, never a saved key.
fn read_hindsight_values(path: &Path) -> Result<Map<String, Value>, String> {
    use std::io::Read;
    if path.is_symlink() || path.parent().is_some_and(Path::is_symlink) {
        return Err("Memory: refusing a symlinked configuration".into());
    }
    let file = match fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Map::new()),
        Err(_) => return Err("Memory configuration unavailable".into()),
    };
    let mut text = String::new();
    file.take(1024 * 1024 + 1)
        .read_to_string(&mut text)
        .map_err(|_| "Memory configuration unavailable")?;
    if text.len() > 1024 * 1024 {
        return Err("Memory configuration is too large".into());
    }
    let mut values = Map::new();
    for line in text.lines() {
        let line = line.trim().strip_prefix("export ").unwrap_or(line.trim());
        let Some((name, value)) = line.split_once('=') else {
            continue;
        };
        if ![
            "HINDSIGHT_API_LLM_PROVIDER",
            "HINDSIGHT_API_LLM_MODEL",
            "HINDSIGHT_API_LLM_BASE_URL",
            "HINDSIGHT_API_LLM_API_KEY",
        ]
        .contains(&name.trim())
        {
            continue;
        }
        let value = value.trim();
        let value = value
            .strip_prefix('"')
            .and_then(|v| v.strip_suffix('"'))
            .or_else(|| value.strip_prefix('\'').and_then(|v| v.strip_suffix('\'')))
            .unwrap_or(value);
        values.insert(name.trim().into(), Value::String(value.into()));
    }
    Ok(values)
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
    key: Option<&str>,
) -> Result<(), String> {
    if path.is_symlink() {
        return Err("refusing a symlink in memory config".into());
    }
    let original = fs::read_to_string(path).map_err(|e| format!("Memory config: {e}"))?;
    let values = [
        ("HINDSIGHT_API_LLM_PROVIDER", Some(provider)),
        ("HINDSIGHT_API_LLM_MODEL", model),
        ("HINDSIGHT_API_LLM_BASE_URL", url),
        ("HINDSIGHT_API_LLM_API_KEY", key),
    ];
    let mut result = String::new();
    let mut seen = [false; 4];
    for line in original.lines() {
        if let Some(index) = values.iter().position(|(name, _)| {
            line.trim_start()
                .strip_prefix("export ")
                .unwrap_or(line)
                .split_once('=')
                .is_some_and(|(key, _)| key.trim() == *name)
        }) {
            if index == 3 && key.is_none() {
                // A model-only edit preserves the saved key line verbatim,
                // including its quoting/reference syntax and duplicate lines.
                result.push_str(line);
                result.push('\n');
                seen[index] = true;
                continue;
            }
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
        fs::create_dir_all(path.join("setup")).unwrap();
        fs::write(path.join("setup/skills-choice"), "programming=true\n").unwrap();
        path
    }

    #[test]
    fn shipped_apply_uses_the_credential_helper_and_never_rewrites_its_auth_merge() {
        let root = root();
        let agent = root.join("pi/agent");
        let resources = root.join("resources");
        fs::create_dir_all(resources.join("node/bin")).unwrap();
        let node = resources.join("node/bin/node");
        let merged = r#"{"openai":{"type":"api_key","key":"fixture-key"},"concurrent":{"type":"api_key","key":"other-owner"}}"#;
        fs::write(&node, format!("#!/bin/sh\n/bin/cat > request.json\nprintf '%s' '{}' > '{}'\nprintf '{{\"version\":1,\"status\":\"ok\",\"wrote\":true}}\\n'\n", merged, agent.join("auth.json").display())).unwrap();
        fs::set_permissions(&node, fs::Permissions::from_mode(0o755)).unwrap();
        let mut page = ProviderPage::new();
        page.pi.choice = Some(Choice::OpenAi);
        page.pi.key = "fixture-key".into();
        page.pi.model = "chosen-model".into();
        page.save_with_runtime(&root, &resources).unwrap();
        let request: Value =
            serde_json::from_slice(&fs::read(resources.join("request.json")).unwrap()).unwrap();
        assert_eq!(request["action"], "apply");
        assert_eq!(request["mode"], "new");
        assert_eq!(request["key"], "fixture-key");
        assert!(
            request.get("baseUrl").is_none(),
            "native credentials have no empty/null endpoint"
        );
        assert_eq!(fs::read_to_string(agent.join("auth.json")).unwrap(), merged);
        assert_eq!(
            read_json_object(&agent.join("settings.json")).unwrap()["defaultModel"],
            "chosen-model"
        );
        fs::remove_file(agent.join("settings.json")).unwrap();
        fs::write(&node, "#!/bin/sh\n/bin/cat >/dev/null\nprintf '{\"version\":99,\"status\":\"ok\",\"wrote\":true}\\n'\n").unwrap();
        assert!(page.save_with_runtime(&root, &resources).is_err());
        assert!(
            !agent.join("settings.json").exists(),
            "bad helper replies never become a saved default"
        );
        fs::write(agent.join("auth.json"), "must-not-be-read-as-json").unwrap();
        fs::remove_file(resources.join("request.json")).unwrap();
        page.pi_source = Some(Mode::Later);
        page.save_with_runtime(&root, &resources).unwrap();
        assert_eq!(
            fs::read_to_string(agent.join("auth.json")).unwrap(),
            "must-not-be-read-as-json"
        );
        assert!(
            !resources.join("request.json").exists(),
            "defer never starts a credential helper"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn service_current_labels_sources_and_model_only_saves_preserve_credentials() {
        let root = root();
        let agent = root.join("pi/agent");
        let auth = r#"{"google":{"type":"api_key","key":"pi-only-secret"}}"#;
        fs::write(agent.join("auth.json"), auth).unwrap();
        fs::write(
            agent.join("web-search.json"),
            r#"{"provider":"google","model":"old-search"}"#,
        )
        .unwrap();
        let embed = root.join(".hindsight/embed");
        let key_line = "HINDSIGHT_API_LLM_API_KEY='hindsight-only-secret'";
        fs::write(&embed, format!("HINDSIGHT_API_PORT=8998\nHINDSIGHT_API_LLM_PROVIDER=openai\nHINDSIGHT_API_LLM_MODEL=old-memory\nHINDSIGHT_API_LLM_BASE_URL=https://memory.invalid/v1\n{key_line}\n")).unwrap();
        let mut page = ProviderPage::new();
        page.load_existing_auth(&agent);
        assert!(page
            .search_label(SearchChoice::Keep)
            .contains("google/old-search"));
        assert!(page
            .hindsight_label(Choice::Keep)
            .contains("Custom endpoint/old-memory"));
        assert!(
            page.pi.key.is_empty() && page.search.key.is_empty() && page.hindsight.key.is_empty()
        );
        page.set_page(Page::WebSearch);
        page.commit_option(Field::WebSearchProvider, 2);
        assert!(page.service_source() == ServiceSource::Saved);
        assert!(!page.fields().contains(&Field::WebSearchKey));
        page.search.model = "new-search".into();
        page.save(&root).unwrap();
        assert_eq!(fs::read_to_string(agent.join("auth.json")).unwrap(), auth);
        page.set_page(Page::Hindsight);
        page.commit_option(Field::HindsightProvider, HINDSIGHT_CHOICES.len() - 1);
        assert!(page.service_source() == ServiceSource::Saved);
        assert!(!page.fields().contains(&Field::HindsightKey));
        page.hindsight.model = "new-memory".into();
        page.save(&root).unwrap();
        let saved = fs::read_to_string(&embed).unwrap();
        assert!(saved.lines().any(|line| line == key_line));
        assert!(saved.contains("HINDSIGHT_API_LLM_MODEL=new-memory"));
        assert!(saved.contains("HINDSIGHT_API_PORT=8998"));
        assert_eq!(fs::read_to_string(agent.join("auth.json")).unwrap(), auth);
        page.hindsight.url = "https://another.invalid/v1".into();
        assert!(!page.service_sources().contains(&ServiceSource::Saved));
        page.hindsight_source = Some(ServiceSource::Later);
        page.save(&root).unwrap();
        assert_eq!(fs::read_to_string(&embed).unwrap(), saved);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn use_chat_is_distinct_from_keep_and_never_borrows_another_providers_key() {
        let root = root();
        let agent = root.join("pi/agent");
        let auth = r#"{"openai":{"type":"api_key","key":"chat-key","env":{"KEEP":"yes"}}}"#;
        fs::write(agent.join("auth.json"), auth).unwrap();
        fs::write(
            agent.join("settings.json"),
            r#"{"defaultProvider":"openai","defaultModel":"chat-model"}"#,
        )
        .unwrap();
        let search = r#"{"provider":"google","model":"search-model"}"#;
        fs::write(agent.join("web-search.json"), search).unwrap();
        let mut page = ProviderPage::new();
        page.load_existing_auth(&agent);
        page.set_page(Page::WebSearch);
        page.save(&root).unwrap();
        assert_eq!(
            fs::read_to_string(agent.join("web-search.json")).unwrap(),
            search
        );
        page.commit_option(Field::WebSearchProvider, 1);
        assert!(page.validate());
        page.save(&root).unwrap();
        assert!(!agent.join("web-search.json").exists());
        assert_eq!(fs::read_to_string(agent.join("auth.json")).unwrap(), auth);
        page.commit_option(Field::WebSearchProvider, 3);
        assert!(page.service_source() == ServiceSource::Chat);
        page.search.model = "another-openai-model".into();
        page.save(&root).unwrap();
        assert_eq!(fs::read_to_string(agent.join("auth.json")).unwrap(), auth);
        page.commit_option(Field::WebSearchProvider, 2);
        assert!(!page.service_sources().contains(&ServiceSource::Chat));
        assert!(!page.service_sources().contains(&ServiceSource::Saved));
        page.search_source = Some(ServiceSource::Later);
        page.search.model = "google-model".into();
        assert!(!page.fields().contains(&Field::WebSearchKey));
        page.save(&root).unwrap();
        assert_eq!(fs::read_to_string(agent.join("auth.json")).unwrap(), auth);
        assert_eq!(
            read_json_object(&agent.join("web-search.json")).unwrap()["provider"],
            "google"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn service_pickers_scope_models_and_preserve_other_page_drafts() {
        let root = root();
        let resources = root.join("resources");
        fs::create_dir_all(resources.join("node/bin")).unwrap();
        let node = resources.join("node/bin/node");
        let report = serde_json::json!({"version":1,"status":"ok","serverVerified":false,"catalogComplete":true,"modelKnown":null,"auth":{"status":"unverified"},"models":[{"provider":"openai","id":"scoped-model","name":"Scoped"},{"provider":"other","id":"must-not-appear","name":"Wrong provider"}]});
        fs::write(
            &node,
            format!(
                "#!/bin/sh\n/bin/cat > request.json\nprintf '%s\\n' '{}'\n",
                report
            ),
        )
        .unwrap();
        fs::set_permissions(&node, fs::Permissions::from_mode(0o755)).unwrap();
        for section in [Page::WebSearch, Page::Hindsight] {
            let mut page = ProviderPage::new();
            page.pi.model = "untouched-chat".into();
            page.set_page(section);
            if section == Page::WebSearch {
                page.commit_option(Field::WebSearchProvider, 3);
                page.search.key = "search-key".into();
            } else {
                page.commit_option(Field::HindsightProvider, 2);
                page.hindsight.key = "memory-key".into();
            }
            page.start_service_models(&resources, &root.join("pi/agent"), false);
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
            while page.is_loading() {
                page.poll_models();
                assert!(std::time::Instant::now() < deadline);
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
            let request = fs::read_to_string(resources.join("request.json")).unwrap();
            assert!(!request.contains("search-key") && !request.contains("memory-key"));
            for (width, height) in [(80, 24), (100, 30)] {
                let mut terminal =
                    ratatui::Terminal::new(ratatui::backend::TestBackend::new(width, height))
                        .unwrap();
                terminal.draw(|frame| page.draw(frame)).unwrap();
                wizard_style::tests::find(terminal.backend().buffer(), "scoped-model");
                let text: String = terminal
                    .backend()
                    .buffer()
                    .content()
                    .iter()
                    .map(|cell| cell.symbol())
                    .collect();
                assert!(!text.contains("must-not-appear"));
            }
            assert!(matches!(
                page.on_key(KeyCode::Enter, KeyModifiers::NONE),
                Some(Decision::Save)
            ));
            assert_eq!(page.pi.model, "untouched-chat");
            assert_eq!(
                if section == Page::WebSearch {
                    &page.search.model
                } else {
                    &page.hindsight.model
                },
                "scoped-model"
            );
            assert_eq!(
                if section == Page::WebSearch {
                    &page.search.key
                } else {
                    &page.hindsight.key
                },
                if section == Page::WebSearch {
                    "search-key"
                } else {
                    "memory-key"
                }
            );
            page.start_service_models(&resources, &root.join("pi/agent"), false);
            page.set_page(Page::Model);
            assert!(
                page.model_job.is_none(),
                "navigation cancels the old catalog owner"
            );
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn every_builtin_can_defer_login_without_reading_or_rewriting_auth() {
        for provider in pi_providers::all().iter().filter(|provider| provider.chat) {
            let root = root();
            let agent = root.join("pi/agent");
            fs::write(agent.join("auth.json"), "malformed-but-must-stay-untouched").unwrap();
            let mut page = ProviderPage::new();
            let index = pi_choices()
                .iter()
                .position(|choice| choice.pi_provider().is_some_and(|p| p.id == provider.id))
                .unwrap();
            page.commit_option(Field::PiProvider, index);
            page.pi_source = Some(Mode::Later);
            page.pi.model = "chosen-model".into();
            assert!(page.validate(), "{}: {:?}", provider.id, page.error);
            page.save(&root).unwrap();
            assert_eq!(
                fs::read_to_string(agent.join("auth.json")).unwrap(),
                "malformed-but-must-stay-untouched"
            );
            assert_eq!(
                read_json_object(&agent.join("settings.json")).unwrap()["defaultProvider"],
                provider.id
            );
            assert!(page
                .login_later_hint()
                .unwrap()
                .contains(&format!("/login {}", provider.id)));
            fs::remove_dir_all(root).unwrap();
        }
    }

    #[test]
    fn the_credential_source_is_chosen_explicitly_and_hides_the_key_field() {
        let root = root();
        let agent = root.join("pi/agent");
        fs::write(
            agent.join("auth.json"),
            r#"{"openai":{"type":"api_key","key":"saved"}}"#,
        )
        .unwrap();
        let mut page = ProviderPage::new();
        page.load_existing_auth(&agent);
        page.pi.choice = Some(Choice::OpenAi);
        // A saved credential is offered first, and no key field is shown for it.
        assert_eq!(page.source(), Mode::Existing);
        assert_eq!(
            page.options(Field::PiSource),
            [
                "Reuse the saved credential",
                "Enter a new API key",
                "Sign in later in Pi"
            ]
        );
        assert!(page.fields().contains(&Field::PiSource));
        assert!(!page.fields().contains(&Field::PiKey));
        page.commit_option(Field::PiSource, 1);
        assert_eq!(page.source(), Mode::New);
        assert!(page.fields().contains(&Field::PiKey));
        // Without a saved credential, key entry and deferred login remain explicit.
        page.pi.choice = Some(Choice::Anthropic);
        assert_eq!(page.source(), Mode::New);
        assert!(page.fields().contains(&Field::PiSource));
        // A local server offers no-key first, so an old token is never implied.
        let mut local = ProviderPage::new();
        local.load_existing_auth(&agent);
        local.pi.choice = Some(Choice::Local(&pi_connection::PRESETS[0]));
        assert_eq!(local.source(), Mode::None);
        assert_eq!(
            local.options(Field::PiSource),
            ["No key (local server)", "Enter a new API key"]
        );
    }

    #[test]
    fn auto_api_is_offered_and_resolves_to_the_probed_family() {
        let root = root();
        let mut page = ProviderPage::new();
        page.pi.choice = Some(Choice::Compatible);
        page.pi.id = "my-gateway".into();
        page.pi.url = "https://example.invalid/v1".into();
        page.pi.key = "fixture-key".into();
        page.commit_option(Field::PiApi, 0);
        page.pi.model = "exact-model".into();
        assert_eq!(page.pi_api, None);
        assert_eq!(page.api_label(), "Auto (detect when tested)");
        // Auto has no family of its own, so it can never be saved untested.
        assert!(page.save(&root).is_err());
        page.accepted_api = Some("openai-responses".into());
        page.save(&root).unwrap();
        let models = read_json_object(&root.join("pi/agent/models.json")).unwrap();
        assert_eq!(
            models["providers"]["my-gateway"]["api"], "openai-responses",
            "Auto must persist the family the endpoint actually answered on"
        );
        page.commit_option(Field::PiApi, 2);
        assert_eq!(page.pi_api, Some(pi_providers::Api::Responses));
        assert_eq!(page.accepted_api, None, "changing the API retests it");
    }

    #[test]
    fn selecting_another_model_invalidates_the_custom_probe_and_endpoint_catalogs_do_not_fall_back()
    {
        let root = root();
        let mut page = ProviderPage::new();
        page.pi.choice = Some(Choice::Compatible);
        page.pi.id = "gateway".into();
        page.pi.url = "https://example.invalid/v1".into();
        page.pi.key = "fake-key".into();
        page.pi.model = "tested-model".into();
        page.accepted_api = Some("openai-responses".into());
        page.accept_model(Model {
            provider: "gateway".into(),
            id: "different-model".into(),
            name: "Different".into(),
        });
        assert!(
            page.accepted_api.is_none(),
            "a receipt for another model is stale"
        );
        assert!(!page.advance(&root, &root.join("pi/agent"), false));
        assert!(page.save(&root).is_err());
        page.receive_models(Ok(Report::parse(br#"{"version":1,"status":"ok","serverVerified":false,"catalogComplete":true,"modelKnown":null,"auth":{"status":"ready"},"models":[{"provider":"hosted-other","id":"must-not-appear"}]}"#).unwrap()));
        let mut terminal =
            ratatui::Terminal::new(ratatui::backend::TestBackend::new(100, 30)).unwrap();
        terminal.draw(|frame| page.draw(frame)).unwrap();
        let text: String = terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect();
        assert!(!text.contains("must-not-appear"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn an_untested_custom_connection_cannot_be_saved_but_an_accepted_one_can() {
        let root = root();
        let mut page = ProviderPage::new();
        page.pi.choice = Some(Choice::Compatible);
        page.pi.id = "my-gateway".into();
        page.pi.url = "https://example.invalid/v1".into();
        page.pi.model = "exact-model".into();
        page.pi.key = "fixture-key".into();
        assert!(!page.validate());
        assert!(
            page.save(&root).is_err(),
            "an unverified endpoint was saved"
        );
        page.accepted_api = Some("anthropic-messages".into());
        assert!(page.validate(), "{:?}", page.error);
        page.save(&root).unwrap();
        let models = read_json_object(&root.join("pi/agent/models.json")).unwrap();
        // The accepted family wins over the dropdown that was merely proposed.
        assert_eq!(
            models["providers"]["my-gateway"]["api"],
            "anthropic-messages"
        );
        // Any draft change invalidates the acceptance it was granted for.
        page.on_key(KeyCode::Char('x'), KeyModifiers::NONE);
        page.focus = Field::PiUrl;
        page.on_key(KeyCode::Char('x'), KeyModifiers::NONE);
        assert_eq!(page.accepted_api, None);
        assert!(!page.validate());
    }

    #[test]
    fn conflicting_local_credentials_get_an_alias_and_matching_models_are_merged() {
        let root = root();
        let agent = root.join("pi/agent");
        let original = serde_json::json!({"baseUrl":"https://old.invalid/v1","api":"openai-completions",
            "headers":{"Authorization":"Bearer old-fixture-token"},"models":[{"id":"old-model"}]});
        fs::write(
            agent.join("models.json"),
            serde_json::json!({"providers":{"ollama":original}}).to_string(),
        )
        .unwrap();
        fs::write(
            agent.join("auth.json"),
            r#"{"ollama":{"type":"api_key","key":"old-fixture-token"}}"#,
        )
        .unwrap();
        let mut page = ProviderPage::new();
        page.pi.choice = Some(Choice::Local(&pi_connection::PRESETS[0]));
        page.resolve_connection_id(&agent).unwrap();
        assert_eq!(page.configured_provider(), "ollama-2");
        page.pi.model = "first:8b".into();
        page.local_models.push("first:8b".into());
        page.save(&root).unwrap();
        let saved = read_json_object(&agent.join("models.json")).unwrap();
        assert_eq!(saved["providers"]["ollama"], original);
        let auth = read_json_object(&agent.join("auth.json")).unwrap();
        assert_eq!(auth["ollama"]["key"], "old-fixture-token");
        assert_eq!(auth["ollama-2"]["key"], "mash-local");
        let mut again = ProviderPage::new();
        again.pi.choice = Some(Choice::Local(&pi_connection::PRESETS[0]));
        again.resolve_connection_id(&agent).unwrap();
        assert_eq!(
            again.configured_provider(),
            "ollama-2",
            "matching aliases are reused, not multiplied"
        );
        again.pi.model = "second:4b".into();
        again.local_models.push("second:4b".into());
        again.save(&root).unwrap();
        let saved = read_json_object(&agent.join("models.json")).unwrap();
        assert_eq!(
            saved["providers"]["ollama-2"]["models"],
            serde_json::json!([{"id":"first:8b"},{"id":"second:4b"}])
        );
        assert_eq!(saved["providers"]["ollama"], original);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn required_local_catalogs_are_not_confused_with_best_effort_manual_routes() {
        for preset in &pi_connection::PRESETS {
            let mut page = ProviderPage::new();
            page.pi.choice = Some(Choice::Local(preset));
            page.pi.model = "exact-model".into();
            assert_eq!(page.validate(), !preset.requires_model);
            page.local_models.push("exact-model".into());
            assert!(page.validate(), "{:?}", page.error);
        }
    }

    #[test]
    fn a_local_preset_saves_its_own_endpoint_without_a_key_or_an_old_token() {
        let root = root();
        let agent = root.join("pi/agent");
        fs::write(
            agent.join("auth.json"),
            r#"{"ollama":{"type":"api_key","key":"old-hosted-token"}}"#,
        )
        .unwrap();
        let preset = &pi_connection::PRESETS[0];
        let mut page = ProviderPage::new();
        page.load_existing_auth(&agent);
        page.pi.choice = Some(Choice::Local(preset));
        page.pi.model = "qwen3:8b".into();
        page.local_models.push("qwen3:8b".into());
        assert_eq!(page.source(), Mode::None);
        assert!(page.fields().contains(&Field::PiTest));
        assert!(
            !page.fields().contains(&Field::PiApi),
            "locals are Chat Completions"
        );
        assert!(page.validate(), "{:?}", page.error);
        page.save(&root).unwrap();
        let models = read_json_object(&agent.join("models.json")).unwrap();
        assert_eq!(models["providers"]["ollama"]["baseUrl"], preset.base_url);
        assert_eq!(models["providers"]["ollama"]["api"], "openai-completions");
        assert_eq!(models["providers"]["ollama"]["models"][0]["id"], "qwen3:8b");
        let auth = read_json_object(&agent.join("auth.json")).unwrap();
        assert_eq!(
            auth["ollama"]["key"], "mash-local",
            "a local server must not keep sending an old real token"
        );
    }

    fn custom_page(id: &str, url: &str, model: &str) -> ProviderPage {
        let mut page = ProviderPage::new();
        page.pi.choice = Some(Choice::Compatible);
        page.pi.id = id.into();
        page.pi.url = url.into();
        page.pi.model = model.into();
        page
    }

    /// A fake bundled Node that records its request and answers with `reply`.
    fn node_fixture(resources: &Path, reply: &str) {
        fs::create_dir_all(resources.join("node/bin")).unwrap();
        let node = resources.join("node/bin/node");
        fs::write(
            &node,
            format!("#!/bin/sh\n/bin/cat > request.json\nprintf '%s\\n' '{reply}'\n"),
        )
        .unwrap();
        fs::set_permissions(&node, fs::Permissions::from_mode(0o755)).unwrap();
    }

    fn wait_for_probe(page: &mut ProviderPage) {
        let until = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while page.probe_revision.is_none() {
            page.poll_connection();
            assert!(std::time::Instant::now() < until, "the test never finished");
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }

    fn wait_for_catalog(page: &mut ProviderPage) {
        let until = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while page.is_loading() {
            page.poll_models();
            assert!(
                std::time::Instant::now() < until,
                "the catalog never returned"
            );
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }

    #[test]
    fn a_saved_login_is_never_replaced_by_a_typed_key() {
        let root = root();
        let agent = root.join("pi/agent");
        let saved =
            r#"{"openai":{"type":"oauth","access":"never-replace","refresh":"r","expires":1}}"#;
        fs::write(agent.join("auth.json"), saved).unwrap();
        let mut page = ProviderPage::new();
        page.load_existing_auth(&agent);
        page.pi.choice = Some(Choice::OpenAi);
        page.pi.model = "gpt-4".into();
        assert!(page.reuses_saved_credential());
        page.save(&root).unwrap();
        assert_eq!(fs::read_to_string(agent.join("auth.json")).unwrap(), saved);
        // Replacing a working /login would sign the user out behind their back.
        page.pi_source = Some(Mode::New);
        page.pi.key = "!touch-pwned".into();
        assert!(page.save(&root).unwrap_err().contains("/login"));
        assert_eq!(fs::read_to_string(agent.join("auth.json")).unwrap(), saved);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_key_with_no_saved_login_is_stored_escaped_not_executed() {
        let root = root();
        let mut page = ProviderPage::new();
        page.pi.choice = Some(Choice::Anthropic);
        page.pi.model = "claude".into();
        page.pi_source = Some(Mode::New);
        page.pi.key = "!touch-pwned".into();
        page.save(&root).unwrap();
        let auth = read_json_object(&root.join("pi/agent/auth.json")).unwrap();
        assert_eq!(auth["anthropic"]["key"], "$!touch-pwned");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn one_page_owns_a_provider_credential() {
        let root = root();
        let mut page = ProviderPage::new();
        page.pi.choice = Some(Choice::OpenAi);
        page.pi.model = "chat-model".into();
        page.pi.key = "model-key".into();
        page.set_page(Page::WebSearch);
        page.search.choice = Some(SearchChoice::OpenAi);
        page.search.model = "search-model".into();
        page.search.key = "search-key".into();
        page.search_source = Some(ServiceSource::New);
        assert!(page
            .save(&root)
            .unwrap_err()
            .contains("Model provider page"));
        assert!(!root.join("pi/agent/auth.json").exists());
        // Sharing the slot explicitly is still allowed, and keeps one key.
        page.search_source = Some(ServiceSource::Chat);
        page.save(&root).unwrap();
        let auth = read_json_object(&root.join("pi/agent/auth.json")).unwrap();
        assert_eq!(auth["openai"]["key"], "model-key");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn auto_endpoint_reuses_its_existing_provider_instead_of_minting_an_alias() {
        let root = root();
        let agent = root.join("pi/agent");
        let original = serde_json::json!({"providers":{"gateway":{"api":"openai-completions",
            "baseUrl":"https://example.invalid/v1","models":[{"id":"exact-model"}]}}});
        fs::write(agent.join("models.json"), original.to_string()).unwrap();
        fs::write(
            agent.join("auth.json"),
            r#"{"gateway":{"type":"api_key","key":"saved"}}"#,
        )
        .unwrap();
        let mut page = custom_page("gateway", "https://example.invalid/v1/", "exact-model");
        page.pi_api = None;
        page.resolve_connection_id(&agent).unwrap();
        assert_eq!(page.configured_provider(), "gateway");
        assert_eq!(
            read_json_object(&agent.join("models.json")).unwrap()["providers"]["gateway"],
            original["providers"]["gateway"],
            "the draft wrote nothing before Apply"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn test_connection_wires_a_result_and_a_missing_helper_to_the_page() {
        let root = root();
        let mut page = custom_page("my-gateway", "https://example.invalid/v1", "exact-model");
        page.pi.key = "fixture-key".into();
        page.pi_api = None;
        let mut command = std::process::Command::new("/bin/sh");
        command.args(["-c", "cat >/dev/null; printf '{\"version\":1,\"status\":\"ok\",\"accepted\":true,\"api\":\"openai-responses\",\"revision\":\"ab\"}'"]);
        let job = Job::spawn_for_test(command, b"{}".to_vec(), std::time::Duration::from_secs(5));
        page.connection
            .set_job_for_test(page.generation, job.unwrap());
        wait_for_probe(&mut page);
        assert_eq!(page.accepted_api.as_deref(), Some("openai-responses"));
        assert_eq!(page.probe_revision.as_deref(), Some("ab"));
        assert!(page
            .connection_status
            .as_deref()
            .unwrap_or_default()
            .contains("Connected"));
        // The click path reaches start_connection and reports instead of hanging.
        page.test_requested = true;
        page.service_connection(&root.join("missing"), &root.join("pi/agent"), false);
        assert!(page
            .connection_status
            .is_some_and(|status| !status.contains("Connected")));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn hindsight_custom_endpoints_fetch_their_own_catalog_with_their_own_key() {
        let root = root();
        let resources = root.join("resource root");
        node_fixture(&resources, "{\"version\":1,\"status\":\"ok\",\"serverVerified\":false,\"catalogComplete\":true,\"modelKnown\":null,\"auth\":{\"status\":\"unverified\"},\"models\":[{\"provider\":\"openai\",\"id\":\"route-model\",\"name\":\"Route\"}]}");
        let mut page = ProviderPage::new();
        page.set_page(Page::Hindsight);
        page.hindsight.choice = Some(Choice::Compatible);
        page.hindsight.url = "https://example.invalid/v1".into();
        page.hindsight.key = "hindsight-fixture-key".into();
        page.hindsight_source = Some(ServiceSource::New);
        page.choose_service_model = true;
        page.service_connection(&resources, &root.join("pi/agent"), false);
        wait_for_catalog(&mut page);
        let request: Value =
            serde_json::from_slice(&fs::read(resources.join("request.json")).unwrap()).unwrap();
        assert_eq!(request["scope"], "hindsight");
        assert_eq!(request["provider"], "openai");
        assert_eq!(request["mode"], "new");
        assert_eq!(request["key"], "hindsight-fixture-key");
        assert_eq!(request["asCatalog"], true);
        assert!(page.model_step == ModelStep::Picker);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn short_and_narrow_terminals_still_show_the_focused_field() {
        use wizard_style::tests::find;
        let mut page = ProviderPage::new();
        page.pi.choice = Some(Choice::Compatible);
        page.pi.url = "https://example.invalid/v1".into();
        page.pi.model = "exact-model".into();
        page.pi_source = Some(Mode::New);
        page.pi.key = "fixture-key".into();
        page.focus = Field::PiKey;
        for height in [17, 18, 19, 24] {
            let mut terminal =
                ratatui::Terminal::new(ratatui::backend::TestBackend::new(80, height)).unwrap();
            terminal.draw(|frame| page.draw(frame)).unwrap();
            find(terminal.backend().buffer(), "API key:");
        }
        // An open menu must not scroll its own field out of the form.
        page.focus = Field::PiApi;
        page.open_menu(Field::PiApi);
        let mut terminal =
            ratatui::Terminal::new(ratatui::backend::TestBackend::new(80, 18)).unwrap();
        terminal.draw(|frame| page.draw(frame)).unwrap();
        find(terminal.backend().buffer(), "API type:");
    }

    #[test]
    fn current_model_label_is_named_and_keep_preserves_files() {
        let root = root();
        let agent = root.join("pi/agent");
        let settings = "{\"defaultProvider\":\"openai\",\"defaultModel\":\"gpt-4\"}";
        let auth = "{\"openai\":{\"type\":\"oauth\",\"access\":\"never-display\"}}";
        fs::write(agent.join("settings.json"), settings).unwrap();
        fs::write(agent.join("auth.json"), auth).unwrap();
        let mut page = ProviderPage::new();
        page.load_existing_auth(&agent);
        let mut terminal =
            ratatui::Terminal::new(ratatui::backend::TestBackend::new(100, 30)).unwrap();
        terminal.draw(|frame| page.draw(frame)).unwrap();
        let text: String = terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect();
        assert!(text.contains("Keep current: openai/gpt-4"));
        assert!(!text.contains("never-display"));
        page.save(&root).unwrap();
        assert_eq!(
            fs::read_to_string(agent.join("settings.json")).unwrap(),
            settings
        );
        assert_eq!(fs::read_to_string(agent.join("auth.json")).unwrap(), auth);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn catalog_flow_keeps_credential_provider_separate_from_fallback_model() {
        let root = root();
        let resources = root.join("resource root with spaces");
        fs::create_dir_all(resources.join("node/bin")).unwrap();
        let report = serde_json::json!({"version":1,"status":"ok","serverVerified":false,"catalogComplete":true,"modelKnown":null,"auth":{"status":"ready"},"models":[{"provider":"anthropic","id":"namespace/model","name":"Fallback model"}]});
        let node = resources.join("node/bin/node");
        fs::write(
            &node,
            format!(
                "#!/bin/sh\n/bin/cat >/dev/null\nprintf '%s\\n' '{}'\n",
                report
            ),
        )
        .unwrap();
        fs::set_permissions(&node, fs::Permissions::from_mode(0o755)).unwrap();
        let agent = root.join("pi/agent");
        fs::write(agent.join("auth.json"), r#"{"openai":{"type":"api_key","key":"old","env":{"KEEP":"yes"}},"anthropic":{"type":"api_key","key":"keep-this-key"}}"#).unwrap();
        let mut page = ProviderPage::new();
        page.pi.choice = Some(Choice::OpenAi);
        page.pi.key = "new-key".into();
        assert!(page.pi.model.is_empty());
        assert!(!page.advance(&resources, &agent, false));
        assert!(page.is_loading());
        let until = std::time::Instant::now() + std::time::Duration::from_secs(3);
        while page.is_loading() {
            page.poll_models();
            assert!(std::time::Instant::now() < until);
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        assert!(page.model_step == ModelStep::Picker);
        assert!(matches!(
            page.on_key(KeyCode::Enter, KeyModifiers::NONE),
            Some(Decision::Save)
        ));
        assert!(page.advance(&resources, &agent, false));
        page.save(&root).unwrap();
        let settings = read_json_object(&agent.join("settings.json")).unwrap();
        assert_eq!(settings["defaultProvider"], "anthropic");
        assert_eq!(settings["defaultModel"], "namespace/model");
        let auth = read_json_object(&agent.join("auth.json")).unwrap();
        assert_eq!(auth["openai"]["key"], "new-key");
        assert_eq!(auth["openai"]["env"]["KEEP"], "yes");
        assert_eq!(auth["anthropic"]["key"], "keep-this-key");

        page.selected_model = None;
        page.on_key(KeyCode::Esc, KeyModifiers::NONE);
        assert!(!page.advance(&root.join("missing"), &agent, false));
        assert!(
            page.model_job.is_none(),
            "cached models must not restart a helper"
        );
        page.on_key(KeyCode::Esc, KeyModifiers::NONE);
        page.focus = Field::PiKey;
        let generation = page.generation;
        page.on_key(KeyCode::Char('x'), KeyModifiers::NONE);
        assert_ne!(page.generation, generation);
        assert!(!page.models_cached);
        assert!(page.selected_model.is_none());
        assert!(!page.advance(&root.join("missing"), &agent, false));
        assert!(page.model_step == ModelStep::Manual);
        page.pi.model = "manual-model".into();
        assert!(page.advance(&resources, &agent, false));
        page.save(&root).unwrap();
        assert_eq!(
            read_json_object(&agent.join("settings.json")).unwrap()["defaultModel"],
            "manual-model"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn preview_and_keep_do_not_start_helpers_or_save_credentials() {
        let root = root();
        let mut page = ProviderPage::new();
        assert!(page.advance(&root.join("missing"), &root.join("pi/agent"), false));
        assert!(page.model_job.is_none());
        page.pi.choice = Some(Choice::OpenAi);
        assert!(!page.advance(&root.join("missing"), &root.join("pi/agent"), true));
        assert!(page.model_step == ModelStep::Picker);
        assert!(page.model_job.is_none());
        assert!(!root.join("pi/agent/auth.json").exists());
        assert!(!root.join("pi/agent/settings.json").exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn current_custom_and_incomplete_defaults_are_truthfully_labelled() {
        let root = root();
        let agent = root.join("pi/agent");
        let mut page = ProviderPage::new();
        for settings in [r#"{}"#, r#"{"defaultProvider":"openai"}"#, "not JSON"] {
            fs::write(agent.join("settings.json"), settings).unwrap();
            page.load_existing_auth(&agent);
            assert_eq!(page.pi_label(Choice::Keep), "Set up later");
        }
        fs::write(
            agent.join("settings.json"),
            r#"{"defaultProvider":"custom-provider","defaultModel":"namespace/model"}"#,
        )
        .unwrap();
        page.load_existing_auth(&agent);
        assert_eq!(
            page.pi_label(Choice::Keep),
            "Keep current: custom-provider/namespace/model"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn expanded_pi_providers_save_canonical_keys_and_defaults() {
        for (label, id) in [
            ("DeepSeek", "deepseek"),
            ("Google", "google"),
            ("Groq", "groq"),
            ("Mistral", "mistral"),
        ] {
            let root = root();
            let mut page = ProviderPage::new();
            let options = page.options(Field::PiProvider);
            assert!(options.len() > 30);
            let index = options
                .iter()
                .position(|name| name == label)
                .expect("Pi provider missing");
            page.commit_option(Field::PiProvider, index);
            page.pi.key = "fixture-key".into();
            page.pi.model = "exact-model".into();
            assert!(page.validate());
            page.save(&root).unwrap();
            let agent = root.join("pi/agent");
            assert_eq!(
                read_json_object(&agent.join("settings.json")).unwrap()["defaultProvider"],
                id
            );
            assert_eq!(
                read_json_object(&agent.join("auth.json")).unwrap()[id]["key"],
                "fixture-key"
            );
            assert!(!agent.join("models.json").exists());
            fs::remove_dir_all(root).unwrap();
        }
    }

    #[test]
    fn pi_handoffs_never_validate_a_key_launch_a_job_or_write_defaults() {
        let root = root();
        let agent = root.join("pi/agent");
        let files = [
            (
                "auth.json",
                r#"{"openai":{"type":"oauth","access":"secret"},"custom":{"type":"api_key","key":"!must-not-run"}}"#,
            ),
            (
                "settings.json",
                r#"{"defaultProvider":"custom","defaultModel":"old"}"#,
            ),
            (
                "models.json",
                r#"{"providers":{"custom":{"api":"openai-responses","baseUrl":"https://example.invalid","models":[{"id":"old"}]}}}"#,
            ),
        ];
        for (file, text) in files {
            fs::write(agent.join(file), text).unwrap();
        }
        for label in [
            "Azure",
            "Cloudflare AI Gateway",
            "Cloudflare Workers AI",
            "OpenAI Codex (legacy)",
        ] {
            let mut page = ProviderPage::new();
            let index = page
                .options(Field::PiProvider)
                .iter()
                .position(|name| name == label)
                .expect("handoff provider missing");
            page.commit_option(Field::PiProvider, index);
            assert!(!page.fields().contains(&Field::PiKey));
            assert_eq!(page.source(), Mode::Later);
            assert!(!page.advance(&root.join("missing"), &agent, false));
            assert!(page.model_job.is_none());
            page.pi.model = "chosen-before-login".into();
            assert!(page.advance(&root.join("missing"), &agent, false));
            page.save(&root).unwrap();
            let mut terminal =
                ratatui::Terminal::new(ratatui::backend::TestBackend::new(80, 24)).unwrap();
            terminal.draw(|frame| page.draw(frame)).unwrap();
            wizard_style::tests::find(terminal.backend().buffer(), "/login");
            for (file, text) in files
                .into_iter()
                .filter(|(file, _)| *file != "settings.json")
            {
                assert_eq!(fs::read_to_string(agent.join(file)).unwrap(), text);
            }
            let saved = read_json_object(&agent.join("settings.json")).unwrap();
            assert_eq!(saved["defaultProvider"], page.configured_provider());
            assert_eq!(saved["defaultModel"], "chosen-before-login");
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn pi_catalog_order_and_compact_radio_list_hit_targets_agree() {
        use wizard_style::tests::{click, find};
        let page = ProviderPage::new();
        let names = page.options(Field::PiProvider);
        assert_eq!(
            &names[2..7],
            ["OpenAI", "Anthropic", "xAI", "Google", "OpenRouter"]
        );
        assert!(!names.iter().any(|name| name == "TypeSafe"));
        assert_eq!(names[1], "Custom provider");
        assert!(names[7..]
            .windows(2)
            .all(|pair| pair[0].to_lowercase() <= pair[1].to_lowercase()));
        for (width, height) in [(80, 24), (100, 30)] {
            let mut page = ProviderPage::new();
            let mut terminal =
                ratatui::Terminal::new(ratatui::backend::TestBackend::new(width, height)).unwrap();
            terminal.draw(|frame| page.draw(frame)).unwrap();
            let buffer = terminal.backend().buffer();
            let (_, provider_y) = find(buffer, "( ) OpenAI");
            let (_, details_y) = find(buffer, "Connection details");
            assert!(
                provider_y < details_y,
                "providers belong above the detail panel"
            );
            let (provider_x, last_initial) = find(buffer, "OpenRouter");
            assert!(last_initial < details_y);
            if height == 30 {
                let visible = (0..height)
                    .filter(|&y| {
                        wizard_style::clicked(&click(provider_x, y)).is_some_and(|id| {
                            (PROVIDER_BASE..PROVIDER_BASE + names.len()).contains(&id)
                        })
                    })
                    .count();
                assert!(
                    visible > MENU_ROWS,
                    "the full page must not retain the six-row menu cap"
                );
            }
            // The list is visible without an extra Enter; End scrolls it directly.
            assert!(!page.menu_open());
            page.on_key(KeyCode::End, KeyModifiers::NONE);
            terminal.draw(|frame| page.draw(frame)).unwrap();
            let (x, y) = find(terminal.backend().buffer(), names.last().unwrap());
            let id = wizard_style::clicked(&click(x, y)).expect("provider is clickable");
            page.on_click(id);
            assert_eq!(page.pi.choice(), *pi_choices().last().unwrap());
            assert!(!page.menu_open());
            // Going back to the start leaves the selected provider checked.
            page.on_key(KeyCode::Home, KeyModifiers::NONE);
            assert_eq!(page.pi.choice(), *pi_choices().last().unwrap());
        }
    }

    #[test]
    fn custom_api_choice_is_saved_and_invalidates_a_previous_selection() {
        let root = root();
        let agent = root.join("pi/agent");
        let mut page = ProviderPage::new();
        page.pi.choice = Some(Choice::Compatible);
        page.pi.id = "my-gateway".into();
        page.pi.url = "https://example.invalid/v1".into();
        page.pi.key = "fixture-key".into();
        assert!(page.fields().contains(&Field::PiApi));
        assert_eq!(page.pi_api, Some(pi_providers::Api::Chat));
        assert_eq!(
            page.options(Field::PiApi),
            [
                "Auto (detect when tested)",
                "OpenAI Chat Completions",
                "OpenAI Responses",
                "Anthropic Messages"
            ]
        );
        for (index, api) in [
            "openai-completions",
            "openai-responses",
            "anthropic-messages",
        ]
        .iter()
        .enumerate()
        {
            page.commit_option(Field::PiApi, index);
            page.pi.model = "exact-model".into();
            // Only an accepted probe decides the saved API family.
            page.accepted_api = Some((*api).into());
            page.save(&root).unwrap();
            let models = read_json_object(&agent.join("models.json")).unwrap();
            assert_eq!(models["providers"]["my-gateway"]["api"], *api);
            let original = fs::read(agent.join("models.json")).unwrap();
            ProviderPage::new().save(&root).unwrap();
            assert_eq!(fs::read(agent.join("models.json")).unwrap(), original);
            page.models_cached = true;
            page.selected_model = Some(("my-gateway".into(), "old-model".into()));
            let generation = page.generation;
            page.commit_option(Field::PiApi, (index + 1) % 3);
            assert!(!page.models_cached);
            assert!(page.selected_model.is_none());
            assert_ne!(page.generation, generation);
        }
        page.set_page(Page::WebSearch);
        assert!(!page.fields().contains(&Field::PiApi));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn custom_api_reaches_the_stdin_bridge_and_compact_mouse_target() {
        use wizard_style::tests::{click, find};
        let root = root();
        let resources = root.join("resources with spaces");
        fs::create_dir_all(resources.join("node/bin")).unwrap();
        let node = resources.join("node/bin/node");
        fs::write(&node, "#!/bin/sh\n/bin/cat > request.json\nprintf '%s\\n' \"$@\" > argv.txt\nprintf '{}\\n'\n").unwrap();
        fs::set_permissions(&node, fs::Permissions::from_mode(0o755)).unwrap();
        for api in pi_providers::Api::ALL {
            let mut page = ProviderPage::new();
            page.pi.choice = Some(Choice::Compatible);
            page.pi.id = "my-gateway".into();
            page.pi.url = "https://example.invalid/v1".into();
            page.pi.key = "stdin-secret".into();
            page.pi_api = Some(api);
            assert!(!page.advance(&resources, &root.join("pi/agent"), false));
            let until = std::time::Instant::now() + std::time::Duration::from_secs(3);
            while page.is_loading() {
                page.poll_models();
                assert!(std::time::Instant::now() < until);
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
            let request: Value =
                serde_json::from_slice(&fs::read(resources.join("request.json")).unwrap()).unwrap();
            assert_eq!(request["draft"]["api"], api.id());
            assert_eq!(request["draft"]["baseUrl"], "https://example.invalid/v1");
            assert!(!fs::read_to_string(resources.join("argv.txt"))
                .unwrap()
                .contains("stdin-secret"));
            assert!(page.model_step == ModelStep::Manual);
        }
        for (width, height) in [(80, 24), (100, 30)] {
            let mut page = ProviderPage::new();
            page.pi.choice = Some(Choice::Compatible);
            page.open_menu(Field::PiApi);
            page.on_key(KeyCode::End, KeyModifiers::NONE);
            let mut terminal =
                ratatui::Terminal::new(ratatui::backend::TestBackend::new(width, height)).unwrap();
            terminal.draw(|frame| page.draw(frame)).unwrap();
            let (x, y) = find(terminal.backend().buffer(), "Anthropic Messages");
            let id = wizard_style::clicked(&click(x, y)).unwrap();
            assert_eq!(id, MENU_BASE + 3);
            page.on_click(id);
            assert_eq!(page.pi_api, Some(pi_providers::Api::Anthropic));
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn every_builtin_id_is_reserved_from_custom_replacement() {
        let mut page = ProviderPage::new();
        page.pi.choice = Some(Choice::Compatible);
        page.pi.url = "https://example.invalid/v1".into();
        page.pi.key = "key".into();
        page.pi.model = "model".into();
        page.accepted_api = Some(pi_providers::Api::Chat.id().into());
        for provider in crate::pi_providers::all() {
            page.pi.id = provider.id.clone();
            assert!(!page.validate(), "reserved ID accepted: {}", provider.id);
        }
        page.pi.id = "my-gateway".into();
        assert!(page.validate());
    }

    #[test]
    fn page_split_keeps_pi_separate_from_services() {
        use ratatui::{backend::TestBackend, Terminal};
        let page = ProviderPage::new();
        let mut terminal = Terminal::new(TestBackend::new(100, 30)).unwrap();
        terminal.draw(|frame| page.draw(frame)).unwrap();
        let text: String = terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect();
        assert!(text.contains("Model providers"));
        assert!(!page.fields().contains(&Field::WebSearchModel));
        assert!(!page.fields().contains(&Field::HindsightModel));
    }

    #[test]
    fn pi_theme_switches_after_provider_setup_reserializes_settings() {
        let root = root();
        let settings = root.join("pi/agent/settings.json");
        fs::write(&settings, include_str!("../defaults/pi/settings.json")).unwrap();
        let mut page = ProviderPage::new();
        page.pi.choice = Some(Choice::OpenAi);
        page.pi.model = "test-model".into();
        page.pi.key = "test-key".into();
        page.save(&root).unwrap();

        for (theme, expected) in [
            (crate::theme::Theme::Light, "Mash Light"),
            (crate::theme::Theme::Dark, "Monokai Pro (CE)"),
        ] {
            theme.apply(&root).unwrap();
            let saved = read_json_object(&settings).unwrap();
            assert_eq!(saved["theme"], expected);
            assert_eq!(saved["defaultProvider"], "openai");
            assert_eq!(saved["defaultModel"], "test-model");
        }
        let mut custom = read_json_object(&settings).unwrap();
        custom.insert("theme".into(), Value::String("User theme".into()));
        save_json(&settings, &custom).unwrap();
        crate::theme::Theme::Light.apply(&root).unwrap();
        assert_eq!(read_json_object(&settings).unwrap(), custom);
        fs::remove_dir_all(root).unwrap();
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
        page.pi_api = Some(pi_providers::Api::Responses);
        page.pi.url = "https://example.invalid/v1".into();
        page.pi.model = "route-model".into();
        page.pi.key = "secret-pi".into();
        page.hindsight.choice = Some(Choice::Compatible);
        page.hindsight.url = "https://example.invalid/v1".into();
        page.hindsight.model = "route-model".into();
        page.hindsight.key = "secret-hindsight".into();
        page.accepted_api = Some(pi_providers::Api::Responses.id().into());
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
    fn programming_opt_out_skips_unseeded_hindsight_config() {
        let root = root();
        fs::write(root.join("setup/skills-choice"), "programming=false\n").unwrap();
        let mut page = ProviderPage::new();
        page.hindsight.choice = Some(Choice::None);
        page.save(&root).unwrap();
        assert!(!root.join(".hindsight/embed").exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn programming_opt_out_keeps_existing_hindsight_but_saves_pi() {
        let root = root();
        let embed = root.join(".hindsight/embed");
        let original = "HINDSIGHT_API_LLM_PROVIDER=none\n";
        fs::write(&embed, original).unwrap();
        fs::write(root.join("setup/skills-choice"), "programming=false\n").unwrap();
        let mut page = ProviderPage::new();
        page.pi.choice = Some(Choice::OpenAi);
        page.pi.model = "test-model".into();
        page.pi.key = "test-key".into();
        // Ignore even an incomplete Hindsight input when its suite is off.
        page.hindsight.choice = Some(Choice::Compatible);
        page.save(&root).unwrap();
        assert_eq!(fs::read_to_string(&embed).unwrap(), original);
        let settings = read_json_object(&root.join("pi/agent/settings.json")).unwrap();
        assert_eq!(settings["defaultProvider"], "openai");

        fs::remove_file(root.join("setup/skills-choice")).unwrap();
        page.save(&root).unwrap();
        assert_eq!(fs::read_to_string(&embed).unwrap(), original);
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
    fn browsing_every_provider_keeps_the_masked_key_in_the_bottom_panel() {
        use wizard_style::tests::{click, find};
        for (width, height) in [(80, 24), (100, 30)] {
            let mut page = ProviderPage::new();
            page.on_key(KeyCode::Down, KeyModifiers::NONE);
            page.on_key(KeyCode::Down, KeyModifiers::NONE);
            page.on_key(KeyCode::Char(' '), KeyModifiers::NONE);
            page.pi.key = "never-show-this-key".into();
            page.accepted_api = Some("old-probe".into());
            let generation = page.generation;
            page.on_key(KeyCode::Home, KeyModifiers::NONE);
            let mut terminal =
                ratatui::Terminal::new(ratatui::backend::TestBackend::new(width, height)).unwrap();
            for (index, &choice) in pi_choices().iter().enumerate() {
                terminal.draw(|frame| page.draw(frame)).unwrap();
                let buffer = terminal.backend().buffer();
                let (x, y) = find(buffer, &page.pi_label(choice));
                let (_, details_y) = find(buffer, "Connection details");
                let (_, key_y) = find(buffer, "API key:");
                assert!(y < details_y && details_y < key_y);
                assert_eq!(
                    wizard_style::clicked(&click(x, y)),
                    Some(PROVIDER_BASE + index)
                );
                find(buffer, &masked(&page.pi.key));
                assert_eq!(
                    page.pi.choice(),
                    Choice::OpenAi,
                    "browsing never selects implicitly"
                );
                assert_eq!(page.generation, generation);
                page.on_key(KeyCode::Down, KeyModifiers::NONE);
            }
            assert_eq!(page.provider_row(), pi_choices().len() - 1);
            page.on_click(PROVIDER_BASE + pi_choices().len() - 1);
            assert_eq!(page.pi.choice(), *pi_choices().last().unwrap());
            assert!(page.pi.key.is_empty());
            assert_eq!(page.accepted_api, None);
            assert_ne!(page.generation, generation);
            assert!(!page.menu_open());
        }
    }

    #[test]
    fn selected_provider_fields_are_visible_and_key_is_masked() {
        let mut page = ProviderPage::new();
        assert_eq!(
            page.fields(),
            vec![Field::PiProvider, Field::Back, Field::Save]
        );
        let custom = page
            .options(Field::PiProvider)
            .iter()
            .position(|name| name == "Custom provider")
            .unwrap();
        page.commit_option(Field::PiProvider, custom);
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
    fn web_search_radios_commit_only_after_confirmation() {
        let mut page = ProviderPage::new();
        page.set_page(Page::WebSearch);
        assert!(!page.fields().contains(&Field::WebSearchModel));
        page.on_key(KeyCode::Down, KeyModifiers::NONE);
        page.on_key(KeyCode::Down, KeyModifiers::NONE);
        assert!(!page.menu_open());
        assert_eq!(page.search.choice(), SearchChoice::Keep);
        page.on_key(KeyCode::Char(' '), KeyModifiers::NONE);
        assert_eq!(page.search.choice(), SearchChoice::Google);
        assert!(page.fields().contains(&Field::WebSearchModel));
        page.on_key(KeyCode::Home, KeyModifiers::NONE);
        assert_eq!(page.search.choice(), SearchChoice::Google);
        page.on_key(KeyCode::Enter, KeyModifiers::NONE);
        assert_eq!(page.search.choice(), SearchChoice::Keep);
        assert!(!page.fields().contains(&Field::WebSearchModel));
    }

    #[test]
    fn changing_web_search_provider_clears_model_only_on_commit() {
        let mut page = ProviderPage::new();
        page.set_page(Page::WebSearch);
        page.commit_option(Field::WebSearchProvider, 3);
        page.search.model = "gpt-5.1".into();
        page.search.key = "old-key".into();
        page.search.endpoint = "https://old.invalid".into();
        page.on_key(KeyCode::Down, KeyModifiers::NONE);
        assert_eq!(page.search.model, "gpt-5.1");
        assert_eq!(page.search.key, "old-key");
        page.on_key(KeyCode::Enter, KeyModifiers::NONE);
        assert_eq!(page.search.choice(), SearchChoice::Anthropic);
        assert!(page.search.model.is_empty());
        assert!(page.search.key.is_empty());
        assert!(page.search.endpoint.is_empty());
    }

    #[test]
    fn provider_radios_and_service_menus_keep_values_until_commit() {
        let mut page = ProviderPage::new();
        page.pi.model = "keep-me".into();
        page.pi.key = "secret".into();
        page.on_key(KeyCode::Down, KeyModifiers::NONE);
        page.on_key(KeyCode::Down, KeyModifiers::NONE);
        assert_eq!(page.pi.choice(), Choice::Keep);
        assert_eq!(page.pi.key, "secret");
        assert_eq!(page.pi.model, "keep-me");
        assert!(!page.menu_open());
        // Tab leaves the list without committing its highlight.
        page.on_key(KeyCode::Tab, KeyModifiers::NONE);
        page.on_key(KeyCode::BackTab, KeyModifiers::NONE);
        assert_eq!(page.pi.choice(), Choice::Keep);
        page.on_key(KeyCode::Char(' '), KeyModifiers::NONE);
        assert_eq!(page.pi.choice(), Choice::OpenAi);
        assert_eq!(page.focus, Field::PiProvider);
        let generation = page.generation;
        page.on_key(KeyCode::Enter, KeyModifiers::NONE);
        assert_eq!(page.focus, Field::PiSource);
        assert_eq!(
            page.generation, generation,
            "reselecting the same provider is harmless"
        );
        assert!(page.pi.key.is_empty());
        assert!(!page.fields().contains(&Field::PiModel));
        assert!(page.fields().contains(&Field::PiKey));

        page.set_page(Page::Hindsight);
        page.on_key(KeyCode::Down, KeyModifiers::NONE);
        assert_eq!(page.hindsight.choice(), Choice::Keep);
        page.on_key(KeyCode::Enter, KeyModifiers::NONE);
        assert_eq!(page.hindsight.choice(), Choice::None);
    }

    #[test]
    fn services_have_separate_radio_lists_and_lower_forms() {
        use wizard_style::tests::{click, find};
        for (width, height) in [(80, 24), (100, 30)] {
            let mut page = ProviderPage::new();
            for (section, label) in [
                (Page::WebSearch, "Google Gemini"),
                (Page::Hindsight, "OpenAI"),
            ] {
                page.set_page(section);
                let mut terminal =
                    ratatui::Terminal::new(ratatui::backend::TestBackend::new(width, height))
                        .unwrap();
                terminal.draw(|frame| page.draw(frame)).unwrap();
                let buffer = terminal.backend().buffer();
                let (x, y) = find(buffer, label);
                let (_, details_y) = find(buffer, "Connection details");
                assert!(y < details_y);
                let id = wizard_style::clicked(&click(x, y)).unwrap();
                assert!(id >= PROVIDER_BASE);
                page.on_click(id);
                assert!(!page.menu_open());
                assert!(!page.fields().contains(&if section == Page::WebSearch {
                    Field::HindsightModel
                } else {
                    Field::WebSearchModel
                }));
            }
        }
    }

    #[test]
    fn long_menu_scrolls_inside_a_short_terminal_and_clicks_the_visible_option() {
        use wizard_style::tests::{click, find};
        let mut page = ProviderPage::new();
        page.set_page(Page::WebSearch);
        page.on_key(KeyCode::End, KeyModifiers::NONE);
        let mut terminal =
            ratatui::Terminal::new(ratatui::backend::TestBackend::new(120, 18)).unwrap();
        terminal.draw(|frame| page.draw(frame)).unwrap();
        let buffer = terminal.backend().buffer();
        let (x, y) = find(buffer, "OpenCode Go");
        assert_eq!(
            wizard_style::clicked(&click(x, y)),
            Some(PROVIDER_BASE + SEARCH_CHOICES.len() - 1)
        );
        assert_eq!(buffer[(x, y)].bg, wizard_style::selected().bg.unwrap());
        assert_eq!(buffer[(118, y)].bg, wizard_style::selected().bg.unwrap());
        page.on_click(PROVIDER_BASE + SEARCH_CHOICES.len() - 1);
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
        page.set_page(Page::WebSearch);
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
        page.set_page(Page::WebSearch);
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
        assert!(rendered.contains("Use saved Pi credentials"));
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
            page.set_page(Page::WebSearch);
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
        page.set_page(Page::WebSearch);
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
        page.set_page(Page::WebSearch);
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
            page.set_page(Page::WebSearch);
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
        page.set_page(Page::WebSearch);
        page.search.choice = Some(SearchChoice::Google);
        assert!(!page.validate());
        assert!(page
            .error
            .as_deref()
            .unwrap_or_default()
            .contains("Web search"));
        page.search.model = "gemini-3.1-flash-lite".into();
        page.search_source = Some(ServiceSource::Later);
        assert!(page.validate());
        page.search_source = Some(ServiceSource::New);
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
    fn web_search_section_is_labelled_on_services_page() {
        let mut page = ProviderPage::new();
        page.set_page(Page::WebSearch);
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
    fn clicks_select_provider_radios_credentials_and_footer_buttons() {
        use wizard_style::tests::{click, find};
        let mut page = ProviderPage::new();
        page.set_page(Page::WebSearch);
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
        let option = at(&page, "Google Gemini");
        assert_eq!(option, PROVIDER_BASE + 2);
        assert!(page.on_click(option).is_none());
        assert!(!page.menu_open());
        assert_eq!(page.search.choice(), SearchChoice::Google);
        let source = page
            .fields()
            .iter()
            .position(|field| *field == Field::WebSearchSource)
            .unwrap();
        page.on_click(source);
        assert!(page.menu_open());
        page.on_key(KeyCode::End, KeyModifiers::NONE);
        page.on_key(KeyCode::Enter, KeyModifiers::NONE);
        assert!(!page.menu_open());
        assert!(page.service_source() == ServiceSource::Later);
        assert!(!page.fields().contains(&Field::WebSearchKey));
        assert!(matches!(
            page.on_click(at(&page, "Back")),
            Some(Decision::Back)
        ));
        assert!(matches!(
            page.on_click(at(&page, "Next — Memory")),
            Some(Decision::Save)
        ));
    }
}
