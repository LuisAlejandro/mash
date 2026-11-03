//! Bounded, read-only bridge to the bundled Pi catalog/auth helper.
use serde_json::Value;
use std::{
    io::{Read, Write},
    os::unix::process::CommandExt,
    path::Path,
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicUsize, Ordering},
        mpsc::{self, Receiver},
        Arc,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

const MAX_OUTPUT: usize = 4 * 1024 * 1024;
const UNAVAILABLE: &str =
    "Pi model inspection unavailable. Configure the model manually or use Pi /login after setup.";
const HELPER_UNAVAILABLE: &str =
    "Setup helper unavailable. Enter the details manually; setup can continue.";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Model {
    pub provider: String,
    pub id: String,
    pub name: String,
}

pub struct Report {
    pub models: Vec<Model>,
    pub model_known: Option<bool>,
    auth: String,
    catalog_complete: bool,
}

impl Report {
    pub fn parse(bytes: &[u8]) -> Result<Self, String> {
        let value: Value = serde_json::from_slice(bytes).map_err(|_| UNAVAILABLE)?;
        if value["version"] != 1 || value["status"] != "ok" || value["serverVerified"] != false {
            return Err(UNAVAILABLE.into());
        }
        let complete = value["catalogComplete"].as_bool().ok_or(UNAVAILABLE)?;
        let auth = value["auth"]["status"].as_str().ok_or(UNAVAILABLE)?;
        if !["ready", "not_ready", "unverified"].contains(&auth) {
            return Err(UNAVAILABLE.into());
        }
        let mut models = Vec::new();
        for row in value["models"].as_array().ok_or(UNAVAILABLE)? {
            let identity = |field: &str| -> Result<String, String> {
                let text = row[field].as_str().ok_or(UNAVAILABLE)?;
                if text.is_empty() || text.len() > 4096 || text.chars().any(char::is_control) {
                    return Err(UNAVAILABLE.into());
                }
                Ok(text.to_string())
            };
            models.push(Model {
                provider: identity("provider")?,
                id: identity("id")?,
                name: row["name"]
                    .as_str()
                    .unwrap_or_default()
                    .chars()
                    .filter(|c| !c.is_control())
                    .take(256)
                    .collect(),
            });
        }
        Ok(Self {
            models,
            model_known: if complete {
                value["modelKnown"].as_bool()
            } else {
                None
            },
            auth: auth.to_string(),
            catalog_complete: complete,
        })
    }

    pub fn warnings(&self) -> Vec<String> {
        let mut lines = Vec::new();
        if self.model_known == Some(false) {
            lines.push(
                "The saved model is not in Pi's local catalog. Its exact ID was kept.".into(),
            );
        } else if !self.catalog_complete {
            lines.push(
                "The saved model has no available local catalog; its ID is unverified.".into(),
            );
        }
        match self.auth.as_str() {
            "not_ready" => lines.push("No configured credentials for the saved model provider. Use Pi /login after setup.".into()),
            "unverified" => lines.push("The saved provider's credentials could not be checked locally. Use Pi /login after setup.".into()),
            _ => {}
        }
        lines
    }
}

enum Message {
    Input(bool),
    Stdout(Result<Vec<u8>, ()>),
    Stderr(bool),
}

pub struct Job {
    child: Child,
    receiver: Receiver<Message>,
    readers: Vec<JoinHandle<()>>,
    bytes: Arc<AtomicUsize>,
    stdout: Option<Vec<u8>>,
    received: usize,
    deadline: Instant,
    done: bool,
}

impl Job {
    pub fn start(resources: &Path, request: Value) -> Result<Self, String> {
        Self::start_helper(
            resources,
            "bin/mash-pi-models.mjs",
            request,
            Duration::from_secs(10),
        )
    }

    /// Any bundled helper, with the budget its own action needs.
    pub fn start_helper(
        resources: &Path,
        helper: &str,
        request: Value,
        timeout: Duration,
    ) -> Result<Self, String> {
        let input = serde_json::to_vec(&request).map_err(|_| HELPER_UNAVAILABLE)?;
        if input.len() > 64 * 1024 {
            return Err(HELPER_UNAVAILABLE.into());
        }
        let mut command = Command::new(resources.join("node/bin/node"));
        command
            .arg(resources.join(helper))
            .current_dir(resources)
            .env("PI_OFFLINE", "1")
            .env_remove("NODE_OPTIONS")
            .env_remove("NODE_PATH");
        Self::spawn(command, input, timeout)
    }

