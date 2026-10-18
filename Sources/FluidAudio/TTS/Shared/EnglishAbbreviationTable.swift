import Foundation

/// Every English abbreviation the frontend reads as words, with the context
/// it needs to be read that way. ``EnglishTitleAbbreviations`` and
/// ``EnglishReferenceAbbreviations`` take their lists from here, so adding
/// one is a single entry.
enum EnglishAbbreviationTable {

    struct Entry: Sendable, Equatable {
        enum Context: Sendable, Equatable {
            /// Introduces a name (`Mr. Gatsby`): keeps its period before a
            /// capitalized word and is matched case-sensitively, so the nouns
            /// `gen`/`rep` keep a sentence-ending period.
            case title
            /// Read only before a number (`Fig. 3`), where it cannot be the
            /// noun or the word "no".
            case beforeNumber
            /// Read wherever it stands (`e.g.`). `pattern` is its regular
            /// expression when the written form alone does not say where it
            /// may match.
            case anywhere(pattern: String?)
            /// A street word after a street name in an address (`12 Elm Ave.`),
            /// written without its period.
            case streetSuffix
            /// A unit after a number (`3 hrs`), plural after any number but a
            /// lone `1`; `written` matches with or without `s` and a period.
            case afterNumber(singular: String)
        }

        /// The written form: without its period for titles and reference
        /// words (`Mr`, `Fig`), with it otherwise (`e.g.`).
        let written: String
        let spoken: String
        let context: Context
    }

    static let entries: [Entry] = titles + beforeNumber + anywhere + afterNumber

    /// `Mrs` reads the lexicon's own `mrs` entry (`mˈɪsɪz`): canonical Misaki
    /// resolves the stem, and the `missus` word entry carries a different vowel.
    private static let titles: [Entry] = [
        ("Mr", "mister"), ("Mrs", "mrs"), ("Ms", "miz"), ("Mx", "mix"),
        ("Dr", "doctor"), ("Prof", "professor"), ("Rev", "reverend"), ("Fr", "father"),
        ("Hon", "honorable"), ("Adm", "admiral"), ("Brig", "brigadier"),
        ("Capt", "captain"), ("Cmdr", "commander"), ("Col", "colonel"),
        ("Gen", "general"), ("Gov", "governor"), ("Lt", "lieutenant"),
        ("Maj", "major"), ("Pres", "president"), ("Rep", "representative"),
        ("Sen", "senator"), ("Sgt", "sergeant"), ("Supt", "superintendent"),
    ].map { Entry(written: $0.0, spoken: $0.1, context: .title) }

    private static let beforeNumber: [Entry] = [
        ("Fig", "figure"), ("fig", "figure"), ("Figs", "figures"), ("figs", "figures"),
        ("Eq", "equation"), ("eq", "equation"), ("Eqs", "equations"), ("eqs", "equations"),
        ("Sec", "section"), ("sec", "section"), ("Secs", "sections"), ("secs", "sections"),
        ("Ch", "chapter"), ("ch", "chapter"), ("Chap", "chapter"), ("chap", "chapter"),
        ("p", "page"), ("pp", "pages"),
        ("Vol", "volume"), ("vol", "volume"), ("Vols", "volumes"), ("vols", "volumes"),
        ("No", "number"), ("no", "number"), ("Nos", "numbers"), ("nos", "numbers"),
        ("Ref", "reference"), ("ref", "reference"), ("Refs", "references"), ("refs", "references"),
        ("Tab", "table"), ("tab", "table"), ("Thm", "theorem"), ("Ex", "example"),
    ].map { Entry(written: $0.0, spoken: $0.1, context: .beforeNumber) }

