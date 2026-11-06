//! UI text in the language Mash chose in the wizard (`MASH_LANGUAGE`).
//!
//! The catalogs are shared by every Rust component in
//! `packaging/i18n/messages/plugins-rust/` and are embedded at compile time, so
//! the crate builds from the repository with no runtime file. An unset or
//! unknown language, or a key a catalog lacks, falls back to English.

use std::collections::HashMap;
use std::sync::OnceLock;

/// Every language code the catalogs ship, as written in `languages.json`.
const CODES: &[&str] = &[
    "bg", "cs", "de", "en", "es", "fr", "it", "ja", "ko", "pt-BR", "ru", "th", "uk", "vi", "zh-CN",
];

const ENGLISH: &str = include_str!("../../../i18n/messages/plugins-rust/en.json");

/// Non-English catalogs. English is the source and lives in `ENGLISH`.
const CATALOGS: &[(&str, &str)] = &[
    (
        "bg",
        include_str!("../../../i18n/messages/plugins-rust/bg.json"),
    ),
    (
        "cs",
        include_str!("../../../i18n/messages/plugins-rust/cs.json"),
    ),
    (
        "de",
        include_str!("../../../i18n/messages/plugins-rust/de.json"),
    ),
    (
        "es",
        include_str!("../../../i18n/messages/plugins-rust/es.json"),
    ),
    (
        "fr",
        include_str!("../../../i18n/messages/plugins-rust/fr.json"),
    ),
    (
        "it",
        include_str!("../../../i18n/messages/plugins-rust/it.json"),
    ),
    (
        "ja",
        include_str!("../../../i18n/messages/plugins-rust/ja.json"),
    ),
    (
        "ko",
        include_str!("../../../i18n/messages/plugins-rust/ko.json"),
    ),
    (
        "pt-BR",
        include_str!("../../../i18n/messages/plugins-rust/pt-BR.json"),
    ),
    (
        "ru",
        include_str!("../../../i18n/messages/plugins-rust/ru.json"),
    ),
    (
        "th",
        include_str!("../../../i18n/messages/plugins-rust/th.json"),
    ),
    (
        "uk",
        include_str!("../../../i18n/messages/plugins-rust/uk.json"),
    ),
    (
        "vi",
        include_str!("../../../i18n/messages/plugins-rust/vi.json"),
    ),
    (
        "zh-CN",
        include_str!("../../../i18n/messages/plugins-rust/zh-CN.json"),
    ),
];

type Table = HashMap<String, String>;

/// Map a raw `MASH_LANGUAGE` value to a supported code. Anything else is English.
pub fn resolve_language(raw: Option<&str>) -> &'static str {
    let wanted = raw.unwrap_or("").trim();
    CODES
        .iter()
        .copied()
        .find(|code| code.eq_ignore_ascii_case(wanted))
        .unwrap_or("en")
}

/// Read a catalog file. Entries are either a plain string (English) or
/// `{"text": ..., "source_hash": ...}` (translations).
fn parse(raw: &str) -> Table {
    let Ok(serde_json::Value::Object(map)) = serde_json::from_str::<serde_json::Value>(raw) else {
        return Table::new();
    };
    map.into_iter()
        .filter_map(|(key, value)| {
            let text = match value {
                serde_json::Value::String(s) => s,
                serde_json::Value::Object(entry) => entry.get("text")?.as_str()?.to_string(),
                _ => return None,
            };
            Some((key, text))
        })
        .collect()
}

fn table_for(lang: &str) -> Table {
    CATALOGS
        .iter()
        .find(|(code, _)| *code == lang)
        .map(|(_, raw)| parse(raw))
        .unwrap_or_default()
}

fn english() -> &'static Table {
    static TABLE: OnceLock<Table> = OnceLock::new();
    TABLE.get_or_init(|| parse(ENGLISH))
}

fn active() -> &'static Table {
    static TABLE: OnceLock<Table> = OnceLock::new();
    TABLE.get_or_init(|| {
        let lang = resolve_language(std::env::var("MASH_LANGUAGE").ok().as_deref());
        table_for(lang)
    })
}

fn lookup(table: &Table, key: &str) -> String {
    table
        .get(key)
        .or_else(|| english().get(key))
        .cloned()
        .unwrap_or_else(|| key.to_string())
}

/// The text for `key` in the language Mash chose.
pub fn t(key: &str) -> String {
    lookup(active(), key)
}

/// The text for `key` in one supported language, falling back to English.
#[allow(dead_code)]
pub fn text_in(lang: &str, key: &str) -> String {
    lookup(&table_for(lang), key)
}

/// Every supported language code, in catalog order.
#[allow(dead_code)]
pub fn languages() -> impl Iterator<Item = &'static str> {
    CATALOGS.iter().map(|(code, _)| *code)
}

/// Replace `{name}` placeholders in a translated template.
pub fn fill(template: &str, vars: &[(&str, &str)]) -> String {
    vars.iter()
        .fold(template.to_string(), |acc, (name, value)| {
            acc.replace(&format!("{{{name}}}"), value)
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn placeholders(text: &str) -> Vec<String> {
        let mut found: Vec<String> = text
            .split('{')
            .skip(1)
            .filter_map(|rest| rest.split('}').next())
            .map(str::to_string)
            .collect();
        found.sort();
        found
    }

    #[test]
    fn unset_unknown_and_empty_languages_are_english() {
        assert_eq!(resolve_language(None), "en");
        assert_eq!(resolve_language(Some("")), "en");
        assert_eq!(resolve_language(Some("xx")), "en");
        assert_eq!(resolve_language(Some("  ")), "en");
    }

    #[test]
    fn known_languages_resolve_case_insensitively() {
        assert_eq!(resolve_language(Some("fr")), "fr");
        assert_eq!(resolve_language(Some("pt-br")), "pt-BR");
        assert_eq!(resolve_language(Some(" zh-CN ")), "zh-CN");
    }

    #[test]
    fn every_catalog_has_the_english_keys_and_placeholders() {
        for (code, raw) in CATALOGS {
            let table = parse(raw);
            assert_eq!(table.len(), english().len(), "{code} key count");
            for (key, en) in english() {
                let text = table
                    .get(key)
                    .unwrap_or_else(|| panic!("{code} lacks {key}"));
                assert!(!text.is_empty(), "{code} {key} is empty");
                assert_eq!(placeholders(text), placeholders(en), "{code} {key}");
            }
        }
    }

    #[test]
    fn a_named_language_translates_and_english_is_the_fallback() {
        let fr = lookup(&table_for("fr"), "plugin.herdr-workspace.form.directory");
        assert_eq!(fr, "Dossier");
        assert_eq!(
            lookup(&table_for("xx"), "plugin.herdr-workspace.form.directory"),
            "Directory"
        );
        assert_eq!(
            lookup(&Table::new(), "plugin.missing.key"),
            "plugin.missing.key"
        );
    }

    #[test]
    fn fill_replaces_placeholders() {
        assert_eq!(
            fill("unknown ref `{ref}`", &[("ref", "main")]),
            "unknown ref `main`"
        );
    }
}
