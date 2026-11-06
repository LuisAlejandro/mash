//! Pi Voice model selection, matching the picks `@earendil-works/pi-voice`'s
//! own onboarding would make.
//!
//! Both data files are vendored from the pinned package and the build fails
//! when they drift (`packaging/build.sh`), so the wizard can never offer a
//! model the extension would not have chosen. The scoring below is a port of
//! the extension's `scoreModels`/`recommendModels`: a geometric mean of the
//! per-language error plus a penalty for waiting, with accuracy as a hard
//! constraint first.

use crate::i18n;
use serde_json::Value;
use std::cmp::Ordering;
use std::collections::HashSet;
use std::sync::OnceLock;

const CATALOG_JSON: &str = include_str!("data/catalog.json");
const RECOMMENDATIONS_JSON: &str = include_str!("data/recommendations.json");

// The extension's benchmark reference is a 30-second dictation, and these are
// the constants recommendations.json carries in its `methodology` block.
const DICTATION_SECONDS: f64 = 30.0;
const FREE_WAIT_SECONDS: f64 = 3.0;
const WAIT_WEIGHT: f64 = 0.5;
const OVERALL_MAX_WAIT_SECONDS: f64 = 5.0;
const MAX_LANGUAGE_ERROR_PERCENT: f64 = 20.0;
const EXPERIMENTAL_MAX_ERROR_PERCENT: f64 = 30.0;
const FAST_CPU_MAX_WAIT_SECONDS: f64 = 4.0;

/// What the wizard hands to `mash-voice-model`.
pub struct VoiceChoice {
    pub model_id: String,
    pub languages: Vec<String>,
    /// Whether to ship `voxlingua107` as well. True exactly when the chosen
    /// model has no native detection and covers more than one language — the
    /// same `requiresLanguageDetector` rule the extension uses before it
    /// downloads the detector.
    pub needs_detector: bool,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Best,
    Fast,
}

impl Role {
    pub fn label(self) -> String {
        match self {
            Role::Best => i18n::t("wizard.voice.best"),
            Role::Fast => i18n::t("wizard.voice.fast"),
        }
    }

    pub fn summary(self) -> String {
        match self {
            Role::Best => i18n::t("wizard.voice.best_summary"),
            Role::Fast => i18n::t("wizard.voice.fast_summary"),
        }
    }
}

/// A model the wizard can offer, with just what the pick pane draws.
#[derive(Clone)]
pub struct Model {
    pub id: String,
    pub name: String,
    pub bytes: u64,
    /// Seconds to transcribe the 30-second reference dictation.
    pub wait_seconds: f64,
    /// Multilingual without native detection: install the detector with it.
    pub needs_detector: bool,
}

impl Model {
    pub fn row(&self) -> String {
        format!(
            "{:<30} {:>9}   ~{:.1} s / 30 s",
            self.name,
            human_size(self.bytes),
            self.wait_seconds
        )
    }
}

pub struct Pick {
    pub best: Model,
    pub fast: Model,
}

impl Pick {
    pub fn model(&self, role: Role) -> &Model {
        match role {
            Role::Best => &self.best,
            Role::Fast => &self.fast,
        }
    }

    /// The same model winning both roles is common; say so once on screen.
    pub fn same_model(&self) -> bool {
        self.best.id == self.fast.id
    }
}

struct Data {
    catalog: Value,
    recommendations: Value,
}

impl Data {
    fn models(&self) -> &[Value] {
        self.catalog["models"]
            .as_array()
            .expect("catalog.json carries a models array")
    }

    fn detector(&self) -> &Value {
        &self.catalog["languageDetector"]
    }
}

fn data() -> &'static Data {
    static DATA: OnceLock<Data> = OnceLock::new();
    DATA.get_or_init(|| Data {
        catalog: serde_json::from_str(CATALOG_JSON).expect("catalog.json is valid JSON"),
        recommendations: serde_json::from_str(RECOMMENDATIONS_JSON)
            .expect("recommendations.json is valid JSON"),
    })
}

