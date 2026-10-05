//! Shared popup lifecycle: run a TUI, then start agents after close.

use crate::herdr;
use std::process::{Command, Stdio};

/// Work the forms hand back to run *after* the TUI is torn down.
#[derive(Debug, Default)]
pub struct Post {
    /// `herdr agent start …` argv lists; see [`crate::apply::ApplyResult`].
    pub agent_starts: Vec<Vec<String>>,
    /// Directory of the workspace that was created, if any.
    pub dir: String,
}

pub fn run(inner: impl FnOnce(&mut Post) -> Result<i32, String>) -> i32 {
    let mut post = Post::default();
    let code = match inner(&mut post) {
        Ok(code) => code,
        Err(e) => {
            // `inner` can fail before the TUI ever starts (e.g. the worktree
            // form's git::repo_root check runs in App::new, ahead of
            // enable_raw_mode). At that point there is no screen left to draw
            // an error on, and close_popup() below removes the pane a moment
            // later regardless -- stderr alone would flash past unseen. A
            // native notification is the only channel that outlives the popup.
            eprintln!("herdr-workspace: {e}");
            notify_failure(&e);
            1
        }
    };
    // Register the directory before the popup dies. zoxide is a fast local
    // write, so unlike agent starts it does not need a detached child.
    if !post.dir.is_empty() {
        zoxide_add(&post.dir);
    }
    // Closing the popup kills this process. Hand agent starts to a detached
    // child first so later tabs (build, review, …) still launch.
    if !post.agent_starts.is_empty() {
        if let Err(e) = spawn_start_agents(&post.agent_starts) {
            eprintln!("herdr-workspace: {e}");
        }
    }
    close_popup();
    code
}

