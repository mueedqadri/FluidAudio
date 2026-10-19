import XCTest

@testable import FluidAudio

final class NemoTextNormalizerMemoTests: XCTestCase {
    override func tearDown() {
        NemoTextNormalizer.memo.disable()
        super.tearDown()
    }

    func testMemoIsOffUntilEnabled() {
        _ = NemoTextNormalizer.normalize("It costs $5.", language: .english)
        XCTAssertTrue(NemoTextNormalizer.memo.contents.isEmpty)
    }

    func testEnabledMemoKeepsAndServesReadings() {
        NemoTextNormalizer.memo.enable()
        let first = NemoTextNormalizer.normalize("It costs $5.", language: .english)
        XCTAssertEqual(NemoTextNormalizer.memo.contents[NemoTextNormalizer.Memo.key("It costs $5.", .english)], first)

        let key = NemoTextNormalizer.Memo.key("seeded 7", .english)
        NemoTextNormalizer.memo.enable(with: [key: "a kept reading"])
        XCTAssertEqual(NemoTextNormalizer.normalize("seeded 7", language: .english), "a kept reading")
        XCTAssertEqual(NemoTextNormalizer.normalize("It costs $5.", language: .english), first)
    }
}
