//! Draw a spinner while a program starts, then hand the terminal to it.
//!
//! The pane that runs `fresh -a .` or resumes a session shows a bare prompt
//! until the program paints its first frame -- a second or two for a warm
//! editor, several for a daemon coming up with its language servers, and
//! seconds again for a restored agent. This runs the program on a pseudo
//! terminal it owns, animates on the real one while nothing has been drawn yet,
//! and forwards bytes transparently from the moment the program speaks.
//!
//! Two rules keep that honest:
//!
//!   * exactly one writer at a time. While the spinner animates the child has
//!     produced nothing, so nothing else can be on screen; the first byte from
//!     the child ends the animation for good.
//!   * nothing may be lost in transit. The pty carries keyboard input, mouse
//!     reports and resize events in both directions, the child's exit status is
//!     this process's exit status, and termination signals reach the child's
//!     process group rather than being swallowed.
//!
//! Usage: mash-pane-runner [--label TEXT] [--max-spin-ms N] -- <command> [args...]
//!
//! With no terminal on stdout (a pipe, a script, a log), it runs the command
//! directly: there is nothing to animate and no reason to own a pty.

use std::ffi::CString;
use std::io::{self, ErrorKind};
use std::os::unix::io::RawFd;
use std::os::unix::process::CommandExt;
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// Braille cells, which every terminal Mash ships can render.
const FRAMES: [&str; 10] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
const TICK: Duration = Duration::from_millis(90);
const DEFAULT_MAX_SPIN: Duration = Duration::from_secs(20);

static WINCH: AtomicBool = AtomicBool::new(false);
static TERMINATE: AtomicBool = AtomicBool::new(false);

extern "C" fn on_winch(_: libc::c_int) {
    WINCH.store(true, Ordering::SeqCst);
}

extern "C" fn on_terminate(_: libc::c_int) {
    TERMINATE.store(true, Ordering::SeqCst);
}

/// Restores the terminal however this process leaves.
struct RawTerminal {
    original: libc::termios,
    active: bool,
}

impl RawTerminal {
    fn enter() -> io::Result<Self> {
        let mut original: libc::termios = unsafe { std::mem::zeroed() };
        if unsafe { libc::tcgetattr(libc::STDIN_FILENO, &mut original) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let mut raw = original;
        // ISIG stays off so ^C reaches the child as a byte, the way it would
        // without this process in the middle.
        unsafe { libc::cfmakeraw(&mut raw) };
        if unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSADRAIN, &raw) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self { original, active: true })
    }

    fn restore(&mut self) {
        if self.active {
            unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSADRAIN, &self.original) };
            self.active = false;
        }
    }
}

impl Drop for RawTerminal {
    fn drop(&mut self) {
        self.restore();
    }
}

fn write_out(fd: RawFd, bytes: &[u8]) -> io::Result<()> {
    let mut off = 0;
    while off < bytes.len() {
        let written = unsafe {
            libc::write(fd, bytes[off..].as_ptr() as *const libc::c_void, bytes.len() - off)
        };
        if written < 0 {
            let err = io::Error::last_os_error();
            match err.kind() {
                ErrorKind::Interrupted => continue,
                ErrorKind::WouldBlock => {
                    // The terminal is momentarily full; this is a start-up
                    // spinner, so dropping a frame is better than blocking the
                    // child's output behind it.
                    return Ok(());
                }
                _ => return Err(err),
            }
        }
        if written == 0 {
            return Ok(());
        }
        off += written as usize;
    }
    Ok(())
}

fn window_size(fd: RawFd) -> Option<libc::winsize> {
    let mut size: libc::winsize = unsafe { std::mem::zeroed() };
    if unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, &mut size) } == 0 {
        Some(size)
    } else {
        None
    }
}

struct Spinner<'a> {
    label: &'a str,
    frame: usize,
    started: Instant,
    max: Duration,
    drawn: bool,
}

impl<'a> Spinner<'a> {
    fn new(label: &'a str, max: Duration) -> Self {
        // Hide the cursor for the duration; the child re-enables it as it likes.
        let _ = write_out(libc::STDOUT_FILENO, b"\x1b[?25l");
        Self { label, frame: 0, started: Instant::now(), max, drawn: false }
    }

    fn tick(&mut self) {
        if self.started.elapsed() >= self.max {
            return;
        }
        let frame = FRAMES[self.frame % FRAMES.len()];
        self.frame += 1;
        let line = format!("\r\x1b[2K  {} {}", frame, self.label);
        let _ = write_out(libc::STDOUT_FILENO, line.as_bytes());
        self.drawn = true;
    }

    /// Erase the animation so the child draws on a clean line.
    fn clear(&mut self) {
        if self.drawn {
            let _ = write_out(libc::STDOUT_FILENO, b"\r\x1b[2K");
            self.drawn = false;
        }
    }
}

impl Drop for Spinner<'_> {
    fn drop(&mut self) {
        self.clear();
        let _ = write_out(libc::STDOUT_FILENO, b"\x1b[?25h");
    }
}

