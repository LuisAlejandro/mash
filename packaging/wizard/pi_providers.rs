//! Non-secret facts from the pinned Pi, embedded like the Voice catalogs.
use serde_json::Value;
use std::{collections::HashSet, sync::OnceLock};

const CATALOG: &str = include_str!("data/pi-providers.json");
const INVALID: &str = "Invalid bundled Pi provider catalog";

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Api {
    #[default]
    Chat,
    Responses,
    Anthropic,
}

impl Api {
    pub const ALL: [Self; 3] = [Self::Chat, Self::Responses, Self::Anthropic];

    pub fn label(self) -> &'static str {
        match self {
            Self::Chat => "OpenAI Chat Completions",
            Self::Responses => "OpenAI Responses",
            Self::Anthropic => "Anthropic Messages",
        }
    }

    pub fn id(self) -> &'static str {
        match self {
            Self::Chat => "openai-completions",
            Self::Responses => "openai-responses",
            Self::Anthropic => "anthropic-messages",
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub struct Provider {
    pub id: String,
    pub name: String,
    pub chat: bool,
    pub api_key: bool,
    pub key_name: String,
    pub oauth: bool,
}

impl Provider {
    pub fn can_configure(&self) -> bool {
        self.api_key
            && !matches!(
                self.id.as_str(),
                "azure" | "cloudflare-ai-gateway" | "cloudflare-workers-ai"
            )
    }

    pub fn key_label(&self) -> &str {
        match self.id.as_str() {
            "amazon-bedrock" => "Bedrock bearer token",
            "google-vertex" => "Google Cloud API key",
            _ => &self.key_name,
        }
    }

    pub fn guidance(&self) -> Option<String> {
        let detail = match self.id.as_str() {
            "azure" => "Set AZURE_OPENAI_BASE_URL or AZURE_OPENAI_RESOURCE_NAME, then use /login azure in Pi. Continue keeps your current Pi configuration.",
            "cloudflare-ai-gateway" => "Requires a token, account ID and gateway ID. Use /login cloudflare-ai-gateway in Pi. Continue keeps your current Pi configuration.",
            "cloudflare-workers-ai" => "Requires a token and account ID. Use /login cloudflare-workers-ai in Pi. Continue keeps your current Pi configuration.",
            "amazon-bedrock" => "Enter a Bedrock bearer token, not an AWS access-key ID. For AWS profiles or IAM, use /login amazon-bedrock in Pi.",
            "google-vertex" => "Enter a Google Cloud API key. For ADC or a service-account file, use /login google-vertex in Pi.",
            _ if !self.api_key => return Some(format!("After setup, use /login {} in Pi. Continue keeps your current Pi configuration.", self.id)),
            _ if self.oauth => return Some(format!("Use an API key here. For browser/device sign-in, use /login {} in Pi after setup.", self.id)),
            _ => return None,
        };
        Some(detail.into())
    }
}

pub fn rank(id: &str) -> usize {
    ["openai", "anthropic", "xai", "google", "openrouter"]
        .iter()
        .position(|featured| *featured == id)
        .unwrap_or(usize::MAX)
}

fn parse(text: &str) -> Result<Vec<Provider>, &'static str> {
    let value: Value = serde_json::from_str(text).map_err(|_| INVALID)?;
    if value["version"] != 1 || value["status"] != "ok" || value["serverVerified"] != false {
        return Err(INVALID);
    }
    let string = |v: &Value, empty: bool| -> Result<String, &'static str> {
        let s = v.as_str().ok_or(INVALID)?;
        if (!empty && s.is_empty()) || s.len() > 1024 || s.chars().any(char::is_control) {
            return Err(INVALID);
        }
        Ok(s.into())
    };
    string(&value["piVersion"], false)?;
    let rows = value["providers"].as_array().ok_or(INVALID)?;
    if rows.is_empty() {
        return Err(INVALID);
    }
    let mut ids = HashSet::new();
    rows.iter()
        .map(|row| {
            let id = string(&row["id"], false)?;
            if !ids.insert(id.clone()) {
                return Err(INVALID);
            }
            let api_key = row["apiKey"].as_bool().ok_or(INVALID)?;
            Ok(Provider {
                id,
                name: string(&row["name"], false)?,
                chat: row["chat"].as_bool().ok_or(INVALID)?,
                api_key,
                key_name: string(&row["keyName"], !api_key)?,
                oauth: row["oauth"].as_bool().ok_or(INVALID)?,
            })
        })
        .collect()
}

pub fn all() -> &'static [Provider] {
    static DATA: OnceLock<Vec<Provider>> = OnceLock::new();
    DATA.get_or_init(|| parse(CATALOG).expect(INVALID))
}

pub fn get(id: &str) -> Option<&'static Provider> {
    all().iter().find(|provider| provider.id == id)
}

pub fn reserved(id: &str) -> bool {
    id == "none" || get(id).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_facts_include_auth_methods_and_non_chat_reserved_ids() {
        let openai = get("openai").unwrap();
        assert!(openai.chat && openai.api_key && openai.oauth);
        assert_eq!(openai.name, "OpenAI");
        assert!(!get("typesafe").unwrap().chat);
        assert!(reserved("typesafe") && reserved("google") && reserved("none"));
        assert!(!reserved("my-gateway"));
        let codex = get("openai-codex").unwrap();
        assert!(codex.chat && codex.oauth && !codex.api_key);
    }

    #[test]
    fn auth_capability_is_not_confused_with_complete_single_key_setup() {
        for id in [
            "azure",
            "cloudflare-ai-gateway",
            "cloudflare-workers-ai",
            "openai-codex",
        ] {
            let provider = get(id).unwrap();
            assert!(!provider.can_configure(), "{id}");
            assert!(provider.guidance().unwrap().contains("/login"));
        }
        assert!(get("azure")
            .unwrap()
            .guidance()
            .unwrap()
            .contains("AZURE_OPENAI_BASE_URL"));
        assert!(get("google-vertex").unwrap().can_configure());
        assert_eq!(
            get("google-vertex").unwrap().key_label(),
            "Google Cloud API key"
        );
        assert!(get("amazon-bedrock").unwrap().can_configure());
        assert_eq!(
            get("amazon-bedrock").unwrap().key_label(),
            "Bedrock bearer token"
        );
        assert!(get("openai").unwrap().can_configure());
        assert!(get("openai")
            .unwrap()
            .guidance()
            .unwrap()
            .contains("browser/device"));
    }

    #[test]
    fn invalid_catalogs_cannot_create_duplicate_or_unsafe_choices() {
        let source: Value = serde_json::from_str(CATALOG).unwrap();
        for field in ["id", "name", "keyName"] {
            let mut value = source.clone();
            value["providers"][0][field] = Value::String("unsafe\u{1}".into());
            assert!(parse(&value.to_string()).is_err());
        }
        let mut value = source.clone();
        value["providers"] = serde_json::json!([]);
        assert!(parse(&value.to_string()).is_err());
        value["providers"] = serde_json::json!([source["providers"][0], source["providers"][0]]);
        assert!(parse(&value.to_string()).is_err());
        assert!(parse("invalid JSON").is_err());
    }
}
