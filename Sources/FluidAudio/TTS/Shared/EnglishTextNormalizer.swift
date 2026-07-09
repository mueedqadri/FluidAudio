import Foundation

/// Conservative pre-tokenization text normalization for English TTS
/// raw-text frontends (issue #711).
///
/// Raw chat-style text often contains standalone numbers, ordinals, and
/// clock times that tokenize poorly (`3.14` splits around `.` and reads
/// closer to `three fourteen` than `three point one four`). This pass
/// rewrites only *strict standalone* numeric forms into spoken words
/// before a frontend tokenizes, reusing ``SayAsInterpreter`` for the
/// actual spelling. It is frontend-agnostic — both ``KokoroAneManager``
/// and (in a follow-up) StyleTTS2 can apply it.
///
/// Raw text carries no caller annotation, so the rules are deliberately
/// stricter than SSML `<say-as>`: anything ambiguous or structured is left
/// untouched. Handled forms:
///   * cardinal integers — `26` → `twenty six`
///   * valid ordinals — `13th` → `thirteenth` (suffix must match the number)
///   * leading-zero digit strings — `007` → `zero zero seven`
///   * decimals — `3.14` → `three point one four`
///   * 12-hour meridiem times — `1:49 PM` → `one forty nine p m`
///   * currency — `$1.50` → `one dollar and fifty cents` (Misaki
///     `get_number` currency semantics: `$`/`£`/`€`, cents dropped at zero)
///   * years — `1999` → `nineteen ninety nine` (Misaki reads standalone
///     4-digit numbers as years via `num2words to='year'`)
///   * grouped numbers — `500,000,000` → `five hundred million`
///
/// Left unchanged (ambiguous / structured): version strings (`1.2.3`),
/// embedded digits (`word26`, `26word`), loose colon numbers without a
/// meridiem (`1:49`), invalid times (`1:99 PM`), and 24-hour forms
/// (`13:49`).
enum EnglishTextNormalizer {

    /// Rewrite strict standalone numeric forms in `text` to spoken words.
    /// Passes run in priority order so a token is consumed by the most
    /// specific rule (a meridiem time before its bare digits, currency
    /// before its decimal, a year before its cardinal).
    static func normalize(_ text: String) -> String {
        var result = text
        result = apply(Self.meridiemTimeRegex, to: result, transform: Self.spellMeridiemTime)
        result = apply(Self.currencyRegex, to: result, transform: Self.spellCurrency)
        result = apply(Self.decimalRegex, to: result, transform: Self.spellDecimal)
        result = apply(Self.ordinalRegex, to: result, transform: Self.spellOrdinal)
        result = apply(Self.yearRegex, to: result, transform: Self.spellYear)
        result = apply(Self.groupedRegex, to: result, transform: Self.spellGrouped)
        result = apply(Self.leadingZeroRegex, to: result, transform: Self.spellLeadingZero)
        result = apply(Self.cardinalRegex, to: result, transform: Self.spellCardinal)
        return result
    }

    // MARK: - Boundaries
    //
    // A standalone number must not be glued to a letter, another digit, or
    // a `. , :` separator that would make it part of a word, version
    // string, grouped number, or clock value. `leadBoundary` guards the
    // left edge; `trailBoundary` guards the right edge while still allowing
    // a trailing sentence period (`26.` / `3.14.`) — a `.`/`,`/`:` only
    // disqualifies when it is itself followed by a digit.
    private static let leadBoundary = #"(?<![A-Za-z0-9.,:])"#
    private static let trailBoundary = #"(?![A-Za-z0-9])(?![.,:][0-9])"#

    // MARK: - Compiled patterns

