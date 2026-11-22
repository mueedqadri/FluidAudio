import Foundation

/// Numbers in words for languages Supertonic reads, through Apple's spell-out
/// for the language.
///
/// Supertonic 3 is meant to read digits itself, but in Spanish, Italian,
/// Portuguese, French, Korean and Japanese it reads them wrongly, and
/// differently on each run: its fp32 reference turned 1495 into 1995, 1495 and
/// "mil mil quinientos sesenta y cinco" over three seeds. Spelled words it
/// reads reliably.
///
/// A number is read the way the language writes it: its decimal separator is a
/// decimal point, and the other separator, or a space, joins groups of three
/// (`2 743 357`, `5,066`). The other separator before anything but a group of
/// three is a decimal point too (`0.1` in a Spanish text). Digits glued to a
/// Latin letter (`km2`, `A4`), clock times and German ordinals (`13.`) are left
/// for the voice, which reads them as they are.
///
/// No expansions are recorded: Supertonic's highlights are estimated from the
/// page text, not from word timings.
public enum SpokenNumbers {

    /// Base language codes this applies to.
    public static let languages: Set<String> = ["de", "es", "fr", "it", "pt", "ja", "ko"]

    public static func spokenText(_ text: String, language: String) -> SpokenText {
        SpokenText(text: normalize(text, language: language), language: language)
    }

    static func normalize(_ text: String, language: String) -> String {
        guard languages.contains(language), text.contains(where: \.isASCIIDigit) else { return text }
        let style = Style(language)
        let spelled = replace(style.numberPattern, in: text) { m in
            if style.leftAlone(m) { return m.whole }
            var words = style.spell(m.value)
            guard !words.isEmpty else { return m.whole }
            if m.percent { words += style.percentWord }
            return words
        }
        return spelled
    }

    // MARK: - One language's way of writing and saying numbers

    struct Match {
        let whole: String
        let value: String
        let percent: Bool
        let before: Character?
        let after: Character?
        let afterNext: Character?
    }

    struct Style {
        let language: String
        let decimal: Character
        let other: Character
        let spaceGroups: Bool
        let spellOut: NumberFormatter

        init(_ language: String) {
            self.language = language
            let identifier = Self.locales[language] ?? language
            let decimal = NumberFormatter()
            decimal.locale = Locale(identifier: identifier)
            decimal.numberStyle = .decimal
            self.decimal = decimal.decimalSeparator.first ?? "."
            self.other = self.decimal == "," ? "." : ","
            self.spaceGroups = !["ja", "ko"].contains(language)
            let spellOut = NumberFormatter()
            spellOut.locale = Locale(identifier: identifier)
            spellOut.numberStyle = .spellOut
            self.spellOut = spellOut
        }

        static let locales = [
            "de": "de_DE", "es": "es_ES", "fr": "fr_FR", "it": "it_IT", "pt": "pt_BR", "ja": "ja_JP", "ko": "ko_KR",
        ]

        var percentWord: String {
            switch language {
            case "de": " Prozent"
            case "es": " por ciento"
            case "fr": " pour cent"
            case "it": " per cento"
            case "pt": " por cento"
            case "ja": "パーセント"
            case "ko": " 퍼센트"
            default: "%"
            }
        }

        /// A run of digits with its group and decimal separators, and a
        /// following `%`.
        var numberPattern: String {
            let groupMarks = "[.,'\u{00A0}\u{202F}\u{2009}" + (spaceGroups ? " " : "") + "]"
            return "(?<![0-9])([0-9]{1,3}(?:\(groupMarks)[0-9]{3})+(?![0-9])|[0-9]+)(?:[.,][0-9]+)?(?:\\s?%)?"
        }

        /// Codes, times and ordinals the voice reads as written.
        func leftAlone(_ m: Match) -> Bool {
            if let b = m.before, b.isASCII, b.isLetter { return true }
            if let a = m.after, a.isASCII, a.isLetter, !m.percent { return true }
            if [":", "/"].contains(m.before) || [":", "/"].contains(m.after) { return true }
            if language == "de", m.after == ".", m.afterNext == nil || m.afterNext?.isWhitespace == true {
                return true
            }
            return false
        }

        /// `value` (digits and separators as written) in words, or "" when it
        /// is not a number this can read.
        func spell(_ written: String) -> String {
            guard let number = parse(written) else { return "" }
            let digits = number.replacingOccurrences(of: ".", with: "")
            if digits.count > 1, digits.hasPrefix("0"), !number.hasPrefix("0.") { return "" }
            var words: String
            if language == "de", let n = Int(number), (1100...1999).contains(n) {
                words = say(n / 100) + "hundert" + (n % 100 == 0 ? "" : say(n % 100))
            } else {
                words = spellOut.string(from: NSDecimalNumber(string: number)) ?? ""
            }
            words = words.replacingOccurrences(of: "\u{00AD}", with: "")
            if language == "ja" { words = words.replacingOccurrences(of: "・", with: "点") }
            return words
        }

        private func say(_ n: Int) -> String {
            spellOut.string(from: NSNumber(value: n)) ?? ""
        }

        /// The written number as a plain decimal (`2743357`, `1287.36`).
        func parse(_ written: String) -> String? {
            var groups = written
            var fraction = ""
            if let last = written.lastIndex(where: { $0 == "." || $0 == "," }) {
                let mark = written[last]
                let tail = written[written.index(after: last)...]
                let isGroup = mark != decimal && tail.count == 3
                if !isGroup {
                    fraction = String(tail)
                    groups = String(written[..<last])
                }
            }
            let whole = groups.filter(\.isASCIIDigit)
            let marks = groups.filter { !$0.isASCIIDigit }
            if marks.contains(decimal) { return nil }
            guard !whole.isEmpty, fraction.allSatisfy(\.isASCIIDigit) else { return nil }
            return fraction.isEmpty ? whole : whole + "." + fraction
        }
    }

    // MARK: - Helpers

    private static func replace(_ pattern: String, in text: String, with transform: (Match) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let whole = ns.substring(with: m.range)
            let percent = whole.hasSuffix("%")
            let value = percent ? whole.dropLast().trimmingCharacters(in: .whitespaces) : whole
            let end = m.range.location + m.range.length
            let match = Match(
                whole: whole, value: value, percent: percent,
                before: character(in: ns, at: m.range.location - 1),
                after: character(in: ns, at: end),
                afterNext: character(in: ns, at: end + 1))
            result = result.replacingCharacters(in: m.range, with: transform(match)) as NSString
        }
        return result as String
    }

    private static func character(in ns: NSString, at offset: Int) -> Character? {
        guard offset >= 0, offset < ns.length else { return nil }
        return Character(UnicodeScalar(ns.character(at: offset)) ?? " ")
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
