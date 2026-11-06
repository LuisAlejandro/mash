mod font_page;
mod github_login;
mod i18n;
mod language_page;
mod model_picker;
mod pi_connection;
mod pi_models;
mod pi_providers;
mod provider_page;
#[cfg(test)]
mod test_support;
mod theme;
mod tools_page;
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
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

// CUA Driver's installer takes its version from the environment; every other
// tool names manifest components resolved by packaging/assets.json.
const CUA_DRIVER_PIN: &str = "0.33.3";

struct IdentityPage {
    name: String,
    email: String,
    signing_key: String,
    /// Why a host signing key was not prefilled, drawn as the field's help.
    /// Recorded here and translated when the page is drawn, so the explanation
    /// follows the language chosen on the wizard's first page.
    signing_note: Option<SigningNote>,
    github: github_login::GithubLogin,
    focus: usize,
}

const FOCUS_NAME: usize = 0;
const FOCUS_EMAIL: usize = 1;
const FOCUS_SIGNING_KEY: usize = 2;
const FOCUS_GITHUB: usize = 3;
const FOCUS_IDENTITY_NEXT: usize = 4;
const IDENTITY_FOCUS_COUNT: usize = 5;

#[derive(Default, Clone)]
struct Identity {
    name: String,
    email: String,
    signing_key: String,
}

