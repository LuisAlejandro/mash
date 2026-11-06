//! The Tools page: one checkbox per tool, with how each one is installed.
//!
//! Tools Mash ships, and on Linux the ones its package depends on, are listed
//! too, checked and greyed out: they are present whatever the page says. The
//! optional Programming Skills suite is chosen here as well, below the tools.
use crate::{i18n, wizard_style};
use ratatui::{
    crossterm::event::{KeyCode, KeyModifiers},
    layout::{Constraint, Layout},
    style::{Modifier, Style},
    text::{Line, Span},
    Frame,
};
use std::path::Path;

/// How a tool reaches the machine on one platform.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Route {
    /// Inside the Mash bundle or package; always present.
    Bundled,
    /// A dependency of Mash's `.deb`, so apt installed it with Mash.
    Apt,
    /// A Homebrew formula, installed into the machine's own Homebrew prefix.
    Brew(&'static str),
    /// Manifest components for `mash-tool-install`, pinned by Mash and kept
    /// under `~/.mash`, where only Mash's panes resolve them.
    Mash(How, &'static [&'static str]),
    /// CUA Driver's own installer, which writes to `~/.local/bin`.
    Installer,
    /// Part of Apple's developer tools; Mash only checks for it.
    Apple,
}

/// Whether a route leaves the tool on the machine for every program, or only
/// inside Mash. The page says which, because an install the user did not want
/// system-wide is not something a checkbox should do quietly.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scope {
    Shared,
    MashOnly,
}

/// The kind of artifact behind a `Route::Mash` component, for the label.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum How {
    Download,
    Npm,
    Pip,
}

impl Route {
    /// Present whatever the page says, so its checkbox cannot be cleared.
    pub fn locked(self) -> bool {
        matches!(self, Route::Bundled | Route::Apt)
    }

    pub fn scope(self) -> Scope {
        match self {
            Route::Bundled | Route::Mash(..) => Scope::MashOnly,
            Route::Apt | Route::Brew(_) | Route::Installer | Route::Apple => Scope::Shared,
        }
    }

    /// The installer, then where the tool ends up.
    fn label(self) -> String {
        let installer = match self {
            Route::Bundled => i18n::t("wizard.tools.route.bundled"),
            Route::Apt => i18n::t("wizard.tools.route.apt"),
            Route::Brew(_) => i18n::t("wizard.tools.route.homebrew"),
            Route::Mash(How::Download, _) => i18n::t("wizard.tools.route.download"),
            Route::Mash(How::Npm, _) => i18n::t("wizard.tools.route.npm"),
            Route::Mash(How::Pip, _) => i18n::t("wizard.tools.route.pip"),
            Route::Installer => i18n::t("wizard.tools.route.cua"),
            Route::Apple => i18n::t("wizard.tools.route.xcode"),
        };
        let scope = match self.scope() {
            Scope::Shared => i18n::t("wizard.tools.scope.shared"),
            Scope::MashOnly => i18n::t("wizard.tools.scope.mash_only"),
        };
        format!("{installer} ({scope})")
    }
}

pub struct Tool {
    pub name: &'static str,
    pub description: &'static str,
    /// What the availability check looks for; empty means `name`.
    pub binaries: &'static [&'static str],
    pub macos: Option<Route>,
    pub linux: Option<Route>,
}

impl Tool {
    /// This platform's route, or None when the tool is not offered here.
    pub fn route(&self) -> Option<Route> {
        if cfg!(target_os = "linux") {
            self.linux
        } else {
            self.macos
        }
    }

    pub fn binaries(&self) -> &[&'static str] {
        if self.binaries.is_empty() {
            std::slice::from_ref(&self.name)
        } else {
            self.binaries
        }
    }

