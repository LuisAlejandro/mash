//! Embedded wizard catalogs and the current setup language.
use serde_json::Value;
use std::{
    collections::HashMap,
    sync::atomic::{AtomicUsize, Ordering},
    sync::OnceLock,
};

#[cfg(test)]
use std::cell::Cell;

const CATALOGS: &[(&str, &str)] = &[
    ("bg", include_str!("../i18n/messages/wizard/bg.json")),
    ("cs", include_str!("../i18n/messages/wizard/cs.json")),
    ("de", include_str!("../i18n/messages/wizard/de.json")),
    ("en", include_str!("../i18n/messages/wizard/en.json")),
    ("es", include_str!("../i18n/messages/wizard/es.json")),
    ("fr", include_str!("../i18n/messages/wizard/fr.json")),
    ("it", include_str!("../i18n/messages/wizard/it.json")),
    ("ja", include_str!("../i18n/messages/wizard/ja.json")),
    ("ko", include_str!("../i18n/messages/wizard/ko.json")),
    ("pt-BR", include_str!("../i18n/messages/wizard/pt-BR.json")),
    ("ru", include_str!("../i18n/messages/wizard/ru.json")),
    ("th", include_str!("../i18n/messages/wizard/th.json")),
    ("uk", include_str!("../i18n/messages/wizard/uk.json")),
    ("vi", include_str!("../i18n/messages/wizard/vi.json")),
    ("zh-CN", include_str!("../i18n/messages/wizard/zh-CN.json")),
];

/// Index of the current language in CATALOGS. usize::MAX means "not chosen yet",
/// which reads as English, so the default never depends on the list's order.
static CURRENT: AtomicUsize = AtomicUsize::new(usize::MAX);

fn english_index() -> usize {
    CATALOGS
        .iter()
        .position(|(code, _)| *code == "en")
        .expect("the wizard ships an English catalog")
}
static PARSED: OnceLock<HashMap<&'static str, Value>> = OnceLock::new();

fn catalogs() -> &'static HashMap<&'static str, Value> {
    PARSED.get_or_init(|| {
        CATALOGS
            .iter()
            .map(|(code, json)| {
                (
                    *code,
                    serde_json::from_str(json).expect("wizard catalog is valid JSON"),
                )
            })
            .collect()
    })
}

#[cfg(test)]
thread_local! {
    static THREAD_LANGUAGE: Cell<Option<usize>> = const { Cell::new(None) };
}

pub fn language() -> &'static str {
    // Tests render several languages in parallel. A thread-local override keeps
    // one test's Spanish screen from rewriting the language every other test sees.
    #[cfg(test)]
    if let Some(index) = THREAD_LANGUAGE.with(Cell::get) {
        return CATALOGS[index].0;
    }
    match CURRENT.load(Ordering::Relaxed) {
        usize::MAX => CATALOGS[english_index()].0,
        index => CATALOGS[index].0,
    }
}

#[cfg(test)]
pub struct LanguageOverride;

#[cfg(test)]
impl Drop for LanguageOverride {
    fn drop(&mut self) {
        THREAD_LANGUAGE.with(|cell| cell.set(None));
    }
}

/// Render `code` from `t` on this test thread, then restore the process default.
#[cfg(test)]
pub fn override_language(code: &str) -> LanguageOverride {
    let index = CATALOGS
        .iter()
        .position(|(candidate, _)| *candidate == code)
        .unwrap_or_else(|| panic!("unknown language {code}"));
    THREAD_LANGUAGE.with(|cell| cell.set(Some(index)));
    LanguageOverride
}

#[cfg(test)]
pub fn language_codes() -> impl Iterator<Item = &'static str> {
    CATALOGS.iter().map(|(code, _)| *code)
}

pub fn set_language(code: &str) -> bool {
    let Some(index) = CATALOGS
        .iter()
        .position(|(candidate, _)| *candidate == code)
    else {
        return false;
    };
    CURRENT.store(index, Ordering::Relaxed);
    true
}

pub fn t(key: &str) -> String {
    text_in(language(), key)
}

/// A key's text in one language, without changing the current language. Falls
/// back to English, then to the key itself.
pub fn text_in(code: &str, key: &str) -> String {
    let english = catalogs()["en"][key].as_str().unwrap_or(key);
    let value = catalogs()
        .get(code)
        .map_or(&Value::Null, |catalog| &catalog[key]);
    value
        .as_str()
        .or_else(|| value["text"].as_str())
        .unwrap_or(english)
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    // Covers AE1: every page's text comes from the chosen language's catalog.
    #[test]
    fn spanish_titles_come_from_the_spanish_catalog() {
        let spanish = text_in("es", "wizard.language.title");
        assert_ne!(spanish, text_in("en", "wizard.language.title"));
        assert!(!spanish.is_empty() && spanish != "wizard.language.title");
    }

    #[test]
    fn english_catalog_loads_by_default() {
        assert_eq!(language(), "en");
        assert_eq!(t("wizard.language.title"), "Choose your language");
        assert!(!set_language("xx"));
    }
}
