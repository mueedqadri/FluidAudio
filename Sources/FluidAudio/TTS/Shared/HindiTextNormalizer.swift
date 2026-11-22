import Foundation

/// Hindi as a voice reads it: numbers, clock times, rupees and percentages in
/// Hindi words, and the Devanagari signs Supertonic has no token for written in
/// letters it has.
///
/// Ported from KokoroG2P's `HindiG2P` (MIT, same author). Each run of digits,
/// in either digit set, is spelled in place with Apple's `hi_IN` number words,
/// so an attached suffix stays on (`१२वीं` → बारहवीं). NeMo's Hindi grammars
/// were tried first and dropped: with a digit anywhere in a sentence they spell
/// its English words letter by letter (`coenzyme` → सी ओ ई…), and they read
/// one year three ways (उन्नीस सौ सत्तासी, एक हज़ार नौ सौ छब्बीस, एक सात सात नौ).
///
/// Supertonic's `unicode_indexer.json` has no entry for ०–९, ॥, ॐ, ऽ, ॰, ऋ, ॠ,
/// ऍ or ॅ, which Indra OCR and legacy-font conversion both produce; each would
/// reach the model as an unknown token.
///
/// No expansions are recorded: Hindi is read by Supertonic, whose highlights
/// are estimated from the page text, not from word timings.
public enum HindiTextNormalizer {

    public static func spokenText(_ text: String) -> SpokenText {
        SpokenText(text: normalize(text), language: "hi")
    }

    static func normalize(_ text: String) -> String {
        var text = spellAbbreviations(text)
        text = ungroupDigits(text)
        text = spellTimes(text)
        text = spellMoney(text)
        text = spellPercentages(text)
        text = spellNumbers(text)
        return replaceUnreadableSigns(text)
    }

    // MARK: - Abbreviations

