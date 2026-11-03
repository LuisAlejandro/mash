mod font_page;
mod model_picker;
mod pi_models;
mod pi_providers;
mod provider_page;
mod skills_page;
mod theme;
mod voice;
mod voice_page;
mod welcome_page;
mod wizard_style;

use ratatui::{
    backend::{Backend, CrosstermBackend},
    crossterm::{
        event::{
            self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind,
            KeyModifiers, MouseButton, MouseEventKind,
        },
        execute,
        terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
    },
    layout::{Alignment, Constraint, Layout, Rect},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Gauge, Paragraph, Wrap},
    Frame, Terminal,
};
use std::{
    env,
    ffi::OsString,
    fs,
    io::{self, Write},
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const UTILITIES: &[(&str, &str)] = &[
    ("git", "Git source control"),
    ("gh", "GitHub CLI and credential helper"),
    ("zoxide", "Smarter directory ranking"),
    ("eza", "File listings"),
    ("fzf", "Interactive fuzzy picker"),
    ("fd", "File discovery"),
    ("bat", "Highlighted file preview"),
    ("rg", "Content search"),
    ("jq", "JSON utility"),
    ("delta", "Git diff and pager"),
    ("sentrux", "Structural analysis for plan, work and qa"),
    ("agent-browser", "Browser automation for page work"),
    ("cua-driver", "Native desktop control for app surfaces"),
];

// CUA Driver ships through its own installer; the remaining Homebrew utilities
// are plain formulae. Every other group carries manifest component names, not
// package specs: the pinned version is resolved from packaging/assets.json at
// install time, so no version is written here.
const CUA_DRIVER_PIN: &str = "0.33.3";

const FORMATTERS: &[(&str, &str)] = &[
    ("prettier", "JavaScript, JSON, Markdown, CSS, Svelte"),
    ("shfmt", "Shell formatting"),
    ("latexindent", "LaTeX formatting"),
    ("gopls", "Go language server"),
    ("rust-analyzer", "Rust language server"),
    ("marksman", "Markdown language server"),
    ("texlab", "LaTeX language server"),
    ("pylsp", "Python language server"),
    (
        "bash-language-server",
        "Bash, TypeScript, YAML, CSS, JSON, Svelte, Tailwind, HTML servers",
    ),
];

// The formatter group covers more servers than the rows above name
// individually. Both platforms resolve these pinned components into Mash's
// data folder. Each entry is the manifest component and the binaries a pane or
// Fresh looks for.
const EXTRA_FORMATTERS: &[(&str, &[&str])] = &[
    // No binary of its own: the plugin has to sit in the same npm prefix as
    // prettier or `prettier --stdin-filepath x.svelte` cannot load it, and
    // defaults/fresh/config.json formats svelte on save with exactly that.
    ("prettier-plugin-svelte", &[]),
    (
        "typescript-language-server",
        &["typescript-language-server"],
    ),
    ("yaml-language-server", &["yaml-language-server"]),
    ("svelte-language-server", &["svelteserver"]),
    (
        "vscode-langservers-extracted",
        &[
            "vscode-css-language-server",
            "vscode-json-language-server",
            "vscode-html-language-server",
        ],
    ),
    (
        "tailwindcss-language-server",
        &["tailwindcss-language-server"],
    ),
];

#[derive(Clone, Copy, PartialEq, Eq)]
enum Group {
    Utilities,
    Formatters,
}

impl Group {
    const ALL: [Group; 2] = [Group::Utilities, Group::Formatters];

    fn title(self) -> &'static str {
        match self {
            Group::Utilities => "Mash utilities",
            Group::Formatters => "Formatters & language servers",
        }
    }

    fn summary(self) -> &'static str {
        match self {
            Group::Utilities => "Git workflows, search, previews, pickers, and GitHub features.",
            Group::Formatters => "Formatting and language intelligence in the editor.",
        }
    }

    fn tools(self) -> &'static [(&'static str, &'static str)] {
        match self {
            Group::Utilities => UTILITIES,
            Group::Formatters => FORMATTERS,
        }
    }
}

struct IdentityPage {
    name: String,
    email: String,
    signing_key: String,
    focus: usize,
}

const FOCUS_NAME: usize = 0;
const FOCUS_EMAIL: usize = 1;
const FOCUS_SIGNING_KEY: usize = 2;
const FOCUS_IDENTITY_NEXT: usize = 3;
const IDENTITY_FOCUS_COUNT: usize = 4;

#[derive(Default, Clone)]
struct Identity {
    name: String,
    email: String,
    signing_key: String,
}

impl IdentityPage {
    fn new() -> Self {
        Self {
            name: git_config_value("user.name"),
            email: git_config_value("user.email"),
            signing_key: git_config_value("user.signingkey"),
            focus: FOCUS_NAME,
        }
    }

    fn identity(&self) -> Identity {
        Identity {
            name: self.name.clone(),
            email: self.email.clone(),
            signing_key: self.signing_key.clone(),
        }
    }

    /// A click focuses the row; the button advances.
    fn on_click(&mut self, focus: usize) -> Option<Outcome> {
        self.focus = focus;
        (focus == FOCUS_IDENTITY_NEXT).then_some(Outcome::Next)
    }

    fn on_key(&mut self, code: KeyCode, modifiers: KeyModifiers) -> Option<Outcome> {
        if modifiers.contains(KeyModifiers::CONTROL) && code == KeyCode::Char('c') {
            return Some(Outcome::Cancel);
        }
        let step = |focus, direction, wrap| {
            wizard_style::focus_step(focus, IDENTITY_FOCUS_COUNT, direction, wrap)
        };
        // A focused text field takes every character. `q`, `j` and `k` are
        // letters in a name, so they cannot double as cancel and navigation
        // while one is focused; Esc still cancels and Enter still continues.
        if self.focus != FOCUS_IDENTITY_NEXT {
            let text = match self.focus {
                FOCUS_NAME => &mut self.name,
                FOCUS_EMAIL => &mut self.email,
                _ => &mut self.signing_key,
            };
            return match code {
                KeyCode::Esc => Some(Outcome::Cancel),
                KeyCode::Enter => Some(Outcome::Next),
                KeyCode::Up | KeyCode::BackTab => {
                    self.focus = step(self.focus, -1, false);
                    None
                }
                KeyCode::Down | KeyCode::Tab => {
                    self.focus = step(self.focus, 1, false);
                    None
                }
                KeyCode::Backspace => {
                    text.pop();
                    None
                }
                KeyCode::Char(c) => {
                    if !modifiers.contains(KeyModifiers::CONTROL) {
                        text.push(c);
                    }
                    None
                }
                _ => None,
            };
        }
        match code {
            KeyCode::Esc | KeyCode::Char('q') => Some(Outcome::Cancel),
            KeyCode::Down | KeyCode::Char('j') => {
                self.focus = step(self.focus, 1, false);
                None
            }
            KeyCode::Up | KeyCode::Char('k') => {
                self.focus = step(self.focus, -1, false);
                None
            }
            KeyCode::Tab => {
                self.focus = step(self.focus, 1, true);
                None
            }
            KeyCode::BackTab => {
                self.focus = step(self.focus, -1, true);
                None
            }
            KeyCode::Enter => Some(Outcome::Next),
            _ => None,
        }
    }
}

struct ToolsPage {
    selections: [bool; 2],
    focus: usize,
}

// Rows 0 and 1 are the groups, in `Group::ALL` order.
const FOCUS_GROUP_UTILITIES: usize = 0;
const FOCUS_GROUP_FORMATTERS: usize = 1;
const FOCUS_TOOLS_BACK: usize = 2;
const FOCUS_TOOLS_NEXT: usize = 3;
const TOOLS_FOCUS_COUNT: usize = 4;

impl ToolsPage {
    fn new() -> Self {
        Self {
            selections: [true, true],
            focus: FOCUS_GROUP_UTILITIES,
        }
    }

    // Which checkbox the focus is on, if any.
    fn selection(&self) -> Option<usize> {
        (self.focus < Group::ALL.len()).then_some(self.focus)
    }

    fn toggle(&mut self, index: usize) {
        self.selections[index] = !self.selections[index];
    }

    /// A click focuses the row; a checkbox toggles too, and the buttons act.
    fn on_click(&mut self, focus: usize) -> Option<Outcome> {
        self.focus = focus;
        if let Some(index) = self.selection() {
            self.toggle(index);
        }
        match focus {
            FOCUS_TOOLS_BACK => Some(Outcome::Back),
            FOCUS_TOOLS_NEXT => Some(Outcome::Next),
            _ => None,
        }
    }

    fn on_key(&mut self, code: KeyCode, modifiers: KeyModifiers) -> Option<Outcome> {
        if modifiers.contains(KeyModifiers::CONTROL) && code == KeyCode::Char('c') {
            return Some(Outcome::Cancel);
        }
        let step = |focus, direction, wrap| {
            wizard_style::focus_step(focus, TOOLS_FOCUS_COUNT, direction, wrap)
        };
        match code {
            KeyCode::Esc | KeyCode::Char('q') => Some(Outcome::Cancel),
            KeyCode::Down | KeyCode::Char('j') => {
                self.focus = step(self.focus, 1, false);
                None
            }
            KeyCode::Up | KeyCode::Char('k') => {
                self.focus = step(self.focus, -1, false);
                None
            }
            KeyCode::Tab => {
                self.focus = step(self.focus, 1, true);
                None
            }
            KeyCode::BackTab => {
                self.focus = step(self.focus, -1, true);
                None
            }
            KeyCode::Char(' ') => {
                if let Some(index) = self.selection() {
                    self.toggle(index);
                }
                None
            }
            KeyCode::Char(digit @ ('1' | '2')) => {
                self.focus = if digit == '1' {
                    FOCUS_GROUP_UTILITIES
                } else {
                    FOCUS_GROUP_FORMATTERS
                };
                self.toggle(self.focus);
                None
            }
            KeyCode::Enter => match self.focus {
                FOCUS_TOOLS_BACK => Some(Outcome::Back),
                FOCUS_TOOLS_NEXT => Some(Outcome::Next),
                _ => None,
            },
            _ => None,
        }
    }
}

enum Outcome {
    Next,
    Back,
    Cancel,
}

fn main() {
    match run() {
        Ok(outcome) => std::process::exit(outcome),
        Err(error) => {
            eprintln!("Mash setup: {error}");
            std::process::exit(1);
        }
    }
}

// Mash's own directory. The wizard runs before the launcher isolates the
// environment, so HOME is still the real home here.
fn data_dir() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(env::temp_dir)
        .join(".mash")
}

// Where a finished run is remembered. Mash's own directory, never the app
// bundle: the bundle is signed, so nothing may be written inside it.
fn state_dir() -> PathBuf {
    data_dir().join("setup")
}

fn setup_is_done() -> bool {
    load_state(&state_dir()).completed
}

// Exit status when the wizard ends without finishing setup. herdr-pane treats
// anything but 0 as "setup is not done" and keeps Herdr closed, so a stray Esc
// can no longer drop the user into an unconfigured Mash. 0 is reserved for a
// finished setup.
const EXIT_NOT_DONE: i32 = 3;
const OPEN_WORKSPACE_MARKER: &str = "open-workspace-once";

