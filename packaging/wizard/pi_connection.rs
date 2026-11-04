//! Typed endpoint connections: local server presets, probes and credential reuse.
use crate::pi_models::Job;
use crate::pi_providers;
use serde_json::Value;
use std::{path::Path, time::Duration};

const UNAVAILABLE: &str =
    "Connection check unavailable. Enter the details manually; setup can continue.";
const CONNECT: &str = "bin/mash-pi-connect.mjs";
const CREDENTIALS: &str = "bin/mash-pi-credentials.mjs";

/// A local server Mash can configure. Policy lives here, not in Pi's snapshot.
#[derive(Debug, PartialEq, Eq)]
pub struct Preset {
    pub id: &'static str,
    pub name: &'static str,
    pub base_url: &'static str,
    /// A model must be chosen from the server's own catalog.
    pub requires_model: bool,
}

pub const PRESETS: [Preset; 4] = [
    Preset {
        id: "ollama",
        name: "Ollama (local)",
        base_url: "http://127.0.0.1:11434/v1",
        requires_model: true,
    },
    Preset {
        id: "lmstudio",
        name: "LM Studio (local)",
        base_url: "http://localhost:1234/v1",
        requires_model: true,
    },
    Preset {
        id: "vllm",
        name: "vLLM (local)",
        base_url: "http://127.0.0.1:8000/v1",
        requires_model: false,
    },
    Preset {
        id: "sglang",
        name: "SGLang (local)",
        base_url: "http://127.0.0.1:30000/v1",
        requires_model: false,
    },
];

/// What the wizard may do with the credential a provider already has.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// Reuse whatever Pi already resolves for this provider.
    Existing,
    /// Send the key typed on this page.
    New,
    /// A local server that takes no real credential.
    None,
    /// Configure a built-in model now; leave authentication entirely to Pi.
    Later,
}

impl Mode {
    pub fn label(self) -> &'static str {
        match self {
            Mode::Existing => "Reuse the saved credential",
            Mode::New => "Enter a new API key",
            Mode::None => "No key (local server)",
            Mode::Later => "Sign in later in Pi",
        }
    }

    pub(crate) fn id(self) -> Option<&'static str> {
        Some(match self {
            Mode::Existing => "existing",
            Mode::New => "new",
            Mode::None => "none",
            // Deferred authentication is UI state, never a credential request.
            Mode::Later => return None,
        })
    }
}

/// A helper answer, already reduced to what the page may show or act on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// A reusable credential: its origin and an opaque revision, never material.
    Source {
        label: String,
        ready: bool,
        /// Why a saved credential is unusable, already reduced to a safe token.
        reason: Option<String>,
        revision: String,
    },
    /// Models the chosen endpoint itself reported.
    Models {
        ids: Vec<String>,
        revision: Option<String>,
        complete: bool,
    },
    /// The endpoint accepted a real request on this API family.
    Accepted {
        api: String,
        revision: Option<String>,
    },
    /// The endpoint, credential or policy refused; the page stays editable.
    Refused { message: String },
}

fn clean(value: &Value, field: &str) -> Option<String> {
    let text = value[field].as_str()?;
    (!text.is_empty() && text.len() <= 4096 && !text.chars().any(char::is_control))
        .then(|| text.to_string())
}

/// One saved-credential reason, already reduced to a safe sentence.
pub fn explain_saved(reason: &str) -> String {
    explain(reason, None)
}

fn with_status(message: &str, http: Option<u64>) -> String {
    http.map_or_else(
        || message.to_string(),
        |status| format!("{message} (HTTP {status})"),
    )
}

fn explain(reason: &str, http: Option<u64>) -> String {
    let message = match reason {
        "unauthorized" => "The endpoint rejected these credentials.",
        "not_found" => "The endpoint has no such model or API path.",
        "timeout" => "The endpoint did not answer in time.",
        "unreachable" | "request_failed" => "No server answered at that address.",
        "blocked_host"
        | "blocked_address"
        | "unsafe_url"
        | "plaintext_not_allowed"
        | "unsupported_scheme" => {
            "That address is not allowed; use an HTTPS endpoint, or a local server address."
        }
        "redirected" => "The endpoint redirected elsewhere; enter the final address.",
        "not_json" => "That address answered with a page, not a model API.",
        "wrong_api" => {
            "That address answered for a different API type; check the address and the selected API."
        }
        "no_models" => "The server is running but has no chat model loaded.",
        "stale" => "The connection changed while checking. Test it again.",
        "consent_required" => "Testing sends one short request. Confirm to continue.",
        "command_secret" => "That credential runs a command; manage it in Pi instead.",
        "oauth_expired" => "The saved login has expired; sign in again through Pi.",
        "endpoint_changed" => "The saved credential belongs to a different endpoint.",
        "additional_setup" => "This provider needs extra setup; finish it in Pi.",
        _ => "The connection could not be verified.",
    };
    with_status(message, http)
}

