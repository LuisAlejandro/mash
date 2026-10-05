//! Shared text-field editing shortcuts for the popup forms.
//!
//! The forms are single-line inputs whose only editing key was `Backspace`
//! (delete one char). On macOS the system conventions for a text field are
//! `Alt+Backspace` to delete the previous word and `Cmd+Backspace` to delete to
//! the start of the line, and neither did anything useful here.
//!
//! Terminals do not forward `Cmd`, so the line-clear is recognised through the
//! control codes a terminal actually sends:
//!
//! | Intent              | macOS keys        | Reaches the TUI as        |
//! |---------------------|-------------------|---------------------------|
//! | delete prev word    | `Alt+Backspace`   | `Backspace` + ALT         |
//! | delete prev word    | `Ctrl+W`          | `Ctrl+W` (readline)       |
//! | delete to line start| `Cmd+Backspace`   | `Ctrl+U` (terminal maps it)|
//! | delete to line start| `Ctrl+U`          | `Ctrl+U` (readline)       |
//!
//! Ghostty, for example, ships `super+backspace=text:\x15`, i.e. `Cmd+Backspace`
//! is *defined* as sending `Ctrl+U`. Handling `Ctrl+U` therefore implements the
//! Cmd shortcut without the TUI ever seeing a `super` modifier. Terminals that
//! send a real `Backspace`+SUPER are covered too.
//!
//! `Ctrl+W` and `Ctrl+U` are also the standard readline bindings, so this keeps
//! the forms consistent with shell prompts as well as with macOS.

use ratatui::crossterm::event::{KeyCode, KeyModifiers};

/// What an editing key should do to a text field.
///
/// The shared `Delete` prefix is intentional: these are the three deletion
/// granularities a single-line field supports, and `Edit::Char` / `Edit::Word`
/// would read as the unit rather than the action at the call sites.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(clippy::enum_variant_names)]
pub enum Edit {
    /// Remove the character before the cursor.
    DeleteChar,
    /// Remove the word before the cursor, plus any whitespace right before it.
    DeleteWord,
    /// Remove everything (single-line field, so "to line start" is "all").
    DeleteLine,
}

/// Classify a key press as a text edit, if it is one.
///
/// Returns `None` for keys the caller should keep handling itself.
pub fn classify(code: KeyCode, mods: KeyModifiers) -> Option<Edit> {
    let ctrl = mods.contains(KeyModifiers::CONTROL);
    let alt = mods.contains(KeyModifiers::ALT);
    let sup = mods.contains(KeyModifiers::SUPER);

    match code {
        // Ctrl+U: readline line-kill, and what Cmd+Backspace becomes in a
        // terminal. Checked before the word cases so Ctrl+Alt+U still clears.
        KeyCode::Char('u') | KeyCode::Char('U') if ctrl => Some(Edit::DeleteLine),

        // Ctrl+W: readline word-kill.
        KeyCode::Char('w') | KeyCode::Char('W') if ctrl => Some(Edit::DeleteWord),

        // Terminals that forward the modifier on Backspace rather than
        // translating it to a control byte.
        KeyCode::Backspace if sup => Some(Edit::DeleteLine),
        KeyCode::Backspace if alt || ctrl => Some(Edit::DeleteWord),

        KeyCode::Backspace => Some(Edit::DeleteChar),

        _ => None,
    }
}

/// Apply an [`Edit`] to `s`. Returns `true` when `s` changed.
pub fn apply(s: &mut String, edit: Edit) -> bool {
    match edit {
        Edit::DeleteChar => s.pop().is_some(),
        Edit::DeleteWord => delete_word(s),
        Edit::DeleteLine => {
            let had = !s.is_empty();
            s.clear();
            had
        }
    }
}

/// Is `c` part of a word, for the purpose of word-wise deletion?
///
/// Alphanumerics only. Separators like `/`, `.`, `-`, `_` and whitespace are
/// boundaries, which is what makes `Alt+Backspace` walk back through a path one
/// segment at a time instead of erasing the whole thing:
///
/// ```text
/// /Volumes/Documents/Software/losa
/// /Volumes/Documents/Software/
/// /Volumes/Documents/
/// /Volumes/
/// /
/// ```
///
/// This matches macOS text fields and readline, where the unit is a word, not a
/// whitespace-delimited token.
fn is_word_char(c: char) -> bool {
    c.is_alphanumeric()
}

