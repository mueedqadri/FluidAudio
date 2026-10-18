import Foundation

/// Roman numerals read as numbers where their context says they are one:
/// after a word that numbers things (`Chapter XIX` → "Chapter nineteen",
/// `Super Bowl CL`), after a monarch's or pope's name as an ordinal (`Henry
/// VIII` → "Henry the eighth"), after another capitalized word when the
/// numeral has two or more letters (`Rocky II` → "Rocky two"), and as list
/// markers (`(ii)` → "(two)"). A numeral alone (`MIX`, `CL`, the pronoun `I`)
/// and a lone letter after a name (`Malcolm X`) stay as written.
enum EnglishRomanNumerals {

    /// `text` with its Roman numerals in words where the context allows.
    static func spell(_ text: String) -> String {
        guard text.contains(where: { "IVXLCDMivx".contains($0) }) else { return text }
        var result = spellEnumerators(text)
        result = replace(afterCueRegex, in: result) { groups in
            // `this chapter I have`: after a lowercase cue a lone letter is the pronoun.
            guard groups[2].count > 1 || groups[1].first?.isUppercase == true else { return nil }
            return value(groups[2]).map { groups[1] + EnglishTextNormalizer.normalize(String($0)) }
        }
        result = replace(afterNameRegex, in: result) { groups in
            let name = groups[1]
            guard let number = value(groups[2]), number < 40,
                !EnglishAbbreviationTable.sentenceOpeners.contains(name)
            else { return nil }
            if regnalNames.contains(name) {
                return "\(name) the \(ordinal(number))\(groups[3])"
            }
            guard groups[2].count >= 2 else { return nil }
            return "\(name) \(EnglishTextNormalizer.normalize(String(number)))\(groups[3])"
        }
        return result
    }

    // MARK: - Values

    /// Strict subtractive form, 1–3999.
    private static let formRegex = try! NSRegularExpression(
        pattern: #"^M{0,3}(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})$"#)

    private static let letterValues: [Character: Int] = [
        "I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000,
    ]

    /// The value of a well-formed numeral written in one case, else `nil`.
    static func value(_ numeral: String) -> Int? {
        guard !numeral.isEmpty, numeral == numeral.uppercased() || numeral == numeral.lowercased() else { return nil }
        let upper = numeral.uppercased()
        guard formRegex.firstMatch(in: upper, range: NSRange(location: 0, length: (upper as NSString).length)) != nil
        else { return nil }
        var total = 0
        let values = upper.compactMap { letterValues[$0] }
        for (index, current) in values.enumerated() {
            total += index + 1 < values.count && current < values[index + 1] ? -current : current
        }
        return total
    }

    /// "eighth", "twenty first", "fourteenth".
    private static func ordinal(_ number: Int) -> String {
        var words = EnglishTextNormalizer.normalize(String(number)).components(separatedBy: " ")
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth",
                         "eight": "eighth", "nine": "ninth", "twelve": "twelfth"]
        let last = words.removeLast()
        let spoken = irregular[last] ?? (last.hasSuffix("y") ? String(last.dropLast()) + "ieth" : last + "th")
        return (words + [spoken]).joined(separator: " ")
    }

    // MARK: - Contexts

    /// Words that number what follows; the numeral may be either case
    /// (`Act II, Scene iii`). A single `C`, `D`, `L` or `M` after one is a
    /// label (`Appendix C`), and lowercase numerals keep to `i v x`
    /// (`section c` is a letter).
    private static let cueWords = [
        "Chapter", "Part", "Book", "Volume", "Act", "Scene", "Article", "Appendix", "Section", "Canto",
        "Phase", "Stage", "Type", "Class", "Episode", "Season", "Title", "Clause", "Psalm", "Plate",
        "World War", "Super Bowl", "Vatican",
    ]