fn text<'a>(value: &'a Value, key: &str) -> &'a str {
    value[key].as_str().unwrap_or("")
}

fn number(value: &Value, key: &str) -> u64 {
    value[key].as_u64().unwrap_or(0)
}

/// A base code, without changing the model's exact code.
fn canonical(language: &str) -> String {
    language
        .trim()
        .to_lowercase()
        .split('-')
        .next()
        .unwrap_or("")
        .to_string()
}

/// The identity the model cards, benchmarks and detector share. `iw`/`jw` are
/// the legacy codes Hebrew and Javanese use in some model cards.
fn identity(language: &str) -> String {
    match canonical(language).as_str() {
        "tl" => "fil".to_string(),
        "no" => "nb".to_string(),
        "iw" => "he".to_string(),
        "jw" => "jv".to_string(),
        other => other.to_string(),
    }
}

fn languages_of(model: &Value) -> Vec<String> {
    model["languages"]
        .as_array()
        .map(|list| {
            list.iter()
                .filter_map(|code| code.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

/// The model's exact code for a language, preserving a regional variant.
fn model_language(model: &Value, language: &str) -> Option<String> {
    let languages = languages_of(model);
    let wanted = language.trim().to_lowercase();
    if let Some(exact) = languages.iter().find(|code| code.to_lowercase() == wanted) {
        return Some(exact.clone());
    }
    let wanted_identity = identity(language);
    languages
        .into_iter()
        .find(|code| identity(code) == wanted_identity)
}

fn matches(model: &Value, language: &str) -> bool {
    model_language(model, language).is_some()
}

fn native_detection(model: &Value) -> bool {
    model["capabilities"]["languageDetection"]
        .as_bool()
        .unwrap_or(false)
}

fn requires_detector(model: &Value) -> bool {
    if native_detection(model) {
        return false;
    }
    let distinct: HashSet<String> = languages_of(model)
        .iter()
        .map(|code| identity(code))
        .collect();
    distinct.len() > 1
}

fn detector_codes() -> &'static HashSet<String> {
    static CODES: OnceLock<HashSet<String>> = OnceLock::new();
    CODES.get_or_init(|| {
        data().detector()["languages"]
            .as_array()
            .map(|list| {
                list.iter()
                    .filter_map(|code| code.as_str())
                    .map(identity)
                    .collect()
            })
            .unwrap_or_default()
    })
}

/// Preferred languages the external detector cannot identify. Non-zero means
/// Auto would be wrong for this model, which is why such a model is only a
/// fallback in the picker.
fn undetectable_preferences(model: &Value, preferred: &[String]) -> usize {
    if !requires_detector(model) {
        return 0;
    }
    let mut seen = HashSet::new();
    preferred
        .iter()
        .filter_map(|language| model_language(model, language))
        .filter(|code| seen.insert(identity(code)))
        .filter(|code| !detector_codes().contains(&identity(code)))
        .count()
}

/// One model's benchmark against the chosen languages, flattened so the
/// selection below needs no borrow of the catalog past this call.
struct Scored {
    id: String,
    name: String,
    bytes: u64,
    needs_detector: bool,
    error: f64,
    worst: f64,
    worst_ci_lower: Option<f64>,
    wait: f64,
    cpu_wait: Option<f64>,
    score: f64,
    manual: bool,
}

fn accuracy(recommendations: &Value, id: &str, language: &str) -> Option<f64> {
    recommendations["models"][id]["accuracy"][identity(language)]["error"].as_f64()
}

fn ci_lower(recommendations: &Value, id: &str, language: &str) -> Option<f64> {
    recommendations["models"][id]["accuracy"][identity(language)]["ciLower"].as_f64()
}

fn real_time_factor(recommendations: &Value, id: &str, tier: &str) -> Option<f64> {
    recommendations["models"][id]["performance"][tier].as_f64()
}

fn score(languages: &[String]) -> Vec<Scored> {
    let data = data();
    let recommendations = &data.recommendations;
    let mut wanted: Vec<String> = Vec::new();
    let mut seen = HashSet::new();
    for language in languages {
        let wanted_identity = identity(language);
        if seen.insert(wanted_identity.clone()) {
            wanted.push(wanted_identity);
        }
    }
    // An empty selection must never reach the per-language zip below: with no
    // wanted languages every model would "match" vacuously.
    if wanted.is_empty() {
        return Vec::new();
    }

    let mut scored = Vec::new();
    for model in data.models() {
        if !wanted.iter().all(|language| matches(model, language)) {
            continue;
        }
        let id = text(model, "id");
        let mut errors = Vec::with_capacity(wanted.len());
        let mut present = true;
        for language in &wanted {
            match accuracy(recommendations, id, language) {
                Some(error) => errors.push(error),
                None => {
                    present = false;
                    break;
                }
            }
        }
        if !present {
            continue;
        }
        let Some(accelerated) = real_time_factor(recommendations, id, "accelerated") else {
            continue;
        };
        let worst_index = errors
            .iter()
            .enumerate()
            .max_by(|left, right| left.1.total_cmp(right.1))
            .map(|(index, _)| index)
            .unwrap_or(0);
        let error =
            (errors.iter().map(|value| value.ln()).sum::<f64>() / errors.len() as f64).exp();
        let wait = DICTATION_SECONDS / accelerated;
        scored.push(Scored {
            id: id.to_string(),
            name: text(model, "name").to_string(),
            bytes: number(model, "size"),
            needs_detector: requires_detector(model),
            error,
            worst: errors[worst_index],
            worst_ci_lower: ci_lower(recommendations, id, &wanted[worst_index]),
            wait,
            cpu_wait: real_time_factor(recommendations, id, "cpu")
                .map(|factor| DICTATION_SECONDS / factor),
            score: error + WAIT_WEIGHT * (wait - FREE_WAIT_SECONDS).max(0.0),
            manual: wanted.len() > 1 && undetectable_preferences(model, languages) > 0,
        });
    }
    scored
}

struct Selection {
    overall: usize,
    fast: usize,
    usable: bool,
}

fn minimum_index_by(
    candidates: &[usize],
    scored: &[Scored],
    key: impl Fn(&Scored) -> f64,
) -> Option<usize> {
    candidates
        .iter()
        .copied()
        .min_by(|left, right| key(&scored[*left]).total_cmp(&key(&scored[*right])))
}

/// The overall, fast and accurate roles of `recommendModels`, reduced to the
/// two roles the wizard offers. Indices point into `scored`.
fn select(scored: &[Scored]) -> Option<Selection> {
    if scored.is_empty() {
        return None;
    }
    let all: Vec<usize> = (0..scored.len()).collect();
    let within_floor: Vec<usize> = all
        .iter()
        .copied()
        .filter(|index| scored[*index].worst < MAX_LANGUAGE_ERROR_PERCENT)
        .collect();
    let detecting: Vec<usize> = within_floor
        .iter()
        .copied()
        .filter(|index| !scored[*index].manual)
        .collect();
    let usable = !within_floor.is_empty();
    let pool: Vec<usize> = if !detecting.is_empty() {
        detecting
    } else if usable {
        within_floor
    } else {
        all
    };

    let overall = if usable {
        let within_budget: Vec<usize> = pool
            .iter()
            .copied()
            .filter(|index| scored[*index].wait <= OVERALL_MAX_WAIT_SECONDS)
            .collect();
        let from = if within_budget.is_empty() {
            pool.clone()
        } else {
            within_budget
        };
        minimum_index_by(&from, scored, |candidate| candidate.score)
            .expect("the pool is never empty")
    } else {
        minimum_index_by(&pool, scored, |candidate| {
            candidate.worst + candidate.error / 1000.0
        })
        .expect("the pool is never empty")
    };

    let fast = if usable {
        let on_cpu: Vec<usize> = pool
            .iter()
            .copied()
            .filter(|index| scored[*index].cpu_wait.is_some())
            .collect();
        let within_cpu: Vec<usize> = on_cpu
            .iter()
            .copied()
            .filter(|index| {
                scored[*index].cpu_wait.unwrap_or(f64::MAX) <= FAST_CPU_MAX_WAIT_SECONDS
            })
            .collect();
        if !within_cpu.is_empty() {
            minimum_index_by(&within_cpu, scored, |candidate| candidate.error)
                .expect("the pool is never empty")
        } else if !on_cpu.is_empty() {
            minimum_index_by(&on_cpu, scored, |candidate| {
                candidate.cpu_wait.unwrap_or(f64::MAX) + candidate.error / 1000.0
            })
            .expect("the pool is never empty")
        } else {
            overall
        }
    } else {
        overall
    };

    Some(Selection {
        overall,
        fast,
        usable,
    })
}

fn as_model(scored: &Scored) -> Model {
    Model {
        id: scored.id.clone(),
        name: scored.name.clone(),
        bytes: scored.bytes,
        wait_seconds: scored.wait,
        needs_detector: scored.needs_detector,
    }
}

/// The Best and Fast picks for the chosen languages, or `None` when no model
/// with a benchmark covers all of them.
pub fn recommend(languages: &[String]) -> Option<Pick> {
    let scored = score(languages);
    let selection = select(&scored)?;
    Some(Pick {
        best: as_model(&scored[selection.overall]),
        fast: as_model(&scored[selection.fast]),
    })
}

/// Whether the extension would call this language eligible or experimental in
/// its own picker — the same test `getPreferredRecommendationLanguages` makes.
fn offerable(language: &str) -> bool {
    let scored = score(&[language.to_string()]);
    let Some(selection) = select(&scored) else {
        return false;
    };
    let overall = &scored[selection.overall];
    selection.usable
        || overall.worst < EXPERIMENTAL_MAX_ERROR_PERCENT
        || overall
            .worst_ci_lower
            .is_some_and(|lower| lower <= EXPERIMENTAL_MAX_ERROR_PERCENT)
}

const LANGUAGE_NAMES: &[(&str, &str)] = &[
    ("af", "Afrikaans"),
    ("am", "Amharic"),
    ("ar", "Arabic"),
    ("as", "Assamese"),
    ("az", "Azerbaijani"),
    ("ba", "Bashkir"),
    ("be", "Belarusian"),
    ("bg", "Bulgarian"),
    ("bn", "Bangla"),
    ("bo", "Tibetan"),
    ("br", "Breton"),
    ("bs", "Bosnian"),
    ("ca", "Catalan"),
    ("cs", "Czech"),
    ("cy", "Welsh"),
    ("da", "Danish"),
    ("de", "German"),
    ("el", "Greek"),
    ("en", "English"),
    ("es", "Spanish"),
    ("et", "Estonian"),
    ("eu", "Basque"),
    ("fa", "Persian"),
    ("fi", "Finnish"),
    ("fil", "Filipino"),
    ("fo", "Faroese"),
    ("fr", "French"),
    ("ga", "Irish"),
    ("gl", "Galician"),
    ("gu", "Gujarati"),
    ("ha", "Hausa"),
    ("haw", "Hawaiian"),
    ("he", "Hebrew"),
    ("hi", "Hindi"),
    ("hr", "Croatian"),
    ("ht", "Haitian Creole"),
    ("hu", "Hungarian"),
    ("hy", "Armenian"),
    ("id", "Indonesian"),
    ("is", "Icelandic"),
    ("it", "Italian"),
    ("ja", "Japanese"),
    ("jv", "Javanese"),
    ("ka", "Georgian"),
    ("kk", "Kazakh"),
    ("km", "Khmer"),
    ("kn", "Kannada"),
    ("ko", "Korean"),
    ("la", "Latin"),
    ("lb", "Luxembourgish"),
    ("ln", "Lingala"),
    ("lo", "Lao"),
    ("lt", "Lithuanian"),
    ("lv", "Latvian"),
    ("mg", "Malagasy"),
    ("mi", "Māori"),
    ("mk", "Macedonian"),
    ("ml", "Malayalam"),
    ("mn", "Mongolian"),
    ("mr", "Marathi"),
    ("ms", "Malay"),
    ("mt", "Maltese"),
    ("my", "Burmese"),
    ("nb", "Norwegian Bokmål"),
    ("ne", "Nepali"),
    ("nl", "Dutch"),
    ("nn", "Norwegian Nynorsk"),
    ("oc", "Occitan"),
    ("pa", "Punjabi"),
    ("pl", "Polish"),
    ("ps", "Pashto"),
    ("pt", "Portuguese"),
    ("ro", "Romanian"),
    ("ru", "Russian"),
    ("sa", "Sanskrit"),
    ("sd", "Sindhi"),
    ("si", "Sinhala"),
    ("sk", "Slovak"),
    ("sl", "Slovenian"),
    ("sn", "Shona"),
    ("so", "Somali"),
    ("sq", "Albanian"),
    ("sr", "Serbian"),
    ("su", "Sundanese"),
    ("sv", "Swedish"),
    ("sw", "Swahili"),
    ("ta", "Tamil"),
    ("te", "Telugu"),
    ("tg", "Tajik"),
    ("th", "Thai"),
    ("tk", "Turkmen"),
    ("tr", "Turkish"),
    ("tt", "Tatar"),
    ("uk", "Ukrainian"),
    ("ur", "Urdu"),
    ("uz", "Uzbek"),
    ("vi", "Vietnamese"),
    ("yi", "Yiddish"),
    ("yo", "Yoruba"),
    ("yue", "Cantonese"),
    ("zh", "Mandarin (Chinese)"),
];

fn cldr_names() -> &'static Value {
    static NAMES: std::sync::OnceLock<Value> = std::sync::OnceLock::new();
    NAMES.get_or_init(|| {
        serde_json::from_str(include_str!("data/language-names.json"))
            .expect("language-names.json is valid JSON")
    })
}

pub fn display_name(language: &str) -> String {
    let language_code = canonical(language);
    let localized = match language_code.as_str() {
        "bg" => Some(i18n::t("wizard.voice.name.bg")),
        "cs" => Some(i18n::t("wizard.voice.name.cs")),
        "de" => Some(i18n::t("wizard.voice.name.de")),
        "en" => Some(i18n::t("wizard.voice.name.en")),
        "es" => Some(i18n::t("wizard.voice.name.es")),
        "fr" => Some(i18n::t("wizard.voice.name.fr")),
        "it" => Some(i18n::t("wizard.voice.name.it")),
        "ja" => Some(i18n::t("wizard.voice.name.ja")),
        "ko" => Some(i18n::t("wizard.voice.name.ko")),
        "pt" => Some(i18n::t("wizard.voice.name.pt")),
        "ru" => Some(i18n::t("wizard.voice.name.ru")),
        "th" => Some(i18n::t("wizard.voice.name.th")),
        "uk" => Some(i18n::t("wizard.voice.name.uk")),
        "vi" => Some(i18n::t("wizard.voice.name.vi")),
        "zh" => Some(i18n::t("wizard.voice.name.zh")),
        _ => None,
    };
    if let Some(name) = localized {
        return name;
    }
    // Every other dictation language: its CLDR name in the interface language
    // (data/language-names.json, from scripts/language-names.swift). English
    // keeps the names below.
    if let Some(name) = cldr_names()[i18n::language()][language_code.as_str()].as_str() {
        if i18n::language() != "en" {
            return name.to_string();
        }
    }
    LANGUAGE_NAMES
        .iter()
        .find(|(table_code, _)| *table_code == language_code)
        .map(|(_, name)| (*name).to_string())
        .unwrap_or_else(|| language.to_string())
}

/// Accented Latin letters that occur in the language names, and the letter
/// each sorts as, so "Árabe" sorts with the A's and not after "Z". Byte order
/// is kept for other scripts, which already sort sensibly that way.
const SORT_FOLD: &[(char, char)] = &[
    ('à', 'a'),
    ('á', 'a'),
    ('â', 'a'),
    ('ã', 'a'),
    ('ä', 'a'),
    ('å', 'a'),
    ('ā', 'a'),
    ('ạ', 'a'),
    ('ả', 'a'),
    ('ầ', 'a'),
    ('ậ', 'a'),
    ('ç', 'c'),
    ('č', 'c'),
    ('ď', 'd'),
    ('đ', 'd'),
    ('è', 'e'),
    ('é', 'e'),
    ('ê', 'e'),
    ('ě', 'e'),
    ('ế', 'e'),
    ('ể', 'e'),
    ('ệ', 'e'),
    ('í', 'i'),
    ('ï', 'i'),
    ('ĩ', 'i'),
    ('ñ', 'n'),
    ('ň', 'n'),
    ('ó', 'o'),
    ('ô', 'o'),
    ('ö', 'o'),
    ('ồ', 'o'),
    ('ổ', 'o'),
    ('ř', 'r'),
    ('š', 's'),
    ('ú', 'u'),
    ('ü', 'u'),
    ('ư', 'u'),
    ('ụ', 'u'),
    ('ứ', 'u'),
    ('ỳ', 'y'),
    ('ž', 'z'),
];

fn sort_key(name: &str) -> String {
    name.to_lowercase()
        .chars()
        .map(|c| {
            SORT_FOLD
                .iter()
                .find(|(from, _)| *from == c)
                .map_or(c, |(_, to)| *to)
        })
        .collect()
}

/// Every language the picker offers: benchmarked, and English first, then
/// alphabetical by display name.
pub fn offered_languages() -> Vec<(String, String)> {
    let mut codes: Vec<String> = Vec::new();
    let mut seen = HashSet::new();
    for model in data().models() {
        for code in languages_of(model) {
            let code = identity(&code);
            if seen.insert(code.clone()) {
                codes.push(code);
            }
        }
    }
    let mut offered: Vec<String> = codes.into_iter().filter(|code| offerable(code)).collect();
    offered.sort_by(|left, right| {
        if left == "en" {
            return Ordering::Less;
        }
        if right == "en" {
            return Ordering::Greater;
        }
        sort_key(&display_name(left)).cmp(&sort_key(&display_name(right)))
    });
    offered
        .into_iter()
        .map(|code| {
            let name = display_name(&code);
            (code, name)
        })
        .collect()
}

/// Size of the language detector, so the pick pane can show what it adds.
pub fn detector_bytes() -> u64 {
    number(data().detector(), "size")
}

pub fn human_size(bytes: u64) -> String {
    const MIB: f64 = 1024.0 * 1024.0;
    if bytes as f64 >= MIB * 1024.0 {
        format!("{:.1} GiB", bytes as f64 / (MIB * 1024.0))
    } else {
        format!("{} MiB", (bytes as f64 / MIB).round() as u64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pick_for(languages: &[&str]) -> Pick {
        let languages: Vec<String> = languages.iter().map(|l| (*l).to_string()).collect();
        recommend(&languages).expect("a pick for a benchmarked language")
    }

    #[test]
    fn english_gets_the_extension_default() {
        let pick = pick_for(&["en"]);
        assert_eq!(pick.best.id, "parakeet-unified-en-0.6b");
        assert_eq!(pick.fast.id, "parakeet-unified-en-0.6b");
        assert!(!pick.best.needs_detector);
        assert!(pick.same_model());
    }

    #[test]
    fn single_languages_match_the_extension_picks() {
        assert_eq!(pick_for(&["es"]).best.id, "parakeet-ultra");
        assert_eq!(pick_for(&["de"]).best.id, "canary-1b-v2");
        assert_eq!(pick_for(&["ru"]).best.id, "gigaam-v3-e2e-rnnt");
        assert_eq!(pick_for(&["zh"]).best.id, "Qwen3-ASR-0.6B");
    }

    #[test]
    fn a_pair_needs_a_model_that_covers_both() {
        assert_eq!(pick_for(&["en", "es"]).best.id, "parakeet-ultra");
        assert_eq!(pick_for(&["en", "zh"]).best.id, "Qwen3-ASR-0.6B");
    }

    #[test]
    fn the_fast_pick_is_a_real_alternative_when_it_differs() {
        let pick = pick_for(&["zh"]);
        assert_ne!(pick.best.id, pick.fast.id);
        assert!(pick.fast.wait_seconds > 0.0 && pick.best.wait_seconds > 0.0);
    }

    #[test]
    fn detector_is_needed_only_for_multilingual_models_without_detection() {
        // English-only: one language, so no detector even without native detection.
        assert!(!pick_for(&["en"]).best.needs_detector);
        // German's canary-1b-v2 has no native detection and covers many
        // languages, so the extension ships the detector with it.
        assert!(pick_for(&["de"]).best.needs_detector);
    }

    #[test]
    fn each_role_carries_its_own_detector_requirement() {
        // Best detects natively; Fast is multilingual without detection.
        let pick = pick_for(&["en", "zh"]);
        assert_eq!(pick.best.id, "Qwen3-ASR-0.6B");
        assert_eq!(pick.fast.id, "Fun-ASR-Nano-2512");
        assert!(!pick.best.needs_detector);
        assert!(pick.fast.needs_detector);
    }

    #[test]
    fn every_dictation_language_has_a_name_in_every_interface_language() {
        let table: Value = serde_json::from_str(include_str!("../i18n/languages.json")).unwrap();
        for row in table.as_array().unwrap() {
            let ui = row["code"].as_str().unwrap();
            for (code, _) in LANGUAGE_NAMES {
                assert!(
                    cldr_names()[ui][*code]
                        .as_str()
                        .is_some_and(|name| !name.is_empty()),
                    "{ui}: no name for {code}; rerun scripts/language-names.swift"
                );
            }
        }
    }

    #[test]
    fn accented_names_sort_with_their_base_letter() {
        let mut names = vec!["Zulú", "Árabe", "Alemán", "Búlgaro"];
        names.sort_by_key(|name| sort_key(name));
        assert_eq!(names, ["Alemán", "Árabe", "Búlgaro", "Zulú"]);
    }

    #[test]
    fn a_non_mash_language_is_named_in_the_interface_language() {
        let _language = i18n::override_language("es");
        assert_eq!(display_name("ar"), "Árabe");
        assert_eq!(display_name("es"), i18n::t("wizard.voice.name.es"));
        drop(_language);
        let _english = i18n::override_language("en");
        assert_eq!(display_name("ar"), "Arabic");
    }

    #[test]
    fn offered_languages_lead_with_english() {
        let offered = offered_languages();
        assert_eq!(offered.first().map(|(code, _)| code.as_str()), Some("en"));
        assert!(offered.len() > 20, "the catalog covers many languages");
        assert!(offered.iter().any(|(code, _)| code == "zh"));
        assert!(offered.iter().any(|(_, name)| name == "Mandarin (Chinese)"));
        // A catalog language the name table does not know would reach the page
        // as its bare code, which reads like a bug to the person using it.
        for (code, name) in &offered {
            assert_ne!(name, code, "offered language {code} has no display name");
        }
    }

    #[test]
    fn sizes_are_human_readable() {
        assert_eq!(human_size(731_357_568), "697 MiB");
        assert_eq!(human_size(218_447_552), "208 MiB");
        assert_eq!(human_size(2_410_655_232), "2.2 GiB");
    }

    #[test]
    fn unknown_languages_fall_back_to_their_code() {
        assert_eq!(display_name("xx"), "xx");
    }
}
