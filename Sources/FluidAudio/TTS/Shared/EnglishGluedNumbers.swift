import Foundation

/// A number glued after one capital letter or before a hyphenated word, which
/// NeMo garbles or reads digit by digit (`A100` → "AONEHUNDRED", `1202-layer`
/// → "one two zero two-layer"): split and read as a number (`A100` → "A one
/// hundred", `1990-era` → "nineteen ninety-era"). A number before a letter
/// (`175B`, `221B`) keeps NeMo's digit reading: a model size and a house number
/// look the same. A code joined by hyphens (`TV-40-E41`, `COVID-19`) or with
/// two letters (`CS581676`) stays a serial.
enum EnglishGluedNumbers {

    /// `text` with its glued numbers read as numbers.
    static func spell(_ text: String) -> String {
        guard text.contains(where: \.isNumber) else { return text }
        var result = replace(letterNumberRegex, in: text) { "\($0[1]) \(EnglishTextNormalizer.normalize($0[2]))" }
        result = replace(numberWordRegex, in: result) { EnglishTextNormalizer.normalize($0[1]) }
        return result
    }

    /// `A100`, `B12`, `Q3`: one capital letter and a number, not part of a dotted
    /// code (`Z39.48`), a list (`50/101`) or a page range (`S85–94`, `R77–R87`),
    /// which the range rule reads whole. `V2` is the version rule's.
    private static let letterNumberRegex = regex(
        #"(?<![A-Za-z0-9.\-–—/])([A-UW-Z])([0-9]{1,4})(?![A-Za-z0-9\-–—/])(?![.,][0-9])"#)
    /// `1202-layer`, `1990-era`: a number of three or four digits, without a
    /// leading zero, before one hyphenated word; a longer chain is a file name
    /// (`0001-add-limit.patch`).
    private static let numberWordRegex = regex(
        #"(?<![A-Za-z0-9.,\-–—/])([1-9][0-9]{2,3})(?=-[a-z]+(?![A-Za-z0-9.\-]))"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    private static func replace(
        _ regex: NSRegularExpression, in text: String, transform: ([String]) -> String
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
            mutable.replaceCharacters(in: match.range, with: transform(groups))
        }
        return mutable as String
    }
}