fn run_without_terminal(command: &[String]) -> ! {
    let error = std::process::Command::new(&command[0]).args(&command[1..]).exec();
    eprintln!("mash-pane-runner: {}: {}", command[0], error);
    std::process::exit(127);
}

struct Options {
    label: String,
    max_spin: Duration,
    command: Vec<String>,
}

/// Parse the command line, or explain why it is unusable.
fn parse(arguments: impl Iterator<Item = String>) -> Result<Options, String> {
    let mut label = String::from("Starting…");
    let mut max_spin = DEFAULT_MAX_SPIN;
    let mut command: Vec<String> = Vec::new();

    let mut args = arguments;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--label" => label = args.next().unwrap_or(label),
            "--max-spin-ms" => {
                if let Some(ms) = args.next().and_then(|v| v.parse::<u64>().ok()) {
                    max_spin = Duration::from_millis(ms);
                }
            }
            "--" => {
                command.extend(args);
                break;
            }
            other => return Err(format!("unexpected argument {other:?}")),
        }
    }
    if command.is_empty() {
        return Err(
            "usage: mash-pane-runner [--label TEXT] [--max-spin-ms N] -- <command> [args...]".to_string(),
        );
    }
    Ok(Options { label, max_spin, command })
}

fn main() {
    let options = match parse(std::env::args().skip(1)) {
        Ok(options) => options,
        Err(message) => {
            eprintln!("mash-pane-runner: {message}");
            std::process::exit(2);
        }
    };
    let Options { label, max_spin, command } = options;

    // No terminal, no animation: run the command and disappear, exactly as the
    // caller would have without this wrapper.
    if unsafe { libc::isatty(libc::STDOUT_FILENO) } != 1 {
        run_without_terminal(&command);
    }

    let size = window_size(libc::STDOUT_FILENO);
    let mut master: RawFd = -1;
    let mut slave: RawFd = -1;
    let size_ptr = size
        .as_ref()
        .map(|s| s as *const libc::winsize as *mut libc::winsize)
        .unwrap_or(ptr::null_mut());
    if unsafe { libc::openpty(&mut master, &mut slave, ptr::null_mut(), ptr::null_mut(), size_ptr) } != 0 {
        let error = io::Error::last_os_error();
        eprintln!("mash-pane-runner: could not allocate a terminal: {error}");
        run_without_terminal(&command);
    }

    let child = unsafe { libc::fork() };
    match child {
        0 => {
            // Child: its own session and controlling terminal, so signals and
            // window-size changes behave as if it were started directly.
            unsafe {
                libc::close(master);
                libc::setsid();
                libc::ioctl(slave, libc::TIOCSCTTY as _, 0);
                libc::dup2(slave, libc::STDIN_FILENO);
                libc::dup2(slave, libc::STDOUT_FILENO);
                libc::dup2(slave, libc::STDERR_FILENO);
                if slave > libc::STDERR_FILENO {
                    libc::close(slave);
                }
            }
            let cstrings: Vec<CString> = command
                .iter()
                .map(|arg| CString::new(arg.as_bytes()).unwrap_or_default())
                .collect();
            let mut argv: Vec<*const libc::c_char> = cstrings.iter().map(|c| c.as_ptr()).collect();
            argv.push(ptr::null());
            unsafe { libc::execvp(cstrings[0].as_ptr(), argv.as_ptr()) };
            let error = io::Error::last_os_error();
            eprintln!("mash-pane-runner: {}: {}", command[0], error);
            unsafe { libc::_exit(127) };
        }
        -1 => {
            let error = io::Error::last_os_error();
            eprintln!("mash-pane-runner: could not start {}: {error}", command[0]);
            unsafe {
                libc::close(master);
                libc::close(slave);
            }
            run_without_terminal(&command);
        }
        pid => unsafe {
            libc::close(slave);
            supervise(pid, master, &label, max_spin);
        },
    }
}