    #[cfg(test)]
    pub fn spawn_for_test(
        command: Command,
        input: Vec<u8>,
        timeout: Duration,
    ) -> Result<Self, String> {
        Self::spawn(command, input, timeout)
    }

    fn spawn(mut command: Command, input: Vec<u8>, timeout: Duration) -> Result<Self, String> {
        command
            .process_group(0)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = command.spawn().map_err(|_| HELPER_UNAVAILABLE)?;
        let mut stdin = child.stdin.take().ok_or(HELPER_UNAVAILABLE)?;
        let stdout = child.stdout.take().ok_or(HELPER_UNAVAILABLE)?;
        let stderr = child.stderr.take().ok_or(HELPER_UNAVAILABLE)?;
        let bytes = Arc::new(AtomicUsize::new(0));
        let (sender, receiver) = mpsc::channel();
        let input_sender = sender.clone();
        let writer = thread::spawn(move || {
            let ok = stdin.write_all(&input).is_ok();
            drop(stdin);
            let _ = input_sender.send(Message::Input(ok));
        });
        let output_sender = sender.clone();
        let stdout_bytes = bytes.clone();
        let output = thread::spawn(move || {
            let result = drain(stdout, &stdout_bytes, true);
            let _ = output_sender.send(Message::Stdout(result));
        });
        let stderr_bytes = bytes.clone();
        let errors = thread::spawn(move || {
            let ok = drain(stderr, &stderr_bytes, false).is_ok();
            let _ = sender.send(Message::Stderr(ok));
        });
        Ok(Self {
            child,
            receiver,
            readers: vec![writer, output, errors],
            bytes,
            stdout: None,
            received: 0,
            deadline: Instant::now() + timeout,
            done: false,
        })
    }

    pub fn poll(&mut self) -> Option<Result<Report, String>> {
        Some(self.poll_bytes()?.and_then(|bytes| Report::parse(&bytes)))
    }

    /// The raw reply, for callers with their own typed contract.
    pub fn poll_json(&mut self) -> Option<Result<Value, String>> {
        Some(self.poll_bytes()?.and_then(|bytes| {
            serde_json::from_slice(&bytes).map_err(|_| String::from(HELPER_UNAVAILABLE))
        }))
    }

    fn poll_bytes(&mut self) -> Option<Result<Vec<u8>, String>> {
        if self.done {
            return None;
        }
        if Instant::now() >= self.deadline || self.bytes.load(Ordering::Relaxed) > MAX_OUTPUT {
            self.stop();
            return Some(Err(HELPER_UNAVAILABLE.into()));
        }
        while let Ok(message) = self.receiver.try_recv() {
            self.received += 1;
            match message {
                Message::Stdout(Ok(output)) => self.stdout = Some(output),
                Message::Input(true) | Message::Stderr(true) => {}
                _ => {
                    self.stop();
                    return Some(Err(HELPER_UNAVAILABLE.into()));
                }
            }
        }
        match self.child.try_wait() {
            Ok(Some(status)) if !status.success() => {
                self.stop();
                Some(Err(HELPER_UNAVAILABLE.into()))
            }
            Ok(Some(_)) if self.received == 3 => {
                let result = self.stdout.take().unwrap_or_default();
                self.stop();
                Some(Ok(result))
            }
            Err(_) => {
                self.stop();
                Some(Err(HELPER_UNAVAILABLE.into()))
            }
            _ => None,
        }
    }

