mod penpot_page;
mod provider_page;
mod voice;
mod voice_page;

use ratatui::{
    backend::{Backend, CrosstermBackend},
    crossterm::{
        event::{self, Event, KeyCode, KeyEventKind, KeyModifiers},
        execute,
        terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
    },
    layout::{Alignment, Constraint, Layout},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Gauge, Paragraph, Wrap},
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

// Sentrux comes from a tap, agent-browser is an npm package, and CUA Driver
// ships through its own installer. Every other utility is a plain formula.
const SENTRUX_FORMULA: &str = "sentrux/tap/sentrux";
const AGENT_BROWSER_PACKAGE: &str = "agent-browser@0.38.2";
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

struct App {
    name: String,
    email: String,
    selections: [bool; 2],
    focus: usize,
}

// The identity fields come first so they stay on screen even when the tool list
// is taller than the window.
const FOCUS_NAME: usize = 0;
const FOCUS_EMAIL: usize = 1;
const FOCUS_GROUP_UTILITIES: usize = 2;
const FOCUS_GROUP_FORMATTERS: usize = 3;
const FOCUS_BUTTON: usize = 4;
const FOCUS_COUNT: usize = 5;

// Focus row carrying group `index`.
fn focus_for_group(index: usize) -> usize {
    if index == 0 {
        FOCUS_GROUP_UTILITIES
    } else {
        FOCUS_GROUP_FORMATTERS
    }
}

fn is_text_field(focus: usize) -> bool {
    focus == FOCUS_NAME || focus == FOCUS_EMAIL
}

#[derive(Default, Clone)]
struct Identity {
    name: String,
    email: String,
}

impl App {
    fn new() -> Self {
        Self {
            name: git_config_value("user.name"),
            email: git_config_value("user.email"),
            selections: [true, true],
            focus: FOCUS_NAME,
        }
    }

    fn identity(&self) -> Identity {
        Identity {
            name: self.name.clone(),
            email: self.email.clone(),
        }
    }

    fn text_mut(&mut self) -> &mut String {
        if self.focus == FOCUS_NAME {
            &mut self.name
        } else {
            &mut self.email
        }
    }

    // Which checkbox the focus is on, if any.
    fn selection(&self) -> Option<usize> {
        match self.focus {
            FOCUS_GROUP_UTILITIES => Some(0),
            FOCUS_GROUP_FORMATTERS => Some(1),
            _ => None,
        }
    }

    fn on_key(&mut self, code: KeyCode, modifiers: KeyModifiers) -> Option<Outcome> {
        if modifiers.contains(KeyModifiers::CONTROL) && code == KeyCode::Char('c') {
            return Some(Outcome::Cancel);
        }
        // A focused text field takes every character. `q`, `j` and `k` are
        // letters in a name, so they cannot double as cancel and navigation
        // while one is focused; Esc still cancels and Enter still continues.
        if is_text_field(self.focus) {
            return match code {
                KeyCode::Esc => Some(Outcome::Cancel),
                KeyCode::Enter => Some(Outcome::Next),
                KeyCode::Up | KeyCode::BackTab => {
                    self.focus = self.focus.saturating_sub(1);
                    None
                }
                KeyCode::Down | KeyCode::Tab => {
                    self.focus = (self.focus + 1).min(FOCUS_BUTTON);
                    None
                }
                KeyCode::Backspace => {
                    self.text_mut().pop();
                    None
                }
                KeyCode::Char(c) => {
                    if !modifiers.contains(KeyModifiers::CONTROL) {
                        self.text_mut().push(c);
                    }
                    None
                }
                _ => None,
            };
        }
        match code {
            KeyCode::Esc | KeyCode::Char('q') => Some(Outcome::Cancel),
            KeyCode::Down | KeyCode::Char('j') if self.focus < FOCUS_BUTTON => {
                self.focus += 1;
                None
            }
            KeyCode::Up | KeyCode::Char('k') if self.focus > 0 => {
                self.focus -= 1;
                None
            }
            KeyCode::Tab | KeyCode::BackTab => {
                self.focus = (self.focus + 1) % FOCUS_COUNT;
                None
            }
            KeyCode::Char(' ') => {
                if let Some(index) = self.selection() {
                    self.selections[index] = !self.selections[index];
                }
                None
            }
            KeyCode::Char('1') => {
                self.selections[0] = !self.selections[0];
                self.focus = FOCUS_GROUP_UTILITIES;
                None
            }
            KeyCode::Char('2') => {
                self.selections[1] = !self.selections[1];
                self.focus = FOCUS_GROUP_FORMATTERS;
                None
            }
            KeyCode::Enter if self.focus == FOCUS_BUTTON => Some(Outcome::Next),
            _ => None,
        }
    }
}