    fn description_text(&self) -> String {
        match self.name {
            "agent-browser" => i18n::t("wizard.tools.description.agent-browser"),
            "atuin" => i18n::t("wizard.tools.description.atuin"),
            "bash-language-server" => i18n::t("wizard.tools.description.bash-language-server"),
            "bat" => i18n::t("wizard.tools.description.bat"),
            "clangd" => i18n::t("wizard.tools.description.clangd"),
            "cua-driver" => i18n::t("wizard.tools.description.cua-driver"),
            "delta" => i18n::t("wizard.tools.description.delta"),
            "eza" => i18n::t("wizard.tools.description.eza"),
            "fd" => i18n::t("wizard.tools.description.fd"),
            "fresh" => i18n::t("wizard.tools.description.fresh"),
            "fzf" => i18n::t("wizard.tools.description.fzf"),
            "gh" => i18n::t("wizard.tools.description.gh"),
            "git" => i18n::t("wizard.tools.description.git"),
            "gopls" => i18n::t("wizard.tools.description.gopls"),
            "herdr" => i18n::t("wizard.tools.description.herdr"),
            "jq" => i18n::t("wizard.tools.description.jq"),
            "latexindent" => i18n::t("wizard.tools.description.latexindent"),
            "lazydocker" => i18n::t("wizard.tools.description.lazydocker"),
            "lazygit" => i18n::t("wizard.tools.description.lazygit"),
            "marksman" => i18n::t("wizard.tools.description.marksman"),
            "node" => i18n::t("wizard.tools.description.node"),
            "pet" => i18n::t("wizard.tools.description.pet"),
            "pi" => i18n::t("wizard.tools.description.pi"),
            "prettier" => i18n::t("wizard.tools.description.prettier"),
            "python" => i18n::t("wizard.tools.description.python"),
            "python-lsp-server" => i18n::t("wizard.tools.description.python-lsp-server"),
            "rg" => i18n::t("wizard.tools.description.rg"),
            "rust-analyzer" => i18n::t("wizard.tools.description.rust-analyzer"),
            "sentrux" => i18n::t("wizard.tools.description.sentrux"),
            "shfmt" => i18n::t("wizard.tools.description.shfmt"),
            "sourcekit-lsp" => i18n::t("wizard.tools.description.sourcekit-lsp"),
            "starship" => i18n::t("wizard.tools.description.starship"),
            "svelte-language-server" => i18n::t("wizard.tools.description.svelte-language-server"),
            "tailwindcss-language-server" => {
                i18n::t("wizard.tools.description.tailwindcss-language-server")
            }
            "texlab" => i18n::t("wizard.tools.description.texlab"),
            "typescript-language-server" => {
                i18n::t("wizard.tools.description.typescript-language-server")
            }
            "viu" => i18n::t("wizard.tools.description.viu"),
            "vscode-css-language-server" => {
                i18n::t("wizard.tools.description.vscode-css-language-server")
            }
            "vscode-html-language-server" => {
                i18n::t("wizard.tools.description.vscode-html-language-server")
            }
            "vscode-json-language-server" => {
                i18n::t("wizard.tools.description.vscode-json-language-server")
            }
            "yaml-language-server" => i18n::t("wizard.tools.description.yaml-language-server"),
            "zoxide" => i18n::t("wizard.tools.description.zoxide"),
            _ => self.description.to_string(),
        }
    }
}

const fn tool(
    name: &'static str,
    description: &'static str,
    macos: Option<Route>,
    linux: Option<Route>,
) -> Tool {
    Tool {
        name,
        description,
        binaries: &[],
        macos,
        linux,
    }
}

const fn npm(components: &'static [&'static str]) -> Option<Route> {
    Some(Route::Mash(How::Npm, components))
}

const fn download(components: &'static [&'static str]) -> Option<Route> {
    Some(Route::Mash(How::Download, components))
}

const BUNDLED: Option<Route> = Some(Route::Bundled);
const APT: Option<Route> = Some(Route::Apt);

