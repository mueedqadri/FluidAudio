import Foundation
import XCTest

@testable import FluidAudio

final class KokoroAneManagerAssetSourceTests: XCTestCase {
    func testEnglishOOVG2PUsesManagersAssetSourceRoot() async throws {
        let localRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = KokoroAssetSource(
            repository: "owner/models",
            revision: "immutable-revision",
            localRoot: localRoot,
            allowsNetworkFallback: false
        )
        let manager = KokoroAneManager(assetSource: source)

        do {
            _ = try await manager.englishG2PPhonemes(for: "unlistedword")
            XCTFail("Expected the deliberately absent local G2P vocabulary to fail")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains(
                    localRoot.appendingPathComponent("g2p_vocab.json").path
                ),
                "Expected G2P lookup under the manager asset root, got: \(error)"
            )
        }
    }
}