    fn stop(&mut self) {
        if self.done {
            return;
        }
        self.done = true;
        // Each job owns a new process group. Also close pipes held by descendants.
        unsafe extern "C" {
            fn kill(pid: i32, signal: i32) -> i32;
        }
        // SAFETY: kill accepts any pid; a negative pid targets only our child group.
        unsafe {
            kill(-(self.child.id() as i32), 9);
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        for reader in self.readers.drain(..) {
            let _ = reader.join();
        }
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        self.stop();
    }
}

fn drain(mut pipe: impl Read, bytes: &AtomicUsize, keep: bool) -> Result<Vec<u8>, ()> {
    let mut output = Vec::new();
    let mut chunk = [0; 8192];
    loop {
        let count = pipe.read(&mut chunk).map_err(|_| ())?;
        if count == 0 {
            return Ok(output);
        }
        if bytes.fetch_add(count, Ordering::Relaxed) + count > MAX_OUTPUT {
            return Err(());
        }
        if keep {
            output.extend_from_slice(&chunk[..count]);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::{
        process::Command,
        time::{Duration, Instant},
    };

    #[test]
    fn typed_catalog_preserves_pairs_and_suppresses_false_unknown_warnings() {
        let value = json!({"version":1,"status":"ok","serverVerified":false,"catalogComplete":false,"modelKnown":false,"auth":{"status":"not_ready"},"models":[{"provider":"openai","id":"namespace/model","name":"Name\u{1b}[31m"}]});
        let report = Report::parse(&serde_json::to_vec(&value).unwrap()).unwrap();
        assert_eq!(report.models[0].id, "namespace/model");
        assert!(!report.models[0].name.contains('\u{1b}'));
        assert_eq!(report.model_known, None);
        assert_eq!(report.warnings().len(), 2);
        assert!(Report::parse(b"secret-raw-error").is_err());
    }

    fn finish(mut job: Job) -> Result<Report, String> {
        let until = Instant::now() + Duration::from_secs(3);
        loop {
            if let Some(result) = job.poll() {
                return result;
            }
            assert!(Instant::now() < until, "child never completed");
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn child_output_is_bounded_and_drop_reaps_a_blocked_writer() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "dd if=/dev/zero bs=1024 count=5000 >&2 2>/dev/null"]);
        let mut job = Job::spawn(command, Vec::new(), Duration::from_secs(3)).unwrap();
        let start = Instant::now();
        loop {
            if let Some(result) = job.poll() {
                assert!(result.is_err());
                break;
            }
            assert!(start.elapsed() < Duration::from_secs(2));
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(job.bytes.load(Ordering::Relaxed) > MAX_OUTPUT);
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "sleep 10"]);
        let job = Job::spawn(command, vec![b'x'; 64 * 1024], Duration::from_secs(10)).unwrap();
        let pid = job.child.id();
        let start = Instant::now();
        drop(job);
        assert!(start.elapsed() < Duration::from_secs(2));
        assert!(!Command::new("/bin/kill")
            .args(["-0", &pid.to_string()])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap()
            .success());
    }

    #[test]
    fn successful_protocol_and_bad_exit_never_echo_stderr() {
        let value = serde_json::json!({"version":1,"status":"ok","serverVerified":false,"catalogComplete":true,"modelKnown":true,"auth":{"status":"ready"},"models":[]});
        let mut command = Command::new("/bin/sh");
        command.args([
            "-c",
            &format!(
                "cat >/dev/null; printf '%s' '{}'; printf secret-error >&2",
                value
            ),
        ]);
        let report =
            finish(Job::spawn(command, b"{}".to_vec(), Duration::from_secs(2)).unwrap()).unwrap();
        assert!(report.warnings().is_empty());
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "printf secret-error >&2; exit 2"]);
        let error = finish(Job::spawn(command, Vec::new(), Duration::from_secs(2)).unwrap())
            .err()
            .unwrap();
        assert!(!error.contains("secret-error"));
    }

    #[test]
    fn bounded_job_drains_both_pipes_and_times_out_without_blocking() {
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "cat >/dev/null; sleep 10"]);
        let start = Instant::now();
        let job = Job::spawn(command, b"{}".to_vec(), Duration::from_millis(80)).unwrap();
        assert!(finish(job).is_err());
        assert!(start.elapsed() < Duration::from_secs(2));

        let mut command = Command::new("/bin/sh");
        command.args(["-c", "while :; do printf 'large stderr output\n' >&2; done"]);
        assert!(finish(Job::spawn(command, Vec::new(), Duration::from_secs(2)).unwrap()).is_err());
    }
}
