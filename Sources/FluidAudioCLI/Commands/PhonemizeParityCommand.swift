#if os(macOS)
import FluidAudio
import Foundation

/// Dumps per-word English phonemizer output for a text corpus as JSONL so it
/// can be diffed against canonical Python Misaki (`scripts/parity/`).
///
/// Usage:
///   fluidaudiocli phonemize-parity --input corpus.txt --output swift.jsonl \
///     [--kokoro-dir ~/.cache/fluidaudio/Models/kokoro] \
///     [--vocab ~/.cache/fluidaudio/Models/kokoro-82m-coreml/ANE/vocab.json]
enum PhonemizeParityCommand {
    private struct Line: Codable {
        let i: Int
        let text: String
        let words: [EnglishFrontendHarness.WordPhonemes]

        enum CodingKeys: String, CodingKey {
            case i, text, words
        }
    }

    static func run(arguments: [String]) async {
        var input: String?
        var output: String?
        var kokoroDir = NSString(string: "~/.cache/fluidaudio/Models/kokoro").expandingTildeInPath
        var vocabFile = NSString(string: "~/.cache/fluidaudio/Models/kokoro-82m-coreml/ANE/vocab.json")
            .expandingTildeInPath

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--input" where index + 1 < arguments.count:
                input = arguments[index + 1]
                index += 2
            case "--output" where index + 1 < arguments.count:
                output = arguments[index + 1]
                index += 2
            case "--kokoro-dir" where index + 1 < arguments.count:
                kokoroDir = NSString(string: arguments[index + 1]).expandingTildeInPath
                index += 2
            case "--vocab" where index + 1 < arguments.count:
                vocabFile = NSString(string: arguments[index + 1]).expandingTildeInPath
                index += 2
            default:
                print("phonemize-parity: unknown argument \(arguments[index])")
                exit(1)
            }
        }

        guard let input, let output else {
            print("phonemize-parity: --input and --output are required")
            exit(1)
        }

        do {
            let harness = try await EnglishFrontendHarness.load(
                kokoroDirectory: URL(fileURLWithPath: kokoroDir),
                vocabFile: URL(fileURLWithPath: vocabFile)
            )

            let corpus = try String(contentsOfFile: input, encoding: .utf8)
            let encoder = JSONEncoder()
            var jsonl = Data()
            var lineNumber = 0
            var wordCount = 0

            for rawLine in corpus.components(separatedBy: .newlines) {
                lineNumber += 1
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }

                let words = try await harness.phonemizeWords(line)
                wordCount += words.count
                jsonl.append(try encoder.encode(Line(i: lineNumber, text: line, words: words)))
                jsonl.append(0x0A)
            }

            try jsonl.write(to: URL(fileURLWithPath: output))
            print("phonemize-parity: wrote \(wordCount) words to \(output)")
        } catch {
            print("phonemize-parity: failed: \(error)")
            exit(1)
        }
    }
}
#endif
