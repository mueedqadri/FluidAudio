import Foundation

extension SpokenText {

    /// `segments` with each expansion's words joined into one segment named for
    /// its written source, so a word timing covers `"$4.50"` rather than four
    /// spoken words the reader never sees. The joined phonemes keep their
    /// single-space separators, so the phoneme string the model receives is
    /// unchanged. Segments that cannot be located in `text` are returned as is.
    func mergingExpansions(
        _ segments: [KokoroAneEnglishPhonemizer.PhonemeSegment]
    ) -> [KokoroAneEnglishPhonemizer.PhonemeSegment] {
        guard !expansions.isEmpty else { return segments }
        let ns = text as NSString
        var cursor = 0
        var offsets: [Int] = []
        offsets.reserveCapacity(segments.count)
        for segment in segments {
            guard !segment.word.isEmpty else {
                offsets.append(cursor)
                continue
            }
            let found = ns.range(
                of: segment.word, options: [.caseInsensitive],
                range: NSRange(location: cursor, length: ns.length - cursor))
            guard found.location != NSNotFound else { return segments }
            offsets.append(found.location)
            cursor = found.location + found.length
        }

        var merged: [KokoroAneEnglishPhonemizer.PhonemeSegment] = []
        var index = 0
        while index < segments.count {
            guard let expansion = expansions.first(where: { $0.range.contains(offsets[index]) }) else {
                merged.append(segments[index])
                index += 1
                continue
            }
            var last = index
            while last + 1 < segments.count, expansion.range.contains(offsets[last + 1]) {
                last += 1
            }
            merged.append(
                .init(
                    word: expansion.source,
                    phonemes: segments[index...last].map(\.phonemes).joined(separator: " ")))
            index = last + 1
        }
        return merged
    }
}
