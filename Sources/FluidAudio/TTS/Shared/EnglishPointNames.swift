import Foundation

/// Point and line names in geometry read letter by letter (`AB` → "A B",
/// `CAB` → "C A B", `AC.AD` → "A C times A D") where the lexicon has a word
/// for them ("ab", "cab"), and a primed letter reads its mark (`A′` → "A
/// prime", `f′′` → "f double prime").
///
/// A run of two or three capitals is a name in a sentence about a figure:
/// right after a figure word (`triangle ABC`, `draw AB`), on a side of `=`,
/// after "equal to" or "greater than", after "let" with "be" to follow, or
/// listed beside another name; or anywhere in a sentence with a figure word
/// and a name that cannot be a word (`CD`, a lone `E`). Names that are common
/// words (`OF`, `BE`, `HE`) take only the first cues, a name glued to a number
/// is a date or a code (`300 BC`), and a sentence in capitals is a heading,
/// read as words.
enum EnglishPointNames {

    /// `text` with its primed letters and point names spelled.
    static func spell(_ text: String) -> String {
        guard text.contains(where: { primeMarks[$0] != nil }) || text.range(of: "[A-Z]{2}", options: .regularExpression) != nil
        else { return text }
        return names(in: primed(text))
    }

    /// Most words of `words` are in capitals, as in a heading. Only words count:
    /// four letters or more, or a common short one, so names do not.
    static func isCapitalsPassage(_ words: [String]) -> Bool {
        let lettered = words.compactMap { word -> String? in
            let core = word.trimmingCharacters(in: .letters.inverted)
            guard core.allSatisfy(\.isLetter), core.count >= 4 || commonWords.contains(core.uppercased()) else { return nil }
            return core
        }
        let capitals = lettered.filter { !$0.contains(where: \.isLowercase) }
        return lettered.count >= 2 && Double(capitals.count) >= 0.6 * Double(lettered.count)
    }

    // MARK: - Primes

    private static let primeMarks: [Character: Int] = ["′": 1, "″": 2, "‴": 3]

