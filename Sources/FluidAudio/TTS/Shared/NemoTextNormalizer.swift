#if canImport(CNemoTextProcessing)
import CNemoTextProcessing
#endif
import Foundation
import os

/// NVIDIA NeMo text normalization through the compiled-FST engine in
/// `text-processing-rs`: written forms to their spoken reading, `"$5"` →
/// `"five dollars"`. Deterministic and rule-authored; the grammars load on the
/// first call and are read-only after, so concurrent calls are safe.
public enum NemoTextNormalizer {

    public enum Language: String, Sendable {
        case english = "en"
        case french = "fr"
        case spanish = "es"
        case german = "de"
        case hindi = "hi"
        case japanese = "ja"
        case mandarin = "zh"
    }

    /// `text` in spoken form, or `text` unchanged when the engine declines it
    /// or is not linked.
    public static func normalize(_ text: String, language: Language) -> String {
        let key = Memo.key(text, language)
        if let known = memo.reading(for: key) { return known }
        let reading = engineReading(text, language: language)
        memo.store(reading, for: key)
        return reading
    }

    private static func engineReading(_ text: String, language: Language) -> String {
        #if canImport(CNemoTextProcessing)
        guard let pointer = nemo_tn_fst(text, language.rawValue) else { return text }
        defer { nemo_free_string(pointer) }
        return String(cString: pointer)
        #else
        return text
        #endif
    }

    /// Readings already made, for a caller that reads the same text across runs
    /// of one engine build (a corpus snapshot); off unless switched on. The
    /// engine is deterministic, so a kept reading is the engine's own answer.
    static let memo = Memo()

    final class Memo: Sendable {
        private let readings = OSAllocatedUnfairLock<[String: String]?>(initialState: nil)

        static func key(_ text: String, _ language: Language) -> String {
            language.rawValue + "\u{1F}" + text
        }

        /// Starts keeping readings, beginning with `known`.
        func enable(with known: [String: String] = [:]) {
            readings.withLock { $0 = ($0 ?? [:]).merging(known) { _, new in new } }
        }

        func disable() {
            readings.withLock { $0 = nil }
        }

        /// Every reading kept so far.
        var contents: [String: String] {
            readings.withLock { $0 ?? [:] }
        }

        func reading(for key: String) -> String? {
            readings.withLock { $0?[key] }
        }

        func store(_ reading: String, for key: String) {
            readings.withLock { if $0 != nil { $0?[key] = reading } }
        }
    }
}
