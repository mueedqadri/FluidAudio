import Foundation

/// Offline access to the English phonemizer chain for parity tooling.
///
/// Builds the same frontend `KokoroAneManager.ensureEnglishPhonemizer()` uses,
/// but from asset files alone — no Core ML models are loaded, and OOV words
/// return a `<OOV:word>` marker instead of running the BART fallback so the
/// parity differ can see exactly which words the chain cannot resolve.
public struct EnglishFrontendHarness: Sendable {
    public struct WordPhonemes: Sendable, Codable {
        public let word: String
        public let phonemes: String

        public init(word: String, phonemes: String) {
            self.word = word
            self.phonemes = phonemes
        }
    }

    private let phonemizer: KokoroAneEnglishPhonemizer

    private init(phonemizer: KokoroAneEnglishPhonemizer) {
        self.phonemizer = phonemizer
    }

    /// - Parameters:
    ///   - kokoroDirectory: directory containing `us_lexicon_cache.json`
    ///     (the Kokoro HF asset cache root).
    ///   - vocabFile: the ANE `vocab.json` single-character IPA → id map.
    public static func load(kokoroDirectory: URL, vocabFile: URL) async throws -> EnglishFrontendHarness {
        let vocab = try KokoroAneVocab.load(from: vocabFile)
        let allowedTokens = Set(vocab.map.keys.map(String.init))
        let allowedPunctuation = Set(
            vocab.map.keys.filter { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }
        )

        let cache = LexiconAssetCache()
        try await cache.ensureLoaded(kokoroDirectory: kokoroDirectory, allowedTokens: allowedTokens)
        let lexicons = await cache.lexicons()

        let phonemizer = KokoroAneEnglishPhonemizer(
            wordToPhonemes: lexicons.word,
            caseSensitiveWordToPhonemes: lexicons.caseSensitive,
            customLexicon: [:],
            allowedPunctuation: allowedPunctuation
        )
        return EnglishFrontendHarness(phonemizer: phonemizer)
    }

    /// Normalizes and phonemizes `text`, returning one entry per resolved word.
    public func phonemizeWords(_ text: String) async throws -> [WordPhonemes] {
        let normalized = EnglishTextNormalizer.normalize(text)
        let segments = try await phonemizer.phonemizeSegments(normalized) { word in
            ["<OOV:\(word)>"]
        }
        return segments.map { WordPhonemes(word: $0.word, phonemes: $0.phonemes) }
    }
}