    /// Up to three capitals each with optional primes, or one lower-case letter
    /// with primes, standing alone (`A′`, `A′B′C′`, `AB′R`, `f′′(x)`); a prime
    /// before a contraction's letter is an apostrophe (`IT′S`).
    private static let primedRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9′″‴])(?:(?:[A-Z][′″‴]*){1,3}|[a-z][′″‴]+)(?![A-Za-z0-9′″‴])"#)

    private static func primed(_ text: String) -> String {
        guard text.contains(where: { primeMarks[$0] != nil }) else { return text }
        let ns = text as NSString
        let result = NSMutableString(string: text)
        for match in primedRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let token = ns.substring(with: match.range)
            guard token.contains(where: { primeMarks[$0] != nil }),
                token.range(of: #"[′″‴][STDM]$"#, options: .regularExpression) == nil
            else { continue }
            var spoken: [String] = []
            var marks = 0
            func flush() -> Bool {
                guard marks > 0 else { return true }
                guard let name = [1: "prime", 2: "double prime", 3: "triple prime"][marks] else { return false }
                spoken.append(name)
                marks = 0
                return true
            }
            var readable = true
            for character in token {
                if let count = primeMarks[character] {
                    marks += count
                } else {
                    readable = readable && flush()
                    spoken.append(String(character))
                }
            }
            readable = readable && flush()
            if readable { result.replaceCharacters(in: match.range, with: spoken.joined(separator: " ")) }
        }
        return result as String
    }

    // MARK: - Names

    private static let tokenRegex = try! NSRegularExpression(pattern: #"\S+"#)
    private static let nameRegex = try! NSRegularExpression(pattern: #"^[(\[]?([A-Z]{2,3})[,.;:)\]]?$"#)
    private static let productRegex = try! NSRegularExpression(
        pattern: #"^[(\[]?([A-Z]{2,3})\.([A-Z]{2,3})[,.;:)\]]?$"#)
    private static let loneLetterRegex = try! NSRegularExpression(pattern: #"^[(\[]?[B-HJ-Z][,.;:)\]]?$"#)

    private static func names(in text: String) -> String {
        let ns = text as NSString
        let ranges = tokenRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        let words = ranges.map { ns.substring(with: $0) }
        guard !isCapitalsPassage(words) else { return text }
        let names = words.map { firstGroup(nameRegex, in: $0) }
        let products = words.map { matches(productRegex, $0) }
        guard names.contains(where: { $0 != nil }) || products.contains(true) else { return text }
        // A word's letters after any `Sol.—` lead-in; a capitalized one is a
        // figure word only where a clause opens (`Join AB`, not `Cone EJ`).
        let parts = words.map { $0.components(separatedBy: "—").last ?? $0 }
        let lower = parts.map { $0.lowercased().filter(\.isLetter) }
        func isPlainWord(_ index: Int) -> Bool {
            index == 0 || parts[index].first?.isUppercase != true || words[index].contains("—")
                || words[index - 1].hasSuffix(".") || words[index - 1].hasSuffix(":")
        }

        var cued: Set<Int> = []
        for index in words.indices where names[index] != nil {
            if index > 0, figureLeads.contains(lower[index - 1]), isPlainWord(index - 1) { cued.insert(index) }
            if index > 1, comparisons.contains("\(lower[index - 2]) \(lower[index - 1])") { cued.insert(index) }
            if index > 0, lower[index - 1] == "let",
                lower[(index + 1)..<min(index + 5, words.count)].contains(where: { $0 == "be" || $0 == "is" })
            {
                cued.insert(index)
            }
            if index + 2 < words.count, operators.contains(words[index + 1]), names[index + 2] != nil {
                cued.formUnion([index, index + 2])
            }
            if index + 4 < words.count, lower[(index + 1)...(index + 3)] == ["is", "equal", "to"], names[index + 4] != nil {
                cued.formUnion([index, index + 4])
            }
        }
        let unwordable =
            names.contains { $0.map { !$0.contains(where: "AEIOUY".contains) } ?? false }
            || words.indices.dropFirst().contains { matches(loneLetterRegex, words[$0]) }
        let isFigure =
            !cued.isEmpty || products.contains(true)
            || (unwordable && lower.indices.contains { figureWords.contains(lower[$0]) && isPlainWord($0) })
        guard isFigure else { return text }
        // A name listed beside another (`AB, BE`, `AO, OB, DH, HE;`).
        for index in words.indices where names[index] != nil {
            if index + 1 < words.count, names[index + 1] != nil, words[index].hasSuffix(",") { cued.insert(index) }
            if index > 0, names[index - 1] != nil, words[index - 1].hasSuffix(",") { cued.insert(index) }
        }

        let result = NSMutableString(string: text)
        for index in words.indices.reversed() {
            let word = words[index]
            if products[index], let factors = productFactors(word) {
                let spoken = "\(letters(factors.0)) times \(letters(factors.1))"
                result.replaceCharacters(
                    in: ranges[index], with: word.replacingOccurrences(of: "\(factors.0).\(factors.1)", with: spoken))
                continue
            }
            guard let name = names[index], name.contains(where: "AEIOUY".contains),
                cued.contains(index) || !commonWords.contains(name)
            else { continue }
            if index > 0, words[index - 1].contains(where: { $0.isASCII && $0.isNumber }) { continue }
            if index + 1 < words.count, words[index + 1].first.map { $0.isASCII && $0.isNumber } == true { continue }
            result.replaceCharacters(in: ranges[index], with: word.replacingOccurrences(of: name, with: letters(name)))
        }
        return result as String
    }

    private static func letters(_ name: String) -> String {
        name.map(String.init).joined(separator: " ")
    }

    private static func productFactors(_ word: String) -> (String, String)? {
        let ns = word as NSString
        guard let match = productRegex.firstMatch(in: word, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (ns.substring(with: match.range(at: 1)), ns.substring(with: match.range(at: 2)))
    }

    private static func firstGroup(_ regex: NSRegularExpression, in word: String) -> String? {
        let ns = word as NSString
        guard let match = regex.firstMatch(in: word, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private static func matches(_ regex: NSRegularExpression, _ word: String) -> Bool {
        regex.firstMatch(in: word, range: NSRange(location: 0, length: (word as NSString).length)) != nil
    }

    private static let operators: Set<String> = ["=", "+", "−", "×", ":", "·"]

    private static let comparisons: Set<String> = [
        "equal to", "parallel to", "perpendicular to", "greater than", "less than",
    ]

    /// Words a name follows (`triangle ABC`, `join AB`).
    private static let figureLeads: Set<String> = [
        "angle", "angles", "triangle", "triangles", "line", "lines", "point", "points", "side", "sides",
        "chord", "chords", "diameter", "diameters", "radius", "radii", "sector", "sectors", "arc", "arcs",
        "segment", "segments", "square", "squares", "rectangle", "rectangles", "parallelogram", "parallelograms",
        "figure", "figures", "circle", "circles", "semicircle", "base", "bases", "perpendicular", "perpendiculars",
        "tangent", "tangents", "draw", "drawn", "join", "joined", "produce", "produced", "bisect", "bisects",
        "bisected", "parallel", "parallels", "polygon", "polygons", "quadrilateral", "pentagon", "hexagon",
        "plane", "planes", "describe", "erect", "intersecting",
    ]

    /// Words that make a sentence with an unwordable name about a figure.
    private static let figureWords: Set<String> = [
        "triangle", "triangles", "angle", "angles", "rectangle", "rectangles", "parallelogram", "parallelograms",
        "perpendicular", "perpendiculars", "bisect", "bisects", "bisected", "diameter", "diameters", "chord",
        "chords", "circle", "circles", "semicircle", "radius", "radii", "tangent", "tangents", "quadrilateral",
        "pentagon", "hexagon", "polygon", "polygons", "proportional", "proportionals", "parallel", "parallels",
        "equal", "equals", "square", "squares", "greater", "less", "sum", "produce", "produced", "describe",
        "intersect", "intersects", "plane", "cut", "meet", "ratio",
    ]

    /// Capitals that are common words, spelled only on a cue (`OF = OG`, `draw BE`).
    private static let commonWords: Set<String> = [
        "OF", "OR", "ON", "TO", "IN", "IS", "IT", "BY", "AT", "AS", "AN", "BE", "DO", "GO", "HE", "ME", "MY",
        "NO", "SO", "UP", "US", "WE", "IF", "AM", "OK", "AND", "THE", "NOT", "YOU", "ARE", "BUT", "FOR", "ALL",
        "ANY", "CAN", "HAS", "HAD", "HIS", "HER", "ITS", "MAY", "GET", "PUT", "NOW", "OUT", "OUR", "WHO", "WHY",
        "HOW", "SHE", "WAS", "ONE", "TWO", "SIX", "TEN", "YES", "NOR", "OFF", "SET", "USE",
    ]
}