// Alphabetical, which is the order the page shows. Every component named here
// is a packaging/assets.json component; the pinned version is resolved from
// the manifest at install time, so no version is written here.
pub const TOOLS: &[Tool] = &[
    tool(
        "agent-browser",
        "Browser automation for page work",
        npm(&["agent-browser"]),
        npm(&["agent-browser"]),
    ),
    tool("atuin", "Searchable shell history", BUNDLED, BUNDLED),
    tool(
        "bash-language-server",
        "Bash language server",
        npm(&["bash-language-server"]),
        npm(&["bash-language-server"]),
    ),
    tool(
        "bat",
        "Highlighted file preview",
        Some(Route::Brew("bat")),
        APT,
    ),
    tool(
        "clangd",
        "C and C++ language server",
        Some(Route::Apple),
        None,
    ),
    tool(
        "cua-driver",
        "Native desktop control for app surfaces",
        Some(Route::Installer),
        download(&["cua-driver"]),
    ),
    tool(
        "delta",
        "Git diff and pager",
        Some(Route::Brew("delta")),
        APT,
    ),
    tool("eza", "File listings", Some(Route::Brew("eza")), APT),
    tool("fd", "File discovery", Some(Route::Brew("fd")), APT),
    tool("fresh", "Mash's editor", BUNDLED, BUNDLED),
    tool(
        "fzf",
        "Interactive fuzzy picker",
        Some(Route::Brew("fzf")),
        APT,
    ),
    tool("gh", "GitHub CLI and credential helper", BUNDLED, BUNDLED),
    tool("git", "Git source control", Some(Route::Brew("git")), APT),
    tool(
        "gopls",
        "Go language server",
        Some(Route::Brew("gopls")),
        APT,
    ),
    tool("herdr", "Workspaces, tabs and panes", BUNDLED, BUNDLED),
    tool("jq", "JSON utility", Some(Route::Brew("jq")), APT),
    tool(
        "latexindent",
        "LaTeX formatting",
        download(&["latexindent"]),
        download(&["latexindent"]),
    ),
    tool("lazydocker", "Docker in the terminal", BUNDLED, BUNDLED),
    tool("lazygit", "Git in the terminal", BUNDLED, BUNDLED),
    tool(
        "marksman",
        "Markdown language server",
        download(&["marksman"]),
        download(&["marksman"]),
    ),
    tool("node", "JavaScript runtime and npm", BUNDLED, BUNDLED),
    tool("pet", "Command snippets", BUNDLED, BUNDLED),
    tool("pi", "Mash's coding agent", BUNDLED, BUNDLED),
    // No binary of its own: the Svelte plugin has to sit in the same npm prefix
    // as prettier or `prettier --stdin-filepath x.svelte` cannot load it, and
    // defaults/fresh/config.json formats svelte on save with exactly that.
    tool(
        "prettier",
        "JavaScript, JSON, Markdown, CSS and Svelte formatting",
        npm(&["prettier", "prettier-plugin-svelte"]),
        npm(&["prettier", "prettier-plugin-svelte"]),
    ),
    Tool {
        binaries: &["python3"],
        ..tool("python", "Python runtime and pip", BUNDLED, BUNDLED)
    },
    Tool {
        binaries: &["pylsp"],
        ..tool(
            "python-lsp-server",
            "Python language server",
            Some(Route::Mash(How::Pip, &["python-lsp-server"])),
            Some(Route::Mash(How::Pip, &["python-lsp-server"])),
        )
    },
    tool("rg", "Content search", Some(Route::Brew("rg")), APT),
    tool(
        "rust-analyzer",
        "Rust language server",
        download(&["rust-analyzer"]),
        download(&["rust-analyzer"]),
    ),
    tool(
        "sentrux",
        "Structural analysis for plan, work and qa",
        download(&["sentrux"]),
        download(&["sentrux"]),
    ),
    tool("shfmt", "Shell formatting", Some(Route::Brew("shfmt")), APT),
    tool(
        "sourcekit-lsp",
        "Swift language server",
        Some(Route::Apple),
        None,
    ),
    tool("starship", "Shell prompt", BUNDLED, BUNDLED),
    Tool {
        binaries: &["svelteserver"],
        ..tool(
            "svelte-language-server",
            "Svelte language server",
            npm(&["svelte-language-server"]),
            npm(&["svelte-language-server"]),
        )
    },
    tool(
        "tailwindcss-language-server",
        "Tailwind CSS language server",
        npm(&["tailwindcss-language-server"]),
        npm(&["tailwindcss-language-server"]),
    ),
    tool(
        "texlab",
        "LaTeX language server",
        download(&["texlab"]),
        download(&["texlab"]),
    ),
    tool(
        "typescript-language-server",
        "TypeScript and JavaScript language server",
        npm(&["typescript-language-server"]),
        npm(&["typescript-language-server"]),
    ),
    tool("viu", "Images in the terminal", BUNDLED, BUNDLED),
    // These have separate checkboxes but share one npm package. The plan
    // installs that package once, even when several of its servers are chosen.
    tool(
        "vscode-css-language-server",
        "CSS server (shared CSS/HTML/JSON package)",
        npm(&["vscode-langservers-extracted"]),
        npm(&["vscode-langservers-extracted"]),
    ),
    tool(
        "vscode-html-language-server",
        "HTML server (shared CSS/HTML/JSON package)",
        npm(&["vscode-langservers-extracted"]),
        npm(&["vscode-langservers-extracted"]),
    ),
    tool(
        "vscode-json-language-server",
        "JSON server (shared CSS/HTML/JSON package)",
        npm(&["vscode-langservers-extracted"]),
        npm(&["vscode-langservers-extracted"]),
    ),
    tool(
        "yaml-language-server",
        "YAML language server",
        npm(&["yaml-language-server"]),
        npm(&["yaml-language-server"]),
    ),
    tool(
        "zoxide",
        "Smarter directory ranking",
        Some(Route::Brew("zoxide")),
        APT,
    ),
];

