import Foundation

/// Greek letters English uses as symbols, read by name (`α` → "alpha", `ΔG` →
/// "delta G", `β₁` → "beta one", `2σ` → "two sigma", `H→γγ` → "gamma gamma").
/// A run of three or more Greek letters is a Greek word and is left as it is.
enum EnglishGreekLetters {

    /// `text` with its Greek symbols named.
    static func spell(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { names[Character($0)] != nil }) else { return text }
        let ns = text as NSString
        let result = NSMutableString(string: text)
        for match in runRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let run = ns.substring(with: match.range(at: 2))
            guard run.count < 3, run.allSatisfy({ names[$0] != nil }) else { continue }
            var spoken = run.compactMap { names[$0] }.joined(separator: " ")
            // A number glued before the letter is its count (`2σ` → "two sigma").
            if match.range(at: 1).location != NSNotFound {
                spoken = EnglishTextNormalizer.normalize(ns.substring(with: match.range(at: 1))) + " " + spoken
            }
            // A name gets its own word beside a letter or digit it was glued to.
            if match.range.location > 0, isWordCharacter(ns.character(at: match.range.location - 1)) {
                spoken = " " + spoken
            }
            if NSMaxRange(match.range) < ns.length, isWordCharacter(ns.character(at: NSMaxRange(match.range))) {
                spoken += " "
            }
            result.replaceCharacters(in: match.range, with: spoken)
        }
        return result as String
    }

    /// One Greek letter, for the power and subscript rules' bases.
    static let letterPattern = "[\\u0391-\\u03A9\\u03B1-\\u03C9\\u03D1\\u03D5\\u03D6\\u03F1\\u03F5\\u03C2]"

    /// A number glued before (group 1), then a run of Greek script with its accents (group 2).
    private static let runRegex = try! NSRegularExpression(pattern: #"(?<![0-9.])([0-9]+)?([\p{Greek}\p{Mn}∆]+)"#)

    private static func isWordCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) && names[Character(scalar)] == nil
    }

    private static let names: [Character: String] = {
        let pairs: [(String, String, String)] = [
            ("Α", "α", "alpha"), ("Β", "β", "beta"), ("Γ", "γ", "gamma"), ("Δ", "δ", "delta"),
            ("Ε", "ε", "epsilon"), ("Ζ", "ζ", "zeta"), ("Η", "η", "eta"), ("Θ", "θ", "theta"),
            ("Ι", "ι", "iota"), ("Κ", "κ", "kappa"), ("Λ", "λ", "lambda"), ("Μ", "μ", "mu"),
            ("Ν", "ν", "nu"), ("Ξ", "ξ", "xi"), ("Ο", "ο", "omicron"), ("Π", "π", "pi"),
            ("Ρ", "ρ", "rho"), ("Σ", "σ", "sigma"), ("Τ", "τ", "tau"), ("Υ", "υ", "upsilon"),
            ("Φ", "φ", "phi"), ("Χ", "χ", "chi"), ("Ψ", "ψ", "psi"), ("Ω", "ω", "omega"),
        ]
        var names: [Character: String] = [:]
        for (upper, lower, name) in pairs {
            names[Character(upper)] = name
            names[Character(lower)] = name
        }
        // Variant forms mathematics uses, and the increment sign papers set for a capital delta.
        for (variant, name) in [("ϑ", "theta"), ("ϕ", "phi"), ("ϖ", "pi"), ("ϱ", "rho"), ("ϵ", "epsilon"), ("ς", "sigma"), ("∆", "delta")] {
            names[Character(variant)] = name
        }
        return names
    }()
}