impl IdentityPage {
    fn new(github: github_login::GithubLogin) -> Self {
        let host = prefill_identity(
            host_identity(&host_home()),
            &data_dir().join("config/git/config"),
        );
        Self {
            name: host.name,
            email: host.email,
            signing_key: host.signing_key,
            signing_note: host.signing_note,
            github,
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

    /// A click focuses the row; the GitHub button acts and Next advances.
    fn on_click(&mut self, focus: usize) -> Option<Outcome> {
        self.focus = focus;
        if focus == FOCUS_GITHUB {
            self.github.activate();
        }
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
        if self.focus <= FOCUS_SIGNING_KEY {
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
            KeyCode::Enter | KeyCode::Char(' ') if self.focus == FOCUS_GITHUB => {
                self.github.activate();
                None
            }
            KeyCode::Enter => Some(Outcome::Next),
            _ => None,
        }
    }
}

// Mash's pinned gh, from the bundle. A development build without one falls
// back to the host's, and the page reports when there is none at all.
fn github_login(preview: bool) -> github_login::GithubLogin {
    let bundled = mash_resources().join("bin/gh");
    let gh = if bundled.is_file() {
        bundled
    } else {
        PathBuf::from("gh")
    };
    let path = if env::var_os("MASH_GH_CONFIG_DIR").is_some() {
        // Sign-in is managed outside the wizard; an empty PATH reports it.
        OsString::new()
    } else {
        bundled_path()
    };
    github_login::GithubLogin::new(gh, data_dir().join("config/gh"), path, preview)
}

/// Host PATH with the bundle's own bin first, so the pinned gh resolves.
fn bundled_path() -> OsString {
    let mut dirs = vec![mash_resources().join("bin")];
    dirs.extend(env::split_paths(&host_path()));
    env::join_paths(dirs).unwrap_or_else(|_| host_path())
}

enum Outcome {
    Next,
    Cancel,
}

fn main() {
    match run() {
        Ok(outcome) => std::process::exit(outcome),
        Err(error) => {
            eprintln!("{}: {error}", i18n::t("wizard.setup.title"));
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
    let mut language = language_page::LanguagePage::new();
    let mut language_chosen = false;
    let mut identity = IdentityPage::new(github_login(preview));
    let mut tools = tools_page::ToolsPage::new();
    let mut providers = provider_page::ProviderPage::new();
    if preview {
        providers.load_preview_defaults();
    } else {
        providers.load_existing_auth(&data_dir().join("pi/agent"));
    }
    let mut fonts =
        font_page::FontPage::new(&mash_resources(), &data_dir().join("config/ghostty/config"));
    fonts.theme = theme::Theme::current(&data_dir());
    fonts.keybindings = font_page::Keybindings::current(&data_dir());
    // The wizard runs directly in Mash's terminal, which names itself here, so
    // font choices can be shown in this window. A preview writes nothing.
    if let Some(terminal) = (!preview)
        .then(|| env::var("MASH_TERMINAL_PID").ok()?.parse::<u32>().ok())
        .flatten()
    {
        fonts.start_live_preview(&data_dir().join("config/ghostty/config"), terminal);
    }
    let mut voice = voice_page::VoicePage::new();
    let mut page = 0;
    let mut started = false;
    let mut start_button = Rect::default();
    loop {
        identity.github.poll();
        fonts.poll_live_preview();
        // The Appearance page's theme choice recolours the wizard at once.
        wizard_style::set_light(fonts.theme == theme::Theme::Light);
        providers.set_memory_enabled(tools.programming());
        providers.set_page(match page {
            3 => provider_page::Page::WebSearch,
            4 => provider_page::Page::Hindsight,
            _ => provider_page::Page::Model,
        });
        if matches!(page, 2..=4) {
            providers.service_connection(&mash_resources(), &data_dir().join("pi/agent"), preview);
            if !preview {
                providers.poll_models();
            }
        }
        terminal
            .draw(|frame| {
                if !language_chosen {
                    language.draw(frame);
                } else if started {
                    match page {
                        0 => draw_identity(frame, &identity),
                        1 => tools.draw(frame),
                        2..=4 => providers.draw(frame),
                        5 => fonts.draw(frame),
                        _ => voice.draw(frame),
                    }
                } else {
                    start_button = welcome_page::draw(frame);
                }
                if preview && started {
                    wizard_style::preview_hint(frame);
                }
                wizard_style::finish(frame);
            })
            .map_err(|e| e.to_string())?;
        if (providers.is_loading()
            || providers.connection_busy()
            || identity.github.busy()
            || fonts.live_preview_pending())
            && !event::poll(Duration::from_millis(50)).map_err(|e| e.to_string())?
        {
            continue;
        }
        let event = event::read().map_err(|e| e.to_string())?;
        if !language_chosen {
            let decision = if let Some(id) = wizard_style::clicked(&event) {
                language.on_click(id)
            } else if let Some(direction) = wizard_style::wheel(&event) {
                language.on_key(
                    if direction < 0 {
                        KeyCode::Up
                    } else {
                        KeyCode::Down
                    },
                    KeyModifiers::NONE,
                )
            } else if let Event::Key(key) = event {
                if key.kind == KeyEventKind::Press {
                    language.on_key(key.code, key.modifiers)
                } else {
                    None
                }
            } else {
                None
            };
            match decision {
                Some(language_page::Decision::Continue) => {
                    language_chosen = true;
                    voice = voice_page::VoicePage::new();
                }
                Some(language_page::Decision::Cancel) if preview || confirm_quit(terminal)? => {
                    return Ok(EXIT_NOT_DONE);
                }
                _ => {}
            }
            continue;
        }
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
        if matches!(page, 2..=4)
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
                    1 => tools.on_click(id).map(|d| {
                        if matches!(d, tools_page::Decision::Back) {
                            -1
                        } else {
                            1
                        }
                    }),
                    2..=4 => providers.on_click(id).map(|d| {
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
            } else if page == 1 && wizard_style::wheel(&event).is_some() {
                let code = if wizard_style::wheel(&event) == Some(-1) {
                    KeyCode::Up
                } else {
                    KeyCode::Down
                };
                let _ = tools.on_key(code, KeyModifiers::NONE);
            } else if matches!(page, 2..=4)
                && (providers.menu_open() || providers.browsing_providers())
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
                    if page == 1
                        && matches!(
                            key.code,
                            KeyCode::Up
                                | KeyCode::Down
                                | KeyCode::Tab
                                | KeyCode::BackTab
                                | KeyCode::Enter
                                | KeyCode::Char(' ')
                                | KeyCode::Char('j' | 'k')
                        )
                    {
                        match tools.on_key(key.code, key.modifiers) {
                            Some(tools_page::Decision::Back) => page = 0,
                            Some(tools_page::Decision::Next) => page = 2,
                            _ => {}
                        }
                    } else if matches!(page, 2..=4)
                        && (providers.menu_open()
                            || providers.browsing_providers()
                                && matches!(
                                    key.code,
                                    KeyCode::Up
                                        | KeyCode::Down
                                        | KeyCode::Home
                                        | KeyCode::End
                                        | KeyCode::PageUp
                                        | KeyCode::PageDown
                                )
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
            0 => match if let Some(id) = click {
                identity.on_click(id)
            } else {
                identity.on_key(code, modifiers)
            } {
                Some(Outcome::Cancel) => {
                    if confirm_quit(terminal)? {
                        return Ok(EXIT_NOT_DONE);
                    }
                }
                Some(Outcome::Next) => page = 1,
                None => {}
            },
            1 => match if let Some(id) = click {
                tools.on_click(id)
            } else {
                tools.on_key(code, modifiers)
            } {
                Some(tools_page::Decision::Cancel) => {
                    if confirm_quit(terminal)? {
                        return Ok(EXIT_NOT_DONE);
                    }
                }
                Some(tools_page::Decision::Back) => page = 0,
                Some(tools_page::Decision::Next) => page = 2,
                None => {}
            },
            2..=4 => match if let Some(id) = click {
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
                Some(voice_page::Decision::Save) if voice.validate() => break,
                _ => {}
            },
        }
    }

    let mut plan = install_plan(&tools.chosen());
    plan.voice = voice.choice();
    plan.programming = tools.programming();
    let git_identity = identity.identity();
    match review_and_apply(
        terminal,
        &plan,
        &git_identity,
        &mut fonts,
        &tools,
        &mut providers,
    ) {
        Ok(()) => {
            // Pi's MCP config is only written once setup has been applied.
            identity.github.poll();
            if identity.github.signed_in() {
                connect_github_mcp();
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
            .draw(|frame| {
                draw_confirm_quit(frame);
                wizard_style::finish(frame);
            })
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
            i18n::t("wizard.setup.quit_title"),
            Style::default().add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
        Line::from(i18n::t("wizard.setup.not_finished")),
        Line::from(i18n::t("wizard.setup.reopen")),
        Line::from(""),
        Line::from(vec![
            Span::styled(
                "y",
                Style::default()
                    .fg(wizard_style::YELLOW)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw(format!(" {}    ", i18n::t("wizard.setup.quit_action"))),
            Span::styled(
                i18n::t("wizard.setup.other_key"),
                Style::default()
                    .fg(wizard_style::YELLOW)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw(format!(" {}", i18n::t("wizard.setup.keep_going"))),
        ]),
    ];
    let area = frame.area();
    let [_, middle, _] = Layout::vertical([
        Constraint::Fill(1),
        Constraint::Length(text.len() as u16 + 2),
        Constraint::Fill(1),
    ])
    .areas(area);
    let body = wizard_style::section(frame, middle, &i18n::t("wizard.setup.title"));
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
    fonts: &mut font_page::FontPage,
    tools: &tools_page::ToolsPage,
    providers: &mut provider_page::ProviderPage,
) -> Result<(), ApplyError> {
    let state_dir = state_dir();
    let mut state = load_state(&state_dir);
    let log_path = state_dir.join("setup.log");
    let result = apply_choices(terminal, plan, identity, fonts, tools, providers, &log_path);
    if let Err(error) = result {
        state.error = error;
        save_state(&state_dir, &state);
        if let Ok(mut log) = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_path)
        {
            let _ = writeln!(log, "Setup could not finish: {}", state.error);
        }
        // Herdr opens next and would cover a stderr line, so say it here.
        show_setup_failure(terminal, &state.error, &log_path);
        return Err(ApplyError::Failed(state.error));
    }
    mark_complete(&state_dir, &mut state);
    Ok(())
}

/// The terminal-free half of setup: every step that must happen before the
/// installers, in the order the first launch depends on. Separated from
/// `apply_choices` so a test can drive the shipped sequence against a scratch
/// data folder instead of re-performing the steps itself.
fn prepare_setup(
    fonts: &mut font_page::FontPage,
    tools: &tools_page::ToolsPage,
    providers: &provider_page::ProviderPage,
    root: &Path,
    resources: &Path,
) -> Result<(), String> {
    // Retire first: a live preview edits the seeded config, and reconciliation
    // would read that edit as the user's own and keep the old keymap.
    fonts.retire_live_preview()?;
    // The keybinding mode comes first: the seed sync below renders Fresh's
    // map for it, and the launcher opens Mash right after this returns.
    fonts.save_mode(root)?;
    tools.save_selection(root)?;
    language_page::LanguagePage::save_selection(root, i18n::language())?;
    seed_selected_skills(resources, root)?;
    providers.save_with_runtime(root, resources)
}

fn apply_choices<B: Backend>(
    terminal: &mut Terminal<B>,
    plan: &Plan,
    identity: &Identity,
    fonts: &mut font_page::FontPage,
    tools: &tools_page::ToolsPage,
    providers: &mut provider_page::ProviderPage,
    log_path: &Path,
) -> Result<(), String> {
    // The seeded terminal config goes back before reconciliation reads it;
    // fonts.save layers the chosen appearance over the result at the end.
    prepare_setup(fonts, tools, providers, &data_dir(), &mash_resources())?;
    check_saved_model(terminal, providers.login_later_hint());
    let missing: Vec<&str> = plan
        .tools
        .iter()
        .copied()
        .filter(|name| !is_available(name))
        .collect();
    apply_steps(plan, &missing, log_path, terminal)?;
    // After the installers, so `git` exists by the time this runs on a fresh
    // machine.
    let note = apply_git_identity(identity, &data_dir().join("config/git/config"))?;
    if let Ok(mut log) = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path)
    {
        let _ = writeln!(log, "  Git identity: {note}");
    }
    fonts.save(&data_dir().join("config/ghostty/config"))?;
    fonts.theme.apply(&data_dir())
}

/// Blocks on the error until a key or click, like the saved-model check.
fn show_setup_failure<B: Backend>(terminal: &mut Terminal<B>, error: &str, log: &Path) {
    let lines = setup_failure_lines(error, log);
    wait_for_acknowledgement(terminal, |frame| draw_setup_failure(frame, &lines));
}

/// Draws a blocking screen until the person acknowledges it or the terminal
/// gives up. Both the model check and the setup-failure screen use it.
fn wait_for_acknowledgement<B: Backend>(terminal: &mut Terminal<B>, draw: impl Fn(&mut Frame)) {
    loop {
        if terminal
            .draw(|frame| {
                draw(frame);
                wizard_style::finish(frame);
            })
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

fn setup_failure_lines(error: &str, log: &Path) -> Vec<String> {
    let error = if error.trim().is_empty() {
        i18n::t("wizard.setup.unknown_error")
    } else {
        error.trim().to_string()
    };
    vec![
        // Keep the cause readable without letting a long installer error push
        // the log path and continuation button off screen. The log keeps all.
        error
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .chars()
            .take(400)
            .collect(),
        String::new(),
        i18n::fill(
            &i18n::t("wizard.setup.details"),
            &[("path", &&log.display().to_string())],
        ),
        i18n::t("wizard.setup.saved_reopen"),
    ]
}

fn draw_setup_failure(frame: &mut Frame, lines: &[String]) {
    let mut text = vec![
        Line::from(Span::styled(
            i18n::t("wizard.setup.could_not_finish"),
            Style::default().add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
    ];
    text.extend(lines.iter().map(|line| Line::from(line.clone())));
    text.push(Line::from(""));
    text.push(Line::from(Span::styled(
        i18n::t("wizard.setup.press_enter"),
        Style::default().fg(wizard_style::YELLOW),
    )));
    let parts = Layout::vertical([Constraint::Min(4), Constraint::Length(3)]).split(frame.area());
    let body = wizard_style::section(frame, parts[0], &i18n::t("wizard.setup.title"));
    frame.render_widget(
        Paragraph::new(text).wrap(Wrap { trim: false }).style(
            Style::default()
                .fg(wizard_style::TEXT)
                .bg(wizard_style::PANEL),
        ),
        body,
    );
    wizard_style::render_buttons(
        frame,
        parts[1],
        &[(
            wizard_style::button(
                true,
                &format!(" {} ", i18n::t("wizard.setup.continue_open")),
            ),
            Some(0),
        )],
    );
}

/// Diagnostic failures are notes, never setup failures or early completion.
/// Deferred sign-in skips credential inspection and shows the chosen next step.
fn check_saved_model<B: Backend>(terminal: &mut Terminal<B>, deferred_login: Option<String>) {
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
    let mut job = if deferred_login.is_none() {
        let request = serde_json::json!({"version":1,"action":"verify","agentDir":agent});
        pi_models::Job::start(&mash_resources(), request).ok()
    } else {
        None
    };
    let unavailable = || i18n::t("wizard.setup.model_unavailable");
    let notes = if let Some(hint) = deferred_login {
        vec![i18n::t("wizard.setup.auth_skipped"), hint]
    } else if let Some(job) = job.as_mut() {
        loop {
            if let Some(result) = job.poll() {
                break result
                    .map(|report| report.warnings())
                    .unwrap_or_else(|_| vec![unavailable()]);
            }
            if terminal
                .draw(|frame| {
                    draw_model_check(frame, &[], true);
                    wizard_style::finish(frame);
                })
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
        vec![unavailable()]
    };
    drop(job);
    if notes.is_empty() {
        return;
    }
    wait_for_acknowledgement(terminal, |frame| draw_model_check(frame, &notes, false));
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
    wizard_style::header(frame, parts[0], &i18n::t("wizard.setup.model_check"));
    let body = wizard_style::section(
        frame,
        parts[1],
        &if loading {
            i18n::t("wizard.setup.checking")
        } else {
            i18n::t("wizard.setup.notes")
        },
    );
    let mut lines: Vec<Line> = notes
        .iter()
        .flat_map(|note| [Line::from(note.clone()), Line::default()])
        .collect();
    lines.push(Line::from(i18n::t("wizard.setup.no_auth_checked")));
    frame.render_widget(Paragraph::new(lines).wrap(Wrap { trim: true }), body);
    wizard_style::render_buttons(
        frame,
        parts[2],
        &[(
            wizard_style::button(
                true,
                &if loading {
                    format!(" {} ", i18n::t("wizard.setup.skip_check"))
                } else {
                    format!(" {} ", i18n::t("wizard.setup.continue"))
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
fn seed_selected_skills(res: &Path, data: &Path) -> Result<(), String> {
    let mut sync = Command::new(res.join("bin/mash-seed-sync"));
    sync.arg(res).arg(data);
    run_logged(sync)?;
    let mut setup = Command::new("/bin/bash");
    setup.args([
        "-c",
        "res=$1; d=$2; source \"$res/bin/launch-common.sh\"; mash_seed_programming_skills; mash_seed_hindsight",
        "mash",
    ]);
    setup.arg(res).arg(data);
    run_logged(setup)?;
    Ok(())
}

// Host installers run only when a selected tool is missing. Mash-owned tools
// install even when the host has a copy: a host binary cannot satisfy Mash's
// pinned, isolated install. Environment steps always run.
const STEP_HINDSIGHT: &str = "Install the memory environment";
const STEP_HINDSIGHT_DAEMON: &str = "Start memory and fetch its models";
const STEP_VOICE: &str = "Install the dictation model";

fn install_steps(plan: &Plan, missing: &[&str]) -> Vec<String> {
    let mut steps = vec!["Check selected tools".to_string()];
    // Linux Route::Mash components are Mash-owned pinned installs: a host copy
    // on PATH cannot satisfy them. Host installers run only for missing tools.
    if !plan.linux.is_empty() {
        steps.push(STEP_LINUX_TOOLS.to_string());
    }
    if !missing.is_empty() && !plan.brew.is_empty() {
        steps.push("Install Homebrew packages".to_string());
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
        .map_err(|e| format!("the memory warm-start script is missing: {e}"))?;
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
            return Ok(i18n::t("wizard.setup.result.daemon_up"));
        }
        let mut shown = messages.to_vec();
        shown.push(format!("  {}", i18n::t("wizard.setup.waiting_daemon")));
        draw_apply(terminal, completed, total, step, &shown);
        std::thread::sleep(Duration::from_secs(10));
    }
    Err("the memory service did not start; see ~/.mash/.hindsight/hook-last-run.log".to_string())
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
            Ok(Some(status)) if status.success() => {
                return Ok(i18n::t("wizard.setup.result.installed"))
            }
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
            Ok(Some(status)) if status.success() => {
                return Ok(i18n::t("wizard.setup.result.model_installed"))
            }
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
/// Exit 4 means the manifest has no build of the tool for this platform (Sentrux
/// on an Intel Mac, say): setup records that too and carries on installing the
/// rest, instead of failing the whole step on a tool that cannot exist here.
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
    let mut unavailable: Vec<&str> = Vec::new();
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
        match tool_outcome(component, status.code())? {
            ToolOutcome::Installed => installed += 1,
            ToolOutcome::Provided => {
                provided += 1;
                shown.push(format!(
                    "  {}",
                    i18n::fill(
                        &i18n::t("wizard.setup.report.system_provided"),
                        &[("component", &component)]
                    )
                ));
            }
            ToolOutcome::Unavailable => {
                unavailable.push(component);
                shown.push(format!(
                    "  {component}: not available for this platform, skipped"
                ));
            }
        }
    }
    Ok(tools_summary(installed, provided, &unavailable))
}

/// What one `mash-tool-install` run means for setup.
#[derive(Debug, PartialEq)]
enum ToolOutcome {
    Installed,
    /// Exit 3: the platform supplies the tool.
    Provided,
    /// Exit 4: the manifest has no build of the tool for this platform.
    Unavailable,
}

/// Map the helper's exit status to an outcome, or to the error that stops the
/// step. Only a failed install is an error: a tool that cannot exist on this
/// platform must not take the rest of the selection down with it.
fn tool_outcome(component: &str, code: Option<i32>) -> Result<ToolOutcome, String> {
    match code {
        Some(0) => Ok(ToolOutcome::Installed),
        Some(3) => Ok(ToolOutcome::Provided),
        Some(4) => Ok(ToolOutcome::Unavailable),
        Some(code) => Err(format!(
            "{component} failed to install (exit {code}); see {}",
            helper_log_path("mash-tool-install").display()
        )),
        None => Err(format!("{component} ended without an exit status")),
    }
}

/// The step's closing line. The counts come from the catalog; a platform that
/// lacks a pinned tool names it, because "0 installed" alone would read as a
/// failure when setup actually did everything this platform allows.
fn tools_summary(installed: usize, provided: usize, unavailable: &[&str]) -> String {
    let mut summary = i18n::fill(
        &i18n::t("wizard.setup.report.counts"),
        &[
            ("installed", &&installed.to_string()),
            ("provided", &&provided.to_string()),
        ],
    );
    if !unavailable.is_empty() {
        summary.push_str(&format!(
            ", not available for this platform: {}",
            unavailable.join(", ")
        ));
    }
    summary
}
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
                && !(plan.linux.is_empty()
                    && plan.npm.is_empty()
                    && plan.pinned.is_empty()
                    && plan.python.is_empty())
            {
                i18n::t("wizard.setup.report.host_tools")
            } else if missing.is_empty() {
                i18n::t("wizard.setup.report.all_installed")
            } else {
                i18n::fill(
                    &i18n::t("wizard.setup.report.missing"),
                    &[("tools", &&missing.join(", "))],
                )
            };
            for tool in &plan.apple {
                if !apple_tool_available(tool) {
                    report.push_str(&format!(
                        " {}",
                        i18n::fill(
                            &i18n::t("wizard.setup.report.apple_tools"),
                            &[("tool", &tool)]
                        )
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
        let message = match result {
            Ok(message) => message,
            Err(_) if host_presence_excuses(step) && tools_available(&plan.tools) => {
                i18n::t("wizard.setup.result.already_installed")
            }
            Err(error) => return Err(error),
        };
        messages.push(format!("  {}: {message}", step_label(step)));
        let _ = write_log(&mut log, &messages);
    }
    draw_apply(
        terminal,
        steps.len(),
        steps.len(),
        &i18n::t("wizard.setup.ready"),
        &messages,
    );
    Ok(())
}

/// An install step keeps its English name as the identifier the dispatch below
/// matches and the log records; only what reaches the screen is translated, so
/// every language installs the same tools.
fn step_label(step: &str) -> String {
    match step {
        "Check selected tools" => i18n::t("wizard.setup.step.check_tools"),
        STEP_LINUX_TOOLS => i18n::t("wizard.setup.step.mash_tools"),
        "Install Homebrew packages" => i18n::t("wizard.setup.step.brew"),
        "Install npm packages" => i18n::t("wizard.setup.step.npm"),
        STEP_PINNED_TOOLS => i18n::t("wizard.setup.step.pinned"),
        "Install Python packages" => i18n::t("wizard.setup.step.python"),
        "Install CUA Driver" => i18n::t("wizard.setup.step.cua"),
        STEP_HINDSIGHT => i18n::t("wizard.setup.step.memory"),
        STEP_HINDSIGHT_DAEMON => i18n::t("wizard.setup.step.memory_models"),
        STEP_VOICE => i18n::t("wizard.setup.step.dictation"),
        other => other.to_string(),
    }
}

// Only host installers may treat an already-present tool as success. Mash-owned
// installs and the environment steps have no such excuse.
fn host_presence_excuses(step: &str) -> bool {
    ![
        STEP_HINDSIGHT,
        STEP_HINDSIGHT_DAEMON,
        STEP_VOICE,
        STEP_LINUX_TOOLS,
        STEP_PINNED_TOOLS,
        "Install npm packages",
        "Install Python packages",
    ]
    .contains(&step)
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

// Mash never installs Homebrew itself, so a missing one is a prerequisite the
// person has to resolve rather than a step that silently fails.
const BREW_MISSING: &str =
    "Homebrew is not installed. Install it from https://brew.sh, or uncheck the Homebrew tools.";

fn install_brew(formulae: &[&'static str]) -> Result<String, String> {
    if formulae.is_empty() {
        return Ok("nothing requested".into());
    }
    let brew = find_brew().ok_or(BREW_MISSING)?;
    let mut command = Command::new(brew);
    command
        .env("PATH", host_path())
        .env("HOMEBREW_NO_AUTO_UPDATE", "1")
        .arg("install")
        .args(formulae);
    run_logged(command)
}

fn find_brew() -> Option<String> {
    if is_linux() {
        return None;
    }
    ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        .into_iter()
        .find(|candidate| {
            use std::os::unix::fs::PermissionsExt;
            fs::metadata(candidate)
                .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
        })
        .map(str::to_string)
        .or_else(|| is_available("brew").then(|| "brew".to_string()))
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
// Register GitHub's MCP server now that Mash's gh is signed in, so the first
// session already has it. The helper decides from the sign-in itself and never
// writes the token; every launch runs it too, so a failure here only delays the
// server to the next launch.
fn connect_github_mcp() {
    let helper = mash_resources().join("bin/mash-github-mcp");
    if helper.is_file() {
        let _ = Command::new(&helper)
            .env("PATH", bundled_path())
            .arg(data_dir())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SigningNote {
    /// The host signs with SSH or X.509, which Mash does not use.
    OpenPgpOnly,
}

impl SigningNote {
    /// Translated here rather than when the page is built: the language is
    /// chosen on the wizard's first page, after this page's state is prepared.
    fn text(self) -> String {
        match self {
            SigningNote::OpenPgpOnly => i18n::t("wizard.identity.key_openpgp_only"),
        }
    }
}

struct HostIdentity {
    name: String,
    email: String,
    signing_key: String,
    signing_note: Option<SigningNote>,
}

fn host_home() -> PathBuf {
    env::var_os("HOME").map(PathBuf::from).unwrap_or_default()
}

// Mash signs with OpenPGP only. An SSH or X.509 key copied without its
// gpg.format would make every signed commit fail, so it is explained instead.
fn openpgp_only(key: String, format: &str) -> (String, Option<SigningNote>) {
    let ssh_key = key.starts_with("ssh-") || key.starts_with("key::") || key.ends_with(".pub");
    if !key.is_empty() && (ssh_key || !matches!(format, "" | "openpgp")) {
        return (String::new(), Some(SigningNote::OpenPgpOnly));
    }
    (key, None)
}

fn host_identity(home: &Path) -> HostIdentity {
    let (signing_key, signing_note) = openpgp_only(
        git_config_value(home, "user.signingkey"),
        &git_config_value(home, "gpg.format"),
    );
    HostIdentity {
        name: git_config_value(home, "user.name"),
        email: git_config_value(home, "user.email"),
        signing_key,
        signing_note,
    }
}

// A retried setup reopens on what the user already saved into Mash's own
// config: the host may have no identity at all, and blanking the fields would
// silently drop the name, email and key an earlier attempt applied.
fn prefill_identity(mut host: HostIdentity, saved: &Path) -> HostIdentity {
    let saved_value = |key| saved_git_value(saved, key);
    if host.name.is_empty() {
        host.name = saved_value("user.name");
    }
    if host.email.is_empty() {
        host.email = saved_value("user.email");
    }
    // A host key Mash cannot use already carries its explanation; do not
    // replace that note with a saved key the user may also be unable to use.
    if host.signing_key.is_empty() && host.signing_note.is_none() {
        let (key, note) = openpgp_only(saved_value("user.signingkey"), &saved_value("gpg.format"));
        host.signing_key = key;
        host.signing_note = note;
    }
    host
}

fn saved_git_value(config: &Path, key: &str) -> String {
    if !config.is_file() {
        return String::new();
    }
    let mut command = Command::new("git");
    command
        .env("PATH", host_path())
        .args(["config", "--file"])
        .arg(config)
        .args(["--get", key]);
    git_output(command)
}

fn git_output(mut command: Command) -> String {
    match command.output() {
        Ok(output) if output.status.success() => {
            String::from_utf8_lossy(&output.stdout).trim().to_string()
        }
        _ => String::new(),
    }
}

// The launcher points XDG_CONFIG_HOME and GIT_CONFIG_GLOBAL at Mash's own
// config; the host's global identity lives under the real home instead.
fn git_config_value(home: &Path, key: &str) -> String {
    let mut command = Command::new("git");
    command
        .env("PATH", host_path())
        .env("HOME", home)
        .env("XDG_CONFIG_HOME", home.join(".config"))
        .env_remove("GIT_CONFIG_GLOBAL")
        .args(["config", "--global", "--get", key]);
    git_output(command)
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
    let identity_title = i18n::t("wizard.identity.title");
    wizard_style::header(
        frame,
        chunks[0],
        &wizard_style::page_title(&identity_title, 0),
    );

    let body = wizard_style::section(frame, chunks[1], &identity_title);
    let fields = [
        (
            FOCUS_NAME,
            i18n::t("wizard.identity.name_label"),
            &page.name,
            i18n::t("wizard.identity.name_help"),
        ),
        (
            FOCUS_EMAIL,
            i18n::t("wizard.identity.email_label"),
            &page.email,
            i18n::t("wizard.identity.email_help"),
        ),
        (
            FOCUS_SIGNING_KEY,
            i18n::t("wizard.identity.key_label"),
            &page.signing_key,
            page.signing_note
                .map(SigningNote::text)
                .unwrap_or_else(|| i18n::t("wizard.identity.key_help")),
        ),
    ];
    let label_width = fields
        .iter()
        .map(|(_, label, _, _)| Line::from(label.as_str()).width())
        .max()
        .unwrap_or(0)
        .saturating_add(1)
        .min(body.width as usize) as u16;
    let input_width = fields
        .iter()
        .map(|(_, _, value, _)| Line::from((*value).clone()).width() + 3)
        .max()
        .unwrap_or(0)
        .max(32)
        .min(body.width.saturating_sub(label_width + 11) as usize) as u16;
    let help_x = body.x + label_width + input_width + 3;
    let help_width = body.right().saturating_sub(help_x);
    let mut row = 0;
    let rows: Vec<_> = fields
        .iter()
        .map(|(_, _, _, hint)| {
            let height = Paragraph::new(hint.as_str())
                .wrap(Wrap { trim: true })
                .line_count(help_width.max(1)) as u16;
            let start = row;
            row += height + 1;
            (start, height)
        })
        .collect();
    let github_row = row;
    let (focus_row, focus_end) = if page.focus <= FOCUS_SIGNING_KEY {
        let (row, height) = rows[page.focus];
        (row, row + height)
    } else {
        (github_row, github_row + 6)
    };
    // Scroll whole fields on short terminals, keeping the focused control visible.
    let scroll = rows
        .iter()
        .map(|(row, _)| *row)
        .chain(std::iter::once(github_row))
        .find(|row| *row <= focus_row && focus_end.saturating_sub(*row) <= body.height)
        .unwrap_or(focus_row);
    for ((focus, label, value, hint), (row, height)) in fields.iter().zip(rows) {
        if row < scroll || row - scroll >= body.height {
            continue;
        }
        let y = body.y + row - scroll;
        let focused = page.focus == *focus;
        let input = Rect::new(body.x + label_width, y, input_width, 1);
        frame.render_widget(
            Paragraph::new(label.as_str()).style(Style::default().add_modifier(Modifier::BOLD)),
            Rect::new(body.x, y, label_width, 1),
        );
        let text = Line::from(vec![
            Span::raw(" "),
            Span::raw((*value).clone()),
            Span::styled(
                if focused { "_" } else { " " },
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
        wizard_style::target(Rect::new(body.x, y, label_width + input_width, 1), *focus);
        frame.render_widget(
            Paragraph::new(hint.as_str())
                .wrap(Wrap { trim: true })
                .style(Style::default().fg(wizard_style::MUTED)),
            Rect::new(help_x, y, help_width, height.min(body.bottom() - y)),
        );
    }
    let github_y = body.y + github_row.saturating_sub(scroll);
    draw_github(
        frame,
        Rect::new(
            body.x,
            github_y.min(body.bottom()),
            body.width,
            body.bottom().saturating_sub(github_y),
        ),
        &page.github,
        page.focus == FOCUS_GITHUB,
    );
    wizard_style::render_buttons(
        frame,
        chunks[2],
        &[(
            wizard_style::button(
                page.focus == FOCUS_IDENTITY_NEXT,
                &format!(" {} ", i18n::t("wizard.identity.next")),
            ),
            Some(FOCUS_IDENTITY_NEXT),
        )],
    );
}

/// Why GitHub sign-in cannot run here, translated when the button is drawn
/// rather than cached when the page is built.
fn unavailable_reason(reason: github_login::UnavailableReason) -> String {
    match reason {
        github_login::UnavailableReason::ConfigInside => i18n::t("wizard.github.config_inside"),
        github_login::UnavailableReason::CliUnavailable => i18n::t("wizard.github.cli_unavailable"),
    }
}

/// A filled GitHub action like the welcome button, with status outside its hit area.
fn draw_github(frame: &mut Frame, area: Rect, github: &github_login::GithubLogin, focused: bool) {
    use github_login::Status;
    if area.height == 0 {
        return;
    }
    frame.render_widget(
        Paragraph::new(i18n::t("wizard.github.section"))
            .style(Style::default().add_modifier(Modifier::BOLD)),
        Rect::new(area.x, area.y, area.width, 1),
    );
    if area.height <= 2 {
        return;
    }
    let (note, color) = match github.status() {
        Status::Unavailable(reason) => (unavailable_reason(*reason), wizard_style::MUTED),
        Status::SignedOut => (i18n::t("wizard.github.signed_out"), wizard_style::MUTED),
        Status::Starting => (i18n::t("wizard.github.starting"), wizard_style::MUTED),
        Status::Waiting { .. } => (i18n::t("wizard.github.waiting"), wizard_style::YELLOW),
        Status::SignedIn(Some(user)) => (
            i18n::fill(&i18n::t("wizard.github.signed_in_as"), &[("user", &user)]),
            wizard_style::GREEN,
        ),
        Status::SignedIn(None) => (i18n::t("wizard.github.signed_in"), wizard_style::GREEN),
        Status::Failed(reason) => (reason.clone(), wizard_style::RED),
    };
    if matches!(github.status(), Status::Unavailable(_)) {
        frame.render_widget(
            Paragraph::new(note)
                .wrap(Wrap { trim: true })
                .style(Style::default().fg(color)),
            Rect::new(area.x, area.y + 2, area.width, area.height - 2),
        );
        return;
    }
    // Same filled, centred treatment as Start config wizard, and sized the same
    // way: from the label, so a longer translation is never clipped.
    let button_text = format!(" {} ", i18n::t(github.button_label_key()));
    let button_width = 23
        .max(Line::from(button_text.as_str()).width() as u16)
        .min(area.width);
    let button = Rect::new(area.x, area.y + 2, button_width, 1);
    frame.render_widget(
        Paragraph::new(button_text)
            .alignment(Alignment::Center)
            .style(if focused {
                wizard_style::selected().add_modifier(Modifier::BOLD)
            } else {
                wizard_style::selected()
            }),
        button,
    );
    wizard_style::target(button, FOCUS_GITHUB);
    let note_x = button.right() + 3;
    let note_width = area.right().saturating_sub(note_x);
    let note_height = (Paragraph::new(note.as_str())
        .wrap(Wrap { trim: true })
        .line_count(note_width.max(1)) as u16)
        .min(area.height - 2);
    frame.render_widget(
        Paragraph::new(note)
            .wrap(Wrap { trim: true })
            .style(Style::default().fg(color)),
        Rect::new(note_x, button.y, note_width, note_height),
    );
    let mut details = Vec::new();
    if let Status::Waiting { code, url, copied } = github.status() {
        details.push(Line::from(vec![
            Span::raw("Your code   "),
            Span::styled(
                code.clone(),
                Style::default()
                    .fg(wizard_style::YELLOW)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw(if *copied {
                format!("   {}", i18n::t("wizard.github.copied"))
            } else {
                String::new()
            }),
        ]));
        details.push(Line::from(i18n::fill(
            &i18n::t("wizard.github.approve"),
            &[("url", &url)],
        )));
    } else if matches!(github.status(), Status::SignedOut | Status::Failed(_)) {
        details.push(Line::from(i18n::t("wizard.github.usage")));
    }
    let details_y = button.y + note_height + 1;
    frame.render_widget(
        Paragraph::new(details)
            .wrap(Wrap { trim: true })
            .style(Style::default().fg(wizard_style::MUTED)),
        Rect::new(
            area.x,
            details_y.min(area.bottom()),
            area.width,
            area.bottom().saturating_sub(details_y),
        ),
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
        wizard_style::header(frame, chunks[0], &i18n::t("wizard.setup.installing"));
        let ratio = if total == 0 {
            1.0
        } else {
            completed as f64 / total as f64
        };
        let progress = wizard_style::section(frame, chunks[1], &step_label(current));
        frame.render_widget(
            Gauge::default()
                .gauge_style(Style::default().fg(wizard_style::GREEN))
                .ratio(ratio),
            progress,
        );
        let log = wizard_style::section(frame, chunks[2], &i18n::t("wizard.setup.progress"));
        frame.render_widget(
            Paragraph::new(messages.join("\n")).wrap(Wrap { trim: true }),
            log,
        );
        wizard_style::finish(frame);
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

/// The install steps for the tools chosen on the Tools page. Bundled tools and
/// apt dependencies are never chosen, so they never reach an installer.
fn install_plan(chosen: &[&tools_page::Tool]) -> Plan {
    use tools_page::{How, Route};
    let mut plan = Plan {
        programming: true,
        ..Plan::default()
    };
    for tool in chosen {
        let Some(route) = tool.route() else {
            continue;
        };
        match route {
            Route::Bundled | Route::Apt => continue,
            Route::Brew(formula) => plan.brew.push(formula),
            // Linux installs every Mash component through one helper call,
            // without elevation; macOS splits them by kind.
            Route::Mash(_, components) if is_linux() => plan.linux.extend(components),
            Route::Mash(How::Download, components) => plan.pinned.extend(components),
            Route::Mash(How::Npm, components) => plan.npm.extend(components),
            Route::Mash(How::Pip, components) => plan.python.extend(components),
            Route::Installer => plan.installer.push(tool.name),
            Route::Apple => plan.apple.push(tool.name),
        }
        plan.tools.extend(tool.binaries());
    }
    // Separate LSP choices may be supplied by the same package.
    plan.linux.sort_unstable();
    plan.linux.dedup();
    plan.npm.sort_unstable();
    plan.npm.dedup();
    plan
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TempDir;

    /// Every tool this platform lets the Tools page choose, all checked.
    fn every_tool() -> Vec<&'static tools_page::Tool> {
        tools_page::ToolsPage::with_homebrew(true).chosen()
    }

    /// The identity page with a preview sign-in, so no test runs gh.
    fn identity_page() -> IdentityPage {
        IdentityPage::new(github_login::GithubLogin::new(
            PathBuf::from("/nonexistent/gh"),
            env::temp_dir().join("mash-wizard-test-gh"),
            OsString::new(),
            true,
        ))
    }

    #[test]
    fn identity_fields_take_letters_that_otherwise_navigate() {
        // q cancels and j/k navigate on the checkbox rows, but all three are
        // valid letters in a name, so a focused field has to take them.
        let mut app = identity_page();
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
        let app = identity_page();
        let host = prefill_identity(
            host_identity(&host_home()),
            &data_dir().join("config/git/config"),
        );
        assert_eq!(app.name, host.name);
        assert_eq!(app.email, host.email);
        assert_eq!(app.signing_key, host.signing_key);
        assert_eq!(app.signing_note, host.signing_note);
    }

    fn scratch_home(name: &str, config: &str) -> TempDir {
        let home = TempDir::new(&format!("wizard-{name}"));
        fs::create_dir_all(home.join(".config/git")).unwrap();
        fs::write(home.join(".config/git/config"), config).unwrap();
        home
    }

    #[test]
    fn host_identity_reads_the_hosts_xdg_git_config_not_mashs() {
        let home = scratch_home(
            "xdg",
            "[user]\n\tname = XDG User\n\temail = xdg@example.org\n\tsigningkey = ABC123\n",
        );
        let host = host_identity(&home);
        assert_eq!(host.name, "XDG User");
        assert_eq!(host.email, "xdg@example.org");
        assert_eq!(host.signing_key, "ABC123");
        assert!(host.signing_note.is_none());
        // A second scratch home with a different identity proves the argument
        // is what gets read, not whatever this process happens to export.
        let second = scratch_home(
            "xdg-b",
            "[user]\n\tname = Second User\n\temail = second@example.org\n",
        );
        let other = host_identity(&second);
        assert_eq!(other.name, "Second User");
        assert_eq!(other.email, "second@example.org");
        assert_eq!(other.signing_key, "");
    }

    #[test]
    fn a_retried_setup_prefills_from_the_identity_mash_already_saved() {
        let saved = scratch_home(
            "saved",
            "[user]\n\tname = Saved Ada\n\temail = saved@example.org\n\tsigningkey = ABC123\n",
        );
        let config = saved.join(".config/git/config");
        let host = host_identity(&scratch_home("empty-host", ""));
        assert!(host.name.is_empty() && host.email.is_empty());
        let merged = prefill_identity(host, &config);
        assert_eq!(merged.name, "Saved Ada");
        assert_eq!(merged.email, "saved@example.org");
        assert_eq!(merged.signing_key, "ABC123");
        // Host values still win when there are any.
        let host = host_identity(&scratch_home(
            "typed-host",
            "[user]\n\tname = Host Ada\n\temail = host@example.org\n",
        ));
        let merged = prefill_identity(host, &config);
        assert_eq!(merged.name, "Host Ada");
        assert_eq!(merged.email, "host@example.org");
        assert_eq!(
            merged.signing_key, "ABC123",
            "a missing field still falls back"
        );
        // A saved key Mash cannot use is explained, never silently enabled.
        let ssh = scratch_home(
            "saved-ssh",
            "[user]\n\tsigningkey = ~/.ssh/id_ed25519.pub\n[gpg]\n\tformat = ssh\n",
        );
        let host = host_identity(&scratch_home("empty-host-2", ""));
        let merged = prefill_identity(host, &ssh.join(".config/git/config"));
        assert_eq!(merged.signing_key, "");
        assert!(merged.signing_note.is_some());
        // A host key with its own explanation keeps it.
        let host = host_identity(&scratch_home(
            "ssh-host",
            "[user]\n\tsigningkey = key::ssh-ed25519 AAAAC3Nz fixture\n",
        ));
        let merged = prefill_identity(host, &config);
        assert_eq!(merged.signing_key, "");
        assert!(merged.signing_note.is_some());
    }

    #[test]
    fn ssh_signing_is_explained_and_never_prefilled_as_openpgp() {
        for (format, key) in [
            ("	format = ssh\n", "~/.ssh/id_ed25519.pub"),
            ("", "ssh-ed25519 AAAAC3Nz fixture"),
            ("", "key::ssh-ed25519 AAAAC3Nz fixture"),
            ("	format = x509\n", "ABC123"),
        ] {
            let home = scratch_home(
                "ssh",
                &format!("[user]\n\tname = Ada\n\tsigningkey = {key}\n[gpg]\n{format}"),
            );
            let host = host_identity(&home);
            assert_eq!(host.name, "Ada");
            assert_eq!(host.signing_key, "", "{format:?} {key}");
            assert!(host.signing_note.is_some(), "{format:?} {key}");
        }
    }

    #[test]
    fn signing_key_controls_commit_signing_in_mash_config() {
        let dir = TempDir::new("wizard-git");
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
    }

    #[test]
    fn backspace_edits_only_the_focused_field() {
        let mut app = identity_page();
        app.focus = FOCUS_EMAIL;
        app.email = "abc".into();
        app.on_key(KeyCode::Backspace, KeyModifiers::NONE);
        assert_eq!(app.email, "ab");
        assert_eq!(app.name, identity_page().name);
        app.focus = FOCUS_SIGNING_KEY;
        app.signing_key = "ABC".into();
        app.on_key(KeyCode::Backspace, KeyModifiers::NONE);
        assert_eq!(app.signing_key, "AB");
        assert_eq!(app.email, "ab");
    }

    #[test]
    fn tab_visits_every_identity_row_and_wraps() {
        let mut identity = identity_page();
        let mut seen = vec![identity.focus];
        for _ in 0..IDENTITY_FOCUS_COUNT {
            identity.on_key(KeyCode::Tab, KeyModifiers::NONE);
            seen.push(identity.focus);
        }
        assert_eq!(seen, vec![0, 1, 2, 3, 4, 0]);
    }

    #[test]
    fn identity_fields_fit_values_and_keep_help_in_a_separate_column() {
        use wizard_style::tests::find;
        for (width, height) in [(80, 24), (100, 30), (140, 40)] {
            let page = IdentityPage {
                name: "Alexandria Example".into(),
                email: "alexandria.example@example.org".into(),
                signing_key: "0123456789ABCDEF0123456789ABCDEF01234567".into(),
                ..identity_page()
            };
            let mut terminal =
                Terminal::new(ratatui::backend::TestBackend::new(width, height)).unwrap();
            terminal.draw(|frame| draw_identity(frame, &page)).unwrap();
            let buffer = terminal.backend().buffer();
            let (_, name_y) = find(buffer, &page.name);
            let (_, email_y) = find(buffer, &page.email);
            let (key_x, key_y) = find(buffer, &page.signing_key);
            assert!(email_y >= name_y + 2, "blank line between name and email");
            assert!(key_y >= email_y + 2, "blank line between email and key");
            for (hint, row) in [("Name on", name_y), ("Email on", email_y), ("Empty", key_y)] {
                let (x, y) = find(buffer, hint);
                assert_eq!(y, row, "help begins alongside its input");
                assert!(x > key_x + page.signing_key.len() as u16);
                assert_eq!(buffer[(x, y)].fg, wizard_style::MUTED);
            }
            assert_eq!(buffer[(key_x, name_y + 1)].symbol(), " ");
            assert_eq!(buffer[(key_x, email_y + 1)].symbol(), " ");
            find(buffer, "Sign in to GitHub");
        }
    }

    #[test]
    fn long_identity_values_scroll_inside_the_input_without_moving_help() {
        let mut page = identity_page();
        page.focus = FOCUS_EMAIL;
        page.email = format!("{}@example.org", "a".repeat(160));
        let mut terminal = Terminal::new(ratatui::backend::TestBackend::new(80, 24)).unwrap();
        terminal.draw(|frame| draw_identity(frame, &page)).unwrap();
        let buffer = terminal.backend().buffer();
        let (_, value_y) = wizard_style::tests::find(buffer, "@example.org_");
        let (_, hint_y) = wizard_style::tests::find(buffer, "Email on");
        assert_eq!(value_y, hint_y);
        assert_eq!(
            page.email.len(),
            172,
            "rendering never truncates the stored value"
        );
    }

    #[test]
    fn github_action_has_the_welcome_buttons_filled_background_without_focus() {
        use wizard_style::tests::{click, find};
        let mut page = identity_page();
        let mut terminal = Terminal::new(ratatui::backend::TestBackend::new(80, 24)).unwrap();
        terminal.draw(|frame| draw_identity(frame, &page)).unwrap();
        let buffer = terminal.backend().buffer();
        let (x, y) = find(buffer, "Sign in to GitHub");
        let background = wizard_style::selected().bg.unwrap();
        assert_eq!(buffer[(x, y)].bg, background);
        assert_eq!(buffer[(x - 1, y)].bg, background, "button includes padding");
        let mut end = x;
        while end < buffer.area.right() && buffer[(end, y)].bg == background {
            end += 1;
        }
        assert_eq!(
            wizard_style::clicked(&click(end - 1, y)),
            Some(FOCUS_GITHUB)
        );
        assert_eq!(
            wizard_style::clicked(&click(end, y)),
            None,
            "status is not clickable"
        );
        page.focus = FOCUS_GITHUB;
        page.github.activate();
        terminal.draw(|frame| draw_identity(frame, &page)).unwrap();
        let buffer = terminal.backend().buffer();
        let (x, y) = find(buffer, "Cancel");
        assert_eq!(buffer[(x, y)].bg, background);
        find(buffer, "ABCD-1234");
    }

    #[test]
    fn the_github_button_signs_in_from_the_identity_page_without_leaving_it() {
        use wizard_style::tests::{click, find};
        let text = |page: &IdentityPage| {
            let mut terminal = Terminal::new(ratatui::backend::TestBackend::new(140, 60)).unwrap();
            terminal.draw(|frame| draw_identity(frame, page)).unwrap();
            let buffer = terminal.backend().buffer().clone();
            let text = buffer
                .content()
                .iter()
                .map(|cell| cell.symbol())
                .collect::<String>();
            (buffer, text)
        };
        let mut page = identity_page();
        let (buffer, rendered) = text(&page);
        assert!(rendered.contains("GitHub (optional)"));
        assert!(rendered.contains("Not signed in"));
        let (x, y) = find(&buffer, "Sign in to GitHub");
        let id = wizard_style::clicked(&click(x, y)).expect("the button is clickable");
        assert_eq!(id, FOCUS_GITHUB);
        assert!(page.on_click(id).is_none(), "signing in stays on the page");
        let (_, rendered) = text(&page);
        assert!(rendered.contains("ABCD-1234"));
        assert!(rendered.contains("Waiting for approval"));
        assert!(rendered.contains("Cancel"));
        // Enter and Space act on the button; neither advances nor types.
        page.focus = FOCUS_GITHUB;
        assert!(page.on_key(KeyCode::Enter, KeyModifiers::NONE).is_none());
        assert!(!text(&page).1.contains("ABCD-1234"));
        assert!(page
            .on_key(KeyCode::Char(' '), KeyModifiers::NONE)
            .is_none());
        assert!(text(&page).1.contains("ABCD-1234"));
        page.on_key(KeyCode::Tab, KeyModifiers::NONE);
        assert_eq!(page.focus, FOCUS_IDENTITY_NEXT);
        assert!(matches!(
            page.on_key(KeyCode::Enter, KeyModifiers::NONE),
            Some(Outcome::Next)
        ));
    }

    #[test]
    fn enter_advances_from_a_field_and_from_next() {
        let mut identity = identity_page();
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
    }

    #[test]
    fn esc_cancels_from_a_field() {
        let mut identity = identity_page();
        identity.focus = FOCUS_NAME;
        assert!(matches!(
            identity.on_key(KeyCode::Esc, KeyModifiers::NONE),
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
    fn clicking_the_identity_page_focuses_fields_and_advances() {
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
        let mut identity = identity_page();
        let render_identity = |page: &IdentityPage| {
            let mut terminal = Terminal::new(ratatui::backend::TestBackend::new(140, 60)).unwrap();
            terminal.draw(|frame| draw_identity(frame, page)).unwrap();
            terminal.backend().buffer().clone()
        };
        let buffer = render_identity(&identity);
        assert!(!text(&buffer).contains("sentrux"));
        assert!(identity.on_click(target(&buffer, "Email")).is_none());
        assert_eq!(identity.focus, FOCUS_EMAIL);
        assert!(matches!(
            identity.on_click(target(&render_identity(&identity), "Next — choose tools")),
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
    fn setup_failure_shows_the_error_and_log_before_mash_opens() {
        let lines = setup_failure_lines(
            "Homebrew is not installed. Install it from https://brew.sh, or uncheck the Homebrew tools.",
            Path::new("/tmp/mash-setup/setup.log"),
        );
        for (width, height) in [(80, 24), (120, 30)] {
            let mut terminal =
                ratatui::Terminal::new(ratatui::backend::TestBackend::new(width, height)).unwrap();
            terminal
                .draw(|frame| draw_setup_failure(frame, &lines))
                .unwrap();
            let buffer = terminal.backend().buffer();
            wizard_style::tests::find(buffer, "Setup could not finish");
            wizard_style::tests::find(buffer, "Homebrew is not installed");
            wizard_style::tests::find(buffer, "setup.log");
            wizard_style::tests::find(buffer, "Press Enter");
        }
        assert_eq!(
            setup_failure_lines(" ", Path::new("x"))[0],
            "An unknown error stopped setup."
        );
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
        let dir = TempDir::new("complete-test");
        fs::create_dir_all(&dir).unwrap();
        let mut state = State::default();
        mark_complete(&dir, &mut state);
        assert!(load_state(&dir).completed);
        assert!(dir.join(OPEN_WORKSPACE_MARKER).is_file());
    }

    #[test]
    fn an_unchecked_suite_adds_no_hindsight_install_steps() {
        let mut plan = install_plan(&[]);
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
            ..identity_page()
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
        assert!(rendered.contains("Identity — page 1/7"));
        assert!(rendered.contains("Tools"));
        assert!(rendered.contains("Model provider"));
        assert!(rendered.contains("ada@example.org"));
        // Sidebar: logo rows 1-10, SETUP, blank, then page 1 on row 13.
        assert_eq!(buffer[(0, 13)].bg, wizard_style::PANEL);
        assert_eq!(buffer[(3, 13)].bg, wizard_style::selected().bg.unwrap());
        assert_eq!(buffer[(40, 5)].bg, wizard_style::PANEL);
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
        let plan = install_plan(&[]);
        let steps = install_steps(&plan, &[]);
        assert!(steps.contains(&STEP_HINDSIGHT.to_string()));
        assert_eq!(steps.last().unwrap(), STEP_HINDSIGHT_DAEMON);
        // Tools install before the environment steps that may use them. The
        // step is Homebrew on macOS and Mash's own installer on Linux.
        let full = install_steps(&install_plan(&every_tool()), &["gopls"]);
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
        let tmp = TempDir::new("port");
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

    #[test]
    fn a_tool_missing_on_this_platform_is_skipped_not_fatal() {
        // Sentrux and latexindent publish no Intel Mac build, so the manifest
        // scopes them out and mash-tool-install exits 4. Both are checked by
        // default; failing the pinned step on them would stop first-run setup.
        assert_eq!(tool_outcome("sentrux", Some(0)), Ok(ToolOutcome::Installed));
        assert_eq!(tool_outcome("git", Some(3)), Ok(ToolOutcome::Provided));
        assert_eq!(
            tool_outcome("sentrux", Some(4)),
            Ok(ToolOutcome::Unavailable)
        );
    }

    #[test]
    fn a_failed_install_still_stops_the_step() {
        for code in [1, 2, 5, 127] {
            let error = tool_outcome("texlab", Some(code)).unwrap_err();
            assert!(error.contains("texlab failed to install"), "{error}");
            assert!(error.contains(&format!("exit {code}")), "{error}");
        }
        let killed = tool_outcome("texlab", None).unwrap_err();
        assert!(killed.contains("without an exit status"), "{killed}");
    }

    #[test]
    fn the_tools_summary_names_what_this_platform_lacks() {
        assert_eq!(
            tools_summary(2, 1, &[]),
            "2 installed, 1 provided by the system"
        );
        assert_eq!(
            tools_summary(4, 0, &["sentrux", "latexindent"]),
            "4 installed, 0 provided by the system, not available for this platform: sentrux, latexindent"
        );
    }

    #[test]
    fn one_checkbox_installs_only_that_tool_and_its_required_components() {
        let chosen = tools_page::TOOLS
            .iter()
            .find(|tool| tool.name == "prettier")
            .unwrap();
        let plan = install_plan(&[chosen]);
        assert_eq!(plan.tools, vec!["prettier"]);
        let components = if is_linux() { &plan.linux } else { &plan.npm };
        assert_eq!(components, &["prettier", "prettier-plugin-svelte"]);
        assert!(plan.brew.is_empty());
        assert!(plan.pinned.is_empty());
        assert!(plan.python.is_empty());
        assert!(plan.installer.is_empty());
        assert!(plan.apple.is_empty());
    }

    #[test]
    fn individually_selected_servers_share_one_package_install() {
        let servers: Vec<_> = tools_page::TOOLS
            .iter()
            .filter(|tool| {
                matches!(
                    tool.name,
                    "vscode-css-language-server" | "vscode-json-language-server"
                )
            })
            .collect();
        assert_eq!(servers.len(), 2);
        let plan = install_plan(&servers);
        assert_eq!(
            plan.tools,
            vec!["vscode-css-language-server", "vscode-json-language-server"]
        );
        let packages = if is_linux() { &plan.linux } else { &plan.npm };
        assert_eq!(packages, &["vscode-langservers-extracted"]);
    }

    #[test]
    fn fixed_tools_never_reach_installers() {
        use tools_page::Route;
        for tool in tools_page::TOOLS
            .iter()
            .filter(|tool| tool.route().is_some_and(Route::locked))
        {
            let plan = install_plan(&[tool]);
            assert!(
                plan.tools.is_empty(),
                "{} is not an optional install",
                tool.name
            );
            assert!(plan.linux.is_empty());
            assert!(plan.brew.is_empty());
            assert!(plan.npm.is_empty());
            assert!(plan.pinned.is_empty());
            assert!(plan.python.is_empty());
            assert!(plan.apple.is_empty());
            assert!(plan.installer.is_empty());
        }
    }

    // macOS installer routing: Linux installs every tool through plan.linux,
    // which the_plan_matches_the_platform asserts.
    #[cfg(target_os = "macos")]
    #[test]
    fn default_plan_covers_requested_tools() {
        let plan = install_plan(&every_tool());
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
        let plan = install_plan(&every_tool());
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
        let plan = install_plan(&[]);
        assert!(plan.brew.is_empty());
        assert!(plan.npm.is_empty());
        assert!(plan.python.is_empty());
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_tools_install_sentrux_without_swift() {
        let plan = install_plan(&every_tool());
        assert!(plan.linux.contains(&"sentrux"));
        assert!(!plan.linux.contains(&"sourcekit-lsp"));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_tools_use_pinned_components_and_keep_binary_names() {
        let plan = install_plan(&every_tool());

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
        let plan = install_plan(&every_tool());
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
    fn selected_tools_name_manifest_components_not_specs() {
        // The Mash helper takes component names; a version here would fail
        // to resolve against the bundled manifest.
        let plan = install_plan(&every_tool());
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
        let plan = install_plan(&every_tool());
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
        let plan = install_plan(&every_tool());
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
    fn a_missing_homebrew_refusal_names_the_remedy() {
        // No formulae is a no-op, never a `brew install` with no arguments.
        assert_eq!(install_brew(&[]).unwrap(), "nothing requested");
        // #22: the alert has to say what to do, not fail silently.
        assert!(BREW_MISSING.contains("https://brew.sh"));
        assert!(BREW_MISSING.contains("uncheck the Homebrew tools"));
        if is_linux() {
            assert!(find_brew().is_none(), "Linux routes tools through Mash");
        }
    }

    #[test]
    fn linux_mash_tools_install_even_when_host_copies_exist() {
        let plan = Plan {
            linux: vec!["agent-browser"],
            tools: vec!["agent-browser"],
            ..Plan::default()
        };
        assert!(install_steps(&plan, &[]).contains(&STEP_LINUX_TOOLS.to_string()));
        assert!(!host_presence_excuses(STEP_LINUX_TOOLS));
    }

    #[test]
    fn nothing_missing_skips_host_installers() {
        // Host-installed tools need no retry. Host binaries cannot satisfy
        // Mash-owned npm or Python components on macOS.
        let plan = install_plan(&every_tool());
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
        let plan = install_plan(&every_tool());
        let steps = install_steps(&plan, &["gopls"]);
        assert!(steps.iter().any(|step| step == "Install npm packages"));
        assert!(steps.iter().any(|step| step == "Install Homebrew packages"));
    }

    #[test]
    fn a_chosen_dictation_model_reaches_installation() {
        // The choice was collected for this long before it installed anything.
        let mut plan = install_plan(&[]);
        assert!(!install_steps(&plan, &[]).iter().any(|s| s == STEP_VOICE));
        plan.voice = Some(voice::VoiceChoice {
            model_id: "parakeet-unified-en-0.6b".into(),
            languages: vec!["en".into()],
            needs_detector: false,
        });
        let steps = install_steps(&plan, &[]);
        assert_eq!(steps.last().map(String::as_str), Some(STEP_VOICE));
    }

    // A fixed-width button clipped the longest translation. Every language has
    // to fit its own label, on screen, in a terminal as small as 80 columns.
    #[test]
    fn the_github_button_fits_its_label_in_every_language() {
        let github = github_login::GithubLogin::new(
            PathBuf::from("/nonexistent/gh"),
            env::temp_dir().join("mash-wizard-test-gh-button"),
            OsString::new(),
            true,
        );
        let selected = wizard_style::selected().bg.unwrap();
        for code in i18n::language_codes() {
            let _language = i18n::override_language(code);
            let mut terminal =
                ratatui::Terminal::new(ratatui::backend::TestBackend::new(80, 24)).unwrap();
            terminal
                .draw(|frame| {
                    let area = wizard_style::page_area(frame, Some(0));
                    draw_github(frame, area, &github, false);
                })
                .unwrap();
            let buffer = terminal.backend().buffer();
            // The filled rectangle is the button: its width is what a clipped
            // label loses, so measure it rather than the text inside it. Wide
            // characters fill two cells but only the first carries the colour.
            let width = (0..buffer.area.height)
                .find_map(|y| {
                    let filled: Vec<u16> = (0..buffer.area.width)
                        .filter(|x| buffer[(*x, y)].bg == selected)
                        .collect();
                    filled
                        .first()
                        .zip(filled.last())
                        .map(|(first, last)| last - first + 1)
                })
                .unwrap_or_else(|| panic!("{code}: no GitHub button drawn"));
            // One space of padding either side of the label has to fit inside.
            let label = i18n::t("wizard.github.sign_in");
            let needed = Line::from(label.as_str()).width() as u16 + 2;
            assert!(
                width >= needed,
                "{code}: {width}-column button for a {needed}-column label"
            );
            assert_eq!(width, needed.max(23), "{code}");
        }
    }

    // The progress and finish screens used to stay English in every language.
    // The step keeps its English identifier; only what is drawn is translated.
    #[test]
    fn the_setup_progress_screen_speaks_the_chosen_language() {
        let _language = i18n::override_language("es");
        let mut terminal =
            ratatui::Terminal::new(ratatui::backend::TestBackend::new(100, 30)).unwrap();
        draw_apply(
            &mut terminal,
            1,
            4,
            "Install npm packages",
            &["  missing; see setup.log".to_string()],
        );
        let rendered = terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect::<String>();
        assert!(rendered.contains(&i18n::t("wizard.setup.installing")));
        assert!(rendered.contains(&i18n::t("wizard.setup.progress")));
        assert!(rendered.contains(&i18n::t("wizard.setup.step.npm")));
        assert!(!rendered.contains("Mash installation"));
        assert!(!rendered.contains("Install npm packages"));
    }
}
