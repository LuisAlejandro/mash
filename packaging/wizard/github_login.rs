//! GitHub sign-in on the identity page.
//!
//! Mash's bundled `gh` runs GitHub's device flow in the background, without a
//! terminal, so it prints its one-time code instead of prompting. The wizard
//! reads that code and draws its own UI; the user never sees `gh` itself.
//! Everything stays in Mash's own `GH_CONFIG_DIR`, and tokens inherited from
//! the environment are ignored so they cannot make Mash look signed in.
use crate::i18n;
use std::{
    ffi::OsString,
    fs,
    io::{BufRead, BufReader, Read},
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::mpsc::{self, Receiver},
    thread,
};

const DEVICE_URL: &str = "https://github.com/login/device";

/// Why GitHub sign-in cannot run. Drawn with `i18n::t` so the wording follows
/// the language chosen later on the first page, not the language at construction.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnavailableReason {
    /// Mash's GitHub config is a symlink, so it is not kept inside Mash.
    ConfigInside,
    /// The bundled `gh` cannot be executed.
    CliUnavailable,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Status {
    /// Sign-in cannot run here; the reason is shown instead of a button.
    Unavailable(UnavailableReason),
    SignedOut,
    /// `gh` is asking GitHub for a code.
    Starting,
    Waiting {
        code: String,
        url: String,
        copied: bool,
    },
    SignedIn(Option<String>),
    Failed(String),
}

pub struct GithubLogin {
    gh: PathBuf,
    config: PathBuf,
    path: OsString,
    status: Status,
    child: Option<Child>,
    output: Option<Receiver<String>>,
    /// The last line `gh` printed, shown when sign-in fails.
    last_line: String,
    open_browser: bool,
    preview: bool,
}

impl GithubLogin {
    /// `gh` is the binary to run, `config` Mash's GitHub config directory and
    /// `path` the PATH `gh` sees. A preview shows the states but never runs it.
    pub fn new(gh: PathBuf, config: PathBuf, path: OsString, preview: bool) -> Self {
        let mut login = Self {
            gh,
            config,
            path,
            status: Status::SignedOut,
            child: None,
            output: None,
            last_line: String::new(),
            open_browser: !preview,
            preview,
        };
        login.status = login.local_status();
        login
    }

    pub fn status(&self) -> &Status {
        &self.status
    }

    pub fn signed_in(&self) -> bool {
        matches!(self.status, Status::SignedIn(_))
    }

    /// True while a sign-in runs, so the caller keeps redrawing without input.
    pub fn busy(&self) -> bool {
        self.child.is_some()
    }

