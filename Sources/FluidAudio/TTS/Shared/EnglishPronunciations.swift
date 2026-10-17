import Foundation

/// English sounds the phoneme-reading frontends (Kokoro, StyleTTS2) give
/// themselves because the Misaki lexicon lacks or misreads the word. Text any
/// voice reads, such as `Mr.` → "mister", is ``EnglishAbbreviationTable``.
enum EnglishPronunciations {

    /// IPA for words the lexicon lacks: `miz` (the reading of `Ms.`), and the
    /// Latin `et` (of `et al.`) and `ibid`, which the G2P model would sound out.
    static let ipa: [String: String] = ["miz": "mˈɪz", "et": "ˈɛt", "ibid": "ˈɪbɪd"]

    /// Exact uppercase spellings read as letter names because their lexicon
    /// entry is not (`AI` → blended `ˈAˌI`, `US` → the pronoun, `AM` → the
    /// verb; `AM` is also the meridiem NeMo writes for `a.m.`). Lowercase
    /// `us`/`ai` keep their word readings.
    static let spelledAsLetters: Set<String> = ["AI", "AM", "US"]
}
