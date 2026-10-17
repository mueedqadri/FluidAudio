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

    /// Written form without the period → spoken expansion word, from
    /// ``EnglishAbbreviationTable``. The expansion resolves from the caller's
    /// lexicon; ``EnglishPronunciations/ipa`` covers the expansions the Misaki
    /// lexicon does not carry.
    static let expansions = EnglishAbbreviationTable.spokenForms(in: .title)

    /// The spoken expansion for a merged title token (`"Mr."`), or `nil`
    /// when the token is not a title abbreviation. An initial (`"J."`) reads
    /// as its letter.
    static func expansion(forTitleToken token: String) -> String? {
        guard token.hasSuffix(".") else { return nil }
        let word = String(token.dropLast())
        return expansions[word] ?? (isInitial(word) ? word : nil)
    }

    /// Whether the initial before `periodIndex` starts a name (`J. Smith`,
    /// `Andrew J. Ballard`) rather than ending one written surname first
    /// (`Söding, J.`, `Eddy, S. R.`: a capitalized word and a comma), where a
    /// reference list's title follows.
    private static func continuesName(beforeInitial word: String, in text: String, periodIndex: String.Index) -> Bool {
        let wordStart = text.index(periodIndex, offsetBy: -word.count)
        let earlier = text[..<wordStart].split(whereSeparator: \.isWhitespace)
        let before = earlier.reversed().first { token in
            !(token.count == 2 && token.hasSuffix(".") && token.first?.isUppercase == true)
        }
        guard let before else { return true }
        // `1.4 Å.` is a unit (a number right before it); `Söding, J.` ends a surname-first name.
        if before.contains(where: \.isNumber), !before.hasSuffix(",") { return false }
        return !(before.hasSuffix(",") && before.first?.isUppercase == true)
    }

    /// A name's initial (`J` of `J. Smith`), which keeps its period like a
    /// title so it never pauses. `I`, `V` and `X` are left out: as Roman
    /// numerals they end sentences and headings (`World War I.`, `Part X.`).
    static func isInitial(_ word: String) -> Bool {
        word.count == 1 && !["I", "V", "X"].contains(word)
            && word.first.map { $0.isUppercase && $0.isLetter } == true
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
        if isInitial(word) {
            guard continuesName(beforeInitial: word, in: text, periodIndex: periodIndex) else { return false }
        } else if expansions[word] == nil {
            return false
        }
        var index = text.index(after: periodIndex)
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        return index < text.endIndex && text[index].isUppercase
    }
}
