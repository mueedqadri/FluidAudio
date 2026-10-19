import Foundation

/// Chemical formulas read letter by letter with their counts (`H₂O`, `H2O`
/// → "H two O", `NaCl` → "N A C L"), and superscript powers read as powers
/// (`mc²` → "m c squared", `10⁻³` → "ten to the minus three"). A unit's power
/// after a number (`3 m²`) is left for NeMo, which reads "square meters".
enum EnglishFormulas {

    /// `text` with its formulas and powers in words.
    static func spell(_ text: String) -> String {
        guard text.contains(where: { $0.isUppercase || superscripts[$0] != nil || subscripts[$0] != nil })
        else { return text }
        var result = replace(formulaRegex, in: text) { groups in formula(groups[1]) }
        result = replace(powerRegex, in: result) { groups in
            guard let exponent = number(groups[4], digits: superscripts) else { return nil }
            let coefficient = groups[1]
            let isNumberBase = groups[2].isEmpty
            let base = isNumberBase ? groups[3] : groups[2]
            if !isNumberBase, coefficient.contains(where: \.isNumber), unitBases.contains(base) { return nil }
            let spokenBase = isNumberBase
                ? EnglishTextNormalizer.normalize(base)
                : base.map(String.init).joined(separator: " ")
            // A coefficient reads as its number (`4AC²` → "four A C squared").
            let spokenCoefficient = coefficient.isEmpty
                ? "" : EnglishTextNormalizer.normalize(coefficient.trimmingCharacters(in: .whitespaces)) + " "
            let negative = groups[4].hasPrefix("⁻")
            // Nobody writes a power of one; a raised 1 is an index (`L¹` → "L one").
            let spokenPower = exponent == 1 && !negative ? "one" : power(exponent, negative: negative)
            // A letter glued after the power starts the next word (`x²a`).
            return spokenCoefficient + spokenBase + " " + spokenPower + (groups[5].isEmpty ? "" : " ")
        }
        result = replace(subscriptVariableRegex, in: result) { groups in
            number(groups[2], digits: subscripts).map { "\(groups[1]) \(EnglishTextNormalizer.normalize(String($0)))" }
        }
        return result
    }

    // MARK: - Formulas

