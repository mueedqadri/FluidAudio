import XCTest

@testable import FluidAudio

final class KokoroAssetSourceTests: XCTestCase {
    func testBuildsImmutableRevisionURLUnderRemoteRoot() throws {
        let source = KokoroAssetSource(
            repository: "owner/models",
            revision: "0123456789abcdef",
            remoteRootPath: "fluidaudio-kokoro",
            localRoot: URL(fileURLWithPath: "/tmp/kokoro")
        )

        XCTAssertEqual(
            try source.remoteURL(for: "ANE/vocab.json").absoluteString,
            "https://huggingface.co/owner/models/resolve/0123456789abcdef/fluidaudio-kokoro/ANE/vocab.json"
        )
    }

    func testBuildsExpectedLocalURL() {
        let source = KokoroAssetSource(
            repository: "owner/models",
            revision: "0123456789abcdef",
            localRoot: URL(fileURLWithPath: "/tmp/kokoro")
        )

        XCTAssertEqual(
            source.localURL(for: "ANE/vocab.json").path,
            "/tmp/kokoro/ANE/vocab.json"
        )
    }
}