pub enum Decision {
    Back,
    Cancel,
    Next,
}

pub struct ToolsPage {
    /// The tools this platform offers, in page order.
    rows: Vec<&'static Tool>,
    selected: Vec<bool>,
    /// Install the Programming Skills suite (with its local memory).
    programming: bool,
    /// Homebrew rows start unchecked, with a note, on a Mac without it.
    homebrew: bool,
    /// An index into `rows`, the skills checkbox, or one of the two buttons.
    pub focus: usize,
}

impl ToolsPage {
    pub fn new() -> Self {
        Self::with_homebrew(crate::find_brew().is_some())
    }

    // Mash never installs Homebrew itself; a missing one would abort setup.
    pub fn with_homebrew(homebrew: bool) -> Self {
        let rows: Vec<&'static Tool> = TOOLS.iter().filter(|tool| tool.route().is_some()).collect();
        let selected = rows
            .iter()
            .map(|tool| homebrew || !matches!(tool.route(), Some(Route::Brew(_))))
            .collect();
        let mut page = Self {
            rows,
            selected,
            programming: true,
            homebrew,
            focus: 0,
        };
        page.focus = page.focusable()[0];
        page
    }

    pub fn back_id(&self) -> usize {
        self.rows.len()
    }

    fn skills_id(&self) -> usize {
        self.rows.len() + 2
    }

    pub fn programming(&self) -> bool {
        self.programming
    }

    // Set only after all wizard pages are complete. Before this file exists,
    // launchers cannot know the choice and must seed no optional suite.
    pub fn save_selection(&self, root: &Path) -> Result<(), String> {
        crate::provider_page::write_private(
            &root.join("setup/skills-choice"),
            &format!("programming={}\n", self.programming),
        )
    }

    pub fn next_id(&self) -> usize {
        self.rows.len() + 1
    }