    /// A run of element symbols with counts of one or two digits (`Fe2O3`, `NaCl`,
    /// `H₂O`), at least two symbols, so serials (`CS581676`) stay codes; checked
    /// against the periodic table in ``formula(_:)``.
    private static let formulaRegex = regex(
        #"(?<![A-Za-z0-9])((?:[A-Z][a-z]?[0-9₀-₉]{0,2}){2,})(?![A-Za-z0-9])"#)

    /// The formula's reading, or `nil` when it is not one: every part must be an
    /// element, and it must have a count or a two-letter symbol, so all-caps
    /// words that spell symbols (`NO`, `SON`, `CHOP`) stay words. Without a
    /// count it must end in a nonmetal, as compounds are written (`HCl`, `GaAs`),
    /// so names that end in a metal (`HeLa`, `SARS-CoV-2`) stay words.
    private static func formula(_ token: String) -> String? {
        let ns = token as NSString
        let parts = symbolRegex.matches(in: token, range: NSRange(location: 0, length: ns.length)).map {
            (symbol: ns.substring(with: $0.range(at: 1)), count: ns.substring(with: $0.range(at: 2)))
        }
        let hasCount = parts.contains { !$0.count.isEmpty }
        guard parts.allSatisfy({ elements.contains($0.symbol) }),
            hasCount || token.contains(where: \.isLowercase),
            hasCount || parts.last.map({ nonmetals.contains($0.symbol) }) == true
        else { return nil }
        return parts.map { part in
            let letters = part.symbol.uppercased().map(String.init).joined(separator: " ")
            let count = part.count.map { subscripts[$0].map(String.init) ?? String($0) }.joined()
            return count.isEmpty ? letters : "\(letters) \(EnglishTextNormalizer.normalize(count))"
        }.joined(separator: " ")
    }

    private static let symbolRegex = regex(#"([A-Z][a-z]?)([0-9₀-₉]*)"#)

    private static let elements: Set<String> = [
        "H", "He", "Li", "Be", "B", "C", "N", "O", "F", "Ne", "Na", "Mg", "Al", "Si", "P", "S", "Cl", "Ar",
        "K", "Ca", "Sc", "Ti", "V", "Cr", "Mn", "Fe", "Co", "Ni", "Cu", "Zn", "Ga", "Ge", "As", "Se", "Br", "Kr",
        "Rb", "Sr", "Y", "Zr", "Nb", "Mo", "Tc", "Ru", "Rh", "Pd", "Ag", "Cd", "In", "Sn", "Sb", "Te", "I", "Xe",
        "Cs", "Ba", "La", "Ce", "Pr", "Nd", "Pm", "Sm", "Eu", "Gd", "Tb", "Dy", "Ho", "Er", "Tm", "Yb", "Lu",
        "Hf", "Ta", "W", "Re", "Os", "Ir", "Pt", "Au", "Hg", "Tl", "Pb", "Bi", "Po", "At", "Rn", "Fr", "Ra",
        "Ac", "Th", "Pa", "U", "Np", "Pu", "Am", "Cm", "Bk", "Cf", "Es", "Fm", "Md", "No", "Lr", "Rf", "Db",
        "Sg", "Bh", "Hs", "Mt", "Ds", "Rg", "Cn", "Nh", "Fl", "Mc", "Lv", "Ts", "Og",
    ]

    /// Nonmetals and metalloids, which end a compound's formula.
    private static let nonmetals: Set<String> = [
        "H", "B", "C", "N", "O", "F", "Si", "P", "S", "Cl", "Ge", "As", "Se", "Br", "Sb", "Te", "I",
    ]

    // MARK: - Powers

    /// A base and a superscript exponent: one or two letters (`x²`, `mc²`), a
    /// closing bracket (`(a+b)²`) or a number (`10⁻³`). Group 1 is a number
    /// before the base, a coefficient (`4AC²`, `3t²`) or a unit's count (`3 m²`,
    /// left for NeMo); groups 2 and 3 are a letter or a number base; group 5 a
    /// letter glued after the power.
    private static let powerRegex = regex(
        #"(?<![A-Za-z0-9.])((?:[0-9]+\s?)?)(?:(?<![A-Za-z])([A-Za-z]{1,2}|\))|(?<![A-Za-z0-9.])([0-9]+))(⁻?[⁰¹²³⁴⁵⁶⁷⁸⁹]+)(?=([A-Za-z]?))"#)

    /// Units NeMo reads with their power after a number ("three square meters").
    private static let unitBases: Set<String> = ["m", "cm", "mm", "km", "ft", "in", "mi", "yd"]

    /// "squared", "cubed", "to the power of four", "to the minus three".
    private static func power(_ exponent: Int, negative: Bool) -> String {
        let number = EnglishTextNormalizer.normalize(String(exponent))
        if negative { return "to the minus \(number)" }
        switch exponent {
        case 2: return "squared"
        case 3: return "cubed"
        default: return "to the power of \(number)"
        }
    }

    /// A subscript after a variable or a word (`x₁` → "x one", `log₁₀` → "log ten").
    private static let subscriptVariableRegex = regex(#"(?<![A-Za-z])([A-Za-z]+)([₀-₉]+)"#)

    private static let superscripts: [Character: Character] = [
        "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9",
    ]
    private static let subscripts: [Character: Character] = [
        "₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4", "₅": "5", "₆": "6", "₇": "7", "₈": "8", "₉": "9",
    ]

    private static func number(_ text: String, digits: [Character: Character]) -> Int? {
        Int(String(text.compactMap { digits[$0] }))
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    /// `transform` gets the match then its groups; `nil` leaves the match.
    private static func replace(
        _ regex: NSRegularExpression, in text: String, transform: ([String]) -> String?
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
            if let replacement = transform(groups) {
                mutable.replaceCharacters(in: match.range, with: replacement)
            }
        }
        return mutable as String
    }
}
