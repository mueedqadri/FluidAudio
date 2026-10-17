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
        }

        /// The written form: without its period for titles and reference
        /// words (`Mr`, `Fig`), with it otherwise (`e.g.`).
        let written: String
        let spoken: String
        let context: Context
    }

    static let entries: [Entry] = titles + beforeNumber + anywhere

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
}