    /// The label of the page's GitHub button for the current state.
    /// The catalog key of the button's label for the current state.
    pub fn button_label_key(&self) -> &'static str {
        match self.status {
            Status::Unavailable(_) | Status::SignedOut => "wizard.github.sign_in",
            Status::Starting | Status::Waiting { .. } => "wizard.github.cancel",
            Status::SignedIn(_) => "wizard.github.sign_out",
            Status::Failed(_) => "wizard.github.retry",
        }
    }

    /// The button: start, cancel, sign out or retry, depending on the state.
    pub fn activate(&mut self) {
        match self.status {
            Status::Unavailable(_) => {}
            Status::SignedOut | Status::Failed(_) => self.start(),
            Status::Starting | Status::Waiting { .. } => self.cancel(),
            Status::SignedIn(_) => self.sign_out(),
        }
    }

    /// What is known without the network: the config's own sign-in.
    fn local_status(&self) -> Status {
        if self.config.is_symlink() || self.config.join("hosts.yml").is_symlink() {
            return Status::Unavailable(UnavailableReason::ConfigInside);
        }
        if self.preview {
            return Status::SignedOut;
        }
        if !self.gh_runs() {
            return Status::Unavailable(UnavailableReason::CliUnavailable);
        }
        // Only Mash's own hosts file counts. `gh auth token` also answers from
        // the system keychain, where the user's personal gh keeps its login
        // whatever GH_CONFIG_DIR says, so it would report that as Mash's.
        if hosts_token(&self.config).is_some() {
            Status::SignedIn(hosts_user(&self.config))
        } else {
            Status::SignedOut
        }
    }

    fn gh_runs(&self) -> bool {
        self.command()
            .arg("--version")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
    }

    fn command(&self) -> Command {
        let mut command = Command::new(&self.gh);
        // The wizard runs before mash_isolate. Inherited tokens must not make the
        // Mash account look signed in or leak into the new login flow.
        command
            .env("PATH", &self.path)
            .env("GH_CONFIG_DIR", &self.config)
            .env("GH_NO_UPDATE_NOTIFIER", "1")
            .env("GH_PROMPT_DISABLED", "1")
            .env_remove("GH_TOKEN")
            .env_remove("GITHUB_TOKEN")
            .env_remove("GH_ENTERPRISE_TOKEN")
            .env_remove("GH_HOST")
            .stdin(Stdio::null());
        command
    }

    fn prepare_config(&self) -> Result<(), String> {
        if self.config.is_symlink() || self.config.join("hosts.yml").is_symlink() {
            return Err(i18n::t("wizard.github.config_inside").into());
        }
        fs::create_dir_all(&self.config).map_err(|e| e.to_string())?;
        fs::set_permissions(&self.config, fs::Permissions::from_mode(0o700))
            .map_err(|e| e.to_string())
    }

    fn start(&mut self) {
        self.last_line.clear();
        if self.preview {
            self.status = Status::Waiting {
                code: "ABCD-1234".into(),
                url: DEVICE_URL.into(),
                copied: true,
            };
            return;
        }
        if let Err(error) = self.prepare_config() {
            self.status = Status::Failed(error);
            return;
        }
        let mut command = self.command();
        command
            .args([
                "auth",
                "login",
                "--hostname",
                "github.com",
                "--web",
                "--git-protocol",
                "https",
                "--insecure-storage",
            ])
            // The wizard opens the browser itself, once, after it has the code;
            // a no-op browser keeps gh from opening a second tab.
            .env("GH_BROWSER", "true")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => {
                self.status = Status::Failed(i18n::fill(
                    &i18n::t("wizard.github.start_failed"),
                    &[("error", &&error.to_string())],
                ));
                return;
            }
        };
        let (sender, receiver) = mpsc::channel();
        for stream in [
            child
                .stdout
                .take()
                .map(|s| Box::new(s) as Box<dyn Read + Send>),
            child
                .stderr
                .take()
                .map(|s| Box::new(s) as Box<dyn Read + Send>),
        ]
        .into_iter()
        .flatten()
        {
            let sender = sender.clone();
            thread::spawn(move || {
                for line in BufReader::new(stream).lines().map_while(Result::ok) {
                    if sender.send(line).is_err() {
                        break;
                    }
                }
            });
        }
        self.child = Some(child);
        self.output = Some(receiver);
        self.status = Status::Starting;
    }

    /// Advance a running sign-in from `gh`'s output and exit status.
    pub fn poll(&mut self) {
        if let Some(output) = &self.output {
            let lines: Vec<String> = output.try_iter().collect();
            for line in lines {
                self.read_line(&line);
            }
        }
        let Some(child) = &mut self.child else {
            return;
        };
        let Ok(Some(exit)) = child.try_wait() else {
            return;
        };
        self.child = None;
        // Output written just before exit may still be in the channel, or still
        // on its way from the reader threads after the pipes close.
        if let Some(output) = self.output.take() {
            while let Ok(line) = output.recv() {
                self.read_line(&line);
            }
        }
        self.status = if exit.success() {
            Status::SignedIn(hosts_user(&self.config))
        } else if self.last_line.is_empty() {
            Status::Failed(i18n::t("wizard.github.incomplete").into())
        } else {
            Status::Failed(self.last_line.clone())
        };
    }

    fn read_line(&mut self, line: &str) {
        let line = line.trim();
        if line.is_empty() {
            return;
        }
        // gh marks notices with `! ` and errors with `X `.
        self.last_line = line
            .strip_prefix("! ")
            .or_else(|| line.strip_prefix("X "))
            .unwrap_or(line)
            .to_string();
        let (mut code, mut url, mut copied) = match &self.status {
            Status::Waiting { code, url, copied } => {
                (Some(code.clone()), Some(url.clone()), *copied)
            }
            _ => (None, None, false),
        };
        code = one_time_code(line).or(code);
        url = line
            .split_whitespace()
            .find(|word| word.starts_with("https://"))
            .map(str::to_string)
            .or(url);
        copied |= line.contains("copied to clipboard");
        let Some(code) = code else {
            return;
        };
        let first = !matches!(self.status, Status::Waiting { .. });
        let url = url.unwrap_or_else(|| DEVICE_URL.into());
        if first && self.open_browser {
            open_in_browser(&url, &self.path);
        }
        self.status = Status::Waiting { code, url, copied };
    }

    fn cancel(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        self.output = None;
        self.status = if self.preview {
            Status::SignedOut
        } else {
            self.local_status()
        };
    }

    /// Forget Mash's sign-in. Not `gh auth logout`: that also deletes the
    /// keychain entry for the same account, which is the user's personal gh.
    fn sign_out(&mut self) {
        if !self.preview {
            let _ = fs::remove_file(self.config.join("hosts.yml"));
        }
        self.status = if self.preview {
            Status::SignedOut
        } else {
            self.local_status()
        };
    }
}