    /// The abbreviations books write with ॰ or a full stop, read as words.
    private static func spellAbbreviations(_ text: String) -> String {
        var text = text
        for (pattern, spoken) in [
            (#"(?<!\S)ई[॰.]\s?पू[॰.]"#, "ईसा पूर्व"),
            (#"(?<!\S)डॉ[॰.]\s?"#, "डॉक्टर "),
            (#"(?<!\S)पृ[॰.]\s?"#, "पृष्ठ "),
            (#"(?<!\S)ई[॰.](?=\s|$|[,;।])"#, "ईसवी"),
        ] {
            text = text.replacingOccurrences(of: pattern, with: spoken, options: .regularExpression)
        }
        return text
    }

    // MARK: - Numbers

    private static let digit = "[0-9०-९]"

    private static let spellOut: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "hi_IN")
        formatter.numberStyle = .spellOut
        return formatter
    }()

    /// Every run of digits in Hindi words, a space kept from a Latin letter it
    /// touches (`H2O` → H दो O).
    private static func spellNumbers(_ text: String) -> String {
        let d = digit
        return replace("([A-Za-z])?(?<![0-9०-९])(\(d)+(?:\\.\(d)+)?)([A-Za-z])?", in: text) { g in
            let words = spell(ascii(g[2]))
            guard !words.isEmpty else { return g[0] }
            return (g[1].isEmpty ? "" : g[1] + " ") + words + (g[3].isEmpty ? "" : " " + g[3])
        }
    }

    /// Hindi words for a number. Years and amounts from 1100 to 1999 are read
    /// in hundreds, as people say them (1947 → उन्नीस सौ सैंतालीस); a code
    /// with a leading zero or over nine digits is read digit by digit.
    static func spell(_ digits: String) -> String {
        let whole = digits.split(separator: ".").first.map(String.init) ?? digits
        if !digits.contains("."), whole.count > 9 || (whole.count > 1 && whole.hasPrefix("0")) {
            return whole.compactMap { spellOut.string(from: NSNumber(value: Int(String($0)) ?? 0)) }
                .joined(separator: " ")
        }
        if let n = Int(digits), (1100...1999).contains(n) {
            let rest = n % 100
            let head = (spellOut.string(from: NSNumber(value: n / 100)) ?? "") + " सौ"
            return rest == 0 ? head : head + " " + (spellOut.string(from: NSNumber(value: rest)) ?? "")
        }
        guard let value = Decimal(string: digits) else { return "" }
        return spellOut.string(from: value as NSDecimalNumber) ?? ""
    }

    /// `1,00,000` and `100,000` without their commas; a list such as `12,15`
    /// keeps them, since its last group is not three digits.
    private static func ungroupDigits(_ text: String) -> String {
        let d = digit
        let grouped = "(?<![0-9०-९,])\(d){1,3}(?:(?:,\(d){2})*,\(d){3}|(?:,\(d){3})+)(?![0-9०-९]|,\(d))"
        return replace(grouped, in: text) { $0[0].replacingOccurrences(of: ",", with: "") }
    }

    /// Clock times the way they are said: 10:30 → साढ़े दस बजे, 7:15 → सवा सात
    /// बजे, 4:45 → पौने पाँच बजे, 9:00 → नौ बजे, 21:40 → इक्कीस बजकर चालीस मिनट.
    /// A written बजे after the time is taken into it.
    private static func spellTimes(_ text: String) -> String {
        let d = digit
        return replace("(?<![0-9०-९:])(\(d){1,2}):(\(d){2})(?![0-9०-९:])(\\s*बजे)?", in: text) { g in
            guard let h = Int(ascii(g[1])), let m = Int(ascii(g[2])), h <= 23, m <= 59 else { return g[0] }
            let baje = " बजे"
            switch (m, h) {
            case (0, _): return "\(h)" + baje
            case (30, 1): return "डेढ़" + baje
            case (30, 2): return "ढाई" + baje
            case (30, _) where h <= 12: return "साढ़े \(h)" + baje
            case (15, _) where h <= 12: return "सवा \(h)" + baje
            case (45, _) where h <= 12: return "पौने \(h % 12 + 1)" + baje
            default: return "\(h) बजकर \(m) मिनट"
            }
        }
    }

    /// ₹100, रु. 100, Rs 100 → 100 रुपये (1 रुपया).
    private static func spellMoney(_ text: String) -> String {
        let d = digit
        return replace("(?:₹|रु\\.?|Rs\\.?)\\s*(\(d)+(?:\\.\(d)+)?)", in: text) { g in
            ascii(g[1]) == "1" ? "1 रुपया" : g[1] + " रुपये"
        }
    }

    /// 50% → 50 प्रतिशत.
    private static func spellPercentages(_ text: String) -> String {
        let d = digit
        return replace("(\(d)+(?:\\.\(d)+)?)\\s*%", in: text) { g in g[1] + " प्रतिशत" }
    }

    // MARK: - Signs Supertonic cannot read

    /// ॥ is a full stop, and so is `|`, which OCR writes for । and Supertonic's
    /// cleanup deletes; ॐ is "om", ऋ and ॠ are said "ri" and "rī" in Hindi,
    /// ऍ and ॅ are the æ of English loans, which Hindi says as ऐ. ऽ only
    /// lengthens a vowel and ॰ only marks an abbreviation, so both go.
    private static let signs: [Unicode.Scalar: String] = [
        "\u{0965}": "। ", "|": "।", "\u{0950}": "ओम", "\u{090B}": "रि", "\u{0960}": "री",
        "\u{090D}": "ऐ", "\u{0945}": "\u{0948}", "\u{093D}": "", "\u{0970}": "",
    ]

    private static func replaceUnreadableSigns(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { signs[$0] != nil }) else { return text }
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if let spoken = signs[scalar] {
                out.append(contentsOf: spoken.unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out).replacingOccurrences(of: #"।(?:\s*।)+"#, with: "।", options: .regularExpression)
    }

    // MARK: - Helpers

    static func digitValue(_ s: Unicode.Scalar) -> Int? {
        if (0x30...0x39).contains(s.value) { return Int(s.value - 0x30) }
        if (0x0966...0x096F).contains(s.value) { return Int(s.value - 0x0966) }
        return nil
    }

    private static func ascii(_ digits: String) -> String {
        String(digits.unicodeScalars.compactMap { digitValue($0).map { Character(String($0)) } ?? (($0 == ".") ? "." : nil) })
    }

    private static func replace(_ pattern: String, in text: String, with transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let groups = (0..<m.numberOfRanges).map {
                m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0))
            }
            result = result.replacingCharacters(in: m.range, with: transform(groups)) as NSString
        }
        return result as String
    }
}
