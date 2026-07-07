import Foundation

/// Shared helpers for reading mixed-shape tokens — camelCase compounds,
/// letter+digit forms, glued hyphen chains — in English TTS frontends.
///
/// Tokens like `MacReader`, `CASP14`, or `COVID-19` miss every lexicon as
/// a whole and fall through to BART G2P, which was trained on dictionary
/// words and sounds such blobs out as one garbled pseudo-word. The token's
/// shape tells us where the seams are, so a frontend can split it into
/// pronounceable parts after a full lexicon miss and resolve each part
/// through its normal chain instead.
///
/// Like ``EnglishInitialisms``, this type holds only the policy (where a
/// token splits, how a digit run is spoken); the lexicon data stays with
/// each frontend.
enum EnglishCompoundWords {

    /// Split `word` at pronunciation seams:
    ///   * letter ↔ digit boundaries — `CASP14` → `CASP`, `14`
    ///   * lowercase → uppercase camel boundaries — `MacReader` → `Mac`, `Reader`
    ///   * an acronym run followed by a Titlecase word — `HTMLParser` →
    ///     `HTML`, `Parser` (the run's last capital starts the next part)
    ///   * non-alphanumeric separators are dropped — `COVID-19` → `COVID`, `19`
    ///
    /// A word with no seams comes back as `[word]`; callers should treat
    /// that as "not a compound" and keep their existing path.
    static func splitParts(_ word: String) -> [String] {
        var parts: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty { parts.append(current) }
            current = ""
        }

        var previous: Character?
        for character in word {
            guard character.isLetter || character.isNumber else {
                flush()
                previous = nil
                continue
            }
            if let previous {
                if previous.isNumber != character.isNumber {
                    flush()
                } else if previous.isLowercase && character.isUppercase {
                    flush()
                } else if previous.isUppercase && character.isLowercase && current.count > 1 {
                    let capital = current.removeLast()
                    flush()
                    current = String(capital)
                }
            }
            current.append(character)
            previous = character
        }
        flush()
        return parts
    }

    /// The spoken words for one digit-run part. Plain runs read as a
    /// cardinal (`14` → `fourteen`, `26` → `twenty six`); leading-zero runs
    /// and runs too long for `Int` read digit-by-digit (`007` → `zero zero
    /// seven`). Returns `[]` when the run can't be spelled (non-ASCII
    /// digits) so the caller falls through to its normal fallback.
    static func spokenWords(forDigits digits: String) -> [String] {
        let interpretAs = (digits.first == "0" || Int(digits) == nil) ? "digits" : "cardinal"
        let spoken = SayAsInterpreter.interpret(content: digits, interpretAs: interpretAs, format: nil)
        guard !spoken.contains(where: { $0.isNumber }) else { return [] }
        return spoken.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
    }
}
