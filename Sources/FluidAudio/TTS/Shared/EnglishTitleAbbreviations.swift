import Foundation

/// English title abbreviations that conventionally introduce a name
/// (`Mr. Gatsby`, `Sen. Warren`) and their spoken expansions.
///
/// Misaki never sees a bare `Mr` + `.` pair: spaCy's tokenizer exceptions
/// keep `Mr.` as a single token, so the period is never emitted as a
/// punctuation prosody token and cannot be voiced as a sentence-ending
/// pause. The word tokenizer here mirrors that: when one of these
/// abbreviations is followed by its period and then a capitalized word,
/// the period stays inside the token.
///
/// Resolution then reads the expansion word rather than probing the
/// lexicon with the stripped stem, which misreads most titles
/// (`Sen.` → "sen", `Adm.` → "Adam", `Pres.` → "prez").
///
/// Ambiguous abbreviations that legitimately end sentences (`Inc.`,
/// `etc.`, `p.m.`) are deliberately absent, and matching is
/// case-sensitive on the capitalized written form so the ordinary nouns
/// `gen`/`rep` keep their terminal period.
enum EnglishTitleAbbreviations {

    /// Written form without the period → spoken expansion word. The
    /// expansion resolves from the caller's lexicon; ``inlineIPA`` covers
    /// the expansions the Misaki lexicon does not carry. `Mrs` maps to the
    /// lexicon's own `mrs` entry (`mˈɪsɪz`) — canonical Misaki resolves the
    /// stem, and the `missus` word entry carries a different vowel.
    static let expansions: [String: String] = [
        "Mr": "mister", "Mrs": "mrs", "Ms": "miz", "Mx": "mix",
        "Dr": "doctor", "Prof": "professor", "Rev": "reverend", "Fr": "father",
        "Hon": "honorable", "Adm": "admiral", "Brig": "brigadier",
        "Capt": "captain", "Cmdr": "commander", "Col": "colonel",
        "Gen": "general", "Gov": "governor", "Lt": "lieutenant",
        "Maj": "major", "Pres": "president", "Rep": "representative",
        "Sen": "senator", "Sgt": "sergeant", "Supt": "superintendent",
    ]

    /// Expansion words missing from the Misaki lexicon.
    static let inlineIPA: [String: String] = ["miz": "mˈɪz"]

    /// The spoken expansion for a merged title token (`"Mr."`), or `nil`
    /// when the token is not a title abbreviation.
    static func expansion(forTitleToken token: String) -> String? {
        guard token.hasSuffix(".") else { return nil }
        return expansions[String(token.dropLast())]
    }

    /// Whether `word` + `"."` should merge into one token: `word` is a
    /// title abbreviation and the first non-whitespace character after
    /// `periodIndex` is uppercase (a following name). A sentence-final
    /// title keeps its period as an ordinary prosody token.
    static func mergesPeriod(
        afterWord word: String,
        in text: String,
        periodIndex: String.Index
    ) -> Bool {
        guard expansions[word] != nil else { return false }
        var index = text.index(after: periodIndex)
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        return index < text.endIndex && text[index].isUppercase
    }
}