/// Show a native Herdr notification for an error that prevented the popup from
/// ever drawing a screen.
///
/// Mirrors the pattern `herdr-new-reviewr-tab` already uses for
/// a `type = "shell"` command that fails invisibly: a notification is the only
/// channel that survives the pane closing right after.
///
/// Best-effort and silent on its own failure: a broken notification call must
/// not replace the real error with a different one, and the `eprintln!` right
/// before this call still puts the message in `herdr plugin log` either way.
fn notify_failure(message: &str) {
    let bin = std::env::var("HERDR_WORKSPACE_HERDR_BIN").unwrap_or_else(|_| "herdr".into());
    let _ = Command::new(bin)
        .args(["notification", "show", "herdr-workspace", "--body", message])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

/// Add `dir` to the zoxide database.
///
/// Pickers that rank directories by zoxide frecency (herdr-plugin-sesh, for
/// one) only list paths zoxide already knows, and a brand new workspace
/// directory has never been `cd`'d into. Registering it here means a workspace
/// created from this popup is immediately selectable there.
///
/// Best-effort and silent: zoxide is optional, so a missing binary or a
/// non-zero exit must not report an error over a workspace that was created
/// successfully.
fn zoxide_add(dir: &str) {
    // Overridable so tests can point at a stub; unset in normal use.
    let bin = std::env::var("HERDR_WORKSPACE_ZOXIDE_BIN").unwrap_or_else(|_| "zoxide".into());
    let _ = Command::new(bin)
        .arg("add")
        .arg(dir)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `notify_failure` must call `herdr notification show` with the message
    /// intact. This is what makes a pre-TUI failure (the worktree popup
    /// rejecting a non-git directory, for one) visible at all: stderr alone
    /// flashes past when the pane closes right after.
    #[test]
    fn notify_failure_invokes_herdr_with_the_message() {
        let tmp = std::env::temp_dir().join(format!("hw-notify-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();
        let stub = tmp.join("stub.sh");
        let out = tmp.join("args.txt");
        std::fs::write(
            &stub,
            format!("#!/bin/sh\nprintf '%s\\n' \"$@\" > {}\n", out.display()),
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        std::env::set_var("HERDR_WORKSPACE_HERDR_BIN", &stub);
        notify_failure("not a git repository: /tmp/not-a-repo");
        std::env::remove_var("HERDR_WORKSPACE_HERDR_BIN");

        let got = std::fs::read_to_string(&out).unwrap();
        let lines: Vec<&str> = got.lines().collect();
        assert_eq!(
            lines,
            vec![
                "notification",
                "show",
                "herdr-workspace",
                "--body",
                "not a git repository: /tmp/not-a-repo",
            ]
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }

    /// A missing `herdr` binary must not panic: this path only runs after an
    /// error has already occurred, and must not mask it with a crash.
    #[test]
    fn notify_failure_tolerates_a_missing_binary() {
        std::env::set_var(
            "HERDR_WORKSPACE_HERDR_BIN",
            "/nonexistent/herdr-does-not-exist",
        );
        notify_failure("irrelevant");
        std::env::remove_var("HERDR_WORKSPACE_HERDR_BIN");
    }

    /// The directory must reach `zoxide add` verbatim, including spaces.
    #[test]
    fn zoxide_add_invokes_the_binary_with_the_dir() {
        let tmp = std::env::temp_dir().join(format!("hw-zx-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();
        let stub = tmp.join("stub.sh");
        let out = tmp.join("args.txt");
        std::fs::write(
            &stub,
            format!("#!/bin/sh
printf '%s\n' \"$@\" > {}
", out.display()),
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        std::env::set_var("HERDR_WORKSPACE_ZOXIDE_BIN", &stub);
        zoxide_add("/tmp/some dir/proj");
        std::env::remove_var("HERDR_WORKSPACE_ZOXIDE_BIN");

        let got = std::fs::read_to_string(&out).unwrap();
        let lines: Vec<&str> = got.lines().collect();
        assert_eq!(lines, vec!["add", "/tmp/some dir/proj"]);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    /// A missing zoxide must not panic: it is an optional dependency.
    #[test]
    fn zoxide_add_tolerates_a_missing_binary() {
        std::env::set_var(
            "HERDR_WORKSPACE_ZOXIDE_BIN",
            "/nonexistent/zoxide-does-not-exist",
        );
        zoxide_add("/tmp/whatever");
        std::env::remove_var("HERDR_WORKSPACE_ZOXIDE_BIN");
    }
}

fn spawn_start_agents(jobs: &[Vec<String>]) -> Result<(), String> {
    let path = std::env::temp_dir().join(format!(
        "herdr-workspace-agents-{}.json",
        std::process::id()
    ));
    let payload = serde_json::to_vec(jobs).map_err(|e| format!("encode agent jobs: {e}"))?;
    std::fs::write(&path, payload).map_err(|e| format!("write {}: {e}", path.display()))?;
    let exe = std::env::current_exe().map_err(|e| format!("current_exe: {e}"))?;
    let log = std::env::temp_dir().join("herdr-workspace-agents.log");
    let log_file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log)
        .map_err(|e| format!("open {}: {e}", log.display()))?;
    // Ignore SIGHUP in this process so the child is not killed in the
    // window between fork and setsid when the popup closes.
    #[cfg(unix)]
    unsafe {
        libc::signal(libc::SIGHUP, libc::SIG_IGN);
    }
    let mut cmd = Command::new(&exe);
    cmd.arg("start-agents")
        .arg(&path)
        .stdin(Stdio::null())
        .stdout(log_file.try_clone().map_err(|e| e.to_string())?)
        .stderr(log_file);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        unsafe {
            cmd.pre_exec(|| {
                libc::signal(libc::SIGHUP, libc::SIG_IGN);
                if libc::setsid() == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }
    cmd.spawn()
        .map_err(|e| format!("spawn start-agents: {e}"))?;
    Ok(())
}

fn close_popup() {
    let pane = std::env::var("HERDR_PANE_ID").unwrap_or_default();
    if !pane.is_empty() {
        let _ = herdr::run(["plugin", "pane", "close", pane.as_str()]);
    }
}
