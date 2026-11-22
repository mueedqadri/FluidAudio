import XCTest

@testable import FluidAudio

final class SpokenNumbersTests: XCTestCase {
    private func spoken(_ text: String, _ language: String) -> String {
        RuleFrontend().spokenText(text, language: language).text
    }

    func testNumbersSupertonicMisreadComeOutInWords() {
        XCTAssertEqual(
            spoken("Tiene una extensión territorial de 1495 km², lo que representa el 0.1 % del territorio.", "es"),
            "Tiene una extensión territorial de mil cuatrocientos noventa y cinco km², lo que representa el cero coma uno por ciento del territorio.")
        XCTAssertEqual(
            spoken("È un comune di 2 743 357 abitanti, fondato nel 753 a.C.", "it"),
            "È un comune di due milioni settecentoquarantatrémilatrecentocinquantasette abitanti, fondato nel settecentocinquantatré a.C.")
        XCTAssertEqual(spoken("a Revolução de 1932", "pt-BR"), "a Revolução de mil novecentos e trinta e dois")
        XCTAssertEqual(spoken("Lettres de mon moulin, 1869", "fr"), "Lettres de mon moulin, mille huit cent soixante-neuf")
    }

    func testEachLanguageReadsItsOwnSeparators() {
        XCTAssertEqual(spoken("mit rund 3,7 Millionen", "de"), "mit rund drei Komma sieben Millionen")
        XCTAssertEqual(spoken("1.287,36 km²", "it"), "milleduecentottantasette virgola tre sei km²")
        XCTAssertEqual(spoken("1287,36 km²", "it"), "milleduecentottantasette virgola tre sei km²")
        XCTAssertEqual(spoken("1.495 habitantes", "es"), "mil cuatrocientos noventa y cinco habitantes")
        XCTAssertEqual(spoken("인구는 931만 5,066명", "ko"), "인구는 구백삼십일만 오천육십육명")
        XCTAssertEqual(spoken("면적은 605.25 km²로", "ko"), "면적은 육백오점이오 km²로")
    }

    func testKoreanAndJapaneseNumbersStayAttachedToTheirCounters() {
        XCTAssertEqual(spoken("2025년 인구는 1,097만 명", "ko"), "이천이십오년 인구는 천구십칠만 명")
        XCTAssertEqual(spoken("国土の0.61%", "ko"), "国土の영점육일 퍼센트")
        XCTAssertEqual(spoken("特別区23区、26市と3町1村", "ja"), "特別区二十三区、二十六市と三町一村")
        XCTAssertEqual(spoken("605.25平方キロ", "ja"), "六百五点二五平方キロ")
    }

    func testGermanReadsYearsInHundreds() {
        XCTAssertEqual(spoken("im Jahr 1932 und 891 Quadratkilometer", "de"),
                       "im Jahr neunzehnhundertzweiunddreißig und achthunderteinundneunzig Quadratkilometer")
        XCTAssertEqual(spoken("seit 1900", "de"), "seit neunzehnhundert")
        XCTAssertEqual(spoken("im Jahr 2004", "de"), "im Jahr zweitausendvier")
    }

    func testPercentReadsInTheLanguage() {
        XCTAssertEqual(spoken("18,0 %", "fr"), "dix-huit pour cent")
        XCTAssertEqual(spoken("50%", "it"), "cinquanta per cento")
        XCTAssertEqual(spoken("12 %", "de"), "zwölf Prozent")
    }

    func testCodesTimesAndOrdinalsAreLeftToTheVoice() {
        XCTAssertEqual(spoken("Berlin wurde im 13. Jahrhundert", "de"), "Berlin wurde im 13. Jahrhundert")
        XCTAssertEqual(spoken("Berlin wurde im 13.", "de"), "Berlin wurde im 13.")
        XCTAssertEqual(spoken("um 10:30 Uhr", "de"), "um 10:30 Uhr")
        XCTAssertEqual(spoken("km2 und A4", "de"), "km2 und A4")
        XCTAssertEqual(spoken("le 21/04", "fr"), "le 21/04")
        XCTAssertEqual(spoken("code 007", "fr"), "code 007")
    }

    func testSentenceEndsAndListsKeepTheirPunctuation() {
        XCTAssertEqual(spoken("Fundada em 1554.", "pt"), "Fundada em mil quinhentos e cinquenta e quatro.")
        XCTAssertEqual(spoken("1, 2 y 3", "es"), "uno, dos y tres")
    }

    func testTextWithoutDigitsIsUntouched() {
        let text = "Le site est occupé sous le nom Lutèce."
        XCTAssertEqual(spoken(text, "fr"), text)
    }

    func testNoSoftHyphensReachTheVoice() {
        XCTAssertFalse(spoken("2743357", "it").contains("\u{00AD}"))
        XCTAssertFalse(spoken("891", "de").contains("\u{00AD}"))
    }
}