fn run() -> Result<i32, String> {
    // Preview is read-only and may run after setup is complete. The ordinary
    // launch still returns immediately once the wizard has been finished.
    let preview = env::args_os().any(|arg| arg == "--preview");
    if !preview && setup_is_done() {
        return Ok(0);
    }
    enable_raw_mode().map_err(|e| e.to_string())?;
    let mut out = io::stdout();
    if let Err(error) = execute!(out, EnterAlternateScreen, EnableMouseCapture) {
        let _ = execute!(io::stdout(), DisableMouseCapture, LeaveAlternateScreen);
        let _ = disable_raw_mode();
        return Err(error.to_string());
    }
    let backend = CrosstermBackend::new(out);
    let result = Terminal::new(backend)
        .map_err(|error| error.to_string())
        .and_then(|mut terminal| interactive(&mut terminal, preview));
    let _ = execute!(io::stdout(), DisableMouseCapture, LeaveAlternateScreen);
    let _ = disable_raw_mode();
    result
}

fn interactive<B: Backend>(terminal: &mut Terminal<B>, preview: bool) -> Result<i32, String> {
    let mut identity = IdentityPage::new();
    let mut tools = ToolsPage::new();
    let mut providers = provider_page::ProviderPage::new();
    providers.load_existing_auth(&data_dir().join("pi/agent"));
    let mut skills = skills_page::SkillsPage::new();
    let mut fonts =
        font_page::FontPage::new(&mash_resources(), &data_dir().join("config/ghostty/config"));
    fonts.theme = theme::Theme::current(&data_dir());
    fonts.keybindings = font_page::Keybindings::current(&data_dir());
    let mut voice = voice_page::VoicePage::new();
    let mut page = 0;
    let mut started = false;
    let mut start_button = Rect::default();
    loop {
        providers.set_services(page == 3);
        if !preview && page == 2 {
            providers.poll_models();
        }
        terminal
            .draw(|frame| {
                if started {
                    match page {
                        0 => draw_identity(frame, &identity),
                        1 => draw_tools(frame, &tools),
                        2 | 3 => providers.draw(frame),
                        4 => skills.draw(frame),
                        5 => fonts.draw(frame),
                        _ => voice.draw(frame),
                    }
                } else {
                    start_button = welcome_page::draw(frame);
                }
                if preview && started {
                    wizard_style::preview_hint(frame);
                }
            })
            .map_err(|e| e.to_string())?;
        if providers.is_loading()
            && !event::poll(Duration::from_millis(50)).map_err(|e| e.to_string())?
        {
            continue;
        }
        let event = event::read().map_err(|e| e.to_string())?;
        if !started {
            if welcome_page::starts_on(&event, start_button) {
                started = true;
            } else if let Event::Key(key) = event {
                if key.kind == KeyEventKind::Press
                    && (key.code == KeyCode::Esc
                        || (key.code == KeyCode::Char('c')
                            && key.modifiers.contains(KeyModifiers::CONTROL)))
                    && (preview || confirm_quit(terminal)?)
                {
                    return Ok(EXIT_NOT_DONE);
                }
            }
            continue;
        }
        let click = wizard_style::clicked(&event);
        if let Some(id) = click.filter(|id| *id >= wizard_style::SIDEBAR_BASE) {
            providers.close_menu();
            providers.cancel_loading();
            page = id - wizard_style::SIDEBAR_BASE;
            continue;
        }
        if matches!(page, 2 | 3)
            && providers.menu_open()
            && click.is_none()
            && matches!(&event, Event::Mouse(mouse) if mouse.kind == MouseEventKind::Down(MouseButton::Left))
        {
            providers.close_menu();
            continue;
        }
        if preview {
            if let Some(id) = click {
                // Clicks show real focus and toggles, but a button only turns
                // the page: nothing is validated or saved in a preview.
                let step = match page {
                    0 => identity.on_click(id).map(|_| 1),
                    1 => tools
                        .on_click(id)
                        .map(|o| if matches!(o, Outcome::Back) { -1 } else { 1 }),
                    2 | 3 => providers.on_click(id).map(|d| {
                        if matches!(d, provider_page::Decision::Back) {
                            -1
                        } else if matches!(d, provider_page::Decision::Save)
                            && page == 2
                            && !providers.advance(
                                &mash_resources(),
                                &data_dir().join("pi/agent"),
                                true,
                            )
                        {
                            0
                        } else {
                            1
                        }
                    }),
                    4 => skills.on_click(id).map(|d| {
                        if matches!(d, skills_page::Decision::Back) {
                            -1
                        } else {
                            1
                        }
                    }),
                    5 => fonts.on_click(id).map(|d| match d {
                        font_page::Decision::Back => -1,
                        font_page::Decision::Next => 1,
                        font_page::Decision::Cancel => 0,
                    }),
                    _ => voice.on_click(id).map(|d| {
                        if matches!(d, voice_page::Decision::Back) {
                            -1
                        } else {
                            0
                        }
                    }),
                };
                page = (page as isize + step.unwrap_or(0))
                    .clamp(0, wizard_style::PAGE_COUNT as isize - 1)
                    as usize;
            } else if matches!(page, 2 | 3)
                && providers.menu_open()
                && wizard_style::wheel(&event).is_some()
            {
                let code = if wizard_style::wheel(&event) == Some(-1) {
                    KeyCode::Up
                } else {
                    KeyCode::Down
                };
                let _ = providers.on_key(code, KeyModifiers::NONE);
            } else if let Event::Key(key) = event {
                if key.kind == KeyEventKind::Press {
                    if matches!(page, 2 | 3)
                        && (providers.menu_open()
                            || providers.has_model_step()
                            || matches!(
                                key.code,
                                KeyCode::Enter
                                    | KeyCode::Char(' ')
                                    | KeyCode::Tab
                                    | KeyCode::BackTab
                            ))
                        && !(key.code == KeyCode::Char('c')
                            && key.modifiers.contains(KeyModifiers::CONTROL))
                    {
                        match providers.on_key(key.code, key.modifiers) {
                            Some(provider_page::Decision::Back) => page = page.saturating_sub(1),
                            Some(provider_page::Decision::Save)
                                if providers.advance(
                                    &mash_resources(),
                                    &data_dir().join("pi/agent"),
                                    true,
                                ) =>
                            {
                                page += 1
                            }
                            _ => {}
                        }
                    } else if preview_key(&mut started, &mut page, key.code, key.modifiers) {
                        return Ok(EXIT_NOT_DONE);
                    }
                }
            }
            // In preview no save calls or installers run.
            continue;
        }
        // The wheel walks focus exactly like the arrow keys.
        let key = match (wizard_style::wheel(&event), event) {
            (Some(-1), _) => Some((KeyCode::Up, KeyModifiers::NONE)),
            (Some(_), _) => Some((KeyCode::Down, KeyModifiers::NONE)),
            (None, Event::Key(key)) if key.kind == KeyEventKind::Press => {
                Some((key.code, key.modifiers))
            }
            _ => None,
        };
        if click.is_none() && key.is_none() {
            continue;
        }
        let (code, modifiers) = key.unwrap_or((KeyCode::Null, KeyModifiers::NONE));
        match page {
            0 | 1 => match if let Some(id) = click {
                if page == 0 {
                    identity.on_click(id)
                } else {
                    tools.on_click(id)
                }
            } else if page == 0 {
                identity.on_key(code, modifiers)
            } else {
                tools.on_key(code, modifiers)
            } {
                Some(Outcome::Cancel) => {
                    if confirm_quit(terminal)? {
                        return Ok(EXIT_NOT_DONE);
                    }
                }
                Some(Outcome::Next) => page += 1,
                Some(Outcome::Back) => page -= 1,
                None => {}
            },
            2 | 3 => match if let Some(id) = click {
                providers.on_click(id)
            } else {
                providers.on_key(code, modifiers)
            } {
                Some(provider_page::Decision::Cancel) => {
                    if confirm_quit(terminal)? {
                        return Ok(EXIT_NOT_DONE);
                    }
                }
                Some(provider_page::Decision::Back) => page -= 1,
                Some(provider_page::Decision::Save)
                    if providers.advance(
                        &mash_resources(),
                        &data_dir().join("pi/agent"),
                        false,
                    ) =>
                {
                    page += 1
                }
                _ => {}
            },
            4 => match if let Some(id) = click {
                skills.on_click(id)
            } else {
                skills.on_key(code, modifiers)
            } {
                Some(skills_page::Decision::Cancel) => {
                    if confirm_quit(terminal)? {
                        return Ok(EXIT_NOT_DONE);
                    }
                }
                Some(skills_page::Decision::Back) => page = 3,
                Some(skills_page::Decision::Save) => page = 5,
                _ => {}
            },
            5 => match if let Some(id) = click {
                fonts.on_click(id)
            } else {
                fonts.on_key(code, modifiers)
            } {
                Some(font_page::Decision::Cancel) => {
                    if confirm_quit(terminal)? {
                        return Ok(EXIT_NOT_DONE);
                    }
                }
                Some(font_page::Decision::Back) => page = 4,
                Some(font_page::Decision::Next) => page = 6,
                None => {}
            },
            _ => match if let Some(id) = click {
                voice.on_click(id)
            } else {
                voice.on_key(code, modifiers)
            } {
                Some(voice_page::Decision::Cancel) => {
                    if confirm_quit(terminal)? {
                        return Ok(EXIT_NOT_DONE);
                    }
                }
                Some(voice_page::Decision::Back) => page = 5,
                Some(voice_page::Decision::Skip) => break,
                Some(voice_page::Decision::Save) if voice.validate() => break,
                _ => {}
            },
        }
    }

    let mut plan = install_plan(tools.selections);
    plan.voice = voice.choice();
    plan.programming = skills.programming();
    let identity = identity.identity();
    match review_and_apply(
        terminal,
        &plan,
        &identity,
        &fonts,
        &mut skills,
        &mut providers,
    ) {
        Ok(()) => {
            if tools.selections[0] {
                offer_github_login(terminal)?;
            }
            Ok(0)
        }
        Err(ApplyError::Failed(message)) => Err(message),
    }
}

// A preview shows the pages without letting fields, saves or installers run.
// Esc returns to the logo, then exits; arrows and page digits browse the pages.
fn preview_key(
    started: &mut bool,
    page: &mut usize,
    code: KeyCode,
    modifiers: KeyModifiers,
) -> bool {
    if code == KeyCode::Esc
        || (code == KeyCode::Char('c') && modifiers.contains(KeyModifiers::CONTROL))
    {
        if *started {
            *started = false;
            *page = 0;
            return false;
        }
        return true;
    }
    match code {
        KeyCode::Right => *page = (*page + 1).min(wizard_style::PAGE_COUNT - 1),
        KeyCode::Left => *page = page.saturating_sub(1),
        KeyCode::Char('1'..='7') => {
            if let KeyCode::Char(digit) = code {
                *page = digit as usize - '1' as usize;
            }
        }
        _ => {}
    }
    false
}

