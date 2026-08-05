@preconcurrency import CoreML
import Foundation
import os

/// Opt-in diagnostics for two questions the field logs cannot answer:
/// *where does CoreML actually plan each model* (the configured compute units
/// are a request, not a fact), and *at what QoS does each prediction submit*.
///
/// Motivating case: on an iPhone, backgrounded Supertonic predictions are
/// refused at the ANE kernel with kIOReturnNotPermitted while Kokoro keeps
/// synthesizing with the screen locked — and the two pipelines are identical
/// in code. Whatever differs is only visible in the compute plan or in the
/// request QoS, so log both, symmetrically, in both pipelines.
///
/// Off by default. Enable with the `FLUIDAUDIO_COMPUTE_PLAN=1` environment
/// variable, or the `fluidaudio.computePlanLogging` UserDefaults key (pass
/// `-fluidaudio.computePlanLogging YES` as a launch argument).
enum ComputePlanLogger {

    private static let logger = AppLogger(category: "ComputePlan")

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["FLUIDAUDIO_COMPUTE_PLAN"] == "1"
            || UserDefaults.standard.bool(forKey: "fluidaudio.computePlanLogging")
    }

    // MARK: - Static placement (per model, at load)

    /// Fire-and-forget per-device op tally for one compiled model, e.g.
    /// `[plan] DurationPredictor.mlmodelc: ane=118 cpu=9`. Loading a compute
    /// plan costs about as much as loading the model, which is why this is
    /// opt-in and off the caller's path.
    static func logPlacement(
        modelURL: URL, configuration: MLModelConfiguration, label: String
    ) {
        guard isEnabled else { return }
        guard #available(macOS 14.4, iOS 17.4, *) else {
            logger.info("[plan] \(label): MLComputePlan needs macOS 14.4 / iOS 17.4")
            return
        }
        Task.detached(priority: .utility) {
            do {
                let plan = try await MLComputePlan.load(
                    contentsOf: modelURL, configuration: configuration)
                guard case .program(let program) = plan.modelStructure else {
                    logger.info("[plan] \(label): not an ML Program")
                    return
                }
                var counts: [String: Int] = [:]
                for function in program.functions.values {
                    tally(block: function.block, plan: plan, into: &counts)
                }
                let summary = counts.sorted { $0.value > $1.value }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " ")
                logger.info("[plan] \(label): opset=\(milOpset(of: modelURL)) \(summary)")
            } catch {
                logger.warning("[plan] \(label): compute plan failed to load: \(error)")
            }
        }
    }

    @available(macOS 14.4, iOS 17.4, *)
    private static func tally(
        block: MLModelStructure.Program.Block,
        plan: MLComputePlan,
        into counts: inout [String: Int]
    ) {
        for operation in block.operations {
            if let usage = plan.deviceUsage(for: operation) {
                counts[name(of: usage.preferred), default: 0] += 1
            } else {
                counts["unplaced", default: 0] += 1
            }
            for nested in operation.blocks {
                tally(block: nested, plan: plan, into: &counts)
            }
        }
    }

    /// The opset stamped into the compiled program (`main<ios17>` vs
    /// `main<ios18>`), read off the installed bytes — so the log proves what
    /// the device is actually running, not what a manifest intended.
    private static func milOpset(of modelURL: URL) -> String {
        let mil = modelURL.appendingPathComponent("model.mil")
        guard let handle = try? FileHandle(forReadingFrom: mil),
            let data = try? handle.read(upToCount: 600),
            let head = String(data: data, encoding: .utf8)
                ?? String(
                    data: data, encoding: .ascii)
        else { return "unreadable" }
        guard let start = head.range(of: "main<"),
            let end = head.range(of: ">", range: start.upperBound..<head.endIndex)
        else { return "unknown" }
        return String(head[start.upperBound..<end.lowerBound])
    }

    @available(macOS 14.4, iOS 17.4, *)
    private static func name(of device: MLComputeDevice) -> String {
        switch device {
        case .cpu: return "cpu"
        case .gpu: return "gpu"
        case .neuralEngine: return "ane"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Prediction QoS (per stage, on change)

    private static let lastQoS = OSAllocatedUnfairLock<[String: qos_class_t]>(initialState: [:])

    /// Log the QoS class a stage is about to predict at — but only when it
    /// differs from that stage's last logged value, so steady state is silent
    /// and a background demotion shows up as one line right before the
    /// prediction it affects.
    static func notePredictionQoS(stage: String) {
        guard isEnabled else { return }
        let qos = qos_class_self()
        let shouldLog = lastQoS.withLock { table -> Bool in
            if table[stage] == qos { return false }
            table[stage] = qos
            return true
        }
        if shouldLog {
            logger.info("[qos] \(stage): predicting at \(name(of: qos))")
        }
    }

    private static func name(of qos: qos_class_t) -> String {
        switch qos {
        case QOS_CLASS_USER_INTERACTIVE: return "userInteractive"
        case QOS_CLASS_USER_INITIATED: return "userInitiated"
        case QOS_CLASS_DEFAULT: return "default"
        case QOS_CLASS_UTILITY: return "utility"
        case QOS_CLASS_BACKGROUND: return "background"
        default: return "unspecified(\(qos.rawValue))"
        }
    }
}