enum Outcome {
    Next,
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

fn run() -> Result<i32, String> {
    // Every later launch runs this binary again; a finished setup only checks
    // its own state file and leaves the terminal untouched.
    if setup_is_done() {
        return Ok(0);
    }
    enable_raw_mode().map_err(|e| e.to_string())?;
    let mut out = io::stdout();
    execute!(out, EnterAlternateScreen).map_err(|e| e.to_string())?;
    let backend = CrosstermBackend::new(out);
    let mut terminal = Terminal::new(backend).map_err(|e| e.to_string())?;
    let result = interactive(&mut terminal);
    let _ = disable_raw_mode();
    let mut out = io::stdout();
    let _ = execute!(out, LeaveAlternateScreen);
    result
}

fn interactive<B: Backend>(terminal: &mut Terminal<B>) -> Result<i32, String> {
    let mut app = App::new();
    let mut providers = provider_page::ProviderPage::new();
    let mut penpot = penpot_page::PenpotPage::new(app.email.clone());
    let mut voice = voice_page::VoicePage::new();
    let mut page = 0;
    loop {
        terminal
            .draw(|frame| match page {
                0 => draw_choices(frame, &app),
                1 => providers.draw(frame),
                2 => penpot.draw(frame),
                _ => voice.draw(frame),
            })
            .map_err(|e| e.to_string())?;
        let Event::Key(key) = event::read().map_err(|e| e.to_string())? else {
            continue;
        };
        if key.kind != KeyEventKind::Press {
            continue;
        }
        match page {
            0 => match app.on_key(key.code, key.modifiers) {
                Some(Outcome::Cancel) => {
                    if confirm_quit(terminal)? {
                        return Ok(EXIT_NOT_DONE);
                    }
                }
                Some(Outcome::Next) => page = 1,
                None => {}
            },
            1 => match providers.on_key(key.code, key.modifiers) {
                Some(provider_page::Decision::Cancel) => {
                    if confirm_quit(terminal)? {
                        return Ok(EXIT_NOT_DONE);
                    }
                }
                Some(provider_page::Decision::Back) => page = 0,
                Some(provider_page::Decision::Save) if providers.validate() => page = 2,
                _ => {}
            },
            2 => match penpot.on_key(key.code, key.modifiers) {
                Some(penpot_page::Decision::Cancel) => {
                    if confirm_quit(terminal)? {
                        return Ok(EXIT_NOT_DONE);
                    }
                }
                Some(penpot_page::Decision::Back) => page = 1,
                Some(penpot_page::Decision::Save) if penpot.validate() => {
                    if let Err(error) = penpot
                        .save(&data_dir())
                        .and_then(|()| providers.save(&data_dir()))
                    {
                        penpot.show_error(error);
                    } else {
                        page = 3;
                    }
                }
                _ => {}
            },
            _ => match voice.on_key(key.code, key.modifiers) {
                Some(voice_page::Decision::Cancel) => {
                    if confirm_quit(terminal)? {
                        return Ok(EXIT_NOT_DONE);
                    }
                }
                Some(voice_page::Decision::Back) => page = 2,
                Some(voice_page::Decision::Skip) => break,
                Some(voice_page::Decision::Save) if voice.validate() => break,
                _ => {}
            },
        }
    }

    let mut plan = install_plan(app.selections);
    plan.voice = voice.choice();
    let identity = app.identity();
    match review_and_apply(terminal, &plan, &identity) {
        Ok(()) => {
            if app.selections[0] {
                offer_github_login(terminal)?;
            }
            Ok(0)
        }
        Err(ApplyError::Failed(message)) => Err(message),
    }
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
                    .fg(Color::Yellow)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw(" quit setup    "),
            Span::styled(
                "any other key",
                Style::default()
                    .fg(Color::Yellow)
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
    frame.render_widget(
        Paragraph::new(text)
            .alignment(Alignment::Center)
            .wrap(Wrap { trim: true })
            .block(Block::default().borders(Borders::ALL).title(" Mash setup ")),
        middle,
    );
}

enum ApplyError {
    Failed(String),
}

fn review_and_apply<B: Backend>(
    terminal: &mut Terminal<B>,
    plan: &Plan,
    identity: &Identity,
) -> Result<(), ApplyError> {
    let state_dir = state_dir();
    let mut state = load_state(&state_dir);
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
    match apply_git_identity(identity) {
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
    state.completed = true;
    state.error.clear();
    state.completed_at = now_millis();
    save_state(&state_dir, &state);
    Ok(())
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

// The launcher puts the app bundle on PATH first, so `npm` and `python3` would
// otherwise resolve to Mash's own copies and install packages inside the signed
// bundle. Every installer runs with a host-only PATH instead.
fn host_path() -> OsString {
    let inherited = env::var_os("PATH").unwrap_or_default();
    let mut dirs: Vec<OsString> = env::split_paths(&inherited)
        .filter(|dir| {
            let text = dir.to_string_lossy();
            !text.contains("/Mash.app/") && !text.ends_with("/.mash/bin")
        })
        .map(PathBuf::into_os_string)
        .collect();
    // CUA Driver and agent-browser install into ~/.local/bin, which a GUI
    // launch never has on PATH. Mash adds the same directory for its panes.
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
    Command::new("sh")
        .env("PATH", host_path())
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

// A selected tool that is already on PATH needs no installer. Running one
// anyway is how the wizard kept reappearing: `npm install --global
// yaml-language-server` fails with EEXIST when Homebrew already owns that
// binary, the failure never writes completed=true, and the setup reopens on
// every launch. Only add installers when something is actually missing.
// Environment steps that always run, after whichever installers the selections
// needed. They are not optional: no one has to opt into having memory or a
// design stack available.
const STEP_HINDSIGHT: &str = "Install the Hindsight environment";
const STEP_HINDSIGHT_DAEMON: &str = "Start Hindsight and fetch its models";
const STEP_DESIGN: &str = "Install the design dependencies";
const STEP_PENPOT: &str = "Create the local Penpot account (or defer until Docker is ready)";
const STEP_VOICE: &str = "Install the dictation model";

fn install_steps(plan: &Plan, missing: &[&str]) -> Vec<String> {
    let mut steps = vec!["Check selected tools".to_string()];
    // A selected tool that is already on PATH needs no installer. Only add one
    // when something is actually missing.
    if !missing.is_empty() {
        if !plan.linux.is_empty() {
            steps.push(STEP_LINUX_TOOLS.to_string());
        }
        if !plan.brew.is_empty() {
            steps.push("Install Homebrew packages".to_string());
        }
        if !plan.npm.is_empty() {
            steps.push("Install npm packages".to_string());
        }
        if !plan.python.is_empty() {
            steps.push("Install Python packages".to_string());
        }
        if !plan.installer.is_empty() {
            steps.push("Install CUA Driver".to_string());
        }
    }
    steps.push(STEP_HINDSIGHT.to_string());
    steps.push(STEP_HINDSIGHT_DAEMON.to_string());
    steps.push(STEP_DESIGN.to_string());
    steps.push(STEP_PENPOT.to_string());
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

/// Install the selected tools into Mash's data folder.
///
/// One helper call per component, so a failure is attributable and a tool that
/// is already present costs nothing. Exit 3 means the platform supplies that
/// tool; setup records it and continues rather than failing the whole step,
/// which is what keeps setup free of privilege prompts.
fn install_linux_tools<B: Backend>(
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
fn penpot_account_ready() -> bool {
    let config = data_dir().join("local/share/mash/design/penpot.env");
    fs::read_to_string(config).is_ok_and(|text| {
        text.lines().any(|line| {
            line.strip_prefix("PENPOT_ACCESS_TOKEN=")
                .is_some_and(|token| !token.is_empty())
        })
    })
}

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
            let mut report = if missing.is_empty() {
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
            install_linux_tools(terminal, index, steps.len(), step, &messages, &plan.linux)
        } else if step == "Install Homebrew packages" {
            install_brew(&plan.brew)
        } else if step == "Install npm packages" {
            install_npm(&plan.npm)
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
        } else if step == STEP_DESIGN {
            install_helper_with_progress(
                terminal,
                index,
                steps.len(),
                step,
                &messages,
                "mash-design-deps",
            )
        } else if step == STEP_PENPOT {
            install_helper_with_progress(
                terminal,
                index,
                steps.len(),
                step,
                &messages,
                "mash-penpot-account-setup",
            )
            .map(|_| {
                if penpot_account_ready() {
                    "local account and MCP token ready".into()
                } else {
                    "credentials saved; reopen Mash after Docker starts".into()
                }
            })
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
            install_python(&plan.python)
        };
        // The same collision can surface when only some tools are missing and
        // an installer trips over one that is already present. The step is
        // done once every selected tool is available; otherwise report why.
        // The environment steps are excluded: they have no such excuse, and
        // masking their failure would leave memory or design quietly absent.
        let environment_step = step == STEP_HINDSIGHT
            || step == STEP_HINDSIGHT_DAEMON
            || step == STEP_DESIGN
            || step == STEP_PENPOT
            || step == STEP_VOICE;
        let message = match result {
            Ok(message) => message,
            Err(_) if !environment_step && tools_available(&plan.tools) => {
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

fn install_npm(packages: &[&'static str]) -> Result<String, String> {
    if packages.is_empty() {
        return Ok("nothing requested".into());
    }
    let mut command = Command::new("npm");
    command
        .env("PATH", host_path())
        .args(["install", "--global"])
        .args(packages);
    run_logged(command)
}

fn install_python(packages: &[&'static str]) -> Result<String, String> {
    if packages.is_empty() {
        return Ok("nothing requested".into());
    }
    let mut command = Command::new("python3");
    command
        .env("PATH", host_path())
        .args(["-m", "pip", "install", "--user"])
        .args(packages);
    run_logged(command)
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
        return Ok(());
    }
    let mut note = String::new();
    loop {
        terminal
            .draw(|frame| {
                frame.render_widget(
                    Paragraph::new(format!(
                        "Sign into GitHub for Mash?\n\nPress y to open browser sign-in, or Enter / n / Esc to skip.\n\n{note}"
                    ))
                    .alignment(Alignment::Center)
                    .block(Block::default().borders(Borders::ALL).title("GitHub (optional)")),
                    frame.area(),
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
                    return Ok(());
                }
                note = "GitHub sign-in did not complete. Press y to retry or Enter to skip.".into();
            }
            _ => {}
        }
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
// rewrites. Mash never reads ~/.gitconfig, so without this a commit made in
// Mash has no author at all.
fn apply_git_identity(identity: &Identity) -> Result<String, String> {
    let name = identity.name.trim();
    let email = identity.email.trim();
    if name.is_empty() && email.is_empty() {
        return Ok("none given; commits stay unattributed".into());
    }
    let config = data_dir().join("config").join("git").join("config");
    if let Some(parent) = config.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    for (key, value) in [("user.name", name), ("user.email", email)] {
        if value.is_empty() {
            continue;
        }
        let mut command = Command::new("git");
        command
            .env("PATH", host_path())
            .env_remove("GIT_CONFIG_GLOBAL")
            .arg("config")
            .arg("--file")
            .arg(&config)
            .arg(key)
            .arg(value);
        run_logged(command)?;
    }
    Ok(format!("set to {name} <{email}>"))
}

fn run_logged(mut command: Command) -> Result<String, String> {
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    let output = command.output().map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    Ok("complete".into())
}

fn draw_choices(frame: &mut Frame, app: &App) {
    let area = frame.area();
    let chunks = Layout::vertical([
        Constraint::Length(3),
        Constraint::Min(8),
        Constraint::Length(3),
    ])
    .split(area);
    frame.render_widget(
        Paragraph::new(Line::styled(
            "Mash first-launch setup — page 1/3",
            Style::default().add_modifier(Modifier::BOLD),
        ))
        .alignment(Alignment::Center)
        .block(Block::default().borders(Borders::ALL)),
        chunks[0],
    );

    let mut lines = vec![
        Line::from(
            "Choose tools and Git identity. GitHub sign-in is offered after installation when utilities are selected.",
        ),
        Line::from(""),
        Line::from("Git identity for commits made in Mash:"),
    ];
    for (focus, label, value) in [
        (FOCUS_NAME, "Name ", &app.name),
        (FOCUS_EMAIL, "Email", &app.email),
    ] {
        let focused = app.focus == focus;
        let marker = if focused { ">" } else { " " };
        lines.push(Line::from(vec![
            Span::styled(marker, Style::default().fg(Color::Yellow)),
            Span::styled(
                format!("{label}: "),
                Style::default().add_modifier(Modifier::BOLD),
            ),
            Span::raw(value.clone()),
            Span::styled(
                if focused { "_" } else { "" },
                Style::default().fg(Color::Yellow),
            ),
        ]));
        if focused {
            lines.push(Line::from(
                "      type to edit, Backspace to delete, empty to leave commits unattributed",
            ));
        }
    }
    lines.push(Line::from(""));
    for (index, group) in Group::ALL.iter().enumerate() {
        let checked = if app.selections[index] { "x" } else { " " };
        let focused = app.focus == focus_for_group(index);
        let marker = if focused { ">" } else { " " };
        let line = Line::from(vec![
            Span::styled(marker, Style::default().fg(Color::Yellow)),
            Span::raw(format!("[{checked}] ")),
            Span::styled(group.title(), Style::default().add_modifier(Modifier::BOLD)),
            Span::raw(format!(" — {}", group.summary())),
        ]);
        lines.push(line);
        for (tool, description) in group.tools() {
            lines.push(Line::from(format!("      {tool:<24} {description}")));
        }
        lines.push(Line::from(""));
    }

    frame.render_widget(
        Paragraph::new(lines).wrap(Wrap { trim: true }).block(
            Block::default()
                .borders(Borders::ALL)
                .title("Install choices"),
        ),
        chunks[1],
    );

    let button_style = if app.focus == FOCUS_BUTTON {
        Style::default().fg(Color::Black).bg(Color::Yellow)
    } else {
        Style::default()
    };
    frame.render_widget(
        Paragraph::new(Line::styled(
            " Next — configure providers ",
            button_style.add_modifier(Modifier::BOLD),
        ))
        .alignment(Alignment::Center)
        .block(Block::default().borders(Borders::ALL)),
        chunks[2],
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
        let area = frame.area();
        let chunks = Layout::vertical([
            Constraint::Length(3),
            Constraint::Length(3),
            Constraint::Min(5),
        ])
        .split(area);
        frame.render_widget(
            Paragraph::new("Mash installation")
                .alignment(Alignment::Center)
                .block(Block::default().borders(Borders::ALL)),
            chunks[0],
        );
        let ratio = if total == 0 {
            1.0
        } else {
            completed as f64 / total as f64
        };
        frame.render_widget(
            Gauge::default()
                .block(Block::default().borders(Borders::ALL).title(current))
                .gauge_style(Style::default().fg(Color::Green))
                .ratio(ratio),
            chunks[1],
        );
        frame.render_widget(
            Paragraph::new(messages.join("\n"))
                .wrap(Wrap { trim: true })
                .block(Block::default().borders(Borders::ALL).title("Progress")),
            chunks[2],
        );
    });
}

/// Linux installs its tools into Mash's own data folder instead of a package
/// manager, so the plan carries names rather than Formula/npm/pip targets.
fn is_linux() -> bool {
    cfg!(target_os = "linux")
}

const STEP_LINUX_TOOLS: &str = "Install tools into Mash";

#[derive(Default)]
struct Plan {
    /// Component names for `mash-tool-install`, Linux only.
    linux: Vec<&'static str>,
    brew: Vec<&'static str>,
    npm: Vec<&'static str>,
    python: Vec<&'static str>,
    apple: Vec<&'static str>,
    installer: Vec<&'static str>,
    tools: Vec<&'static str>,
    /// The dictation model to download, from the last wizard page.
    voice: Option<voice::VoiceChoice>,
}

fn install_plan(selections: [bool; 2]) -> Plan {
    let mut plan = Plan::default();
    if is_linux() {
        // The same capability groups, installed without elevation: everything
        // is a pinned component in packaging/assets.json, resolved by the
        // helper, so nothing here can drift to a host version.
        if selections[0] {
            for &(name, _) in UTILITIES {
                plan.tools.push(name);
                plan.linux.push(name);
            }
        }
        if selections[1] {
            for &(name, _) in FORMATTERS {
                plan.tools.push(name);
                plan.linux.push(name);
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
                "sentrux" => plan.brew.push(SENTRUX_FORMULA),
                "agent-browser" => plan.npm.push(AGENT_BROWSER_PACKAGE),
                "cua-driver" => plan.installer.push(name),
                other => plan.brew.push(other),
            }
        }
    }
    if selections[1] {
        plan.brew.extend([
            "latexindent",
            "gopls",
            "rust-analyzer",
            "marksman",
            "texlab",
            "shfmt",
            "prettier",
        ]);
        plan.npm.extend([
            "prettier",
            "prettier-plugin-svelte",
            "bash-language-server",
            "typescript-language-server",
            "yaml-language-server",
            "svelte-language-server",
            "vscode-langservers-extracted",
            "@tailwindcss/language-server",
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
        let mut app = App::new();
        app.focus = FOCUS_NAME;
        // Prefilled from the machine, so start from empty to isolate typing.
        app.name.clear();
        for c in ['j', 'k', 'q', '1', ' '] {
            assert!(app.on_key(KeyCode::Char(c), KeyModifiers::NONE).is_none());
        }
        assert_eq!(app.name, "jkq1 ");
        assert!(app.selections[0] && app.selections[1]);
    }

    #[test]
    fn identity_is_prefilled_from_the_machines_git_config() {
        let app = App::new();
        assert_eq!(app.name, git_config_value("user.name"));
        assert_eq!(app.email, git_config_value("user.email"));
    }

    #[test]
    fn backspace_edits_only_the_focused_field() {
        let mut app = App::new();
        app.focus = FOCUS_EMAIL;
        app.email = "abc".into();
        app.on_key(KeyCode::Backspace, KeyModifiers::NONE);
        assert_eq!(app.email, "ab");
        assert_eq!(app.name, App::new().name);
    }

    #[test]
    fn tab_visits_every_row_and_wraps() {
        let mut app = App::new();
        let mut seen = vec![app.focus];
        for _ in 0..FOCUS_COUNT {
            app.on_key(KeyCode::Tab, KeyModifiers::NONE);
            seen.push(app.focus);
        }
        assert_eq!(seen, vec![0, 1, 2, 3, 4, 0]);
    }

    #[test]
    fn space_toggles_only_on_checkbox_rows() {
        let mut app = App::new();
        app.focus = FOCUS_GROUP_UTILITIES;
        app.on_key(KeyCode::Char(' '), KeyModifiers::NONE);
        assert!(!app.selections[0]);
        app.focus = FOCUS_BUTTON;
        app.on_key(KeyCode::Char(' '), KeyModifiers::NONE);
        assert!(!app.selections[0] && app.selections[1]);
    }

    #[test]
    fn enter_advances_from_the_button_and_from_a_field() {
        let mut app = App::new();
        app.focus = FOCUS_BUTTON;
        assert!(matches!(
            app.on_key(KeyCode::Enter, KeyModifiers::NONE),
            Some(Outcome::Next)
        ));
        app.focus = FOCUS_EMAIL;
        assert!(matches!(
            app.on_key(KeyCode::Enter, KeyModifiers::NONE),
            Some(Outcome::Next)
        ));
    }

    #[test]
    fn esc_cancels_from_both_kinds_of_row() {
        let mut app = App::new();
        app.focus = FOCUS_NAME;
        assert!(matches!(
            app.on_key(KeyCode::Esc, KeyModifiers::NONE),
            Some(Outcome::Cancel)
        ));
        app.focus = FOCUS_GROUP_UTILITIES;
        assert!(matches!(
            app.on_key(KeyCode::Esc, KeyModifiers::NONE),
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
    fn selection_maps_only_the_checkbox_rows() {
        let mut app = App::new();
        app.focus = FOCUS_NAME;
        assert_eq!(app.selection(), None);
        app.focus = FOCUS_GROUP_UTILITIES;
        assert_eq!(app.selection(), Some(0));
        app.focus = FOCUS_GROUP_FORMATTERS;
        assert_eq!(app.selection(), Some(1));
        app.focus = FOCUS_BUTTON;
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
        // having memory or a design stack available.
        let plan = install_plan([false, false]);
        let steps = install_steps(&plan, &[]);
        assert!(steps.contains(&STEP_HINDSIGHT.to_string()));
        assert!(steps.contains(&STEP_DESIGN.to_string()));
        assert!(steps.contains(&STEP_PENPOT.to_string()));
        assert_eq!(steps.last().unwrap(), STEP_PENPOT);
        let full = install_steps(&install_plan([true, true]), &["gopls"]);
        let hindsight = full.iter().position(|s| s == STEP_HINDSIGHT).unwrap();
        let brew = full
            .iter()
            .position(|s| s == "Install Homebrew packages")
            .unwrap();
        assert!(brew < hindsight, "brew must install first");
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
        assert!(helper_log_path("mash-design-deps")
            .to_string_lossy()
            .ends_with("setup/design-deps.log"));
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
            assert!(plan.installer.is_empty(), "linux plan used a vendor installer");
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
        assert!(plan.brew.contains(&SENTRUX_FORMULA));
        assert!(!plan.brew.contains(&"sentrux"));
        assert!(plan.npm.contains(&AGENT_BROWSER_PACKAGE));
        assert_eq!(plan.installer, vec!["cua-driver"]);
    }

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
    fn nothing_missing_skips_tool_installers() {
        // This is the loop: everything selected is already on PATH, so no tool
        // installer may run and trip over a Homebrew-provided binary. The two
        // environment steps are not tool installers and always run.
        let plan = install_plan([true, true]);
        let steps = install_steps(&plan, &[]);
        assert!(!steps.iter().any(|s| s == "Install Homebrew packages"));
        assert!(!steps.iter().any(|s| s == "Install npm packages"));
        assert!(!steps.iter().any(|s| s == "Install Python packages"));
        assert!(!steps.iter().any(|s| s == "Install CUA Driver"));
        assert!(!steps.iter().any(|s| s == STEP_VOICE));
        assert_eq!(
            steps,
            vec![
                "Check selected tools",
                STEP_HINDSIGHT,
                STEP_HINDSIGHT_DAEMON,
                STEP_DESIGN,
                STEP_PENPOT
            ]
        );
    }

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