    /// `1:49 PM`, `1:49 p.m.` — hour 1-12, minute 00-59, explicit meridiem.
    /// The `m` half is an explicit alternation (`.m`/`.m.` for the dotted
    /// form, bare `m` otherwise) so a sentence period after `PM` is left as
    /// punctuation instead of being swallowed (`1:49 PM.`).
    private static let meridiemTimeRegex = regex(
        leadBoundary + #"(1[0-2]|[1-9]):([0-5][0-9])\s*([AaPp])(?:\.[Mm]\.?|[Mm])"# + #"(?![A-Za-z])"#)

    /// `$1.50`, `£500,000,000` — currency symbol immediately before a
    /// number with optional grouping commas and decimal part.
    private static let currencyRegex = regex(
        #"([$£€])\s?([0-9][0-9,]*(?:\.[0-9]+)?)"# + trailBoundary)

    /// `1999` — a standalone 4-digit number reads as a year (Misaki
    /// `get_number` sends every non-currency 4-digit token through
    /// `num2words to='year'`).
    private static let yearRegex = regex(
        leadBoundary + #"([1-9][0-9]{3})"# + trailBoundary)

    /// `500,000,000` — comma-grouped integer.
    private static let groupedRegex = regex(
        leadBoundary + #"([0-9]{1,3}(?:,[0-9]{3})+)"# + trailBoundary)

    /// `3.14` — integer and fractional parts, not part of a version string.
    private static let decimalRegex = regex(
        leadBoundary + #"([0-9]+)\.([0-9]+)"# + trailBoundary)

    /// `13th`, `21st` — digits immediately followed by an ordinal suffix.
    private static let ordinalRegex = regex(
        leadBoundary + #"([0-9]+)(st|nd|rd|th)"# + #"(?![A-Za-z])"#)

    /// `007` — leading zero forces a digit-by-digit reading.
    private static let leadingZeroRegex = regex(
        leadBoundary + #"(0[0-9]+)"# + trailBoundary)

    /// `26` — a plain standalone integer.
    private static let cardinalRegex = regex(
        leadBoundary + #"([0-9]+)"# + trailBoundary)

    // MARK: - Per-match spelling (return nil to leave the match unchanged)

    private static func spellMeridiemTime(_ groups: [String]) -> String? {
        let clock = "\(groups[1]):\(groups[2])"
        let spoken = spaced(SayAsInterpreter.interpret(content: clock, interpretAs: "time", format: nil))
        guard !containsDigit(spoken) else { return nil }
        let meridiem = groups[3].lowercased() == "p" ? "p m" : "a m"
        return "\(spoken) \(meridiem)"
    }

    private static func spellDecimal(_ groups: [String]) -> String? {
        guard let integerPart = cardinalWords(groups[1]) else { return nil }
        let fractionalPart = SayAsInterpreter.interpret(
            content: groups[2], interpretAs: "digits", format: nil)
        guard !containsDigit(fractionalPart) else { return nil }
        return "\(integerPart) point \(fractionalPart)"
    }

    private static func spellOrdinal(_ groups: [String]) -> String? {
        // Only rewrite grammatically valid ordinals (`13th`, not `13st`).
        guard let number = Int(groups[1]), expectedOrdinalSuffix(for: number) == groups[2].lowercased()
        else { return nil }
        let spoken = spaced(SayAsInterpreter.interpret(content: groups[1], interpretAs: "ordinal", format: nil))
        return containsDigit(spoken) ? nil : spoken
    }

    private static func spellLeadingZero(_ groups: [String]) -> String? {
        let spoken = SayAsInterpreter.interpret(content: groups[1], interpretAs: "digits", format: nil)
        return containsDigit(spoken) ? nil : spoken
    }

    private static func spellCardinal(_ groups: [String]) -> String? {
        cardinalWords(groups[1])
    }

    /// Port of Misaki `get_number`'s currency branch: integer and cents
    /// pairs with `and` between them, units pluralized away from 1, a zero
    /// pair dropped. A cents part longer than two digits isn't currency by
    /// Misaki's `is_currency` — it reads as a decimal plus the plural unit
    /// (`$1.234` → `one point two three four dollars`).
    private static func spellCurrency(_ groups: [String]) -> String? {
        let units: (major: String, minor: String)
        switch groups[1] {
        case "$": units = ("dollar", "cent")
        case "£": units = ("pound", "pence")
        case "€": units = ("euro", "cent")
        default: return nil
        }

        let value = groups[2].replacingOccurrences(of: ",", with: "")
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let major = Int(parts[0].isEmpty ? "0" : parts[0]) else { return nil }

        func unitWord(_ unit: String, count: Int) -> String {
            (count == 1 || unit == "pence") ? unit : unit + "s"
        }

        if parts.count == 2, parts[1].count > 2, !parts[1].allSatisfy({ $0 == "0" }) {
            guard let spoken = spellDecimal(["", String(parts[0]), String(parts[1])]) else { return nil }
            return "\(spoken) \(unitWord(units.major, count: 2))"
        }

        let minor = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
        var spoken: [String] = []
        if major != 0 || minor == 0 {
            guard let majorWords = cardinalWords(String(major)) else { return nil }
            spoken.append("\(majorWords) \(unitWord(units.major, count: major))")
        }
        if minor != 0 {
            guard let minorWords = cardinalWords(String(minor)) else { return nil }
            spoken.append("\(minorWords) \(unitWord(units.minor, count: minor))")
        }
        return spoken.joined(separator: " and ")
    }

    /// Port of `num2words to='year'` as Misaki consumes it (its `extend_num`
    /// drops the `and` connective): `1999` → `nineteen ninety nine`, `1905` →
    /// `nineteen oh five`, `1900` → `nineteen hundred`, `2005` → `two
    /// thousand five`.
    private static func spellYear(_ groups: [String]) -> String? {
        guard let year = Int(groups[1]) else { return nil }
        let century = year / 100
        let remainder = year % 100
        if century % 10 == 0 {
            // 2000 → two thousand, 2005 → two thousand five, 1000 → one thousand
            guard let whole = cardinalWords(String(year)) else { return nil }
            return whole
        }
        guard let high = cardinalWords(String(century)) else { return nil }
        if remainder == 0 {
            return "\(high) hundred"
        }
        guard let low = cardinalWords(String(remainder)) else { return nil }
        return remainder < 10 ? "\(high) oh \(low)" : "\(high) \(low)"
    }

    private static func spellGrouped(_ groups: [String]) -> String? {
        cardinalWords(groups[1].replacingOccurrences(of: ",", with: ""))
    }

    // MARK: - Helpers

    /// Spell a non-negative integer string with spaces between words
    /// (`twenty-six` → `twenty six`); `nil` if it overflows `Int` and the
    /// interpreter hands the digits back unchanged.
    private static func cardinalWords(_ digits: String) -> String? {
        let spoken = spaced(SayAsInterpreter.interpret(content: digits, interpretAs: "cardinal", format: nil))
        return containsDigit(spoken) ? nil : spoken
    }

    /// The grammatically correct ordinal suffix for `number`.
    private static func expectedOrdinalSuffix(for number: Int) -> String {
        if (11...13).contains(number % 100) { return "th" }
        switch number % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    private static func spaced(_ text: String) -> String {
        text.replacingOccurrences(of: "-", with: " ")
    }

    private static func containsDigit(_ text: String) -> Bool {
        text.contains { $0.isNumber }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure is a programmer error
        // (mirrors `SayAsInterpreter`'s regex initialization).
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    /// Apply `regex` to `text`, replacing each match with `transform`'s
    /// result. Matches are spliced in reverse so earlier ranges stay valid.
    /// `transform` receives the full match plus capture groups (index 0 is
    /// the whole match); returning `nil` leaves that match untouched.
    private static func apply(
        _ regex: NSRegularExpression,
        to text: String,
        transform: ([String]) -> String?
    ) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            var groups: [String] = []
            groups.reserveCapacity(match.numberOfRanges)
            for index in 0..<match.numberOfRanges {
                let range = match.range(at: index)
                groups.append(range.location == NSNotFound ? "" : ns.substring(with: range))
            }
            if let replacement = transform(groups) {
                mutable.replaceCharacters(in: match.range, with: replacement)
            }
        }
        return mutable as String
    }
}
