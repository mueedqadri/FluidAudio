import Foundation

/// Abbreviations that research papers and reference lists use, read as their
/// words: `Fig. 3` → "figure 3", `pp. 45` → "pages 45", `i.e.` → "that is",
/// `et al.` → "et al". Each rewrite keeps the written word as its source in
/// ``EnglishTextNormalizer/spokenText(_:)``, so word timings still name it.
///
/// A reference word (`Fig.`, `no.`, `p.`) is read only before a number, where
/// it cannot be the noun or the word "no". Title abbreviations (`Mr.`) are
/// ``EnglishTitleAbbreviations``.
enum EnglishReferenceAbbreviations {

    /// Read before a number: written form without the period → words.
    static let beforeNumber: [String: String] = [
        "Fig": "figure", "fig": "figure", "Figs": "figures", "figs": "figures",
        "Eq": "equation", "eq": "equation", "Eqs": "equations", "eqs": "equations",
        "Sec": "section", "sec": "section", "Secs": "sections", "secs": "sections",
        "Ch": "chapter", "ch": "chapter", "Chap": "chapter", "chap": "chapter",
        "p": "page", "pp": "pages",
        "Vol": "volume", "vol": "volume", "Vols": "volumes", "vols": "volumes",
        "No": "number", "no": "number", "Nos": "numbers", "nos": "numbers",
        "Ref": "reference", "ref": "reference", "Refs": "references", "refs": "references",
        "Tab": "table", "tab": "table", "Thm": "theorem", "Ex": "example",
    ]

    /// Latin words the Misaki lexicon lacks, which the G2P model would sound out.
    static let latinIPA: [String: String] = ["et": "ˈɛt", "ibid": "ˈɪbɪd"]

    /// `text` with its reference abbreviations in words.
    static func spell(_ text: String) -> String {
        guard text.contains(where: { $0 == "." || $0.isNumber }) else { return text }
        var result = text
        result = replace(beforeNumberRegex, in: result) { groups in
            beforeNumber[groups[1]].map { "\($0) " }
        }
        for (regex, words) in phrases {
            result = replace(regex, in: result) { _ in words }
        }
        result = replace(letteredYearRegex, in: result) { groups in
            // "twenty nineteen", as NeMo reads the plain years around it.
            let digits = groups[1]
            let year = digits.hasPrefix("20") && digits >= "2010"
                ? "twenty " + EnglishTextNormalizer.normalize(String(digits.dropFirst(2)))
                : EnglishTextNormalizer.normalize(digits)
            return year.contains(where: \.isNumber) ? nil : "\(year) \(groups[2].uppercased())"
        }
        for (regex, words) in units {
            result = replace(regex, in: result) { _ in words }
        }
        return result
    }

    private static let beforeNumberRegex: NSRegularExpression = {
        let keys = beforeNumber.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        return regex(#"(?<![A-Za-z.])("# + keys + #")\.\s*(?=\(?[0-9])"#)
    }()

    /// Abbreviations read the same anywhere. `et al.` keeps its period only
    /// where it ends a sentence, so it never pauses mid-sentence.
    private static let phrases: [(NSRegularExpression, String)] = [
        (regex(#"(?<![A-Za-z.])i\.\s?e\.(?=[\s,;:)]|$)"#), "that is"),
        (regex(#"(?<![A-Za-z.])e\.\s?g\.(?=[\s,;:)]|$)"#), "for example"),
        (regex(#"(?<![A-Za-z.])cf\."#), "compare"),
        (regex(#"(?<![A-Za-z.])viz\."#), "namely"),
        (regex(#"(?<![A-Za-z.])vs\."#), "versus"),
        (regex(#"(?<![A-Za-z.])approx\."#), "approximately"),
        (regex(#"(?<![A-Za-z.])Proc\."#), "proceedings"),
        (regex(#"\bet\s+al\.(?!\s+[A-Z]|\s*$)"#), "et al"),
        (regex(#"\((Ed)\.\)"#), "(editor)"),
        (regex(#"\((Eds)\.\)"#), "(editors)"),
        (regex(#"(?<=[0-9](?:st|nd|rd|th) )ed\."#), "edition"),
    ]

    /// `2019b`: the second 2019 work cited from one author, a year and a letter.
    private static let letteredYearRegex = regex(
        #"(?<![A-Za-z0-9.])((?:1[5-9]|20)[0-9]{2})([a-z])(?![A-Za-z0-9])"#)

    /// A time unit after a number (`3.5 hrs`, `20 min`, `1 hr`); the number is NeMo's.
    private static let units: [(NSRegularExpression, String)] = [
        (regex(#"(?<=(?<![0-9.])1 )hrs?\.?(?![A-Za-z])"#), "hour"),
        (regex(#"(?<=(?<![0-9.])1 )mins?\.?(?![A-Za-z])"#), "minute"),
        (regex(#"(?<=(?<![0-9.])1 )secs?\.?(?![A-Za-z])"#), "second"),
        (regex(#"(?<=[0-9] )hrs?\.?(?![A-Za-z])"#), "hours"),
        (regex(#"(?<=[0-9] )mins?\.?(?![A-Za-z])"#), "minutes"),
        (regex(#"(?<=[0-9] )secs?\.?(?![A-Za-z])"#), "seconds"),
    ]

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [])
    }

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
