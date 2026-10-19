import Foundation

/// British money before decimalisation, as old books write it: pounds,
/// shillings and pence after a pound amount (`£259. 7s. 6d.` → "two hundred
/// fifty nine pounds, seven shillings and six pence"), a shillings-and-pence
/// pair (`3s. 6d.`), and the colon form (`£983,254:11:9¼` → "… pounds, eleven
/// shillings and nine and a quarter pence"). An `s.` or `d.` counts only in
/// that company, so `the 1990s.` stays a decade.
enum EnglishOldMoney {

    /// `text` with a currency sign joined to the amount after it (`£ 4` →
    /// `£4`), as Project Gutenberg texts set it apart.
    static func joiningSpacedCurrency(_ text: String) -> String {
        guard text.contains(where: { "£$€".contains($0) }) else { return text }
        return text.replacingOccurrences(of: #"([£$€])\s+(?=[0-9])"#, with: "$1", options: .regularExpression)
    }

    /// `text` with its old money in words.
    static func spell(_ text: String) -> String {
        guard text.contains("£") || text.contains("d.") else { return text }
        var result = replace(colonRegex, in: text) { groups in
            "\(pounds(groups[1])), \(shillings(groups[2])) and \(pence(groups[3], groups[4]))"
        }
        result = replace(poundsRegex, in: result) { groups in
            var parts = [pounds(groups[1]), shillings(groups[2])]
            if !groups[3].isEmpty { parts.append(pence(groups[3], groups[4])) }
            return parts.count == 2 ? parts.joined(separator: ", ") : "\(parts[0]), \(parts[1]) and \(parts[2])"
        }
        result = replace(pairRegex, in: result) { groups in
            "\(shillings(groups[1])) and \(pence(groups[2], groups[3]))"
        }
        return result
    }

    // MARK: - Forms

    /// `£983,254:11:9¼`: pounds, shillings and pence with colons.
    private static let colonRegex = regex(#"£([0-9][0-9,]*):\s?([0-9]{1,2}):\s?([0-9]{1,2})([¼½¾]?)"#)
    /// `£259. 7s. 6d.`, `£88 10s.`: shillings, and pence if given, after a pound amount.
    private static let poundsRegex = regex(
        #"£([0-9][0-9,]*)\.?\s+([0-9]{1,2})_?s_?\.(?:\s+([0-9]{1,2})([¼½¾]?)_?d_?\.)?"#)
    /// `3s. 6d.`: a shillings-and-pence pair.
    private static let pairRegex = regex(#"(?<![0-9£.])([0-9]{1,2})_?s_?\.\s+([0-9]{1,2})([¼½¾]?)_?d_?\."#)

    private static func pounds(_ amount: String) -> String {
        NemoTextNormalizer.normalize("£" + amount, language: .english)
    }

    private static func shillings(_ count: String) -> String {
        let words = EnglishTextNormalizer.normalize(count)
        return count == "1" ? "\(words) shilling" : "\(words) shillings"
    }

    private static func pence(_ count: String, _ fraction: String) -> String {
        let words = EnglishTextNormalizer.normalize(count)
        let part = ["¼": " and a quarter", "½": " and a half", "¾": " and three quarters"][fraction] ?? ""
        return count == "1" && part.isEmpty ? "\(words) penny" : "\(words)\(part) pence"
    }

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