/// Drop trailing separators, then the run of word characters before them.
///
/// Operates on `char`s, not bytes, so multi-byte input cannot be truncated
/// mid-character.
fn delete_word(s: &mut String) -> bool {
    if s.is_empty() {
        return false;
    }
    let keep = {
        let chars: Vec<char> = s.chars().collect();
        let mut i = chars.len();
        while i > 0 && !is_word_char(chars[i - 1]) {
            i -= 1;
        }
        while i > 0 && is_word_char(chars[i - 1]) {
            i -= 1;
        }
        i
    };
    let truncated: String = s.chars().take(keep).collect();
    let changed = truncated.chars().count() != s.chars().count();
    *s = truncated;
    changed
}

#[cfg(test)]
mod tests {
    use super::*;

    fn word(s: &str) -> String {
        let mut owned = s.to_string();
        apply(&mut owned, Edit::DeleteWord);
        owned
    }

    #[test]
    fn deletes_previous_word() {
        assert_eq!(word("foo bar"), "foo ");
        assert_eq!(word("one"), "");
    }

    #[test]
    fn word_delete_skips_trailing_space_then_word() {
        // "foo bar " -> drop the space, then "bar".
        assert_eq!(word("foo bar "), "foo ");
    }

    #[test]
    fn word_delete_walks_a_path_one_segment_at_a_time() {
        // The reason is_word_char excludes separators: erasing a whole path in
        // one press is indistinguishable from Cmd+Backspace.
        let mut s = "/Volumes/Documents/Software/losa".to_string();
        for expected in [
            "/Volumes/Documents/Software/",
            "/Volumes/Documents/",
            "/Volumes/",
            "/",
            "",
        ] {
            apply(&mut s, Edit::DeleteWord);
            assert_eq!(s, expected);
        }
    }

    #[test]
    fn word_delete_treats_separators_as_boundaries() {
        assert_eq!(word("~/Documents/Repos"), "~/Documents/");
        assert_eq!(word("a b/c"), "a b/");
        assert_eq!(word("feature/foo-bar"), "feature/foo-");
        assert_eq!(word("file.txt"), "file.");
    }

    #[test]
    fn word_delete_is_char_safe() {
        assert_eq!(word("héllo wörld"), "héllo ");
        // No panic and no partial char on a single multi-byte word.
        // Accented letters are alphanumeric, so this is one word.
        assert_eq!(word("naïve"), "");
    }

    #[test]
    fn empty_edits_report_no_change() {
        let mut s = String::new();
        assert!(!apply(&mut s, Edit::DeleteChar));
        assert!(!apply(&mut s, Edit::DeleteWord));
        assert!(!apply(&mut s, Edit::DeleteLine));
    }

    #[test]
    fn line_delete_clears() {
        let mut s = "~/some/path".to_string();
        assert!(apply(&mut s, Edit::DeleteLine));
        assert!(s.is_empty());
    }

    #[test]
    fn classifies_ctrl_u_as_line() {
        assert_eq!(
            classify(KeyCode::Char('u'), KeyModifiers::CONTROL),
            Some(Edit::DeleteLine)
        );
    }

    #[test]
    fn classifies_ctrl_w_as_word() {
        assert_eq!(
            classify(KeyCode::Char('w'), KeyModifiers::CONTROL),
            Some(Edit::DeleteWord)
        );
    }

    #[test]
    fn classifies_alt_backspace_as_word() {
        assert_eq!(
            classify(KeyCode::Backspace, KeyModifiers::ALT),
            Some(Edit::DeleteWord)
        );
    }

    #[test]
    fn classifies_super_backspace_as_line() {
        assert_eq!(
            classify(KeyCode::Backspace, KeyModifiers::SUPER),
            Some(Edit::DeleteLine)
        );
    }

    #[test]
    fn classifies_plain_backspace_as_char() {
        assert_eq!(
            classify(KeyCode::Backspace, KeyModifiers::NONE),
            Some(Edit::DeleteChar)
        );
    }

    #[test]
    fn plain_letters_are_not_edits() {
        assert_eq!(classify(KeyCode::Char('u'), KeyModifiers::NONE), None);
        assert_eq!(classify(KeyCode::Char('w'), KeyModifiers::NONE), None);
        assert_eq!(classify(KeyCode::Enter, KeyModifiers::NONE), None);
    }
}