    private static let afterCueRegex: NSRegularExpression = {
        let cues = cueWords.flatMap { [$0, $0.lowercased(), $0.uppercased()] }
            .map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return try! NSRegularExpression(
            pattern: #"(\b(?:"# + cues + #")\s+)([IVXLCDM]{2,}|[IVX]|[ivx]+)(?![A-Za-z0-9])"#)
    }()

    /// A capitalized word, then an uppercase numeral of `I`, `V` and `X`
    /// (1–39; `CL`, `DC`, `MIX` are left alone), then a possessive or nothing.
    private static let afterNameRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z.])([A-Z][a-z]+) ([IVX]+)((?:['’]s)?)(?![A-Za-z0-9])"#)

    /// Monarchs' and popes' names, read with an ordinal (`Louis XIV` →
    /// "Louis the fourteenth"); other names read a cardinal.
    private static let regnalNames: Set<String> = [
        "Alexander", "Alfonso", "Amenhotep", "Anne", "Benedict", "Boniface", "Carlos", "Casimir",
        "Catherine", "Charles", "Christian", "Clement", "Constantine", "David", "Edmund", "Edward",
        "Elizabeth", "Eric", "Ferdinand", "Francis", "Frederick", "Friedrich", "George", "Gregory",
        "Gustav", "Gustavus", "Haakon", "Harold", "Henry", "Innocent", "Ivan", "James", "John",
        "Joseph", "Juan", "Leo", "Leopold", "Louis", "Ludwig", "Magnus", "Manuel", "Mary",
        "Maximilian", "Mehmed", "Napoleon", "Nicholas", "Olaf", "Otto", "Paul", "Pedro", "Peter",
        "Philip", "Pius", "Ramesses", "Ramses", "Richard", "Robert", "Rudolf", "Selim", "Sigismund",
        "Stephen", "Suleiman", "Thutmose", "Urban", "Valdemar", "Victor", "Wilhelm", "William",
    ]

    // MARK: - List markers (from upstream FluidAudio `spellRomanEnumerators`)

    /// `(ii)`, `ii)` and `ii.` as cardinals, keyed on the enumerator form: a
    /// numeral that is not plainly a list marker (uppercase, a lone `v`/`x`,
    /// `xx`) needs a second one in the text, since a list has members.
    private static func spellEnumerators(_ text: String) -> String {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let found = parenthesizedRegex.matches(in: text, range: range).map { ns.substring(with: $0.range(at: 1)) }
            + enumeratorRegex.matches(in: text, range: range).map { ns.substring(with: $0.range(at: 2)) }
        let markers = found.filter { listValue($0) != nil }
        guard !markers.isEmpty else { return text }
        let isList = markers.count >= 2

        func words(_ numeral: String) -> String? {
            guard isList || isSelfEvidentEnumerator(numeral), let number = listValue(numeral) else { return nil }
            return EnglishTextNormalizer.normalize(String(number))
        }
        var result = replace(parenthesizedRegex, in: text) { groups in words(groups[1]).map { "(\($0))" } }
        result = replace(enumeratorRegex, in: result) { groups in
            words(groups[2]).map { "\(groups[1])\($0)\(groups[3])" }
        }
        return result
    }

    /// `i`, or lowercase two or more letters that are not all `x`.
    private static func isSelfEvidentEnumerator(_ numeral: String) -> Bool {
        guard numeral == numeral.lowercased() else { return false }
        return numeral == "i" || (numeral.count >= 2 && numeral.contains { $0 != "x" })
    }

    /// List markers stay within `i v x` (1–39), so `mix`, `cd` and `mm` are never markers.
    private static func listValue(_ numeral: String) -> Int? {
        guard numeral.allSatisfy({ "ivxIVX".contains($0) }), let number = value(numeral), number < 40 else { return nil }
        return number
    }

    private static let parenthesizedRegex = try! NSRegularExpression(
        pattern: #"(?<!\p{L})\(([ivx]{1,7}|[IVX]{1,7})\)(?![\p{L}0-9])"#)

    private static let enumeratorRegex = try! NSRegularExpression(
        pattern: #"(^[ \t]*|[;:,.]\s)([ivx]{1,7}|[IVX]{1,7})(\)(?![\p{L}0-9])|\.(?=\s))"#,
        options: [.anchorsMatchLines])

    /// `transform` gets the match then its groups; `nil` leaves the match.
    private static func replace(
        _ regex: NSRegularExpression, in text: String, transform: ([String]) -> String?
    ) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            if let replacement = transform(groups) {
                mutable.replaceCharacters(in: match.range, with: replacement)
            }
        }
        return mutable as String
    }
}
