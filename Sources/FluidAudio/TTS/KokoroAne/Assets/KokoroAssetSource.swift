import Foundation

public enum KokoroAssetSourceError: Error, LocalizedError {
    case missingLocalAsset(String)

    public var errorDescription: String? {
        switch self {
        case .missingLocalAsset(let path):
            return "The configured Kokoro asset source is missing '\(path)'."
        }
    }
}

/// Describes an application-owned Kokoro asset installation.
///
/// FluidAudio normally resolves Kokoro files from its shared cache and the
/// mutable upstream Hugging Face `main` branch. Apps that manage model assets
/// themselves can instead provide one immutable repository revision and a
/// local root containing the same relative paths (`ANE/...`,
/// `G2PEncoder.mlmodelc/...`, and so on).
///
/// When `allowsNetworkFallback` is false, a missing local asset is reported to
/// the caller instead of silently reaching a different host during synthesis.
public struct KokoroAssetSource: Sendable, Equatable {
    public let repository: String
    public let revision: String
    public let remoteRootPath: String
    public let localRoot: URL
    public let allowsNetworkFallback: Bool

    public init(
        repository: String,
        revision: String,
        remoteRootPath: String = "",
        localRoot: URL,
        allowsNetworkFallback: Bool = false
    ) {
        self.repository = repository
        self.revision = revision
        self.remoteRootPath = remoteRootPath
        self.localRoot = localRoot
        self.allowsNetworkFallback = allowsNetworkFallback
    }

    func localURL(for relativePath: String) -> URL {
        localRoot.appendingPathComponent(relativePath)
    }

    func remoteURL(for relativePath: String) throws -> URL {
        let rootedPath = remoteRootPath.isEmpty
            ? relativePath
            : "\(remoteRootPath)/\(relativePath)"
        return try ModelRegistry.resolveModel(
            repository,
            rootedPath,
            revision: revision
        )
    }
}
