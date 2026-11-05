//! Embedded wizard catalogs and the current setup language.
use serde_json::Value;
use std::{
    collections::HashMap,
    sync::atomic::{AtomicUsize, Ordering},
    sync::OnceLock,
};

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

static CURRENT: AtomicUsize = AtomicUsize::new(3);
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

pub fn language() -> &'static str {
    CATALOGS[CURRENT.load(Ordering::Relaxed)].0
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
    let english = catalogs()["en"][key].as_str().unwrap_or(key);
    let value = &catalogs()[language()][key];
    value
        .as_str()
        .or_else(|| value["text"].as_str())
        .unwrap_or(english)
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn english_catalog_loads_by_default() {
        assert_eq!(language(), "en");
        assert_eq!(t("wizard.language.title"), "Choose your language");
        assert!(!set_language("xx"));
    }
}
