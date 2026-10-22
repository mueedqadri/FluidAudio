import Foundation

/// Where an English sentence ends for narration: whether a sentence tokenizer's
/// boundary after an abbreviation is real. Built on the frontend's own table
/// (`EnglishAbbreviationTable`), so the app that cuts sentences and the voice
/// that reads them agree about every title, initial and reference word.
public enum SentenceBoundaryPolicy {
    /// Reference words read before a number (`Fig`, `pp`, `Art`), without their period.
    public static let referenceWords = Set(EnglishAbbreviationTable.spokenForms(in: .beforeNumber).keys)

    /// Whether `text` ends in an abbreviation that `next` continues: a title, a
    /// Latin abbreviation, a reference word before a number, a saint's or
    /// mountain's prefix before a name, or a name's initial before a capitalized
    /// word (`J. Smith`). Not an initial that is a Roman numeral (`I`, `V`, `X`,
    /// which end headings), one after a surname and a comma (`Söding, J.` ends a
    /// reference's names), one after a number (`1.4 Å.` is a unit), or one
    /// before a word that opens a sentence (`from P. ‖ I shall`), unless that
    /// word is an initial too (`A. A. Milne`).
    public static func continuesAcrossBoundary(_ text: String, into next: String) -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace)
        guard let lastWord = words.last else { return false }

        // Only leading wrappers go (`(Mr.`, `“Mr.`): the period and the case make the title.
        let token = String(lastWord.drop(while: \.isPunctuation))
        if titles.contains(token) || EnglishAbbreviationTable.neverEndASentence.contains(token) { return true }

        let following = next.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "(" }
        guard let first = following.first else { return false }
        let nextWord = String(following.prefix(while: \.isLetter))
        if beforeNumber.contains(token) { return first.isNumber }
        if EnglishAbbreviationTable.placePrefixes.contains(token) {
            guard first.isUppercase else { return false }
            return words.dropLast().last?.first?.isUppercase != true
                || !EnglishAbbreviationTable.sentenceOpeners.contains(nextWord)
        }
        guard isInitial(token), first.isUppercase else { return false }
        if EnglishAbbreviationTable.sentenceOpeners.contains(nextWord),
            !following.dropFirst(nextWord.count).hasPrefix(".")
        {
            return false
        }
        guard let before = words.dropLast().reversed().first(where: { !isInitial(String($0)) }) else { return true }
        if before.contains(where: \.isNumber), !before.hasSuffix(",") { return false }
        return !(before.hasSuffix(",") && before.first?.isUppercase == true)
    }

    private static let titles = Set(EnglishAbbreviationTable.spokenForms(in: .title).keys.map { $0 + "." })
    private static let beforeNumber = Set(referenceWords.map { $0 + "." })

    private static func isInitial(_ token: String) -> Bool {
        token.count == 2 && token.hasSuffix(".")
            && token.first.map { $0.isUppercase && !"IVX".contains($0) } == true
    }
}
