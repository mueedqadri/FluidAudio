import Foundation

/// Penn Treebank part-of-speech tagger for the Kokoro English frontend: a port
/// of NLTK's averaged perceptron (`averaged_perceptron_tagger_eng`), with its
/// weights converted by `Scripts/generate_english_pos_tagger.py`.
///
/// It stands in for `NLTagger`, whose lexical classes are all `OtherWord` on
/// iOS 27, and tags the same on every OS. Tagging is NLTK's `tag()`: a word
/// in the tag dictionary takes its tag, any other is scored from its own,
/// neighbouring and previous-tag features.
struct EnglishPOSTagger: Sendable {

    private static let logger = AppLogger(category: "EnglishPOSTagger")

    /// The bundled model, loaded on first use; nil if the resource is missing
    /// or malformed, which leaves heteronyms on their DEFAULT reading.
    static let shared: EnglishPOSTagger? = {
        guard let url = Bundle.module.url(forResource: "EnglishPOSTagger", withExtension: "bin"),
            let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        else {
            logger.error("EnglishPOSTagger.bin is missing from the bundle")
            return nil
        }
        guard let tagger = EnglishPOSTagger(data: data) else {
            logger.error("EnglishPOSTagger.bin is malformed")
            return nil
        }
        return tagger
    }()

    private let classes: [String]
    private let tagDictionary: [String: Int]
    private let scale: Double
    /// FNV-1a hashes of the feature strings, ascending.
    private let featureHashes: [UInt64]
    /// `featureStarts[i]..<featureStarts[i + 1]` indexes feature `i`'s weights.
    private let featureStarts: [Int32]
    private let weightClasses: [UInt8]
    private let weightValues: [Int16]

    private static let start = ["-START-", "-START2-"]
    private static let end = ["-END-", "-END2-"]

    init?(data: Data) {
        var reader = Reader(data: data)
        guard reader.readBytes(4) == Array("FAPT".utf8), reader.readUInt32() == 1,
            let scale = reader.readFloat64(),
            let classCount = reader.readUInt32()
        else { return nil }

        var classes: [String] = []
        for _ in 0..<classCount {
            guard let tag = reader.readShortString() else { return nil }
            classes.append(tag)
        }

        guard let wordCount = reader.readUInt32() else { return nil }
        var tagDictionary = [String: Int](minimumCapacity: Int(wordCount))
        for _ in 0..<wordCount {
            guard let word = reader.readShortString(), let tag = reader.readUInt8(), Int(tag) < classes.count
            else { return nil }
            tagDictionary[word] = Int(tag)
        }

        guard let featureCount = reader.readUInt32().map(Int.init),
            let hashes = reader.readArray(UInt64.self, count: featureCount),
            let counts = reader.readBytes(featureCount)
        else { return nil }
        var starts = [Int32](repeating: 0, count: featureCount + 1)
        for (index, count) in counts.enumerated() {
            starts[index + 1] = starts[index] + Int32(count)
        }
        let weightCount = Int(starts[featureCount])
        guard let weightClasses = reader.readBytes(weightCount),
            let weightValues = reader.readArray(Int16.self, count: weightCount),
            reader.isAtEnd,
            weightClasses.allSatisfy({ Int($0) < classes.count })
        else { return nil }

        self.classes = classes
        self.tagDictionary = tagDictionary
        self.scale = scale
        self.featureHashes = hashes
        self.featureStarts = starts
        self.weightClasses = weightClasses
        self.weightValues = weightValues
    }

    /// Penn tags for a sentence already split into Treebank tokens.
    func tag(_ words: [String]) -> [String] {
        let context = Self.start + words.map(Self.normalize) + Self.end
        var previous = Self.start[0]
        var previous2 = Self.start[1]
        var tags: [String] = []
        tags.reserveCapacity(words.count)
        for (index, word) in words.enumerated() {
            let tag =
                tagDictionary[word].map { classes[$0] }
                ?? predict(Self.features(index, word: word, context: context, previous: previous, previous2: previous2))
            tags.append(tag)
            previous2 = previous
            previous = tag
        }
        return tags
    }

    // MARK: - Perceptron

    /// NLTK `_get_features`: one feature string per template, joined by spaces.
    private static func features(
        _ index: Int, word: String, context: [String], previous: String, previous2: String
    ) -> [String] {
        let i = index + start.count
        return [
            "bias",
            "i suffix " + suffix3(word),
            "i pref1 " + (word.unicodeScalars.first.map { String($0) } ?? ""),
            "i-1 tag " + previous,
            "i-2 tag " + previous2,
            "i tag+i-2 tag " + previous + " " + previous2,
            "i word " + context[i],
            "i-1 tag+i word " + previous + " " + context[i],
            "i-1 word " + context[i - 1],
            "i-1 suffix " + suffix3(context[i - 1]),
            "i-2 word " + context[i - 2],
            "i+1 word " + context[i + 1],
            "i+1 suffix " + suffix3(context[i + 1]),
            "i+2 word " + context[i + 2],
        ]
    }

