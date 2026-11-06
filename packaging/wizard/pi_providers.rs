//! Non-secret facts from the pinned Pi, embedded like the Voice catalogs.
use serde_json::Value;
use std::{collections::HashSet, sync::OnceLock};

use crate::i18n;

const CATALOG: &str = include_str!("data/pi-providers.json");
fn invalid() -> String {
    i18n::t("wizard.providers.invalid_catalog")
}

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

/// Per-provider setup facts in one place: the deferred-login note and the form
/// hint describe the same requirement and must not drift apart. Text is looked
/// up per language, so each lookup is a literal catalog key.
fn setup_row(id: &str) -> Option<(String, String)> {
    let row = match id {
        "azure" => (
            i18n::t("wizard.providers.hint.azure"),
            i18n::t("wizard.providers.guidance.azure"),
        ),
        "cloudflare-ai-gateway" => (
            i18n::t("wizard.providers.hint.cloudflare_gateway"),
            i18n::t("wizard.providers.guidance.cloudflare_gateway"),
        ),
        "cloudflare-workers-ai" => (
            i18n::t("wizard.providers.hint.cloudflare_workers"),
            i18n::t("wizard.providers.guidance.cloudflare_workers"),
        ),
        "amazon-bedrock" => (
            i18n::t("wizard.providers.hint.bedrock"),
            i18n::t("wizard.providers.guidance.bedrock"),
        ),
        "google-vertex" => (
            i18n::t("wizard.providers.hint.vertex"),
            i18n::t("wizard.providers.guidance.vertex"),
        ),
        _ => return None,
    };
    Some(row)
}

impl Provider {
    pub fn can_configure(&self) -> bool {
        self.api_key
            && !matches!(
                self.id.as_str(),
                "azure" | "cloudflare-ai-gateway" | "cloudflare-workers-ai"
            )
    }

    pub fn key_label(&self) -> String {
        match self.id.as_str() {
            "amazon-bedrock" => i18n::t("wizard.providers.key_bedrock"),
            "google-vertex" => i18n::fill(
                &i18n::t("wizard.providers.key_api"),
                &[("name", &"Google Cloud")],
            ),
            _ => localized_key_name(&self.key_name),
        }
    }

    pub fn login_guidance(&self) -> String {
        let base = i18n::fill(
            &i18n::t("wizard.providers.login_deferred"),
            &[("id", &&self.id)],
        );
        match setup_row(&self.id) {
            Some((hint, _)) => format!("{base} {hint}"),
            None => base,
        }
    }

    pub fn guidance(&self) -> Option<String> {
        if let Some((_, guidance)) = setup_row(&self.id) {
            return Some(guidance);
        }
        if !self.api_key {
            return Some(i18n::fill(
                &i18n::t("wizard.providers.guidance.generic"),
                &[("id", &&self.id)],
            ));
        }
        if self.oauth {
            return Some(i18n::fill(
                &i18n::t("wizard.providers.guidance.oauth"),
                &[("id", &&self.id)],
            ));
        }
        None
    }
}

/// Key names come from the bundled catalog. Common shapes are translated by
/// pattern; any other name is shown as the catalog gives it.
fn localized_key_name(key_name: &str) -> String {
    if let Some(name) = key_name.strip_suffix(" API key") {
        return i18n::fill(&i18n::t("wizard.providers.key_api"), &[("name", &name)]);
    }
    if let Some(name) = key_name.strip_suffix(" token") {
        return i18n::fill(&i18n::t("wizard.providers.key_token"), &[("name", &name)]);
    }
    match key_name {
        "AWS credentials or bearer token" => i18n::t("wizard.providers.key_aws"),
        "Google Cloud credentials" => i18n::t("wizard.providers.key_gcloud"),
        other => other.to_string(),
    }
}

pub fn rank(id: &str) -> usize {
    ["openai", "anthropic", "xai", "google", "openrouter"]
        .iter()
        .position(|featured| *featured == id)
        .unwrap_or(usize::MAX)
}

fn parse(text: &str) -> Result<Vec<Provider>, String> {
    let value: Value = serde_json::from_str(text).map_err(|_| invalid())?;
    if value["version"] != 1 || value["status"] != "ok" || value["serverVerified"] != false {
        return Err(invalid());
    }
    let string = |v: &Value, empty: bool| -> Result<String, String> {
        let s = v.as_str().ok_or_else(invalid)?;
        if (!empty && s.is_empty()) || s.len() > 1024 || s.chars().any(char::is_control) {
            return Err(invalid());
        }
        Ok(s.into())
    };
    string(&value["piVersion"], false)?;
    let rows = value["providers"].as_array().ok_or_else(invalid)?;
    if rows.is_empty() {
        return Err(invalid());
    }
    let mut ids = HashSet::new();
    rows.iter()
        .map(|row| {
            let id = string(&row["id"], false)?;
            if !ids.insert(id.clone()) {
                return Err(invalid());
            }
            let api_key = row["apiKey"].as_bool().ok_or_else(invalid)?;
            Ok(Provider {
                id,
                name: string(&row["name"], false)?,
                chat: row["chat"].as_bool().ok_or_else(invalid)?,
                api_key,
                key_name: string(&row["keyName"], !api_key)?,
                oauth: row["oauth"].as_bool().ok_or_else(invalid)?,
            })
        })
        .collect()
}

pub fn all() -> &'static [Provider] {
    static DATA: OnceLock<Vec<Provider>> = OnceLock::new();
    DATA.get_or_init(|| parse(CATALOG).expect(&invalid()))
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