impl Outcome {
    pub fn parse(value: &Value) -> Result<Self, String> {
        if value["version"] != 1 || value["status"] != "ok" {
            return Err(UNAVAILABLE.into());
        }
        if let Some(revision) = clean(value, "revision") {
            if value["accepted"].is_null() {
                return Ok(Outcome::Source {
                    label: clean(value, "label").unwrap_or_else(|| "Saved credential".into()),
                    ready: value["ready"].as_bool().unwrap_or(false),
                    reason: clean(value, "reason"),
                    revision,
                });
            }
        }
        if value["accepted"] != true {
            let reason = value["reason"].as_str().unwrap_or_default();
            return Ok(Outcome::Refused {
                message: explain(reason, value["http"].as_u64()),
            });
        }
        if let Some(models) = value["models"].as_array() {
            return Ok(Outcome::Models {
                revision: clean(value, "revision"),
                complete: value["truncated"] == false && models.len() <= 500,
                ids: models
                    .iter()
                    .filter_map(|row| clean(&serde_json::json!({ "id": row }), "id"))
                    .take(500)
                    .collect(),
            });
        }
        let api = clean(value, "api").ok_or(UNAVAILABLE)?;
        if !pi_providers::Api::ALL.iter().any(|known| known.id() == api) {
            return Err(UNAVAILABLE.into());
        }
        Ok(Outcome::Accepted {
            api,
            revision: clean(value, "revision"),
        })
    }
}

/// The endpoint identity every action shares, so no caller can mix two drafts.
pub struct Target {
    pub provider: String,
    pub base_url: String,
    pub mode: Mode,
    pub nonce: String,
    pub key: String,
    pub self_hosted: bool,
}

/// One in-flight connection action, bound to the draft generation that asked.
pub struct Connection {
    job: Option<(u64, Job)>,
}

impl Connection {
    pub fn new() -> Self {
        Self { job: None }
    }

    pub fn busy(&self) -> bool {
        self.job.is_some()
    }

    pub fn cancel(&mut self) {
        self.job = None;
    }

    /// Test seam: install a real job without spawning the bundled helper.
    #[cfg(test)]
    pub fn set_job_for_test(&mut self, generation: u64, job: Job) {
        self.job = Some((generation, job));
    }

    /// Ask which credential a provider would use, without resolving material here.
    pub fn inspect(
        &mut self,
        resources: &Path,
        agent: &Path,
        generation: u64,
        target: &Target,
    ) -> Result<(), String> {
        let mode = target
            .mode
            .id()
            .ok_or("Authentication is deferred to Pi /login")?;
        let mut request = serde_json::json!({
            "version": 1, "action": "inspect", "agentDir": agent, "provider": target.provider,
            "mode": mode, "nonce": target.nonce,
            "key": (target.mode == Mode::New).then_some(&target.key),
        });
        if !target.base_url.is_empty() {
            request["baseUrl"] = Value::String(target.base_url.clone());
        }
        self.start(
            resources,
            CREDENTIALS,
            request,
            generation,
            Duration::from_secs(10),
        )
    }

    /// List the models one configured endpoint itself reports.
    pub fn discover(
        &mut self,
        resources: &Path,
        agent: &Path,
        generation: u64,
        target: &Target,
        preset: &str,
    ) -> Result<(), String> {
        let mode = target
            .mode
            .id()
            .ok_or("Authentication is deferred to Pi /login")?;
        let request = serde_json::json!({
            "version": 1, "action": "discover", "agentDir": agent, "provider": target.provider,
            "preset": preset, "baseUrl": target.base_url, "mode": mode,
            "nonce": target.nonce, "selfHosted": target.self_hosted,
            "key": (target.mode == Mode::New).then_some(&target.key),
        });
        self.start(
            resources,
            CONNECT,
            request,
            generation,
            Duration::from_secs(15),
        )
    }

    /// Send one explicitly confirmed, tiny request to the exact endpoint.
    pub fn probe(
        &mut self,
        resources: &Path,
        agent: &Path,
        generation: u64,
        target: &Target,
        api: Option<&str>,
        model: &str,
    ) -> Result<(), String> {
        let mode = target
            .mode
            .id()
            .ok_or("Authentication is deferred to Pi /login")?;
        let request = serde_json::json!({
            "version": 1, "action": "probe", "agentDir": agent, "provider": target.provider,
            "baseUrl": target.base_url, "api": api.unwrap_or("auto"), "model": model,
            "mode": mode, "nonce": target.nonce, "consent": true,
            // Auto selects an API family, never a broader destination policy.
            "selfHosted": target.self_hosted,
            "key": (target.mode == Mode::New).then_some(&target.key),
        });
        self.start(
            resources,
            CONNECT,
            request,
            generation,
            Duration::from_secs(100),
        )
    }