impl Drop for GithubLogin {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// The first `XXXX-XXXX` word of letters and digits in a line.
fn one_time_code(line: &str) -> Option<String> {
    line.split(|c: char| !(c.is_ascii_alphanumeric() || c == '-'))
        .find(|word| {
            word.len() == 9
                && word.char_indices().all(|(index, c)| {
                    if index == 4 {
                        c == '-'
                    } else {
                        c.is_ascii_uppercase() || c.is_ascii_digit()
                    }
                })
        })
        .map(str::to_string)
}

/// The token Mash's sign-in stored; `--insecure-storage` keeps it in hosts.yml.
fn hosts_token(config: &Path) -> Option<String> {
    let text = fs::read_to_string(config.join("hosts.yml")).ok()?;
    text.lines()
        .find_map(|line| line.trim().strip_prefix("oauth_token:"))
        .map(|token| token.trim().to_string())
        .filter(|token| !token.is_empty())
}

/// The signed-in account, from gh's own hosts file. `users:` is a map, not it.
fn hosts_user(config: &Path) -> Option<String> {
    let text = fs::read_to_string(config.join("hosts.yml")).ok()?;
    text.lines()
        .find_map(|line| line.trim().strip_prefix("user:"))
        .map(|user| user.trim().to_string())
        .filter(|user| !user.is_empty())
}

fn open_in_browser(url: &str, path: &OsString) {
    let opener = if cfg!(target_os = "macos") {
        "open"
    } else {
        "xdg-open"
    };
    let _ = Command::new(opener)
        .arg(url)
        .env("PATH", path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TempDir;
    use std::{
        env,
        time::{Duration, Instant},
    };

    /// A stand-in gh: `login` runs the given script, `logout` fails so a test
    /// notices if sign-out ever calls it, and `token` always succeeds, like a
    /// keychain login would.
    fn fixture(login: &str) -> (TempDir, GithubLogin) {
        let root = TempDir::new("gh-test");
        let gh = root.join("gh");
        fs::write(
            &gh,
            format!(
                "#!/bin/sh\n\
                 hosts=\"$GH_CONFIG_DIR/hosts.yml\"\n\
                 case \"$2\" in\n\
                 token) echo keychain-token ;;\n\
                 logout) exit 7 ;;\n\
                 login) {login} ;;\n\
                 *) exit 0 ;;\n\
                 esac\n"
            ),
        )
        .unwrap();
        fs::set_permissions(&gh, fs::Permissions::from_mode(0o755)).unwrap();
        // Another test thread forking while the script was open for writing
        // briefly holds that descriptor, and exec then fails with ETXTBSY.
        let deadline = Instant::now() + Duration::from_secs(5);
        while Command::new(&gh).arg("--version").status().is_err() {
            assert!(
                Instant::now() < deadline,
                "the fake gh never became runnable"
            );
            thread::sleep(Duration::from_millis(10));
        }
        let mut login = GithubLogin::new(
            gh,
            root.join("config/gh"),
            env::var_os("PATH").unwrap_or_default(),
            false,
        );
        login.open_browser = false;
        (root, login)
    }

    fn wait_until(login: &mut GithubLogin, done: impl Fn(&Status) -> bool) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !done(login.status()) {
            assert!(Instant::now() < deadline, "stuck at {:?}", login.status());
            login.poll();
            thread::sleep(Duration::from_millis(20));
        }
    }

    const CODE_THEN_APPROVE: &str = "echo '! One-time code (WXYZ-9876) copied to clipboard' >&2; \
         echo 'Open this URL to continue in your web browser: https://github.com/login/device' >&2; \
         sleep 0.3; printf 'github.com:\\n    users:\\n        ada:\\n    oauth_token: t\\n    user: ada\\n' >\"$hosts\"";

    #[test]
    fn reads_the_code_then_reports_the_account() {
        let (root, mut login) = fixture(CODE_THEN_APPROVE);
        assert_eq!(login.status(), &Status::SignedOut);
        login.activate();
        assert!(login.busy());
        wait_until(&mut login, |status| {
            matches!(status, Status::Waiting { .. })
        });
        assert_eq!(
            login.status(),
            &Status::Waiting {
                code: "WXYZ-9876".into(),
                url: DEVICE_URL.into(),
                copied: true
            }
        );
        wait_until(&mut login, |status| matches!(status, Status::SignedIn(_)));
        assert_eq!(login.status(), &Status::SignedIn(Some("ada".into())));
        assert!(!login.busy());
        let mode = fs::metadata(root.join("config/gh"))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o077, 0, "Mash's GitHub config stays private");

        // A new wizard run sees the stored sign-in without the network.
        let again = GithubLogin::new(
            login.gh.clone(),
            login.config.clone(),
            login.path.clone(),
            false,
        );
        assert_eq!(again.status(), &Status::SignedIn(Some("ada".into())));
        login.activate();
        assert_eq!(login.status(), &Status::SignedOut);
    }

