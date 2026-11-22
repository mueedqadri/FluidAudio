import XCTest

@testable import FluidAudio

final class HindiTextNormalizerTests: XCTestCase {
    private func spoken(_ text: String) -> String {
        RuleFrontend().spokenText(text, language: "hi-IN").text
    }

    func testRuleFrontendReadsHindiWithTheHindiPass() {
        let spoken = RuleFrontend().spokenText("सन् १९४७ में।", language: "hi")
        XCTAssertEqual(spoken.language, "hi")
        XCTAssertEqual(spoken.text, "सन् उन्नीस सौ सैंतालीस में।")
    }

    func testDevanagariAndAsciiDigitsReadAlike() {
        XCTAssertEqual(spoken("पृष्ठ १२३ पर"), "पृष्ठ एक सौ तेईस पर")
        XCTAssertEqual(spoken("पृष्ठ 123 पर"), "पृष्ठ एक सौ तेईस पर")
        XCTAssertEqual(spoken("१२वीं कक्षा"), "बारहवीं कक्षा")
    }

    func testGroupedDigitsReadAsOneNumber() {
        XCTAssertEqual(spoken("1,00,000 लोग"), "एक लाख लोग")
        XCTAssertEqual(spoken("१,००,००० लोग"), "एक लाख लोग")
        XCTAssertEqual(spoken("100,000 लोग"), "एक लाख लोग")
    }

    func testClockTimesUseHindiIdioms() {
        XCTAssertEqual(spoken("सुबह 10:30 बजे"), "सुबह साढ़े दस बजे")
        XCTAssertEqual(spoken("7:15 पर"), "सवा सात बजे पर")
        XCTAssertEqual(spoken("4:45 बजे"), "पौने पाँच बजे")
        XCTAssertEqual(spoken("1:30 बजे"), "डेढ़ बजे")
        XCTAssertEqual(spoken("21:40 को"), "इक्कीस बजकर चालीस मिनट को")
    }

    func testMoneyAndPercentages() {
        XCTAssertEqual(spoken("कीमत ₹250 है।"), "कीमत दो सौ पचास रुपये है।")
        XCTAssertEqual(spoken("Rs. 500 दिए"), "पाँच सौ रुपये दिए")
        XCTAssertEqual(spoken("रु. 1 मिला"), "एक रुपया मिला")
        XCTAssertEqual(spoken("95% लोग"), "पंचानबे प्रतिशत लोग")
        XCTAssertEqual(spoken("२५ % छूट"), "पच्चीस प्रतिशत छूट")
    }

    func testAbbreviationsReadAsWords() {
        XCTAssertEqual(spoken("डॉ॰ शर्मा आए"), "डॉक्टर शर्मा आए")
        XCTAssertEqual(spoken("पृ॰ १२"), "पृष्ठ बारह")
        XCTAssertEqual(spoken("३०० ई॰ पू॰ में"), "तीन सौ ईसा पूर्व में")
    }

    func testSignsTheVoiceCannotReadBecomeLettersItCan() {
        XCTAssertEqual(spoken("॥१॥ ॐ नमः"), "। एक। ओम नमः")
        XCTAssertEqual(spoken("ऋषि ऋतु"), "रिषि रितु")
        XCTAssertEqual(spoken("सोऽहम्"), "सोहम्")
        XCTAssertEqual(spoken("बॅट"), "बैट")
    }

    func testPlainHindiIsUnchanged() {
        XCTAssertEqual(spoken("मुझे चाय पसंद है।"), "मुझे चाय पसंद है।")
        XCTAssertEqual(spoken("3,4 और 5"), "तीन,चार और पाँच")
    }

    func testOutputHasOnlyScalarsSupertonicReads() {
        let input = "॥ ॐ ॥ सन् १९४७ में ऋषि डॉ॰ शर्मा ने ₹१,००,००० दिए, ९५% सोऽहम् बॅट।"
        let unreadable: Set<UInt32> = [0x0965, 0x0950, 0x093D, 0x0970, 0x090B, 0x0960, 0x090D, 0x0945]
        let output = spoken(input)
        for scalar in output.unicodeScalars {
            XCTAssertFalse((0x0966...0x096F).contains(scalar.value), "digit \(scalar) in \(output)")
            XCTAssertFalse(unreadable.contains(scalar.value), "sign \(scalar) in \(output)")
        }
    }
}
