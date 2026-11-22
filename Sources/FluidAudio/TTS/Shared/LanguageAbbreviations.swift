import Foundation

/// Abbreviations that end in a period without ending the sentence, in the other
/// Latin-script languages ONarrator ships: titles before a name, words that
/// never close a sentence, and reference words before a number. English keeps
/// its own table (`EnglishAbbreviationTable`); `SentenceBoundaryPolicy` reads
/// both, so the app that cuts sentences and the voice that reads them agree.
///
/// Only common written forms. A title written without a period (`Mme`, `Dr` in
/// French) needs no entry.
enum LanguageAbbreviations {
    /// Titles before a name (`M. Seguin`, `Sr. García`).
    static let titles: Set<String> = [
        // French (`M.` alone is a capital's initial, which the policy already continues)
        "MM.",
        // German
        "Hr.", "Fr.", "Dr.", "Prof.",
        // Spanish and Portuguese
        "Sr.", "Sra.", "Srta.", "Sres.", "Dra.", "Ud.", "Uds.",
        // Italian
        "Sig.", "Sig.ra", "Sig.na", "Dott.", "Dott.ssa", "Ing.", "Avv.",
    ]

    /// Words that do not close a sentence, one or two tokens (`z. B.`, `p. ej.`).
    static let neverEndASentence: Set<String> = [
        // German
        "z. B.", "z.B.", "d. h.", "d.h.", "bzw.", "vgl.", "ca.", "evtl.",
        // French
        "env.",
        // Spanish and Portuguese
        "p. ej.", "p.ej.", "p. ex.", "p.ex.", "aprox.",
        // Italian
        "cfr.",
    ]

    /// Reference words before a number (`Nr. 27`, `pág. 12`).
    static let beforeNumber: Set<String> = [
        // German
        "Nr.", "S.", "Bd.", "Abb.", "Kap.", "Tab.",
        // French
        "chap.", "vol.",
        // Spanish and Portuguese
        "pág.", "págs.", "núm.", "cap.",
        // Italian
        "pag.", "n.",
    ]

    /// German writes an ordinal as a number and a period (`im 13. Jahrhundert`,
    /// `am 3. Oktober`). The sentence goes on after one when the word before it
    /// is one of these, lower-cased. Not `am`, which English has too (`I am 13.`);
    /// a date after it is caught by its month.
    static let ordinalLeads: Set<String> = ["im", "vom", "zum", "beim", "dem", "den", "der", "des", "ins", "ans"]

    /// …or when the next word starts with one of these.
    static let ordinalNouns: [String] = [
        "Januar", "Jänner", "Februar", "März", "April", "Mai", "Juni", "Juli", "August",
        "September", "Oktober", "November", "Dezember", "Jahrhundert", "Jahrtausend", "Auflage",
    ]
}