    #[test]
    fn a_failed_sign_in_shows_why_and_offers_a_retry() {
        let (_root, mut login) =
            fixture("echo 'X expired_token: the device code has expired' >&2; exit 1");
        login.activate();
        wait_until(&mut login, |status| matches!(status, Status::Failed(_)));
        assert_eq!(
            login.status(),
            &Status::Failed("expired_token: the device code has expired".into())
        );
        assert_eq!(login.button_label_key(), "wizard.github.retry");
    }

    #[test]
    fn cancel_stops_gh_and_signs_nothing_in() {
        let (_root, mut login) = fixture("echo 'code: ABCD-1234' >&2; sleep 30");
        login.activate();
        wait_until(&mut login, |status| {
            matches!(status, Status::Waiting { .. })
        });
        assert_eq!(login.button_label_key(), "wizard.github.cancel");
        let started = Instant::now();
        login.activate();
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "cancel waited for gh"
        );
        assert!(!login.busy());
        assert_eq!(login.status(), &Status::SignedOut);
    }

    #[test]
    fn a_keychain_login_is_not_mash_sign_in() {
        // The fake gh's `auth token` always answers, as the user's own
        // keychain login does; only Mash's hosts file may count.
        let (_root, login) = fixture("exit 1");
        assert_eq!(login.status(), &Status::SignedOut);
    }

    #[test]
    fn inherited_tokens_never_count_as_mash_sign_in() {
        let (_root, login) = fixture("exit 1");
        let envs: Vec<_> = login
            .command()
            .get_envs()
            .map(|(k, v)| (k.to_owned(), v.map(|v| v.to_owned())))
            .collect();
        for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GH_HOST"] {
            assert!(envs
                .iter()
                .any(|(name, value)| name == key && value.is_none()));
        }
        assert!(envs.iter().any(|(name, value)| name == "GH_CONFIG_DIR"
            && value.as_deref() == Some(login.config.as_os_str())));
    }

    #[test]
    fn a_symlinked_config_is_refused() {
        let (root, _) = fixture("exit 0");
        let elsewhere = root.join("elsewhere");
        fs::create_dir_all(&elsewhere).unwrap();
        fs::create_dir_all(root.join("config")).unwrap();
        std::os::unix::fs::symlink(&elsewhere, root.join("config/gh")).unwrap();
        let mut login = GithubLogin::new(
            root.join("gh"),
            root.join("config/gh"),
            env::var_os("PATH").unwrap_or_default(),
            false,
        );
        assert!(matches!(login.status(), Status::Unavailable(_)));
        login.activate();
        assert!(!login.busy());
    }

    #[test]
    fn a_missing_gh_is_reported_not_offered() {
        let login = GithubLogin::new(
            PathBuf::from("/nonexistent/mash/bin/gh"),
            env::temp_dir().join("mash-gh-missing"),
            OsString::new(),
            false,
        );
        assert!(matches!(login.status(), Status::Unavailable(_)));
    }

    #[test]
    fn preview_shows_the_states_without_running_gh() {
        let mut login = GithubLogin::new(
            PathBuf::from("/nonexistent/mash/bin/gh"),
            env::temp_dir().join("mash-gh-preview"),
            OsString::new(),
            true,
        );
        assert_eq!(login.status(), &Status::SignedOut);
        login.activate();
        assert!(matches!(login.status(), Status::Waiting { .. }));
        assert!(!login.busy());
        login.activate();
        assert_eq!(login.status(), &Status::SignedOut);
    }

    #[test]
    fn parses_both_of_ghs_code_lines() {
        assert_eq!(
            one_time_code("! One-time code (AB12-CD34) copied to clipboard").as_deref(),
            Some("AB12-CD34")
        );
        assert_eq!(
            one_time_code("! First copy your one-time code: 1234-WXYZ").as_deref(),
            Some("1234-WXYZ")
        );
        assert_eq!(one_time_code("open https://github.com/login/device"), None);
        assert_eq!(one_time_code("ab12-cd34 lower-case is not a code"), None);
    }
}