// Esc, `q` and Ctrl+C all land here instead of leaving the wizard. Quitting
// half-way used to drop the user into Herdr with nothing configured, and Esc
// is the key people press to back out of a field, so one keystroke must never
// be enough. Only an explicit `y` quits; any other key returns to the page
// exactly as it was. Returns Ok(true) to quit.
fn confirm_quit<B: Backend>(terminal: &mut Terminal<B>) -> Result<bool, String> {
    loop {
        terminal
            .draw(draw_confirm_quit)
            .map_err(|e| e.to_string())?;
        let Event::Key(key) = event::read().map_err(|e| e.to_string())? else {
            continue;
        };
        if key.kind != KeyEventKind::Press {
            continue;
        }
        return Ok(confirm_quit_answer(key.code));
    }
}

// Kept apart from the event loop so the rule is testable without a terminal.
fn confirm_quit_answer(code: KeyCode) -> bool {
    matches!(code, KeyCode::Char('y') | KeyCode::Char('Y'))
}

fn draw_confirm_quit(frame: &mut Frame) {
    let text = vec![
        Line::from(Span::styled(
            "Quit Mash setup?",
            Style::default().add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from("Setup is not finished, so Mash will not open yet."),
        Line::from("Open Mash again to start setup from the beginning."),
        Line::from(""),
        Line::from(vec![
            Span::styled(
                "y",
                Style::default()
                    .fg(wizard_style::YELLOW)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw(" quit setup    "),
            Span::styled(
                "any other key",
                Style::default()
                    .fg(wizard_style::YELLOW)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw(" keep going"),
        ]),
    ];
    let area = frame.area();
    let [_, middle, _] = Layout::vertical([
        Constraint::Fill(1),
        Constraint::Length(text.len() as u16 + 2),
        Constraint::Fill(1),
    ])
    .areas(area);
    let body = wizard_style::section(frame, middle, "Mash setup");
    frame.render_widget(
        Paragraph::new(text)
            .alignment(Alignment::Center)
            .wrap(Wrap { trim: true })
            .style(
                Style::default()
                    .fg(wizard_style::TEXT)
                    .bg(wizard_style::PANEL),
            ),
        body,
    );
}

enum ApplyError {
    Failed(String),
}

fn review_and_apply<B: Backend>(
    terminal: &mut Terminal<B>,
    plan: &Plan,
    identity: &Identity,
    fonts: &font_page::FontPage,
    skills: &mut skills_page::SkillsPage,
    providers: &mut provider_page::ProviderPage,
) -> Result<(), ApplyError> {
    let state_dir = state_dir();
    let mut state = load_state(&state_dir);
    let prepare = (|| -> Result<(), String> {
        // The keybinding mode comes first: the seed sync below renders Fresh's
        // map for it, and the launcher opens Mash right after this returns.
        fonts.save_mode(&data_dir())?;
        skills.save_selection(&data_dir())?;
        seed_selected_skills()?;
        providers.save(&data_dir())?;
        Ok(())
    })();
    if let Err(error) = prepare {
        state.error = error;
        save_state(&state_dir, &state);
        return Err(ApplyError::Failed(state.error));
    }
    check_saved_model(terminal);
    let missing: Vec<&str> = plan
        .tools
        .iter()
        .copied()
        .filter(|name| !is_available(name))
        .collect();
    let log_path = state_dir.join("setup.log");
    if let Err(error) = apply_steps(plan, &missing, &log_path, terminal) {
        state.error = error;
        save_state(&state_dir, &state);
        return Err(ApplyError::Failed(state.error));
    }
    // After the installers, so `git` exists by the time this runs on a fresh
    // machine.
    match apply_git_identity(identity, &data_dir().join("config/git/config")) {
        Ok(note) => {
            if let Ok(mut log) = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(state_dir.join("setup.log"))
            {
                let _ = writeln!(log, "  Git identity: {note}");
            }
        }
        Err(error) => {
            state.error = error;
            save_state(&state_dir, &state);
            return Err(ApplyError::Failed(state.error));
        }
    }
    if let Err(error) = fonts
        .save(&data_dir().join("config/ghostty/config"))
        .and_then(|()| fonts.theme.apply(&data_dir()))
    {
        state.error = error;
        save_state(&state_dir, &state);
        return Err(ApplyError::Failed(state.error));
    }
    mark_complete(&state_dir, &mut state);
    Ok(())
}

/// Diagnostic failures are notes, never setup failures or early completion.
fn check_saved_model<B: Backend>(terminal: &mut Terminal<B>) {
    let agent = data_dir().join("pi/agent");
    let selected = fs::read_to_string(agent.join("settings.json"))
        .ok()
        .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
        .is_some_and(|value| {
            value["defaultProvider"]
                .as_str()
                .is_some_and(|s| !s.is_empty())
                && value["defaultModel"]
                    .as_str()
                    .is_some_and(|s| !s.is_empty())
        });
    if !selected {
        return;
    }
    let request = serde_json::json!({"version":1,"action":"verify","agentDir":agent});
    let mut job = pi_models::Job::start(&mash_resources(), request).ok();
    let notes = if let Some(job) = job.as_mut() {
        loop {
            if let Some(result) = job.poll() {
                break result.map(|report| report.warnings()).unwrap_or_else(|_| vec!["Pi model check unavailable. Your configuration was kept; use Pi /model and /login after setup.".into()]);
            }
            if terminal
                .draw(|frame| draw_model_check(frame, &[], true))
                .is_err()
            {
                return;
            }
            if event::poll(Duration::from_millis(50)).unwrap_or(true) {
                match event::read() {
                    Ok(event) if acknowledges_model_check(&event) => return,
                    Ok(_) => {}
                    Err(_) => return,
                }
            }
        }
    } else {
        vec!["Pi model check unavailable. Your configuration was kept; use Pi /model and /login after setup.".into()]
    };
    drop(job);
    if notes.is_empty() {
        return;
    }
    loop {
        if terminal
            .draw(|frame| draw_model_check(frame, &notes, false))
            .is_err()
        {
            return;
        }
        match event::read() {
            Ok(event) if acknowledges_model_check(&event) => return,
            Ok(_) => {}
            Err(_) => return,
        }
    }
}

fn acknowledges_model_check(event: &Event) -> bool {
    matches!(event, Event::Key(key) if key.kind == KeyEventKind::Press && matches!(key.code, KeyCode::Enter | KeyCode::Esc))
        || wizard_style::clicked(event) == Some(0)
}

fn draw_model_check(frame: &mut Frame, notes: &[String], loading: bool) {
    let parts = Layout::vertical([
        Constraint::Length(3),
        Constraint::Min(4),
        Constraint::Length(3),
    ])
    .split(wizard_style::page_area(frame, None));
    wizard_style::header(frame, parts[0], "Model check");
    let body = wizard_style::section(
        frame,
        parts[1],
        if loading {
            "Checking saved local configuration..."
        } else {
            "Configuration notes (non-blocking)"
        },
    );
    let mut lines: Vec<Line> = notes
        .iter()
        .flat_map(|note| [Line::from(note.clone()), Line::default()])
        .collect();
    lines.push(Line::from(
        "No server authentication or account entitlement was checked.",
    ));
    frame.render_widget(Paragraph::new(lines).wrap(Wrap { trim: true }), body);
    wizard_style::render_buttons(
        frame,
        parts[2],
        &[(
            wizard_style::button(
                true,
                if loading {
                    " Skip check "
                } else {
                    " Continue "
                },
            ),
            Some(0),
        )],
    );
}

fn now_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

#[derive(Default)]
struct State {
    completed: bool,
    completed_at: u128,
    error: String,
}

fn load_state(dir: &Path) -> State {
    let text = fs::read_to_string(dir.join("state.txt")).unwrap_or_default();
    State {
        completed: text.lines().any(|line| line == "completed=true"),
        completed_at: 0,
        error: text
            .lines()
            .find_map(|line| line.strip_prefix("error="))
            .unwrap_or_default()
            .to_string(),
    }
}

fn mark_complete(dir: &Path, state: &mut State) {
    state.completed = true;
    state.error.clear();
    state.completed_at = now_millis();
    save_state(dir, state);
    // herdr-pane consumes this once, on the handoff right after setup, to open
    // the new-workspace popup. Later launches find no marker and skip it.
    let _ = fs::write(dir.join(OPEN_WORKSPACE_MARKER), "1\n");
}

fn save_state(dir: &Path, state: &State) {
    let _ = fs::create_dir_all(dir);
    let _ = fs::write(
        dir.join("state.txt"),
        format!(
            "completed={}\ncompleted_at={}\nerror={}\n",
            state.completed, state.completed_at, state.error
        ),
    );
}

// Host installers (Homebrew, CUA) must not resolve Mash's bundled runtimes
// or install into the signed bundle. npm and Python tools use mash-tool-install.
fn host_path() -> OsString {
    let inherited = env::var_os("PATH").unwrap_or_default();
    let mut dirs: Vec<OsString> = env::split_paths(&inherited)
        .filter(|dir| {
            let text = dir.to_string_lossy();
            !text.contains("/Mash.app/") && !text.ends_with("/.mash/bin")
        })
        .map(PathBuf::into_os_string)
        .collect();
    // CUA Driver installs into ~/.local/bin, which a GUI launch never has on
    // PATH. Mash adds the directory for its panes; npm tools use ~/.mash/bin.
    if let Some(home) = env::var_os("HOME") {
        let local = PathBuf::from(home).join(".local/bin").into_os_string();
        if !dirs.contains(&local) {
            dirs.push(local);
        }
    }
    for extra in [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ] {
        let dir = OsString::from(extra);
        if !dirs.contains(&dir) {
            dirs.push(dir);
        }
    }
    env::join_paths(dirs).unwrap_or(inherited)
}

fn is_available(tool: &str) -> bool {
    // Managed tool shims live in Mash's bin on both platforms. On macOS the
    // host path remains available for Homebrew tools and CUA Driver.
    if data_dir().join("bin").join(tool).is_file() {
        return true;
    }
    let path = if is_linux() {
        env::var_os("PATH").unwrap_or_default()
    } else {
        host_path()
    };
    Command::new("sh")
        .env("PATH", path)
        .args(["-c", &format!("command -v {tool} >/dev/null 2>&1")])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn tools_available(tools: &[&str]) -> bool {
    tools.iter().all(|tool| is_available(tool))
}

// The bundle already contains the optional suites. Sync only after the final
// choice has been written, then wire up their runtime paths just as the Linux
// launcher does. The regular launcher does the same on later opens.
fn seed_selected_skills() -> Result<(), String> {
    let res = mash_resources();
    let data = data_dir();
    let mut sync = Command::new(res.join("bin/mash-seed-sync"));
    sync.arg(&res).arg(&data);
    run_logged(sync)?;
    let mut setup = Command::new("/bin/bash");
    setup.args([
        "-c",
        "res=$1; d=$2; source \"$res/bin/launch-common.sh\"; mash_seed_programming_skills; mash_seed_hindsight",
        "mash",
    ]);
    setup.arg(&res).arg(&data);
    run_logged(setup)?;
    Ok(())
}

// Host installers run only when a selected tool is missing. Mash-owned tools
// install even when the host has a copy: a host binary cannot satisfy Mash's
// pinned, isolated install. Environment steps always run.
const STEP_HINDSIGHT: &str = "Install the Hindsight environment";
const STEP_HINDSIGHT_DAEMON: &str = "Start Hindsight and fetch its models";
const STEP_VOICE: &str = "Install the dictation model";

fn install_steps(plan: &Plan, missing: &[&str]) -> Vec<String> {
    let mut steps = vec!["Check selected tools".to_string()];
    // Host and Linux tool installers are skipped when everything is present.
    if !missing.is_empty() {
        if !plan.linux.is_empty() {
            steps.push(STEP_LINUX_TOOLS.to_string());
        }
        if !plan.brew.is_empty() {
            steps.push("Install Homebrew packages".to_string());
        }
    }
    // A host binary must not satisfy Mash's own install: first launch creates
    // pinned shims even when the machine already has these tools.
    if !plan.npm.is_empty() {
        steps.push("Install npm packages".to_string());
    }
    if !plan.pinned.is_empty() {
        steps.push(STEP_PINNED_TOOLS.to_string());
    }
    if !plan.python.is_empty() {
        steps.push("Install Python packages".to_string());
    }
    if !missing.is_empty() && !plan.installer.is_empty() {
        steps.push("Install CUA Driver".to_string());
    }
    if plan.programming {
        steps.push(STEP_HINDSIGHT.to_string());
        steps.push(STEP_HINDSIGHT_DAEMON.to_string());
    }
    // Last, and only when the page chose one: the model is the big download,
    // and it goes straight into the cache Pi Voice reads, so nothing re-runs
    // it when the same file is already there.
    if plan.voice.is_some() {
        steps.push(STEP_VOICE.to_string());
    }
    steps
}

// The embedding model and the reranker are fetched on the daemon's first start,
// not when its environment is installed. Doing it here is what makes the first
// chat session fast, and it is the only place the daemon is proven to boot
// before anyone depends on it.
fn start_hindsight_daemon<B: Backend>(
    terminal: &mut Terminal<B>,
    completed: usize,
    total: usize,
    step: &str,
    messages: &[String],
) -> Result<String, String> {
    let warm_start = mash_resources().join("defaults/pi/scripts/ensure-hindsight-daemon.sh");
    let warm_start = warm_start
        .canonicalize()
        .map_err(|e| format!("the Hindsight warm-start script is missing: {e}"))?;
    let data = data_dir();
    let mut command = Command::new(&warm_start);
    command
        .env("PATH", env::var_os("PATH").unwrap_or_default())
        .env("MASH_DATA_DIR", &data)
        .env("MASH_CONFIG_DIR", data.join("config/mash"))
        // The wizard runs before mash_isolate, so it has to set these itself.
        // Without HF_HOME the daemon's HOME is the data folder, and the default
        // cache falls to <data>/.cache/huggingface: a second 470 MB copy of the
        // embedding model, beside the one mash_isolate would use later.
        .env("HF_HOME", data.join("cache/huggingface"))
        .env(
            "HINDSIGHT_API_RERANKER_FLASHRANK_CACHE_DIR",
            data.join("cache/flashrank"),
        )
        // A cold boot loads an ONNX model and an embedded Postgres, so the
        // daemon gets the same generous deadline the warm-start script uses.
        .env("HINDSIGHT_EMBED_DAEMON_STARTUP_TIMEOUT", "600")
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // The warm-start script always exits 0, so its status proves nothing. The
    // daemon's own /version is the real check.
    let _ = command.status();
    for _ in 0..60 {
        if hindsight_is_up() {
            return Ok("daemon up, models cached".into());
        }
        let mut shown = messages.to_vec();
        shown.push("  ...waiting for the daemon to answer on its port".to_string());
        draw_apply(terminal, completed, total, step, &shown);
        std::thread::sleep(Duration::from_secs(10));
    }
    Err(
        "the Hindsight daemon did not come up; see ~/.mash/.hindsight/hook-last-run.log"
            .to_string(),
    )
}

// The daemon answers /health for any squatter, so ask for /version.
fn hindsight_is_up() -> bool {
    let port = mash_hindsight_port();
    Command::new("/usr/bin/curl")
        .args([
            "-fsS",
            "-m",
            "2",
            &format!("http://127.0.0.1:{port}/version"),
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .map(|out| {
            out.status.success() && String::from_utf8_lossy(&out.stdout).contains("api_version")
        })
        .unwrap_or(false)
}

// Read from the config Mash seeds, so the two never drift.
fn mash_hindsight_port() -> u16 {
    let config = data_dir().join(".hindsight/embed");
    fs::read_to_string(config)
        .ok()
        .and_then(|text| {
            text.lines()
                .find_map(|line| line.strip_prefix("HINDSIGHT_API_PORT="))
                .and_then(|value| value.trim().parse().ok())
        })
        .unwrap_or(8998)
}

// The environment installers ship with Mash and do their own logging and
// locking. This runs one with the data folder as its argument, redrawing while
// it works: these steps download hundreds of megabytes, and a screen frozen on
// one frame for ten minutes is indistinguishable from a hang.
fn install_helper_with_progress<B: Backend>(
    terminal: &mut Terminal<B>,
    completed: usize,
    total: usize,
    step: &str,
    messages: &[String],
    script_name: &str,
) -> Result<String, String> {
    let script = mash_bin().join(script_name);
    if !script.is_file() {
        return Err(format!("{script_name} is missing from the bundle"));
    }
    let helper_log = helper_log_path(script_name);
    let mut command = Command::new(&script);
    command
        // The inherited PATH, not host_path(): these scripts drive the bundled
        // node and python, and host_path deliberately strips both.
        .env("PATH", env::var_os("PATH").unwrap_or_default())
        .arg(data_dir())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let mut child = command.spawn().map_err(|e| e.to_string())?;
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Ok("installed".into()),
            Ok(Some(_)) => {
                return Err(format!(
                    "{script_name} failed; see {}",
                    helper_log.display()
                ))
            }
            Ok(None) => {}
            Err(error) => return Err(error.to_string()),
        }
        let mut shown = messages.to_vec();
        if let Some(line) = last_log_line(&helper_log) {
            shown.push(format!("  ...{line}"));
        }
        draw_apply(terminal, completed, total, step, &shown);
        std::thread::sleep(Duration::from_millis(700));
    }
}

// Install the dictation model through the bundled helper. It writes the voice
// settings only after the download and checksum succeed, so a failed install
// leaves Pi Voice's own wizard ready to take over rather than half-configured.
fn install_voice_model<B: Backend>(
    terminal: &mut Terminal<B>,
    completed: usize,
    total: usize,
    step: &str,
    messages: &[String],
    choice: &voice::VoiceChoice,
) -> Result<String, String> {
    let script = mash_bin().join("mash-voice-model");
    if !script.is_file() {
        return Err("mash-voice-model is missing from the bundle".into());
    }
    let helper_log = helper_log_path("mash-voice-model");
    let mut command = Command::new(&script);
    command
        // The inherited PATH, as with the other environment helpers:
        // mash-voice-model drives the bundled node and curl itself.
        .env("PATH", env::var_os("PATH").unwrap_or_default())
        .arg(data_dir())
        .arg(&choice.model_id)
        .arg(choice.languages.join(","))
        .arg(if choice.needs_detector { "1" } else { "0" })
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let mut child = command.spawn().map_err(|e| e.to_string())?;
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Ok("model installed".into()),
            Ok(Some(_)) => {
                return Err(format!(
                    "mash-voice-model failed; see {}",
                    helper_log.display()
                ))
            }
            Ok(None) => {}
            Err(error) => return Err(error.to_string()),
        }
        let mut shown = messages.to_vec();
        if let Some(line) = last_log_line(&helper_log) {
            shown.push(format!("  ...{line}"));
        }
        draw_apply(terminal, completed, total, step, &shown);
        std::thread::sleep(Duration::from_millis(700));
    }
}

/// Install selected components into Mash's data folder through the manifest.
///
/// One helper call per component, so a failure is attributable and a tool that
/// is already present costs nothing. Exit 3 means the platform supplies that
/// tool; setup records it and continues rather than asking for a password.
fn install_mash_tools<B: Backend>(
    terminal: &mut Terminal<B>,
    completed: usize,
    total: usize,
    step: &str,
    messages: &[String],
    components: &[&'static str],
) -> Result<String, String> {
    let helper = mash_bin().join("mash-tool-install");
    if !helper.is_file() {
        return Err(format!("{} is missing from the bundle", helper.display()));
    }
    let mut installed = 0usize;
    let mut provided = 0usize;
    let mut shown = messages.to_vec();
    for component in components {
        draw_apply(terminal, completed, total, step, &shown);
        let status = Command::new(&helper)
            .env("PATH", env::var_os("PATH").unwrap_or_default())
            .env("MASH_DATA_DIR", data_dir())
            .env(
                "MASH_INSTALL_NPM_ONLY",
                if step == "Install npm packages" {
                    "1"
                } else {
                    "0"
                },
            )
            .env(
                "MASH_INSTALL_BINARY_ONLY",
                if step == STEP_PINNED_TOOLS { "1" } else { "0" },
            )
            .arg(component)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map_err(|e| format!("{component}: {e}"))?;
        match status.code() {
            Some(0) => installed += 1,
            Some(3) => {
                provided += 1;
                shown.push(format!(
                    "  {component}: provided by the system, not installed by Mash"
                ));
            }
            Some(code) => {
                return Err(format!(
                    "{component} failed to install (exit {code}); see {}",
                    helper_log_path("mash-tool-install").display()
                ))
            }
            None => return Err(format!("{component} ended without an exit status")),
        }
    }
    Ok(format!(
        "{installed} installed, {provided} provided by the system"
    ))
}

// mash-hindsight-install logs to setup/hindsight-install.log, and so on.
fn helper_log_path(script_name: &str) -> PathBuf {
    let stem = script_name.strip_prefix("mash-").unwrap_or(script_name);
    data_dir().join("setup").join(format!("{stem}.log"))
}

fn last_log_line(path: &Path) -> Option<String> {
    let text = fs::read_to_string(path).ok()?;
    text.lines()
        .rev()
        .find(|line| !line.trim().is_empty())
        .map(|line| line.trim().chars().take(96).collect::<String>())
}

fn mash_bin() -> PathBuf {
    mash_resources().join("bin")
}

// The one resource root both adapters stage into: a macOS Contents/Resources or
// a Linux /opt/letsmash. MASH_RES_ROOT wins when the launcher set it, because
// that is the value the rest of the process tree already uses. Otherwise the
// binary's own location decides: inside a bundle it is the bundle's Resources
// directory, and everywhere else the wizard sits at <root>/bin/mash-wizard.
fn mash_resources() -> PathBuf {
    if let Some(explicit) = env::var_os("MASH_RES_ROOT") {
        if !explicit.is_empty() {
            return PathBuf::from(explicit);
        }
    }
    let exe = match env::current_exe() {
        Ok(path) => path,
        Err(_) => return PathBuf::from("/Applications/Mash.app/Contents/Resources"),
    };
    if let Some(bundle) = exe
        .ancestors()
        .find(|path| path.extension().is_some_and(|ext| ext == "app"))
    {
        return bundle.join("Contents/Resources");
    }
    exe.parent()
        .and_then(Path::parent)
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("/Applications/Mash.app/Contents/Resources"))
}

fn apply_steps<B: Backend>(
    plan: &Plan,
    missing: &[&str],
    log_path: &Path,
    terminal: &mut Terminal<B>,
) -> Result<(), String> {
    let mut log = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path)
        .map_err(|e| e.to_string())?;
    let steps = install_steps(plan, missing);
    let mut messages = Vec::new();
    for (index, step) in steps.iter().enumerate() {
        draw_apply(terminal, index, steps.len(), step, &messages);
        let result = if index == 0 {
            let mut report = if missing.is_empty()
                && !(plan.npm.is_empty() && plan.pinned.is_empty() && plan.python.is_empty())
            {
                "Host tools are present; installing Mash's pinned tools.".to_string()
            } else if missing.is_empty() {
                "Everything selected is already installed.".to_string()
            } else {
                format!("Missing: {}", missing.join(", "))
            };
            for tool in &plan.apple {
                if !apple_tool_available(tool) {
                    report.push_str(&format!(
                        " {tool} comes with Apple's developer tools (run xcode-select --install)."
                    ));
                }
            }
            Ok(report)
        } else if step == STEP_LINUX_TOOLS {
            install_mash_tools(terminal, index, steps.len(), step, &messages, &plan.linux)
        } else if step == "Install Homebrew packages" {
            install_brew(&plan.brew)
        } else if step == "Install npm packages" {
            install_mash_tools(terminal, index, steps.len(), step, &messages, &plan.npm)
        } else if step == STEP_PINNED_TOOLS {
            install_mash_tools(terminal, index, steps.len(), step, &messages, &plan.pinned)
        } else if step == "Install CUA Driver" {
            install_cua_driver()
        } else if step == STEP_HINDSIGHT {
            install_helper_with_progress(
                terminal,
                index,
                steps.len(),
                step,
                &messages,
                "mash-hindsight-install",
            )
        } else if step == STEP_HINDSIGHT_DAEMON {
            start_hindsight_daemon(terminal, index, steps.len(), step, &messages)
        } else if step == STEP_VOICE {
            install_voice_model(
                terminal,
                index,
                steps.len(),
                step,
                &messages,
                plan.voice.as_ref().expect("STEP_VOICE follows a choice"),
            )
        } else {
            install_mash_tools(terminal, index, steps.len(), step, &messages, &plan.python)
        };
        // The same collision can surface when only some tools are missing and
        // an installer trips over one that is already present. The step is
        // done once every selected tool is available; otherwise report why.
        // The environment steps are excluded: they have no such excuse, and
        // masking their failure would leave memory quietly absent.
        let environment_step =
            step == STEP_HINDSIGHT || step == STEP_HINDSIGHT_DAEMON || step == STEP_VOICE;
        let message = match result {
            Ok(message) => message,
            Err(_)
                if !environment_step
                    && step != "Install npm packages"
                    && step != "Install Python packages"
                    && step != STEP_PINNED_TOOLS
                    && tools_available(&plan.tools) =>
            {
                "already installed".to_string()
            }
            Err(error) => return Err(error),
        };
        messages.push(format!("  {step}: {message}"));
        let _ = write_log(&mut log, &messages);
    }
    draw_apply(
        terminal,
        steps.len(),
        steps.len(),
        "Ready to launch Mash",
        &messages,
    );
    Ok(())
}

fn write_log(file: &mut fs::File, lines: &[String]) -> io::Result<()> {
    for line in lines {
        writeln!(file, "{line}")?;
    }
    writeln!(file)
}

fn apple_tool_available(tool: &str) -> bool {
    Command::new("xcrun")
        .env("PATH", host_path())
        .args(["--find", tool])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn install_brew(formulae: &[&'static str]) -> Result<String, String> {
    if formulae.is_empty() {
        return Ok("nothing requested".into());
    }
    let brew = find_brew();
    let mut command = Command::new(brew);
    command
        .env("PATH", host_path())
        .env("HOMEBREW_NO_AUTO_UPDATE", "1")
        .arg("install")
        .args(formulae);
    run_logged(command)
}

fn find_brew() -> String {
    for candidate in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
        if fs::metadata(candidate).is_ok() {
            return candidate.to_string();
        }
    }
    "brew".into()
}

// The vendor installer drops CuaDriver.app and its CLI. Accessibility and
// Screen Recording are a human grant on that app at first use; the installer
// must not ask for them, and neither does this.
fn install_cua_driver() -> Result<String, String> {
    let mut command = Command::new("/bin/bash");
    command
        .env("PATH", host_path())
        .env("CUA_DRIVER_RS_VERSION", CUA_DRIVER_PIN)
        .args([
            "-c",
            "eval \"$(curl -fsSL https://cua.ai/driver/install.sh)\"",
        ]);
    run_logged(command)
}

// The machine's own git identity, used to prefill the wizard. GIT_CONFIG_GLOBAL
// is cleared first: a Mash launched from inside another Mash would otherwise
// report Mash's config instead of the machine's, and Mash's is the one being
// filled in.
fn offer_github_login<B: Backend>(terminal: &mut Terminal<B>) -> Result<(), String> {
    if !is_available("gh") || env::var_os("MASH_GH_CONFIG_DIR").is_some() {
        return Ok(());
    }
    let config = data_dir().join("config/gh");
    if config.is_symlink() || config.join("hosts.yml").is_symlink() {
        return Err("GitHub config must stay inside Mash".into());
    }
    fs::create_dir_all(&config).map_err(|e| e.to_string())?;
    fs::set_permissions(&config, fs::Permissions::from_mode(0o700)).map_err(|e| e.to_string())?;
    let already_signed_in = github_command(&config)
        .args(["auth", "status"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success());
    if already_signed_in || github_token(&config).is_some() {
        connect_github_mcp();
        return Ok(());
    }
    let mut note = String::new();
    loop {
        terminal
            .draw(|frame| {
                let body = wizard_style::section(frame, frame.area(), "GitHub (optional)");
                frame.render_widget(
                    Paragraph::new(format!(
                        "Sign into GitHub for Mash?\n\nPress y to open browser sign-in, or Enter / n / Esc to skip.\n\n{note}"
                    ))
                    .alignment(Alignment::Center),
                    body,
                );
            })
            .map_err(|e| e.to_string())?;
        let Event::Key(key) = event::read().map_err(|e| e.to_string())? else {
            continue;
        };
        if key.kind != KeyEventKind::Press {
            continue;
        }
        match key.code {
            KeyCode::Enter | KeyCode::Esc | KeyCode::Char('n') => return Ok(()),
            KeyCode::Char('y') => {
                disable_raw_mode().map_err(|e| e.to_string())?;
                execute!(io::stdout(), LeaveAlternateScreen).map_err(|e| e.to_string())?;
                let result = github_command(&config)
                    .args([
                        "auth",
                        "login",
                        "--web",
                        "--git-protocol",
                        "https",
                        "--insecure-storage",
                    ])
                    .status();
                let _ = execute!(io::stdout(), EnterAlternateScreen);
                enable_raw_mode().map_err(|e| e.to_string())?;
                terminal.clear().map_err(|e| e.to_string())?;
                if result.is_ok_and(|status| status.success()) {
                    connect_github_mcp();
                    return Ok(());
                }
                note = "GitHub sign-in did not complete. Press y to retry or Enter to skip.".into();
            }
            _ => {}
        }
    }
}

// Register GitHub's MCP server now that Mash's gh is signed in, so the first
// session already has it. The helper decides from the sign-in itself and never
// writes the token; every launch runs it too, so a failure here only delays the
// server to the next launch.
fn connect_github_mcp() {
    let helper = mash_resources().join("bin/mash-github-mcp");
    if helper.is_file() {
        let _ = Command::new(&helper)
            .env("PATH", host_path())
            .arg(data_dir())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}

fn github_token(config: &Path) -> Option<String> {
    let text = fs::read_to_string(config.join("hosts.yml")).ok()?;
    for line in text.lines() {
        if let Some(value) = line.trim().strip_prefix("oauth_token:") {
            return Some(value.trim().to_string());
        }
    }
    None
}

fn github_command(config: &Path) -> Command {
    let mut command = Command::new("gh");
    // The wizard runs before mash_isolate. Inherited tokens must not make the
    // Mash account look signed in or leak into the new login flow.
    command
        .env("PATH", host_path())
        .env("GH_CONFIG_DIR", config)
        .env_remove("GH_TOKEN")
        .env_remove("GITHUB_TOKEN")
        .env_remove("GH_ENTERPRISE_TOKEN")
        .env_remove("GH_HOST");
    command
}

fn git_config_value(key: &str) -> String {
    let mut command = Command::new("git");
    command
        .env("PATH", host_path())
        .env_remove("GIT_CONFIG_GLOBAL")
        .args(["config", "--global", "--get", key]);
    match command.output() {
        Ok(output) if output.status.success() => {
            String::from_utf8_lossy(&output.stdout).trim().to_string()
        }
        _ => String::new(),
    }
}

// Written into Mash's own git config, which the launcher seeds once and never
// rewrites. Mash never reads ~/.gitconfig, so both identity and signing must
// be carried into its config for commits made inside Mash.
fn apply_git_identity(identity: &Identity, config: &Path) -> Result<String, String> {
    let name = identity.name.trim();
    let email = identity.email.trim();
    let signing_key = identity.signing_key.trim();
    let signing = (!signing_key.is_empty()).to_string();
    if let Some(parent) = config.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    for (key, value) in [
        ("user.name", name),
        ("user.email", email),
        ("user.signingkey", signing_key),
        ("commit.gpgsign", signing.as_str()),
    ] {
        if value.is_empty() && key != "user.signingkey" {
            continue;
        }
        let mut command = Command::new("git");
        command
            .env("PATH", host_path())
            .env_remove("GIT_CONFIG_GLOBAL")
            .arg("config")
            .arg("--file")
            .arg(config)
            .arg("--replace-all")
            .arg(key)
            .arg(value);
        run_logged(command)?;
    }
    let note = if name.is_empty() && email.is_empty() {
        "none given; commits stay unattributed".to_string()
    } else {
        format!("set to {name} <{email}>")
    };
    Ok(format!("{note}; commit.gpgsign={signing}"))
}

fn run_logged(mut command: Command) -> Result<String, String> {
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    let output = command.output().map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    Ok("complete".into())
}

fn draw_identity(frame: &mut Frame, page: &IdentityPage) {
    let area = wizard_style::page_area(frame, Some(0));
    let chunks = Layout::vertical([
        Constraint::Length(3),
        Constraint::Min(8),
        Constraint::Length(3),
    ])
    .split(area);
    wizard_style::header(
        frame,
        chunks[0],
        &wizard_style::page_title("Git identity", 0),
    );

    let mut lines: Vec<(Line<'static>, Option<usize>)> = vec![
        (Line::from("Git identity for commits made in Mash."), None),
        (Line::from(""), None),
    ];
    for (focus, label, value) in [
        (FOCUS_NAME, "Name       ", &page.name),
        (FOCUS_EMAIL, "Email      ", &page.email),
        (FOCUS_SIGNING_KEY, "Signing key", &page.signing_key),
    ] {
        let focused = page.focus == focus;
        lines.push((
            wizard_style::text_field(focused, label, value.clone()),
            Some(focus),
        ));
        if focused {
            lines.push((
                Line::from(if focus == FOCUS_SIGNING_KEY {
                    "      empty disables commit signing; a key enables it"
                } else {
                    "      type to edit, Backspace to delete, empty to leave commits unattributed"
                }),
                None,
            ));
        }
    }

    let body = wizard_style::section(frame, chunks[1], "Identity");
    wizard_style::render_form(frame, body, lines, true);
    wizard_style::render_buttons(
        frame,
        chunks[2],
        &[(
            wizard_style::button(page.focus == FOCUS_IDENTITY_NEXT, " Next — choose tools "),
            Some(FOCUS_IDENTITY_NEXT),
        )],
    );
}

fn draw_tools(frame: &mut Frame, page: &ToolsPage) {
    let area = wizard_style::page_area(frame, Some(1));
    let chunks = Layout::vertical([
        Constraint::Length(3),
        Constraint::Min(8),
        Constraint::Length(3),
    ])
    .split(area);
    wizard_style::header(frame, chunks[0], &wizard_style::page_title("Tools", 1));

    let mut lines: Vec<(Line<'static>, Option<usize>)> = vec![
        (
            Line::from(
                "Choose tools to install. GitHub sign-in is offered after installation when utilities are selected.",
            ),
            None,
        ),
        (Line::from(""), None),
    ];
    for (index, group) in Group::ALL.iter().enumerate() {
        let focused = page.focus == index;
        let mut line = wizard_style::checkbox(focused, group.title(), page.selections[index]);
        line.spans
            .push(Span::raw(format!(" — {}", group.summary())));
        lines.push((line, Some(index)));
        for (tool, description) in group.tools() {
            lines.push((Line::from(format!("      {tool:<24} {description}")), None));
        }
        lines.push((Line::from(""), None));
    }

    let body = wizard_style::section(frame, chunks[1], "Install choices");
    wizard_style::render_form(frame, body, lines, true);
    wizard_style::render_buttons(
        frame,
        chunks[2],
        &[
            (
                wizard_style::button(page.focus == FOCUS_TOOLS_BACK, " Back "),
                Some(FOCUS_TOOLS_BACK),
            ),
            (Span::raw("    "), None),
            (
                wizard_style::button(
                    page.focus == FOCUS_TOOLS_NEXT,
                    " Next — configure providers ",
                ),
                Some(FOCUS_TOOLS_NEXT),
            ),
        ],
    );
}

fn draw_apply<B: Backend>(
    terminal: &mut Terminal<B>,
    completed: usize,
    total: usize,
    current: &str,
    messages: &[String],
) {
    let _ = terminal.draw(|frame| {
        let area = wizard_style::page_area(frame, None);
        let chunks = Layout::vertical([
            Constraint::Length(3),
            Constraint::Length(3),
            Constraint::Min(5),
        ])
        .split(area);
        wizard_style::header(frame, chunks[0], "Mash installation");
        let ratio = if total == 0 {
            1.0
        } else {
            completed as f64 / total as f64
        };
        let progress = wizard_style::section(frame, chunks[1], current);
        frame.render_widget(
            Gauge::default()
                .gauge_style(Style::default().fg(wizard_style::GREEN))
                .ratio(ratio),
            progress,
        );
        let log = wizard_style::section(frame, chunks[2], "Progress");
        frame.render_widget(
            Paragraph::new(messages.join("\n")).wrap(Wrap { trim: true }),
            log,
        );
    });
}

/// Linux installs all selected tools into Mash's data folder; macOS does so
/// for npm components while keeping Homebrew and pip for other tools.
fn is_linux() -> bool {
    cfg!(target_os = "linux")
}

const STEP_LINUX_TOOLS: &str = "Install tools into Mash";
const STEP_PINNED_TOOLS: &str = "Install pinned tools into Mash";

#[derive(Default)]
struct Plan {
    /// Component names for `mash-tool-install`, Linux only.
    linux: Vec<&'static str>,
    brew: Vec<&'static str>,
    /// npm component names for `mash-tool-install` on macOS.
    npm: Vec<&'static str>,
    /// Pinned release binaries for `mash-tool-install` on macOS.
    pinned: Vec<&'static str>,
    /// pip component names for `mash-tool-install` on macOS.
    python: Vec<&'static str>,
    apple: Vec<&'static str>,
    installer: Vec<&'static str>,
    tools: Vec<&'static str>,
    /// The dictation model to download, from the last wizard page.
    voice: Option<voice::VoiceChoice>,
    programming: bool,
}

fn install_plan(selections: [bool; 2]) -> Plan {
    let mut plan = Plan {
        programming: true,
        ..Plan::default()
    };
    if is_linux() {
        // The same capability groups, installed without elevation. Every
        // component named here is pinned in packaging/assets.json; the helper
        // installs Linux binaries where pinned and reports host-package tools
        // that Mash does not install.
        if selections[0] {
            for &(name, _) in UTILITIES {
                plan.tools.push(name);
                plan.linux.push(name);
            }
        }
        if selections[1] {
            for &(name, _) in FORMATTERS {
                plan.tools.push(name);
                match name {
                    // The manifest names the package, the binary is pylsp.
                    "pylsp" => plan.linux.push("python-lsp-server"),
                    other => plan.linux.push(other),
                }
            }
            for &(component, tools) in EXTRA_FORMATTERS {
                plan.linux.push(component);
                plan.tools.extend(tools.iter().copied());
            }
        }
        return plan;
    }
    if selections[0] {
        // Every utility lands in `tools`, which drives the availability check
        // and the "already installed" report. Only the installer differs.
        for &(name, _) in UTILITIES {
            plan.tools.push(name);
            match name {
                // Pinned release binaries, like Linux: an unversioned formula
                // cannot honour the manifest, and Sentrux's grammars are
                // checksummed beside the binary.
                "sentrux" => plan.pinned.push("sentrux"),
                "agent-browser" => plan.npm.push("agent-browser"),
                "cua-driver" => plan.installer.push(name),
                other => plan.brew.push(other),
            }
        }
    }
    if selections[1] {
        // Only the tools with no pinned macOS artifact stay on Homebrew.
        // prettier is absent for the same reason: the npm step installs it at
        // its pinned version, and a formula alongside it would shadow that.
        plan.brew.extend(["gopls", "shfmt"]);
        plan.pinned
            .extend(["marksman", "texlab", "latexindent", "rust-analyzer"]);
        plan.npm.extend([
            "prettier",
            "prettier-plugin-svelte",
            "bash-language-server",
            "typescript-language-server",
            "yaml-language-server",
            "svelte-language-server",
            "vscode-langservers-extracted",
            "tailwindcss-language-server",
        ]);
        plan.python.push("python-lsp-server");
        plan.apple.extend(["clangd", "sourcekit-lsp"]);
        plan.tools.extend([
            "prettier",
            "shfmt",
            "latexindent",
            "gopls",
            "rust-analyzer",
            "marksman",
            "texlab",
            "pylsp",
            "bash-language-server",
            "typescript-language-server",
            "yaml-language-server",
            "svelteserver",
            "vscode-css-language-server",
            "vscode-json-language-server",
            "vscode-html-language-server",
            "tailwindcss-language-server",
            "clangd",
            "sourcekit-lsp",
        ]);
    }
    plan
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn github_login_uses_only_mash_config_not_inherited_tokens() {
        let command = github_command(Path::new("/tmp/mash/config/gh"));
        let envs: Vec<_> = command.get_envs().collect();
        assert!(envs.iter().any(|(key, value)| *key == "GH_CONFIG_DIR"
            && value.is_some_and(|v| v == "/tmp/mash/config/gh")));
        for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GH_HOST"] {
            assert!(envs
                .iter()
                .any(|(name, value)| *name == key && value.is_none()));
        }
    }

    #[test]
    fn identity_fields_take_letters_that_otherwise_navigate() {
        // q cancels and j/k navigate on the checkbox rows, but all three are
        // valid letters in a name, so a focused field has to take them.
        let mut app = IdentityPage::new();
        app.focus = FOCUS_NAME;
        // Prefilled from the machine, so start from empty to isolate typing.
        app.name.clear();
        for c in ['j', 'k', 'q', '1', ' '] {
            assert!(app.on_key(KeyCode::Char(c), KeyModifiers::NONE).is_none());
        }
        assert_eq!(app.name, "jkq1 ");
        assert_eq!(app.focus, FOCUS_NAME);
    }

    #[test]
    fn identity_is_prefilled_from_the_machines_git_config() {
        let app = IdentityPage::new();
        assert_eq!(app.name, git_config_value("user.name"));
        assert_eq!(app.email, git_config_value("user.email"));
        assert_eq!(app.signing_key, git_config_value("user.signingkey"));
    }

    #[test]
    fn signing_key_controls_commit_signing_in_mash_config() {
        let dir = env::temp_dir().join(format!(
            "mash-wizard-git-{}-{}",
            std::process::id(),
            now_millis()
        ));
        let config = dir.join("git/config");
        let identity = Identity {
            name: "Ada".into(),
            email: "ada@example.org".into(),
            signing_key: "ABC123".into(),
        };
        let get = |key| {
            let output = Command::new("git")
                .args(["config", "--file"])
                .arg(&config)
                .arg("--get")
                .arg(key)
                .output()
                .unwrap();
            assert!(output.status.success());
            String::from_utf8(output.stdout).unwrap().trim().to_string()
        };
        apply_git_identity(&identity, &config).unwrap();
        assert_eq!(get("user.name"), "Ada");
        assert_eq!(get("user.email"), "ada@example.org");
        assert_eq!(get("user.signingkey"), "ABC123");
        assert_eq!(get("commit.gpgsign"), "true");

        apply_git_identity(&Identity::default(), &config).unwrap();
        assert_eq!(get("user.signingkey"), "");
        assert_eq!(get("commit.gpgsign"), "false");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn backspace_edits_only_the_focused_field() {
        let mut app = IdentityPage::new();
        app.focus = FOCUS_EMAIL;
        app.email = "abc".into();
        app.on_key(KeyCode::Backspace, KeyModifiers::NONE);
        assert_eq!(app.email, "ab");
        assert_eq!(app.name, IdentityPage::new().name);
        app.focus = FOCUS_SIGNING_KEY;
        app.signing_key = "ABC".into();
        app.on_key(KeyCode::Backspace, KeyModifiers::NONE);
        assert_eq!(app.signing_key, "AB");
        assert_eq!(app.email, "ab");
    }

    #[test]
    fn tab_visits_every_row_on_each_page_and_wraps() {
        let mut identity = IdentityPage::new();
        let mut seen = vec![identity.focus];
        for _ in 0..IDENTITY_FOCUS_COUNT {
            identity.on_key(KeyCode::Tab, KeyModifiers::NONE);
            seen.push(identity.focus);
        }
        assert_eq!(seen, vec![0, 1, 2, 3, 0]);
        let mut tools = ToolsPage::new();
        let mut seen = vec![tools.focus];
        for _ in 0..TOOLS_FOCUS_COUNT {
            tools.on_key(KeyCode::Tab, KeyModifiers::NONE);
            seen.push(tools.focus);
        }
        assert_eq!(seen, vec![0, 1, 2, 3, 0]);
        tools.on_key(KeyCode::BackTab, KeyModifiers::NONE);
        assert_eq!(tools.focus, FOCUS_TOOLS_NEXT);
    }

    #[test]
    fn space_toggles_only_on_checkbox_rows() {
        let mut app = ToolsPage::new();
        app.focus = FOCUS_GROUP_UTILITIES;
        app.on_key(KeyCode::Char(' '), KeyModifiers::NONE);
        assert!(!app.selections[0]);
        app.focus = FOCUS_TOOLS_NEXT;
        app.on_key(KeyCode::Char(' '), KeyModifiers::NONE);
        assert!(!app.selections[0] && app.selections[1]);
        app.on_key(KeyCode::Char('2'), KeyModifiers::NONE);
        assert!(!app.selections[1]);
        assert_eq!(app.focus, FOCUS_GROUP_FORMATTERS);
    }

    #[test]
    fn enter_moves_between_identity_tools_and_providers() {
        let mut identity = IdentityPage::new();
        identity.focus = FOCUS_EMAIL;
        assert!(matches!(
            identity.on_key(KeyCode::Enter, KeyModifiers::NONE),
            Some(Outcome::Next)
        ));
        identity.focus = FOCUS_IDENTITY_NEXT;
        assert!(matches!(
            identity.on_key(KeyCode::Enter, KeyModifiers::NONE),
            Some(Outcome::Next)
        ));
        let mut tools = ToolsPage::new();
        assert!(tools.on_key(KeyCode::Enter, KeyModifiers::NONE).is_none());
        tools.focus = FOCUS_TOOLS_BACK;
        assert!(matches!(
            tools.on_key(KeyCode::Enter, KeyModifiers::NONE),
            Some(Outcome::Back)
        ));
        tools.focus = FOCUS_TOOLS_NEXT;
        assert!(matches!(
            tools.on_key(KeyCode::Enter, KeyModifiers::NONE),
            Some(Outcome::Next)
        ));
    }

    #[test]
    fn esc_cancels_from_both_pages() {
        let mut identity = IdentityPage::new();
        identity.focus = FOCUS_NAME;
        assert!(matches!(
            identity.on_key(KeyCode::Esc, KeyModifiers::NONE),
            Some(Outcome::Cancel)
        ));
        let mut tools = ToolsPage::new();
        assert!(matches!(
            tools.on_key(KeyCode::Esc, KeyModifiers::NONE),
            Some(Outcome::Cancel)
        ));
    }

    // Esc only asks; the wizard quits on an explicit `y`. Every other key,
    // Esc and Enter included, must keep the user in setup, because a stray
    // Esc used to drop them into an unconfigured Mash.
    #[test]
    fn only_y_confirms_quitting_setup() {
        assert!(confirm_quit_answer(KeyCode::Char('y')));
        assert!(confirm_quit_answer(KeyCode::Char('Y')));
        for key in [
            KeyCode::Esc,
            KeyCode::Enter,
            KeyCode::Char('n'),
            KeyCode::Char('q'),
            KeyCode::Char(' '),
            KeyCode::Backspace,
            KeyCode::Tab,
        ] {
            assert!(!confirm_quit_answer(key), "{key:?} must not quit setup");
        }
    }

    // herdr-pane opens Herdr only on a zero exit. Quitting must never report
    // success, or Mash would open with nothing configured.
    #[test]
    fn quitting_setup_never_reports_success() {
        assert_ne!(EXIT_NOT_DONE, 0);
    }

    #[test]
    fn the_quit_prompt_says_mash_will_not_open() {
        let mut terminal =
            ratatui::Terminal::new(ratatui::backend::TestBackend::new(80, 24)).unwrap();
        terminal.draw(draw_confirm_quit).unwrap();
        let rendered = terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect::<String>();
        assert!(rendered.contains("Quit Mash setup?"));
        assert!(rendered.contains("will not open"));
    }

    #[test]
    fn clicking_identity_and_tools_pages_focuses_toggles_and_navigates() {
        use wizard_style::tests::{click, find};
        let text = |buffer: &ratatui::buffer::Buffer| {
            buffer
                .content()
                .iter()
                .map(|cell| cell.symbol())
                .collect::<String>()
        };
        let target = |buffer: &ratatui::buffer::Buffer, label| {
            let (x, y) = find(buffer, label);
            wizard_style::clicked(&click(x, y)).expect("label is clickable")
        };
        let mut identity = IdentityPage::new();
        let render_identity = |page: &IdentityPage| {
            let mut terminal = Terminal::new(ratatui::backend::TestBackend::new(140, 60)).unwrap();
            terminal.draw(|frame| draw_identity(frame, page)).unwrap();
            terminal.backend().buffer().clone()
        };
        let buffer = render_identity(&identity);
        assert!(!text(&buffer).contains("Mash utilities"));
        assert!(identity.on_click(target(&buffer, "Email")).is_none());
        assert_eq!(identity.focus, FOCUS_EMAIL);
        assert!(matches!(
            identity.on_click(target(&render_identity(&identity), "Next — choose tools")),
            Some(Outcome::Next)
        ));

        let mut tools = ToolsPage::new();
        let render_tools = |page: &ToolsPage| {
            let mut terminal = Terminal::new(ratatui::backend::TestBackend::new(140, 60)).unwrap();
            terminal.draw(|frame| draw_tools(frame, page)).unwrap();
            terminal.backend().buffer().clone()
        };
        let buffer = render_tools(&tools);
        assert!(!text(&buffer).contains("Signing key"));
        assert!(tools.on_click(target(&buffer, "Mash utilities")).is_none());
        assert!(!tools.selections[0]);
        assert!(matches!(
            tools.on_click(target(&render_tools(&tools), "Back")),
            Some(Outcome::Back)
        ));
        assert!(matches!(
            tools.on_click(target(&render_tools(&tools), "Next — configure")),
            Some(Outcome::Next)
        ));
    }

    #[test]
    fn model_check_is_readable_and_acknowledged_at_compact_sizes() {
        for (width, height) in [(80, 24), (100, 30)] {
            let mut terminal =
                ratatui::Terminal::new(ratatui::backend::TestBackend::new(width, height)).unwrap();
            terminal
                .draw(|frame| {
                    draw_model_check(
                        frame,
                        &["No configured credentials for the saved provider.".into()],
                        false,
                    )
                })
                .unwrap();
            wizard_style::tests::find(terminal.backend().buffer(), "Continue");
            wizard_style::tests::find(terminal.backend().buffer(), "No configured credentials");
        }
        let event = Event::Key(event::KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE));
        assert!(acknowledges_model_check(&event));
        let event = Event::Key(event::KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE));
        assert!(!acknowledges_model_check(&event));
    }

    #[test]
    fn preview_only_changes_pages_and_returns_to_the_logo() {
        let mut started = true;
        let mut page = 0;
        assert!(!preview_key(
            &mut started,
            &mut page,
            KeyCode::Right,
            KeyModifiers::NONE
        ));
        assert_eq!(page, 1);
        assert!(!preview_key(
            &mut started,
            &mut page,
            KeyCode::Char('4'),
            KeyModifiers::NONE,
        ));
        assert_eq!(page, 3);
        assert!(!preview_key(
            &mut started,
            &mut page,
            KeyCode::Char('5'),
            KeyModifiers::NONE,
        ));
        assert_eq!(page, 4);
        assert!(!preview_key(
            &mut started,
            &mut page,
            KeyCode::Esc,
            KeyModifiers::NONE
        ));
        assert!(!started);
        assert_eq!(page, 0);
        assert!(preview_key(
            &mut started,
            &mut page,
            KeyCode::Esc,
            KeyModifiers::NONE
        ));
    }

    #[test]
    fn completing_setup_leaves_a_one_shot_workspace_popup_marker() {
        let dir = env::temp_dir().join(format!("mash-complete-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let mut state = State::default();
        mark_complete(&dir, &mut state);
        assert!(load_state(&dir).completed);
        assert!(dir.join(OPEN_WORKSPACE_MARKER).is_file());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_unchecked_suite_adds_no_hindsight_install_steps() {
        let mut plan = install_plan([false, false]);
        plan.programming = false;
        let steps = install_steps(&plan, &[]);
        assert!(!steps
            .iter()
            .any(|step| [STEP_HINDSIGHT, STEP_HINDSIGHT_DAEMON].contains(&step.as_str())));
        plan.programming = true;
        assert!(install_steps(&plan, &[]).contains(&STEP_HINDSIGHT.to_string()));
    }

    #[test]
    fn first_page_uses_sidebar_and_panel_palette() {
        let app = IdentityPage {
            name: "Ada".into(),
            email: "ada@example.org".into(),
            signing_key: String::new(),
            focus: FOCUS_NAME,
        };
        let mut terminal =
            ratatui::Terminal::new(ratatui::backend::TestBackend::new(120, 40)).unwrap();
        terminal.draw(|frame| draw_identity(frame, &app)).unwrap();
        let buffer = terminal.backend().buffer();
        let rendered = buffer
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect::<String>();
        assert!(rendered.contains("Git identity — page 1/7"));
        assert!(rendered.contains("Tools"));
        assert!(rendered.contains("Model provider"));
        assert!(rendered.contains("ada@example.org"));
        // Sidebar: logo rows 1-10, SETUP, blank, then page 1 on row 13.
        assert_eq!(buffer[(0, 13)].bg, wizard_style::PANEL);
        assert_eq!(buffer[(3, 13)].bg, wizard_style::selected().bg.unwrap());
        assert_eq!(buffer[(40, 5)].bg, wizard_style::PANEL);
    }

    #[test]
    fn selection_maps_only_the_checkbox_rows() {
        let mut app = ToolsPage::new();
        app.focus = FOCUS_GROUP_UTILITIES;
        assert_eq!(app.selection(), Some(0));
        app.focus = FOCUS_GROUP_FORMATTERS;
        assert_eq!(app.selection(), Some(1));
        app.focus = FOCUS_TOOLS_BACK;
        assert_eq!(app.selection(), None);
        app.focus = FOCUS_TOOLS_NEXT;
        assert_eq!(app.selection(), None);
    }

    #[test]
    fn github_existing_token_skips_login() {
        let root = env::temp_dir().join(format!("mash-github-test-{}", std::process::id()));
        let config = root.join("config/gh");
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&config).unwrap();
        fs::write(
            config.join("hosts.yml"),
            "github.com:\n  oauth_token: fake-token\n",
        )
        .unwrap();
        assert!(github_token(&config).as_deref() == Some("fake-token"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn fixed_startup_choices_are_dev_layout_and_medium_thinking() {
        let settings: serde_json::Value =
            serde_json::from_str(include_str!("../defaults/pi/settings.json")).unwrap();
        assert_eq!(settings["defaultThinkingLevel"], "medium");
        assert!(
            include_str!("../defaults/plugins/herdr-workspace/config.yaml")
                .contains("profiles:\n  - id: dev")
        );
    }

    #[test]
    fn environment_steps_always_run() {
        // Not optional, and not gated on the tool selections: no one opts into
        // having memory available.
        let plan = install_plan([false, false]);
        let steps = install_steps(&plan, &[]);
        assert!(steps.contains(&STEP_HINDSIGHT.to_string()));
        assert_eq!(steps.last().unwrap(), STEP_HINDSIGHT_DAEMON);
        // Tools install before the environment steps that may use them. The
        // step is Homebrew on macOS and Mash's own installer on Linux.
        let full = install_steps(&install_plan([true, true]), &["gopls"]);
        let hindsight = full.iter().position(|s| s == STEP_HINDSIGHT).unwrap();
        let tool_step = if is_linux() {
            STEP_LINUX_TOOLS
        } else {
            "Install Homebrew packages"
        };
        let tools = full.iter().position(|s| s == tool_step).unwrap();
        assert!(tools < hindsight, "tools must install first");
    }

    #[test]
    fn hindsight_port_parses_the_seeded_config() {
        // The step must read the port from the config Mash seeds rather than
        // assuming it, or it would poll the owner's own daemon.
        let tmp = env::temp_dir().join(format!("mash-port-{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(tmp.join(".hindsight")).unwrap();
        fs::write(
            tmp.join(".hindsight/embed"),
            "HINDSIGHT_EMBED_BANK_ID=default\nHINDSIGHT_API_PORT=8998\n",
        )
        .unwrap();
        let text = fs::read_to_string(tmp.join(".hindsight/embed")).unwrap();
        let port: u16 = text
            .lines()
            .find_map(|line| line.strip_prefix("HINDSIGHT_API_PORT="))
            .and_then(|value| value.trim().parse().ok())
            .unwrap();
        assert_eq!(port, 8998);
        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn helper_logs_match_their_scripts() {
        assert!(helper_log_path("mash-hindsight-install")
            .to_string_lossy()
            .ends_with("setup/hindsight-install.log"));
    }

    #[test]
    fn resource_root_follows_the_binary_not_a_bundle() {
        // Under `cargo test` the executable is target/debug/deps/mash-wizard-*,
        // so there is no bundle and no <root>/bin layout: the function must fall
        // back instead of inventing a path from the test binary's ancestors.
        let root = mash_resources();
        assert!(!root.as_os_str().is_empty());
        assert!(root.is_absolute());
    }

    #[test]
    fn explicit_resource_root_wins() {
        // The launcher exports MASH_RES_ROOT, and the wizard must agree with the
        // panes about where the payload lives rather than re-deriving it.
        let previous = env::var_os("MASH_RES_ROOT");
        // SAFETY: this test is the only writer of this variable in this process.
        unsafe { env::set_var("MASH_RES_ROOT", "/opt/letsmash") };
        assert_eq!(mash_resources(), PathBuf::from("/opt/letsmash"));
        assert_eq!(mash_bin(), PathBuf::from("/opt/letsmash/bin"));
        match previous {
            Some(value) => unsafe { env::set_var("MASH_RES_ROOT", value) },
            None => unsafe { env::remove_var("MASH_RES_ROOT") },
        }
    }

    // macOS installer routing: Linux installs every tool through plan.linux,
    // which the_plan_matches_the_platform asserts.
    #[cfg(target_os = "macos")]
    #[test]
    fn default_plan_covers_requested_tools() {
        let plan = install_plan([true, true]);
        assert!(plan.tools.contains(&"git"));
        assert!(plan.tools.contains(&"prettier"));
        assert!(plan.tools.contains(&"clangd"));
    }

    #[test]
    fn the_plan_matches_the_platform() {
        // The two plans must not mix: Linux resolves pinned components through
        // its own helper, macOS uses the package manager. A laptop running the
        // macOS suite asserts the macOS side, and the Linux lane in CI asserts
        // the other, so neither can quietly take the wrong branch.
        let plan = install_plan([true, true]);
        if is_linux() {
            assert!(!plan.linux.is_empty(), "linux plan has no components");
            assert!(plan.brew.is_empty(), "linux plan reached for brew");
            assert!(plan.npm.is_empty(), "linux plan reached for global npm");
            assert!(plan.python.is_empty(), "linux plan reached for global pip");
            assert!(
                plan.installer.is_empty(),
                "linux plan used a vendor installer"
            );
        } else {
            assert!(plan.linux.is_empty(), "macOS plan carries Linux components");
            assert!(!plan.brew.is_empty(), "macOS plan has no formulas");
        }
    }

    #[test]
    fn no_selection_creates_empty_plan() {
        let plan = install_plan([false, false]);
        assert!(plan.brew.is_empty());
        assert!(plan.npm.is_empty());
        assert!(plan.python.is_empty());
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_utilities_install_sentrux_without_swift() {
        let plan = install_plan([true, false]);
        assert!(plan.linux.contains(&"sentrux"));
        assert!(!plan.linux.contains(&"sourcekit-lsp"));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_formatters_use_pinned_components_and_keep_binary_names() {
        let plan = install_plan([false, true]);

        // Every name handed to mash-tool-install must resolve in assets.py.
        // pylsp's component is named after the Python package.
        for component in [
            "python-lsp-server",
            "typescript-language-server",
            "yaml-language-server",
            "svelte-language-server",
            "vscode-langservers-extracted",
            "tailwindcss-language-server",
        ] {
            assert!(
                plan.linux.contains(&component),
                "{component} missing from plan.linux"
            );
        }
        assert!(!plan.linux.contains(&"pylsp"));
        for component in ["latexindent", "marksman", "texlab"] {
            assert!(
                plan.linux.contains(&component),
                "{component} missing from plan.linux"
            );
        }
        assert!(!plan.linux.contains(&"sourcekit-lsp"));

        // The availability check still speaks in binary names: `pylsp` and
        // `svelteserver` are what Fresh and the panes run.
        for tool in [
            "pylsp",
            "svelteserver",
            "latexindent",
            "vscode-css-language-server",
            "vscode-json-language-server",
            "vscode-html-language-server",
        ] {
            assert!(plan.tools.contains(&tool), "{tool} missing from plan.tools");
        }
    }

    // macOS installer routing: Linux installs every tool through plan.linux,
    // which the_plan_matches_the_platform asserts.
    #[cfg(target_os = "macos")]
    #[test]
    fn automation_tools_route_to_their_own_installers() {
        // Sentrux is a tapped formula, agent-browser is npm, CUA Driver has a
        // vendor installer. Feeding all three to `brew install` would fail.
        let plan = install_plan([true, true]);
        for tool in ["sentrux", "agent-browser", "cua-driver"] {
            assert!(
                plan.tools.contains(&tool),
                "{tool} missing from the check list"
            );
        }
        assert!(plan.pinned.contains(&"sentrux"));
        assert!(!plan.brew.contains(&"sentrux"));
        assert!(plan.npm.contains(&"agent-browser"));
        assert_eq!(plan.installer, vec!["cua-driver"]);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn package_groups_name_manifest_components_not_specs() {
        // The Mash helper takes component names; a version here would fail
        // to resolve against the bundled manifest.
        let plan = install_plan([true, true]);
        for component in &plan.npm {
            assert!(
                !component.contains('@'),
                "{component} is a package spec, not a manifest component"
            );
        }
        for component in &plan.python {
            assert!(
                !component.contains('=') && !component.contains('@'),
                "{component} is a package spec, not a manifest component"
            );
        }
        // prettier is installed by the npm step at its pinned version; a formula
        // beside it would put an unpinned copy earlier on PATH.
        assert!(!plan.brew.contains(&"prettier"));
        assert!(plan.npm.contains(&"prettier"));
    }

    // Every tool with a pinned macOS artifact must come from Mash's installer,
    // or the manifest version is not what lands on the machine.
    #[cfg(target_os = "macos")]
    #[test]
    fn tools_with_a_macos_artifact_are_not_brewed() {
        let plan = install_plan([true, true]);
        for component in [
            "sentrux",
            "marksman",
            "texlab",
            "latexindent",
            "rust-analyzer",
        ] {
            assert!(
                plan.pinned.contains(&component),
                "{component} missing from the pinned plan"
            );
            assert!(
                !plan.brew.iter().any(|formula| formula.contains(component)),
                "{component} is still installed through Homebrew"
            );
            assert!(
                plan.tools.contains(&component),
                "{component} missing from the check list"
            );
        }
        // The formulae that remain have no pinned macOS artifact to use.
        assert_eq!(plan.brew.iter().filter(|f| f.contains("texlab")).count(), 0);
        assert!(plan.brew.contains(&"gopls"));
    }

    // macOS installer routing: Linux installs every tool through plan.linux,
    // which the_plan_matches_the_platform asserts.
    #[cfg(target_os = "macos")]
    #[test]
    fn cua_driver_installs_only_when_missing() {
        let plan = install_plan([true, true]);
        assert!(!install_steps(&plan, &[])
            .iter()
            .any(|s| s == "Install CUA Driver"));
        assert!(install_steps(&plan, &["cua-driver"])
            .iter()
            .any(|s| s == "Install CUA Driver"));
    }

    #[test]
    fn python_packages_install_even_when_host_tools_are_present() {
        let plan = Plan {
            python: vec!["python-lsp-server"],
            tools: vec!["pylsp"],
            ..Plan::default()
        };
        assert_eq!(
            install_steps(&plan, &[]),
            vec!["Check selected tools", "Install Python packages"]
        );
    }

    #[test]
    fn nothing_missing_skips_host_installers() {
        // Host-installed tools need no retry. Host binaries cannot satisfy
        // Mash-owned npm or Python components on macOS.
        let plan = install_plan([true, true]);
        let steps = install_steps(&plan, &[]);
        assert!(!steps.iter().any(|s| s == "Install Homebrew packages"));
        assert!(!steps.iter().any(|s| s == "Install CUA Driver"));
        assert!(!steps.iter().any(|s| s == STEP_VOICE));
        if is_linux() {
            assert!(!steps.iter().any(|s| s == "Install npm packages"));
            assert!(!steps.iter().any(|s| s == "Install Python packages"));
        } else {
            assert!(steps.iter().any(|s| s == "Install npm packages"));
            assert!(steps.iter().any(|s| s == "Install Python packages"));
        }
        assert_eq!(
            steps.first().map(String::as_str),
            Some("Check selected tools")
        );
        assert_eq!(
            steps.last().map(String::as_str),
            Some(STEP_HINDSIGHT_DAEMON)
        );
    }

    // macOS installer routing: Linux installs every tool through plan.linux,
    // which the_plan_matches_the_platform asserts.
    #[cfg(target_os = "macos")]
    #[test]
    fn missing_tools_add_installers() {
        let plan = install_plan([true, true]);
        let steps = install_steps(&plan, &["gopls"]);
        assert!(steps.iter().any(|step| step == "Install npm packages"));
        assert!(steps.iter().any(|step| step == "Install Homebrew packages"));
    }

    #[test]
    fn a_chosen_dictation_model_reaches_installation() {
        // The choice was collected for this long before it installed anything.
        let mut plan = install_plan([false, false]);
        assert!(!install_steps(&plan, &[]).iter().any(|s| s == STEP_VOICE));
        plan.voice = Some(voice::VoiceChoice {
            model_id: "parakeet-unified-en-0.6b".into(),
            languages: vec!["en".into()],
            needs_detector: false,
        });
        let steps = install_steps(&plan, &[]);
        assert_eq!(steps.last().map(String::as_str), Some(STEP_VOICE));
    }
}
