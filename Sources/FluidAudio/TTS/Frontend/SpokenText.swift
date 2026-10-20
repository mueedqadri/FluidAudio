import Foundation

/// Text as a voice reads it, with every rewritten span tied to the written
/// words it replaced, so word timings can be reported against the words a
/// reader sees (`"1999"`, not `"nineteen"` and `"ninety"`).
public struct SpokenText: Sendable, Equatable {
    public struct Expansion: Sendable, Equatable {
        /// UTF-16 offsets of the spoken words in `text`.
        public let range: Range<Int>
        /// The written words they replace.
        public let source: String

        public init(range: Range<Int>, source: String) {
            self.range = range
            self.source = source
        }
    }

    public let text: String
    /// The base language code it is read in (`en`, `fr`).
    public let language: String
    public let expansions: [Expansion]

    public init(text: String, language: String, expansions: [Expansion] = []) {
        self.text = text
        self.language = language
        self.expansions = expansions
    }
}

/// Decides how written text is said, once per passage, before any voice reads
/// it. Every voice takes a `SpokenText`, so which frontend a voice uses is the
/// caller's choice, not the voice's.
public protocol SpokenTextFrontend: Sendable {
    /// `text` as it is read in `language` (`en`, `en-US`).
    func spokenText(_ text: String, language: String) -> SpokenText
}

extension SpokenTextFrontend {
    static func baseLanguage(_ language: String) -> String {
        String(language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(language)).lowercased()
    }
}

/// The fork's rules: English through ``EnglishTextNormalizer/spokenText(_:)``
/// (our rules, NeMo, the number fallback); other languages as written.
public struct RuleFrontend: SpokenTextFrontend {
    public init() {}

    public func spokenText(_ text: String, language: String) -> SpokenText {
        let base = Self.baseLanguage(language)
        guard base == "en" else { return SpokenText(text: text, language: base) }
        return EnglishTextNormalizer.spokenText(text)
    }
}

/// The text as written, for a voice that reads raw text itself.
public struct PassthroughFrontend: SpokenTextFrontend {
    public init() {}

    public func spokenText(_ text: String, language: String) -> SpokenText {
        SpokenText(text: text, language: Self.baseLanguage(language))
    }
}
