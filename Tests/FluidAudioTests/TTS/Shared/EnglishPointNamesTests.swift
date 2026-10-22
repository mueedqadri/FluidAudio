import Foundation
import XCTest

@testable import FluidAudio

/// Point and line names in geometry are letters; capitals elsewhere keep their reading.
final class EnglishPointNamesTests: XCTestCase {

    private func spoken(_ text: String) -> String { EnglishTextNormalizer.spokenText(text).text }

    func testNamesInAFigureAreLetters() {
        XCTAssertEqual(
            spoken("Angles CAB and BAG are both right angles; therefore C, A, and G are collinear."),
            "Angles C A B and B A G are both right angles; therefore C, A, and G are collinear.")
        XCTAssertEqual(
            spoken("From the point of contact A draw AB at right angles to the tangent."),
            "From the point of contact A draw A B at right angles to the tangent.")
        XCTAssertEqual(spoken("Lastly, cut off OR = ON, and OS = OQ."), "Lastly, cut off O R equals O N, and O S equals O Q.")
        XCTAssertEqual(spoken("Dem.—Draw BE parallel to AC."), "Dem.—Draw B E parallel to A C.")
        XCTAssertEqual(spoken("Hence AB is bisected in D."), "Hence A B is bisected in D.")
        XCTAssertEqual(spoken("Join the sides (BA, CA), and bisect them."), "Join the sides (B A, C A), and bisect them.")
        XCTAssertEqual(spoken("Join AO, OB, DH, HE; then the radii are equal."), "Join A O, O B, DH, H E; then the radii are equal.")
    }

    func testProductsAndPrimes() {
        XCTAssertEqual(spoken("Then AC.AD + BC.BE = AB²."), "Then A C times A D plus B C times B E equals A B squared.")
        XCTAssertEqual(
            spoken("the points A′, B′, C′ form a second triangle A′B′C′,"),
            "the points A prime, B prime, C prime form a second triangle A prime B prime C prime,")
        XCTAssertEqual(spoken("we may write f′′(x) instead."), "we may write f double prime(x) instead.")
        XCTAssertEqual(spoken("Relative to K′, the event."), "Relative to K prime, the event.")
    }

    func testCapitalsElsewhereKeepTheirReading() {
        XCTAssertEqual(
            spoken("OF THE REAL AND NOMINAL PRICE OF COMMODITIES, OR OF THEIR PRICE IN LABOUR."),
            "OF THE REAL AND NOMINAL PRICE OF COMMODITIES, OR OF THEIR PRICE IN LABOUR.")
        XCTAssertEqual(spoken("A recipient MAY combine multiple field lines."), "A recipient MAY combine multiple field lines.")
        XCTAssertEqual(EnglishPointNames.spell("McCusker RR, Cone EJ (October 2006)."), "McCusker RR, Cone EJ (October 2006).")
        XCTAssertEqual(EnglishPointNames.spell("I did NOT draw the line."), "I did NOT draw the line.")
        XCTAssertEqual(EnglishPointNames.spell("Euclid lived about 300 BC near the circle."), "Euclid lived about 300 BC near the circle.")
        XCTAssertEqual(EnglishPointNames.spell("IT′S a 3′ end."), "IT′S a 3′ end.")
        XCTAssertEqual(EnglishPointNames.spell("Calle Loreto, Num. 4, Mexico, D. F. BKI.MAR."), "Calle Loreto, Num. 4, Mexico, D. F. BKI.MAR.")
        XCTAssertEqual(spoken("JOHN MAYNARD KEYNES, C.B."), "JOHN MAYNARD KEYNES, C.B.")
    }
}
