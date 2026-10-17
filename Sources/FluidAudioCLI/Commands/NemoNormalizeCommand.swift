import FluidAudio
import Foundation

/// Reads lines from standard input and prints NeMo's written-to-spoken
/// reading of each, for probing what the linked grammars say.
enum NemoNormalizeCommand {
    static func run(arguments: [String]) async {
        var language = NemoTextNormalizer.Language.english
        if let index = arguments.firstIndex(of: "--language"), index + 1 < arguments.count {
            guard let chosen = NemoTextNormalizer.Language(rawValue: arguments[index + 1]) else {
                print("nemo-normalize: unknown language \(arguments[index + 1])")
                exit(1)
            }
            language = chosen
        }
        while let line = readLine() {
            print(NemoTextNormalizer.normalize(line, language: language))
        }
    }
}
