import CoreML
import Foundation
import OSLog

struct KokoroAneTraceContext: Sendable {
    let id: String
    let pieceIndex: Int
    let pieceCount: Int
    let phonemeLength: Int

    var pieceLabel: String { "\(pieceIndex + 1)/\(pieceCount)" }
}

enum KokoroAneDiagnostics {
    private static let logger = Logger(
        subsystem: "com.fluidinference",
        category: "KokoroAneMemoryTrace")

    static func log(traceID: String?, event: @autoclosure () -> String) {
        guard let traceID else { return }
        let event = event()
        let message = "KOKORO_TRACE trace=\(traceID) \(event) \(memoryFields())"
        logger.notice("\(message, privacy: .public)")
    }

    static func log(context: KokoroAneTraceContext?, event: @autoclosure () -> String) {
        guard let context else { return }
        let event = event()
        log(
            traceID: context.id,
            event: "piece=\(context.pieceLabel) phonemes=\(context.phonemeLength) \(event)")
    }

    static func tensorShapes(_ arrays: [String: MLMultiArray]) -> String {
        arrays.keys.sorted().map { key in
            let shape = arrays[key]?.shape.map(\.intValue) ?? []
            return "\(key):\(shape)"
        }.joined(separator: ",")
    }

    static func outputShapes(_ provider: MLFeatureProvider) -> String {
        provider.featureNames.sorted().compactMap { key in
            guard let array = provider.featureValue(for: key)?.multiArrayValue else { return nil }
            return "\(key):\(array.shape.map(\.intValue))"
        }.joined(separator: ",")
    }

    private static func memoryFields() -> String {
        let resident = SystemInfo.currentResidentMemoryBytes().map(String.init) ?? "unavailable"
        let footprint = SystemInfo.currentPhysicalFootprintBytes().map(String.init) ?? "unavailable"
        return "residentBytes=\(resident) physicalFootprintBytes=\(footprint)"
    }
}