    /// NLTK `predict`: the highest score wins, ties going to the later tag name.
    private func predict(_ features: [String]) -> String {
        var scores = [Double](repeating: 0, count: classes.count)
        for feature in features {
            guard let row = featureRow(Self.fnv1a64(feature)) else { continue }
            for weight in Int(featureStarts[row])..<Int(featureStarts[row + 1]) {
                scores[Int(weightClasses[weight])] += Double(weightValues[weight]) * scale
            }
        }
        var best = 0
        for candidate in classes.indices.dropFirst()
        where scores[candidate] > scores[best]
            || (scores[candidate] == scores[best] && classes[candidate] > classes[best])
        {
            best = candidate
        }
        return classes[best]
    }

    private func featureRow(_ hash: UInt64) -> Int? {
        var low = 0
        var high = featureHashes.count
        while low < high {
            let mid = (low + high) / 2
            if featureHashes[mid] < hash {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low < featureHashes.count && featureHashes[low] == hash ? low : nil
    }

    /// NLTK `normalize`: hyphenated words, years and numbers share one token each.
    private static func normalize(_ word: String) -> String {
        let scalars = word.unicodeScalars
        if scalars.contains("-"), scalars.first != "-" { return "!HYPHEN" }
        if scalars.count == 4, scalars.allSatisfy(isDigit) { return "!YEAR" }
        if let first = scalars.first, isDigit(first) { return "!DIGITS" }
        return word.lowercased()
    }

    /// Python's `str.isdigit` for one code point.
    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.numericType == .decimal || scalar.properties.numericType == .digit
    }

    /// Python's `word[-3:]`, by code point.
    private static func suffix3(_ word: String) -> String {
        String(String.UnicodeScalarView(word.unicodeScalars.suffix(3)))
    }

    private static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    // MARK: - Binary reader

    private struct Reader {
        let data: Data
        var offset = 0

        var isAtEnd: Bool { offset == data.count }

        mutating func readBytes(_ count: Int) -> [UInt8]? {
            guard count >= 0, offset + count <= data.count else { return nil }
            let start = data.startIndex + offset
            offset += count
            return [UInt8](data[start..<start + count])
        }

        mutating func readArray<T: FixedWidthInteger>(_ type: T.Type, count: Int) -> [T]? {
            let size = MemoryLayout<T>.size
            guard count >= 0, offset + count * size <= data.count else { return nil }
            let start = offset
            offset += count * size
            return data.withUnsafeBytes { raw in
                (0..<count).map { T(littleEndian: raw.loadUnaligned(fromByteOffset: start + $0 * size, as: T.self)) }
            }
        }

        mutating func readUInt8() -> UInt8? { readBytes(1)?.first }

        mutating func readUInt32() -> UInt32? { readArray(UInt32.self, count: 1)?.first }

        mutating func readFloat64() -> Double? {
            readArray(UInt64.self, count: 1)?.first.map(Double.init(bitPattern:))
        }

        mutating func readShortString() -> String? {
            guard let length = readUInt8(), let bytes = readBytes(Int(length)) else { return nil }
            return String(bytes: bytes, encoding: .utf8)
        }
    }
}

// MARK: - Treebank tokens

extension EnglishPOSTagger {

    /// One Penn tag per phonemizer token (`splitWordTokens`), nil for tokens
    /// the tagger has no word for. The tokens are re-cut the way the model was
    /// trained: clitics split off (`do` `n't`, `Gatsby` `'s`) and quotes
    /// turned into Treebank's opening and closing marks. A token takes the tag
    /// of its first piece.
    func tags(
        forWordTokens tokens: [(token: String, range: Range<String.Index>)],
        in text: String
    ) -> [String?] {
        var words: [String] = []
        var heads = [Int?](repeating: nil, count: tokens.count)
        for (index, entry) in tokens.enumerated() {
            let pieces = Self.treebankPieces(entry.token, range: entry.range, in: text)
            guard !pieces.isEmpty else { continue }
            heads[index] = words.count
            words.append(contentsOf: pieces)
        }
        let tagged = tag(words)
        return heads.map { $0.map { tagged[$0] } }
    }

    private static let clitics = ["n't", "'s", "'re", "'ve", "'ll", "'d", "'m"]

    private static func treebankPieces(_ token: String, range: Range<String.Index>, in text: String) -> [String] {
        if token.count == 1, let ch = token.first, !ch.isLetter, !ch.isNumber {
            switch ch {
            case "\u{201C}", "\u{2018}": return ["``"]
            case "\u{201D}", "\u{2019}": return ["''"]
            case "\"", "'":
                let opens =
                    range.lowerBound == text.startIndex || text[text.index(before: range.lowerBound)].isWhitespace
                return [opens ? "``" : "''"]
            case "\u{2026}": return ["..."]
            case "\u{2014}", "\u{2013}": return ["--"]
            default: return [token]
            }
        }
        let lowered = token.lowercased()
        guard !token.hasPrefix("'"),
            let clitic = clitics.first(where: { lowered.hasSuffix($0) && lowered.count > $0.count })
        else { return [token] }
        let cut = token.index(token.endIndex, offsetBy: -clitic.count)
        return [String(token[..<cut]), String(token[cut...])]
    }
}
