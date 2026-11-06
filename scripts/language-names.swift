// Regenerate packaging/wizard/data/language-names.json from the CLDR language
// names that ship with macOS, for the dictation page's language list.
//
//   swift scripts/language-names.swift > packaging/wizard/data/language-names.json
//
// Reads the dictation codes from packaging/wizard/voice.rs (LANGUAGE_NAMES) and
// the interface languages from packaging/i18n/languages.json. A name CLDR does not
// know is left out; the wizard then falls back to the English name in voice.rs.
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let voice = try String(contentsOf: root.appendingPathComponent("packaging/wizard/voice.rs"), encoding: .utf8)
guard let start = voice.range(of: "const LANGUAGE_NAMES"),
      let end = voice.range(of: "];", range: start.upperBound..<voice.endIndex) else {
    fatalError("LANGUAGE_NAMES not found in voice.rs")
}
let table = String(voice[start.upperBound..<end.lowerBound])
let codeRegex = try NSRegularExpression(pattern: #"\(\"([a-z]{2,3})\","#)
let codes = codeRegex.matches(in: table, range: NSRange(table.startIndex..., in: table)).map {
    String(table[Range($0.range(at: 1), in: table)!])
}

let languagesData = try Data(contentsOf: root.appendingPathComponent("packaging/i18n/languages.json"))
let rows = try JSONSerialization.jsonObject(with: languagesData) as! [[String: Any]]
// CLDR locale for each interface language; zh-CN is Simplified Chinese.
let cldr = ["zh-CN": "zh-Hans", "pt-BR": "pt-BR"]

var out: [String: [String: String]] = [:]
for row in rows {
    let ui = row["code"] as! String
    let locale = Locale(identifier: cldr[ui] ?? ui)
    var names: [String: String] = [:]
    for code in codes {
        guard let name = locale.localizedString(forLanguageCode: code), name != code else { continue }
        // Names appear alone in a list, so the first letter is capitalized as a
        // list item is; the rest is left as CLDR spells it.
        names[code] = name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }
    out[ui] = names
}
let json = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(json)
FileHandle.standardOutput.write("\n".data(using: .utf8)!)