    /// The tools to install: checked, and not already present by design.
    pub fn chosen(&self) -> Vec<&'static Tool> {
        self.rows
            .iter()
            .zip(&self.selected)
            .filter(|(tool, selected)| **selected && !Self::locked(tool))
            .map(|(tool, _)| *tool)
            .collect()
    }

    fn locked(tool: &Tool) -> bool {
        tool.route().is_some_and(Route::locked)
    }

    /// Locked rows are skipped: there is nothing to do on them.
    fn focusable(&self) -> Vec<usize> {
        (0..self.rows.len())
            .filter(|index| !Self::locked(self.rows[*index]))
            .chain([self.skills_id(), self.back_id(), self.next_id()])
            .collect()
    }

    fn toggle(&mut self, index: usize) {
        if index < self.rows.len() && !Self::locked(self.rows[index]) {
            self.selected[index] = !self.selected[index];
        }
    }

    fn move_focus(&mut self, direction: isize, wrap: bool) {
        let ids = self.focusable();
        let current = ids.iter().position(|id| *id == self.focus).unwrap_or(0);
        self.focus = ids[wizard_style::focus_step(current, ids.len(), direction, wrap)];
    }

    /// A click focuses and toggles a row, or presses a button.
    pub fn on_click(&mut self, id: usize) -> Option<Decision> {
        if !self.focusable().contains(&id) {
            return None;
        }
        self.focus = id;
        self.press()
    }

    fn press(&mut self) -> Option<Decision> {
        if self.focus == self.back_id() {
            Some(Decision::Back)
        } else if self.focus == self.next_id() {
            Some(Decision::Next)
        } else if self.focus == self.skills_id() {
            self.programming = !self.programming;
            None
        } else {
            self.toggle(self.focus);
            None
        }
    }

    pub fn on_key(&mut self, code: KeyCode, modifiers: KeyModifiers) -> Option<Decision> {
        if modifiers.contains(KeyModifiers::CONTROL) && code == KeyCode::Char('c') {
            return Some(Decision::Cancel);
        }
        match code {
            KeyCode::Esc | KeyCode::Char('q') => Some(Decision::Cancel),
            KeyCode::Down | KeyCode::Char('j') => {
                self.move_focus(1, false);
                None
            }
            KeyCode::Up | KeyCode::Char('k') => {
                self.move_focus(-1, false);
                None
            }
            KeyCode::Tab => {
                self.move_focus(1, true);
                None
            }
            KeyCode::BackTab => {
                self.move_focus(-1, true);
                None
            }
            KeyCode::Char(' ') | KeyCode::Enter => self.press(),
            _ => None,
        }
    }

    pub fn draw(&self, frame: &mut Frame) {
        let parts = Layout::vertical([
            Constraint::Length(3),
            Constraint::Min(8),
            Constraint::Length(5),
            Constraint::Length(3),
        ])
        .split(wizard_style::page_area(frame, Some(1)));
        wizard_style::header(
            frame,
            parts[0],
            &wizard_style::page_title(&i18n::t("wizard.tools.title"), 1),
        );

        let name_width = if parts[1].width >= 100 {
            self.rows
                .iter()
                .map(|tool| tool.name.len())
                .max()
                .unwrap_or(0)
        } else {
            0
        };
        let mut lines: Vec<(Line<'static>, Option<usize>)> = vec![
            (Line::from(i18n::t("wizard.tools.intro")), None),
            (
                Line::from(Span::styled(
                    i18n::t("wizard.tools.mash_only"),
                    Style::default().fg(wizard_style::MUTED),
                )),
                None,
            ),
            (
                Line::from(Span::styled(
                    i18n::t("wizard.tools.shared"),
                    Style::default().fg(wizard_style::MUTED),
                )),
                None,
            ),
        ];
        if !self.homebrew
            && self
                .rows
                .iter()
                .any(|tool| matches!(tool.route(), Some(Route::Brew(_))))
        {
            lines.push((
                Line::from(Span::styled(
                    i18n::t("wizard.tools.no_homebrew"),
                    Style::default().fg(wizard_style::YELLOW),
                )),
                None,
            ));
        }
        lines.push((Line::from(""), None));
        for (index, tool) in self.rows.iter().enumerate() {
            let route = tool.route().expect("rows only hold offered tools");
            let locked = route.locked();
            let checked = locked || self.selected[index];
            let mut line = wizard_style::checkbox(
                self.focus == index,
                &format!("{:<name_width$}", tool.name),
                checked,
            );
            line.spans
                .push(Span::raw(format!("  {}", tool.description_text())));
            line.spans.push(Span::styled(
                format!("  · {}", route.label()),
                Style::default().fg(wizard_style::MUTED),
            ));
            if locked {
                // Grey the whole row, checkbox included, so it reads as fixed.
                for span in &mut line.spans {
                    span.style = Style::default()
                        .fg(wizard_style::MUTED)
                        .remove_modifier(Modifier::BOLD);
                }
            }
            lines.push((line, (!locked).then_some(index)));
        }

        let body = wizard_style::section(frame, parts[1], &i18n::t("wizard.tools.choices"));
        wizard_style::render_form(frame, body, lines, true);

        let skills = wizard_style::section(frame, parts[2], &i18n::t("wizard.tools.skills"));
        wizard_style::render_form(
            frame,
            skills,
            vec![
                (
                    wizard_style::checkbox(
                        self.focus == self.skills_id(),
                        &i18n::t("wizard.tools.skills_check"),
                        self.programming,
                    ),
                    Some(self.skills_id()),
                ),
                (
                    Line::from(Span::styled(
                        format!("    {}", i18n::t("wizard.tools.skills_help")),
                        Style::default().fg(wizard_style::MUTED),
                    )),
                    None,
                ),
            ],
            true,
        );
        wizard_style::render_buttons(
            frame,
            parts[3],
            &[
                (
                    wizard_style::button(
                        self.focus == self.back_id(),
                        &format!(" {} ", i18n::t("wizard.tools.back")),
                    ),
                    Some(self.back_id()),
                ),
                (Span::raw("    "), None),
                (
                    wizard_style::button(
                        self.focus == self.next_id(),
                        &format!(" {} ", i18n::t("wizard.tools.next")),
                    ),
                    Some(self.next_id()),
                ),
            ],
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TempDir;
    use ratatui::{backend::TestBackend, Terminal};

    /// Wide and tall enough that every row is on screen unwrapped, so a test
    /// can assert about the whole list and about labels as one piece. The
    /// wrapped case is covered by long_list_scrolls_without_losing_click_targets.
    fn render(page: &ToolsPage) -> (ratatui::buffer::Buffer, String) {
        // The tool rows, the legend, the Skills section and the buttons.
        let height = TOOLS.len() as u16 + 20;
        let mut terminal = Terminal::new(TestBackend::new(200, height)).unwrap();
        terminal.draw(|frame| page.draw(frame)).unwrap();
        let buffer = terminal.backend().buffer().clone();
        let text = buffer.content().iter().map(|cell| cell.symbol()).collect();
        (buffer, text)
    }

    #[test]
    fn missing_homebrew_unchecks_its_tools_and_says_why() {
        let page = ToolsPage::with_homebrew(false);
        let brew = |tool: &&Tool| matches!(tool.route(), Some(Route::Brew(_)));
        assert!(!page.chosen().iter().any(brew));
        let (_, text) = render(&page);
        if page.rows.iter().any(brew) {
            assert!(text.contains("Homebrew was not found"), "{text}");
        }
        // Mash-owned tools stay checked; Homebrew tools are opt-in again.
        assert!(page.chosen().iter().any(|tool| !brew(tool)));
        let (_, text) = render(&ToolsPage::with_homebrew(true));
        assert!(!text.contains("Homebrew was not found"));
    }

    #[test]
    fn every_row_says_whether_the_tool_leaves_mash() {
        let (_, text) = render(&ToolsPage::with_homebrew(true));
        assert!(text.contains("Mash only: kept under ~/.mash"));
        assert!(text.contains("On your computer: installed system-wide"));
        for route in TOOLS.iter().filter_map(Tool::route) {
            let label = route.label();
            assert!(text.contains(&label), "{label} is missing from the page");
            match route.scope() {
                Scope::Shared => assert!(label.ends_with("(your computer)"), "{label}"),
                Scope::MashOnly => assert!(label.ends_with("(Mash only)"), "{label}"),
            }
        }
        // A Homebrew formula and a pinned download must not read alike: one
        // changes the machine, the other only what Mash's panes resolve.
        let brewed = TOOLS
            .iter()
            .find(|tool| matches!(tool.route(), Some(Route::Brew(_))));
        let pinned = TOOLS
            .iter()
            .find(|tool| matches!(tool.route(), Some(Route::Mash(How::Download, _))));
        if let (Some(brewed), Some(pinned)) = (brewed, pinned) {
            assert_eq!(brewed.route().unwrap().scope(), Scope::Shared);
            assert_eq!(pinned.route().unwrap().scope(), Scope::MashOnly);
            assert_ne!(
                brewed.route().unwrap().label(),
                pinned.route().unwrap().label()
            );
        }
    }

    #[test]
    fn the_list_is_alphabetical_and_names_are_unique() {
        let names: Vec<_> = TOOLS.iter().map(|tool| tool.name).collect();
        let mut sorted = names.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(names, sorted);
    }

    #[test]
    fn mash_routes_name_manifest_components_not_package_specs() {
        let manifest: serde_json::Value =
            serde_json::from_str(include_str!("../assets.json")).unwrap();
        for tool in TOOLS {
            for route in [tool.macos, tool.linux].into_iter().flatten() {
                if let Route::Mash(_, components) = route {
                    for component in components {
                        assert!(
                            manifest["components"][component].is_object(),
                            "{component} ({}) is not a manifest component",
                            tool.name
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn bundled_tools_match_the_manifest_and_companion_build_loop() {
        let manifest: serde_json::Value =
            serde_json::from_str(include_str!("../assets.json")).unwrap();
        for tool in TOOLS.iter().filter(|tool| tool.macos == BUNDLED) {
            assert_eq!(
                tool.linux, BUNDLED,
                "{} is bundled on one platform only",
                tool.name
            );
            assert_eq!(manifest["components"][tool.name]["install"], "bundled");
        }
        let staged = include_str!("../build-common.sh")
            .lines()
            .find_map(|line| line.trim().strip_prefix("for tool in "))
            .unwrap()
            .split(';')
            .next()
            .unwrap();
        for name in staged.split_whitespace() {
            assert!(
                TOOLS
                    .iter()
                    .any(|tool| tool.name == name && tool.macos == BUNDLED),
                "the build stages {name} but the Tools page does not list it as bundled"
            );
        }
    }

    #[test]
    fn apt_tools_are_the_packages_dependencies() {
        let build = include_str!("../build-linux.sh");
        let deps = build
            .lines()
            .find_map(|line| line.strip_prefix("host_utilities=\""))
            .expect("build-linux.sh lists host_utilities")
            .trim_end_matches('"');
        // The Debian names that differ from the command they provide.
        let debian = |name: &'static str| match name {
            "fd" => "fd-find",
            "rg" => "ripgrep",
            "delta" => "git-delta",
            other => other,
        };
        let packages: Vec<_> = deps.split(", ").collect();
        let apt: Vec<_> = TOOLS
            .iter()
            .filter(|tool| tool.linux == APT)
            .map(|tool| debian(tool.name))
            .collect();
        for package in &packages {
            assert!(
                apt.contains(package),
                "{package} is an apt dependency but not listed as one"
            );
        }
        for package in &apt {
            assert!(
                packages.contains(package),
                "{package} is marked apt but the .deb does not depend on it"
            );
        }
    }

    #[test]
    fn locked_rows_are_checked_greyed_and_cannot_be_changed() {
        let mut page = ToolsPage::with_homebrew(true);
        let gh = page.rows.iter().position(|tool| tool.name == "gh").unwrap();
        let (_, text) = render(&page);
        assert!(text.contains("ships in Mash (Mash only)"));
        // Not focusable from the keyboard, and a click does nothing.
        assert!(!page.focusable().contains(&gh));
        assert!(page.on_click(gh).is_none());
        assert!(!page.chosen().iter().any(|tool| tool.name == "gh"));
        let (buffer, _) = render(&page);
        let (x, y) = wizard_style::tests::find(&buffer, "gh ");
        assert_eq!(buffer[(x - 4, y)].symbol(), "[");
        assert_eq!(buffer[(x - 3, y)].symbol(), "x");
        assert_eq!(buffer[(x, y)].fg, wizard_style::MUTED);
    }

    #[test]
    fn each_row_toggles_on_its_own_and_shows_how_it_installs() {
        let mut page = ToolsPage::with_homebrew(true);
        let all = page.chosen().len();
        let sentrux = page
            .rows
            .iter()
            .position(|tool| tool.name == "sentrux")
            .unwrap();
        let (buffer, text) = render(&page);
        assert!(text.contains("pinned download (Mash only)"));
        let (hint_x, hint_y) = wizard_style::tests::find(&buffer, "pinned npm");
        assert_eq!(buffer[(hint_x, hint_y)].fg, wizard_style::MUTED);
        let (x, y) = wizard_style::tests::find(&buffer, "sentrux ");
        let id = wizard_style::clicked(&wizard_style::tests::click(x, y)).unwrap();
        assert_eq!(id, sentrux);
        assert!(page.on_click(id).is_none());
        assert_eq!(page.chosen().len(), all - 1);
        assert!(!page.chosen().iter().any(|tool| tool.name == "sentrux"));
        page.on_key(KeyCode::Char(' '), KeyModifiers::NONE);
        assert_eq!(page.chosen().len(), all);
    }

    #[test]
    fn every_locked_tool_ignores_keyboard_and_mouse_toggles() {
        let mut page = ToolsPage::with_homebrew(true);
        let (buffer, _) = render(&page);
        for index in 0..page.rows.len() {
            if !ToolsPage::locked(page.rows[index]) {
                continue;
            }
            let before = page.focus;
            page.toggle(index);
            assert!(page.on_click(index).is_none());
            assert!(page.selected[index]);
            assert_eq!(page.focus, before);
            let (x, y) = wizard_style::tests::find(&buffer, &format!("{} ", page.rows[index].name));
            assert_eq!(buffer[(x - 3, y)].symbol(), "x");
            assert_eq!(buffer[(x - 3, y)].fg, wizard_style::MUTED);
            assert_eq!(
                wizard_style::clicked(&wizard_style::tests::click(x, y)),
                None
            );
        }
    }

    #[test]
    fn long_list_scrolls_without_losing_click_targets() {
        for (width, height) in [(80, 24), (100, 30)] {
            let mut page = ToolsPage::with_homebrew(true);
            let last_tool = page
                .focusable()
                .into_iter()
                .rfind(|index| *index < page.rows.len())
                .unwrap();
            page.focus = last_tool;
            let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
            terminal.draw(|frame| page.draw(frame)).unwrap();
            let (x, y) =
                wizard_style::tests::find(terminal.backend().buffer(), page.rows[last_tool].name);
            let target = wizard_style::clicked(&wizard_style::tests::click(x, y)).unwrap();
            assert_eq!(target, last_tool);
            page.on_click(target);
            assert!(!page.selected[last_tool]);
            assert!(
                page.selected[0],
                "toggling a scrolled row must not change the first tool"
            );
        }
    }

    #[test]
    fn the_skills_suite_is_a_separate_section_below_the_tools() {
        let mut page = ToolsPage::with_homebrew(true);
        assert!(page.programming(), "on by default");
        let (buffer, _) = render(&page);
        let (_, last_tool) = wizard_style::tests::find(&buffer, page.rows.last().unwrap().name);
        let (_, section) = wizard_style::tests::find(&buffer, "Skills");
        let (x, row) = wizard_style::tests::find(&buffer, "Install Programming Skills");
        assert!(
            last_tool < section && section < row,
            "a section of its own, after the list"
        );
        let id = wizard_style::clicked(&wizard_style::tests::click(x, row)).unwrap();
        assert!(page.on_click(id).is_none());
        assert!(!page.programming());
        // Toggling the suite never changes which tools install.
        assert_eq!(
            page.chosen().len(),
            ToolsPage::with_homebrew(true).chosen().len()
        );
        page.focus = id;
        page.on_key(KeyCode::Char(' '), KeyModifiers::NONE);
        assert!(page.programming());
    }

    #[test]
    fn the_skills_choice_is_written_privately() {
        use std::os::unix::fs::PermissionsExt;
        let root = TempDir::new("skills-choice");
        std::fs::create_dir_all(root.join("setup")).unwrap();
        let mut page = ToolsPage::with_homebrew(true);
        page.save_selection(&root).unwrap();
        assert_eq!(
            std::fs::read_to_string(root.join("setup/skills-choice")).unwrap(),
            "programming=true\n"
        );
        let mode = std::fs::metadata(root.join("setup/skills-choice"))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o077, 0, "the choice file stays private");
        page.focus = page.skills_id();
        page.on_key(KeyCode::Enter, KeyModifiers::NONE);
        page.save_selection(&root).unwrap();
        assert_eq!(
            std::fs::read_to_string(root.join("setup/skills-choice")).unwrap(),
            "programming=false\n"
        );
    }

    #[test]
    fn focus_walks_the_selectable_rows_then_the_buttons() {
        let mut page = ToolsPage::with_homebrew(true);
        let ids = page.focusable();
        let mut seen = vec![page.focus];
        for _ in 0..ids.len() {
            page.on_key(KeyCode::Tab, KeyModifiers::NONE);
            seen.push(page.focus);
        }
        assert_eq!(&seen[..ids.len()], ids.as_slice());
        assert_eq!(seen.last(), Some(&ids[0]), "Tab wraps");
        page.focus = page.back_id();
        assert!(matches!(
            page.on_key(KeyCode::Enter, KeyModifiers::NONE),
            Some(Decision::Back)
        ));
        page.focus = page.next_id();
        assert!(matches!(
            page.on_key(KeyCode::Enter, KeyModifiers::NONE),
            Some(Decision::Next)
        ));
        assert!(matches!(
            page.on_key(KeyCode::Esc, KeyModifiers::NONE),
            Some(Decision::Cancel)
        ));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_lists_apple_tools_and_no_apt_ones() {
        let page = ToolsPage::with_homebrew(true);
        assert!(page.rows.iter().any(|tool| tool.name == "sourcekit-lsp"));
        assert!(!page.rows.iter().any(|tool| tool.route() == APT));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_locks_apt_dependencies_and_has_no_apple_tools() {
        let page = ToolsPage::with_homebrew(true);
        assert!(!page.rows.iter().any(|tool| tool.name == "sourcekit-lsp"));
        let (_, text) = render(&page);
        assert!(text.contains("On your computer: installed system-wide"));
        assert!(!page.chosen().iter().any(|tool| tool.name == "git"));
    }
}