/// Forward bytes both ways until the child exits, then return its status.
unsafe fn supervise(child: libc::pid_t, master: RawFd, label: &str, max_spin: Duration) {
    let mut terminal = match RawTerminal::enter() {
        Ok(term) => term,
        Err(error) => {
            eprintln!("mash-pane-runner: could not set up the terminal: {error}");
            forward_until_exit(child, master);
        }
    };

    unsafe {
        libc::signal(libc::SIGWINCH, on_winch as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, on_terminate as *const () as libc::sighandler_t);
        libc::signal(libc::SIGINT, on_terminate as *const () as libc::sighandler_t);
    }

    let mut spinner = Spinner::new(label, max_spin);
    let mut handed_over = false;
    let mut buffer = [0u8; 8192];

    loop {
        if TERMINATE.load(Ordering::SeqCst) {
            unsafe { libc::kill(-child, libc::SIGTERM) };
            TERMINATE.store(false, Ordering::SeqCst);
        }
        if WINCH.swap(false, Ordering::SeqCst) {
            if let Some(size) = window_size(libc::STDOUT_FILENO) {
                unsafe { libc::ioctl(master, libc::TIOCSWINSZ as _, &size) };
            }
        }

        let mut fds = [
            libc::pollfd { fd: libc::STDIN_FILENO, events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: master, events: libc::POLLIN, revents: 0 },
        ];
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), 2, TICK.as_millis() as libc::c_int) };

        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == ErrorKind::Interrupted {
                continue;
            }
            break;
        }

        if ready == 0 {
            if handed_over {
                if let Some(status) = unsafe { reap(child) } {
                    terminal.restore();
                    unsafe { drain(master) };
                    std::process::exit(status);
                }
            } else {
                spinner.tick();
            }
            continue;
        }

        if fds[1].revents & libc::POLLIN != 0 {
            let read = unsafe { libc::read(master, buffer.as_mut_ptr() as *mut libc::c_void, buffer.len()) };
            if read > 0 {
                if !handed_over {
                    // The program has spoken: from here it owns the screen.
                    spinner.clear();
                    handed_over = true;
                }
                let _ = write_out(libc::STDOUT_FILENO, &buffer[..read as usize]);
            } else if read < 0 {
                let error = io::Error::last_os_error();
                if error.kind() != ErrorKind::Interrupted {
                    // EIO is how a pty reports that the other side is gone.
                    break;
                }
            } else {
                break;
            }
        }

        if fds[0].revents & libc::POLLIN != 0 {
            let read = unsafe { libc::read(libc::STDIN_FILENO, buffer.as_mut_ptr() as *mut libc::c_void, buffer.len()) };
            if read > 0 {
                let _ = write_out(master, &buffer[..read as usize]);
            } else if read == 0 {
                break;
            }
        }
    }

    terminal.restore();
    unsafe {
        if let Some(status) = reap(child) {
            drain(master);
            libc::close(master);
            std::process::exit(status);
        }
        libc::kill(-child, libc::SIGTERM);
        drain(master);
        libc::close(master);
    }
}

/// Wait without blocking; Some(exit code) when the child is gone.
unsafe fn reap(child: libc::pid_t) -> Option<i32> {
    let mut status: libc::c_int = 0;
    let pid = unsafe { libc::waitpid(child, &mut status, libc::WNOHANG) };
    if pid != child {
        return None;
    }
    if libc::WIFEXITED(status) {
        return Some(libc::WEXITSTATUS(status));
    }
    if libc::WIFSIGNALED(status) {
        return Some(128 + libc::WTERMSIG(status));
    }
    Some(0)
}

/// Read whatever the child left behind before it exited.
unsafe fn drain(master: RawFd) {
    let mut buffer = [0u8; 8192];
    loop {
        let read = unsafe { libc::read(master, buffer.as_mut_ptr() as *mut libc::c_void, buffer.len()) };
        if read <= 0 {
            return;
        }
        let _ = write_out(libc::STDOUT_FILENO, &buffer[..read as usize]);
    }
}

/// Last resort when the terminal could not be taken over: plain forwarding.
unsafe fn forward_until_exit(child: libc::pid_t, master: RawFd) -> ! {
    let mut buffer = [0u8; 8192];
    loop {
        let mut fds = [libc::pollfd { fd: master, events: libc::POLLIN, revents: 0 }];
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), 1, 100) };
        if ready > 0 && fds[0].revents & libc::POLLIN != 0 {
            let read = unsafe { libc::read(master, buffer.as_mut_ptr() as *mut libc::c_void, buffer.len()) };
            if read > 0 {
                let _ = write_out(libc::STDOUT_FILENO, &buffer[..read as usize]);
                continue;
            }
        }
        if let Some(status) = unsafe { reap(child) } {
            std::process::exit(status);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> impl Iterator<Item = String> {
        list.iter().map(|v| v.to_string()).collect::<Vec<_>>().into_iter()
    }

    #[test]
    fn the_command_follows_a_double_dash() {
        let parsed = parse(args(&["--label", "Opening", "--", "fresh", "-a"])).expect("parsed");
        assert_eq!(parsed.label, "Opening");
        assert_eq!(parsed.command, vec!["fresh", "-a"]);
    }

    #[test]
    fn arguments_after_the_command_belong_to_it() {
        // `--label` past the separator is the child's argument, not ours.
        let parsed = parse(args(&["--", "pi", "--label", "not ours"])).expect("parsed");
        assert_eq!(parsed.command, vec!["pi", "--label", "not ours"]);
    }

    #[test]
    fn a_missing_command_is_refused() {
        // Otherwise the pty is allocated and nothing runs, which looks like a
        // hung pane rather than a mistake.
        assert!(parse(args(&["--label", "Opening"])).is_err());
        assert!(parse(args(&["--"])).is_err());
    }

    #[test]
    fn an_unknown_flag_is_refused_rather_than_guessed() {
        assert!(parse(args(&["--labl", "typo", "--", "fresh"])).is_err());
    }

    #[test]
    fn a_bad_spin_budget_keeps_the_default() {
        let parsed = parse(args(&["--max-spin-ms", "soon", "--", "fresh"])).expect("parsed");
        assert_eq!(parsed.max_spin, DEFAULT_MAX_SPIN);
    }
}
