#if canImport(CNemoTextProcessing)
import CNemoTextProcessing
#endif
import Foundation

/// NVIDIA NeMo text normalization through the compiled-FST engine in
/// `text-processing-rs`: written forms to their spoken reading, `"$5"` →
/// `"five dollars"`. Deterministic and rule-authored; the grammars load on the
/// first call and are read-only after, so concurrent calls are safe.
enum NemoTextNormalizer {

    enum Language: String {
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
    static func normalize(_ text: String, language: Language) -> String {
        #if canImport(CNemoTextProcessing)
        guard let pointer = nemo_tn_fst(text, language.rawValue) else { return text }
        defer { nemo_free_string(pointer) }
        return String(cString: pointer)
        #else
        return text
        #endif
    }
}