    fn start(
        &mut self,
        resources: &Path,
        helper: &str,
        request: Value,
        generation: u64,
        timeout: Duration,
    ) -> Result<(), String> {
        let job = Job::start_helper(resources, helper, request, timeout)?;
        self.job = Some((generation, job));
        Ok(())
    }

    /// Results from an older draft are discarded, never applied to this one.
    pub fn poll(&mut self, generation: u64) -> Option<Result<Outcome, String>> {
        let (started, job) = self.job.as_mut()?;
        let started = *started;
        let result = job.poll_json()?;
        self.job = None;
        if started != generation {
            return None;
        }
        Some(result.and_then(|value| Outcome::parse(&value)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn typed_keys_reach_the_bounded_helper_on_stdin_not_argv() {
        use std::{fs, os::unix::fs::PermissionsExt};
        let root = std::env::temp_dir().join(format!(
            "mash-probe-stdin-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(root.join("node/bin")).unwrap();
        let node = root.join("node/bin/node");
        fs::write(&node, "#!/bin/sh\n/bin/cat > request.json\nprintf '%s\\n' \"$@\" > argv.txt\nprintf '{\"version\":1,\"status\":\"ok\",\"accepted\":true,\"api\":\"openai-responses\"}\\n'\n").unwrap();
        fs::set_permissions(&node, fs::Permissions::from_mode(0o755)).unwrap();
        let mut connection = Connection::new();
        let target = Target {
            provider: "fixture".into(),
            base_url: "https://example.invalid/v1".into(),
            mode: Mode::New,
            nonce: "a".repeat(64),
            key: "fake-private-key".into(),
            self_hosted: false,
        };
        connection
            .probe(&root, &root.join("agent"), 1, &target, None, "exact-model")
            .unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while connection.busy() {
            let _ = connection.poll(1);
            assert!(std::time::Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(5));
        }
        let request: Value =
            serde_json::from_slice(&fs::read(root.join("request.json")).unwrap()).unwrap();
        assert_eq!(request["key"], "fake-private-key");
        assert_eq!(
            request["selfHosted"], false,
            "Auto is not permission to contact private hosts"
        );
        assert!(!fs::read_to_string(root.join("argv.txt"))
            .unwrap()
            .contains("fake-private-key"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn presets_are_distinct_local_chat_completions_routes() {
        assert_eq!(PRESETS.len(), 4);
        for preset in &PRESETS {
            assert!(preset.base_url.starts_with("http://"));
            assert!(preset.base_url.ends_with("/v1"));
            assert!(!PRESETS
                .iter()
                .any(|other| !std::ptr::eq(other, preset) && other.base_url == preset.base_url));
        }
        assert!(PRESETS[0].requires_model && !PRESETS[2].requires_model);
    }

    #[test]
    fn typed_outcomes_separate_source_catalog_acceptance_and_refusal() {
        let source = Outcome::parse(&json!({"version":1,"status":"ok","ready":true,"source":"saved","label":"Saved Pi credential","revision":"ab"})).unwrap();
        assert_eq!(
            source,
            Outcome::Source {
                label: "Saved Pi credential".into(),
                ready: true,
                reason: None,
                revision: "ab".into()
            }
        );
        let models = Outcome::parse(
            &json!({"version":1,"status":"ok","accepted":true,"models":["a:1","\u{1b}bad",""]}),
        )
        .unwrap();
        assert_eq!(
            models,
            Outcome::Models {
                ids: vec!["a:1".into()],
                revision: None,
                complete: false,
            }
        );
        assert_eq!(
            Outcome::parse(
                &json!({"version":1,"status":"ok","accepted":true,"api":"openai-responses"})
            )
            .unwrap(),
            Outcome::Accepted {
                api: "openai-responses".into(),
                revision: None,
            }
        );
        let refused = Outcome::parse(
            &json!({"version":1,"status":"ok","accepted":false,"reason":"unauthorized"}),
        )
        .unwrap();
        assert!(matches!(refused, Outcome::Refused { message } if message.contains("rejected")));
        assert!(Outcome::parse(&json!({"version":1,"status":"unavailable","reason":"x"})).is_err());
    }

    #[test]
    fn a_stale_generation_result_never_reaches_the_current_draft() {
        let mut connection = Connection::new();
        let mut command = std::process::Command::new("/bin/sh");
        command.args([
            "-c",
            "cat >/dev/null; printf '{\"version\":1,\"status\":\"ok\",\"accepted\":true,\"api\":\"openai-completions\"}'",
        ]);
        connection.job = Some((
            7,
            Job::spawn_for_test(command, b"{}".to_vec(), Duration::from_secs(5)).unwrap(),
        ));
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        loop {
            match connection.poll(8) {
                Some(_) => panic!("an obsolete draft result was accepted"),
                None if !connection.busy() => break,
                None => assert!(std::time::Instant::now() < deadline, "child never finished"),
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}