    /// `et al.` keeps its period only where it ends a sentence, so it never
    /// pauses mid-sentence.
    private static let anywhere: [Entry] = [
        Entry(written: "i.e.", spoken: "that is", context: .anywhere(pattern: #"(?<![A-Za-z.])i\.\s?e\.(?=[\s,;:)]|$)"#)),
        Entry(written: "e.g.", spoken: "for example", context: .anywhere(pattern: #"(?<![A-Za-z.])e\.\s?g\.(?=[\s,;:)]|$)"#)),
        Entry(written: "cf.", spoken: "compare", context: .anywhere(pattern: nil)),
        Entry(written: "viz.", spoken: "namely", context: .anywhere(pattern: nil)),
        Entry(written: "vs.", spoken: "versus", context: .anywhere(pattern: nil)),
        Entry(written: "approx.", spoken: "approximately", context: .anywhere(pattern: nil)),
        Entry(written: "Proc.", spoken: "proceedings", context: .anywhere(pattern: nil)),
        Entry(written: "et al.", spoken: "et al", context: .anywhere(pattern: #"\bet\s+al\.(?!\s+[A-Z]|\s*$)"#)),
        Entry(written: "(Ed.)", spoken: "(editor)", context: .anywhere(pattern: #"\((Ed)\.\)"#)),
        Entry(written: "(Eds.)", spoken: "(editors)", context: .anywhere(pattern: #"\((Eds)\.\)"#)),
        Entry(written: "ed.", spoken: "edition", context: .anywhere(pattern: #"(?<=[0-9](?:st|nd|rd|th) )ed\."#)),
    ]

    /// The number itself is NeMo's; only the unit word is rewritten.
    private static let afterNumber: [Entry] = [
        ("hr", "hours", "hour"), ("min", "minutes", "minute"), ("sec", "seconds", "second"),
    ].map { Entry(written: $0.0, spoken: $0.1, context: .afterNumber(singular: $0.2)) }

    /// Written form → spoken words for the entries read in `context`.
    static func spokenForms(in context: Entry.Context) -> [String: String] {
        Dictionary(entries.filter { $0.context == context }.map { ($0.written, $0.spoken) }) { first, _ in first }
    }

    /// The anywhere entries with the regular expression each matches: its
    /// own pattern, or the written form wherever no letter or period precedes it.
    static var anywherePatterns: [(pattern: String, spoken: String)] {
        entries.compactMap { entry in
            guard case .anywhere(let pattern) = entry.context else { return nil }
            return (pattern ?? #"(?<![A-Za-z.])"# + NSRegularExpression.escapedPattern(for: entry.written), entry.spoken)
        }
    }

    /// The units with their patterns: every singular (after a lone `1`)
    /// before any plural, so `1 hr` never reads "hours".
    static var afterNumberPatterns: [(pattern: String, spoken: String)] {
        let units: [(stem: String, plural: String, singular: String)] = entries.compactMap { entry in
            guard case .afterNumber(let singular) = entry.context else { return nil }
            return (NSRegularExpression.escapedPattern(for: entry.written), entry.spoken, singular)
        }
        return units.map { (#"(?<=(?<![0-9.])1 )"# + $0.stem + #"s?\.?(?![A-Za-z])"#, $0.singular) }
            + units.map { (#"(?<=[0-9] )"# + $0.stem + #"s?\.?(?![A-Za-z])"#, $0.plural) }
    }

    // MARK: - Words read before NeMo

    /// NeMo readings REPORT.md keeps ours for, or holds back from NeMo.
    private static let nemoDeclined: Set<String> = ["etc.", "Mrs.", "Ms."]

    /// Our titles: the ones NeMo reads wherever they stand (`Mr.` in `Mr. and
    /// Mrs.`) are read anywhere, the rest only before a name.
    private static let titleReadings: [String: (spoken: String, anywhere: Bool)] = {
        let nemoAnywhere = Set(nemoEntries.filter { $0.context == .anywhere(pattern: nil) }.map(\.written))
        var readings: [String: (spoken: String, anywhere: Bool)] = [:]
        for entry in entries where entry.context == .title {
            readings[entry.written] = (entry.spoken, nemoAnywhere.contains(entry.written + "."))
        }
        for entry in nemoEntries where entry.context == .title && readings[entry.written] == nil {
            readings[entry.written] = (entry.spoken, false)
        }
        return readings
    }()

    /// NeMo's street words, read after a street name (`Elm Ave.`).
    private static let streetReadings = Dictionary(
        nemoEntries.filter { $0.context == .streetSuffix }.map { ($0.written, $0.spoken) }) { first, _ in first }

    /// NeMo's words read anywhere that our table does not already read.
    private static let otherReadings: [String: String] = {
        let ours = Set(entries.map(\.written))
        let titles = Set(titleReadings.keys.map { $0 + "." })
        return Dictionary(
            nemoEntries.filter {
                $0.context == .anywhere(pattern: nil) && !nemoDeclined.contains($0.written)
                    && !ours.contains($0.written) && !titles.contains($0.written)
            }.map { ($0.written, $0.spoken) }) { first, _ in first }
    }()

    /// Capitalized words that start a sentence rather than continue a name, so
    /// `Elm St. Then` ends at the street while `Neville St. Clair` is a name.
    static let sentenceOpeners: Set<String> = [
        "I", "A", "An", "The", "It", "He", "She", "We", "They", "You", "This", "That", "These", "Those",
        "There", "Then", "But", "And", "Or", "So", "If", "In", "On", "At", "As", "Well", "Yes", "No",
        "What", "When", "Why", "How", "My", "His", "Her", "Our", "Their",
    ]

    /// A word with its wrappers: `“Mr.` → `“`, `Mr`, `` ; `Jr.,` → ``, `Jr`, `,`.
    private static let tokenRegex = try! NSRegularExpression(pattern: #"^([(\[“"‘']*)([A-Za-z]+)\.(?![A-Za-z])(.*)$"#)

    /// `text` with its titles (`Mr. Smith`), street words (`Elm St.`) and the
    /// abbreviations NeMo reads as words (`Mt.`, `Esq.`) spelled from the
    /// table, so they never need a NeMo call. `St.` and `Dr.` are titles before
    /// a name (`St. Paul`, `Neville St. Clair`) and street words after a
    /// capitalized word or a house number otherwise (`Elm St.`).
    static func spellWords(_ text: String) -> String {
        guard text.contains(".") else { return text }
        var words = text.components(separatedBy: " ")
        for index in words.indices {
            let word = words[index] as NSString
            guard let match = tokenRegex.firstMatch(in: words[index], range: NSRange(location: 0, length: word.length))
            else { continue }
            let lead = word.substring(with: match.range(at: 1))
            let stem = word.substring(with: match.range(at: 2))
            let trail = word.substring(with: match.range(at: 3))
            let previous = index > words.startIndex ? words[index - 1] : ""
            let next = index + 1 < words.endIndex ? words[index + 1] : ""
            let afterStreetName = lead.isEmpty
                && previous.first.map { $0.isUppercase || $0.isNumber } == true
                && previous.last.map { $0.isLetter || $0.isNumber } == true
            let nextWord = String(next.drop { !$0.isLetter }.prefix { $0.isLetter })
            let beforeName = nextWord.first?.isUppercase == true && !sentenceOpeners.contains(nextWord)

            let spoken: String?
            if let street = streetReadings[stem], afterStreetName, !beforeName {
                spoken = street
            } else if let title = titleReadings[stem], title.anywhere || beforeName {
                spoken = title.spoken
            } else {
                spoken = otherReadings[stem + "."]
            }
            if let spoken { words[index] = lead + spoken + trail }
        }
        return words.joined(separator: " ")
    }
}
