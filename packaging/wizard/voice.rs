//! Pi Voice model selection, matching the picks `@earendil-works/pi-voice`'s
//! own onboarding would make.
//!
//! Both data files are vendored from the pinned package and the build fails
//! when they drift (`packaging/build.sh`), so the wizard can never offer a
//! model the extension would not have chosen. The scoring below is a port of
//! the extension's `scoreModels`/`recommendModels`: a geometric mean of the
//! per-language error plus a penalty for waiting, with accuracy as a hard
//! constraint first.

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
    pub fn label(self) -> &'static str {
        match self {
            Role::Best => "Best",
            Role::Fast => "Fast",
        }
    }

    pub fn summary(self) -> &'static str {
        match self {
            Role::Best => "the suggested balance of speed and accuracy",
            Role::Fast => "the quickest transcription that stays usable",
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
    pub needs_detector: bool,
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
        needs_detector: scored[selection.overall].needs_detector,
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

pub fn display_name(language: &str) -> String {
    LANGUAGE_NAMES
        .iter()
        .find(|(code, _)| *code == canonical(language))
        .map(|(_, name)| (*name).to_string())
        .unwrap_or_else(|| language.to_string())
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
        display_name(left)
            .to_lowercase()
            .cmp(&display_name(right).to_lowercase())
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
        assert!(!pick.needs_detector);
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
        assert!(!pick_for(&["en"]).needs_detector);
        // German's canary-1b-v2 has no native detection and covers many
        // languages, so the extension ships the detector with it.
        assert!(pick_for(&["de"]).needs_detector);
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
