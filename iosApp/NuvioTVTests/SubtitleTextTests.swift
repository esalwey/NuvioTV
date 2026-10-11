import XCTest
@testable import NuvioTV

/// The text side of add-on subtitles: which code page a legacy file is read in (`SubtitleCharset`),
/// and the repairs applied to the WebVTT the native engine serves (`SubtitleTextNormalizer`:
/// mojibake, right-to-left lines). Pure data in, pure data out.
@MainActor
final class SubtitleTextTests: XCTestCase {

    // MARK: - Samples (bytes encoded in the code pages named)

    private let russianText = "Привет, как дела? Я давно тебя не видел."
    private let russian1251 = Data([0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, 0x2C, 0x20, 0xEA, 0xE0, 0xEA, 0x20, 0xE4, 0xE5, 0xEB,
                                    0xE0, 0x3F, 0x20, 0xDF, 0x20, 0xE4, 0xE0, 0xE2, 0xED, 0xEE, 0x20, 0xF2, 0xE5, 0xE1, 0xFF,
                                    0x20, 0xED, 0xE5, 0x20, 0xE2, 0xE8, 0xE4, 0xE5, 0xEB, 0x2E])

    private let arabicText = "مرحبا، كيف حالك؟ لم أراك منذ وقت طويل."
    private let arabic1256 = Data([0xE3, 0xD1, 0xCD, 0xC8, 0xC7, 0xA1, 0x20, 0xDF, 0xED, 0xDD, 0x20, 0xCD, 0xC7, 0xE1, 0xDF,
                                   0xBF, 0x20, 0xE1, 0xE3, 0x20, 0xC3, 0xD1, 0xC7, 0xDF, 0x20, 0xE3, 0xE4, 0xD0, 0x20, 0xE6,
                                   0xDE, 0xCA, 0x20, 0xD8, 0xE6, 0xED, 0xE1, 0x2E])

    private let frenchText = "Qu'est-ce que tu fais ici à cette heure-là ? C'était déjà très tard."
    private let french1252 = Data([0x51, 0x75, 0x27, 0x65, 0x73, 0x74, 0x2D, 0x63, 0x65, 0x20, 0x71, 0x75, 0x65, 0x20, 0x74, 0x75,
                                   0x20, 0x66, 0x61, 0x69, 0x73, 0x20, 0x69, 0x63, 0x69, 0x20, 0xE0, 0x20, 0x63, 0x65, 0x74, 0x74,
                                   0x65, 0x20, 0x68, 0x65, 0x75, 0x72, 0x65, 0x2D, 0x6C, 0xE0, 0x20, 0x3F, 0x20, 0x43, 0x27, 0xE9,
                                   0x74, 0x61, 0x69, 0x74, 0x20, 0x64, 0xE9, 0x6A, 0xE0, 0x20, 0x74, 0x72, 0xE8, 0x73, 0x20, 0x74,
                                   0x61, 0x72, 0x64, 0x2E])

    private let simplifiedText = "你好，你最近怎么样？我很久没有见到你了。\n我只是想和你谈谈。"
    private let simplifiedGB = Data([0xC4, 0xE3, 0xBA, 0xC3, 0xA3, 0xAC, 0xC4, 0xE3, 0xD7, 0xEE, 0xBD, 0xFC, 0xD4, 0xF5, 0xC3, 0xB4,
                                     0xD1, 0xF9, 0xA3, 0xBF, 0xCE, 0xD2, 0xBA, 0xDC, 0xBE, 0xC3, 0xC3, 0xBB, 0xD3, 0xD0, 0xBC, 0xFB,
                                     0xB5, 0xBD, 0xC4, 0xE3, 0xC1, 0xCB, 0xA1, 0xA3, 0x0A, 0xCE, 0xD2, 0xD6, 0xBB, 0xCA, 0xC7, 0xCF,
                                     0xEB, 0xBA, 0xCD, 0xC4, 0xE3, 0xCC, 0xB8, 0xCC, 0xB8, 0xA1, 0xA3])

    private let traditionalText = "你好，你最近怎麼樣？我很久沒有見到你了。\n我只是想和你談談。"
    private let traditionalBig5 = Data([0xA7, 0x41, 0xA6, 0x6E, 0xA1, 0x41, 0xA7, 0x41, 0xB3, 0xCC, 0xAA, 0xF1, 0xAB, 0xE7, 0xBB, 0xF2,
                                        0xBC, 0xCB, 0xA1, 0x48, 0xA7, 0xDA, 0xAB, 0xDC, 0xA4, 0x5B, 0xA8, 0x53, 0xA6, 0xB3, 0xA8, 0xA3,
                                        0xA8, 0xEC, 0xA7, 0x41, 0xA4, 0x46, 0xA1, 0x43, 0x0A, 0xA7, 0xDA, 0xA5, 0x75, 0xAC, 0x4F, 0xB7,
                                        0x51, 0xA9, 0x4D, 0xA7, 0x41, 0xBD, 0xCD, 0xBD, 0xCD, 0xA1, 0x43])

    private let japaneseText = "こんにちは、お元気ですか？ずっと会っていませんでしたね。\nこんな時間にここで何をしているんですか？"
    private let japaneseSJIS = Data([
        0x82, 0xB1, 0x82, 0xF1, 0x82, 0xC9, 0x82, 0xBF, 0x82, 0xCD, 0x81, 0x41, 0x82, 0xA8, 0x8C, 0xB3, 0x8B, 0x43, 0x82, 0xC5,
        0x82, 0xB7, 0x82, 0xA9, 0x81, 0x48, 0x82, 0xB8, 0x82, 0xC1, 0x82, 0xC6, 0x89, 0xEF, 0x82, 0xC1, 0x82, 0xC4, 0x82, 0xA2,
        0x82, 0xDC, 0x82, 0xB9, 0x82, 0xF1, 0x82, 0xC5, 0x82, 0xB5, 0x82, 0xBD, 0x82, 0xCB, 0x81, 0x42, 0x0A, 0x82, 0xB1, 0x82,
        0xF1, 0x82, 0xC8, 0x8E, 0x9E, 0x8A, 0xD4, 0x82, 0xC9, 0x82, 0xB1, 0x82, 0xB1, 0x82, 0xC5, 0x89, 0xBD, 0x82, 0xF0, 0x82,
        0xB5, 0x82, 0xC4, 0x82, 0xA2, 0x82, 0xE9, 0x82, 0xF1, 0x82, 0xC5, 0x82, 0xB7, 0x82, 0xA9, 0x81, 0x48])

    private let koreanText = "안녕하세요, 잘 지내세요? 오랫동안 못 봤네요.\n이런 시간에 여기서 뭐 하세요?"
    private let koreanEUCKR = Data([
        0xBE, 0xC8, 0xB3, 0xE7, 0xC7, 0xCF, 0xBC, 0xBC, 0xBF, 0xE4, 0x2C, 0x20, 0xC0, 0xDF, 0x20, 0xC1, 0xF6, 0xB3, 0xBB, 0xBC,
        0xBC, 0xBF, 0xE4, 0x3F, 0x20, 0xBF, 0xC0, 0xB7, 0xA7, 0xB5, 0xBF, 0xBE, 0xC8, 0x20, 0xB8, 0xF8, 0x20, 0xBA, 0xC3, 0xB3,
        0xD7, 0xBF, 0xE4, 0x2E, 0x0A, 0xC0, 0xCC, 0xB7, 0xB1, 0x20, 0xBD, 0xC3, 0xB0, 0xA3, 0xBF, 0xA1, 0x20, 0xBF, 0xA9, 0xB1,
        0xE2, 0xBC, 0xAD, 0x20, 0xB9, 0xB9, 0x20, 0xC7, 0xCF, 0xBC, 0xBC, 0xBF, 0xE4, 0x3F])

    // MARK: - Unicode forms

    func testValidUTF8IsReadAsItIs() {
        XCTAssertEqual(SubtitleCharset.decode(Data(russianText.utf8), languageHint: "ru"), russianText)
        XCTAssertEqual(SubtitleCharset.decode(Data(frenchText.utf8)), frenchText)
    }

    func testUTF16WithAByteOrderMarkLosesTheMark() {
        var data = Data([0xFF, 0xFE])
        for unit in "1\n00:00:01,000 --> 00:00:02,000\nHello".utf16 {
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8(unit >> 8))
        }
        XCTAssertEqual(SubtitleCharset.decode(data), "1\n00:00:01,000 --> 00:00:02,000\nHello")
    }

    func testUTF16WithoutAByteOrderMarkIsRecognisedByItsZeros() {
        let text = "1\n00:00:01,000 --> 00:00:02,000\nHello there"
        var little = Data(), big = Data()
        for unit in text.utf16 {
            little.append(UInt8(unit & 0xFF)); little.append(UInt8(unit >> 8))
            big.append(UInt8(unit >> 8)); big.append(UInt8(unit & 0xFF))
        }
        XCTAssertEqual(SubtitleCharset.decode(little), text)
        XCTAssertEqual(SubtitleCharset.decode(big), text)
    }

    func testNoDataDecodesToNothing() {
        XCTAssertNil(SubtitleCharset.decode(Data()))
    }

    // MARK: - Legacy code pages named by the language

    func testRussianIsWindows1251() {
        XCTAssertEqual(SubtitleCharset.decode(russian1251, languageHint: "ru"), russianText)
    }

    func testArabicIsWindows1256() {
        XCTAssertEqual(SubtitleCharset.decode(arabic1256, languageHint: "ar"), arabicText)
    }

    func testFrenchOfferedAsRussianStaysFrench() {
        // Read as Windows-1251 the accents would be Cyrillic letters; the script check refuses that.
        XCTAssertEqual(SubtitleCharset.decode(french1252, languageHint: "ru"), frenchText)
    }

    func testTheCodePageFollowsTheChineseVariant() {
        XCTAssertEqual(SubtitleCharset.decode(simplifiedGB, languageHint: "zh-CN"), simplifiedText)
        XCTAssertEqual(SubtitleCharset.decode(traditionalBig5, languageHint: "zh-TW"), traditionalText)
        XCTAssertEqual(SubtitleCharset.decode(traditionalBig5, languageHint: "zh-Hant"), traditionalText)
    }

    func testJapaneseAndKoreanWithTheirLanguage() {
        XCTAssertEqual(SubtitleCharset.decode(japaneseSJIS, languageHint: "ja"), japaneseText)
        XCTAssertEqual(SubtitleCharset.decode(koreanEUCKR, languageHint: "ko"), koreanText)
    }

    func testWindows1252IsTheFallback() {
        XCTAssertEqual(SubtitleCharset.decode(french1252), frenchText)
        XCTAssertEqual(SubtitleCharset.decode(french1252, languageHint: "fr"), frenchText)
    }

    // MARK: - Double-byte code pages from the bytes alone

    func testEachDoubleByteCodePageIsRecognisedWithoutALanguage() {
        XCTAssertEqual(SubtitleCharset.decode(simplifiedGB), simplifiedText)
        XCTAssertEqual(SubtitleCharset.decode(traditionalBig5), traditionalText)
        XCTAssertEqual(SubtitleCharset.decode(japaneseSJIS), japaneseText)
        XCTAssertEqual(SubtitleCharset.decode(koreanEUCKR), koreanText)
    }

    func testBig5HasLowTrailBytesAndGB2312DoesNot() {
        XCTAssertGreaterThan(SubtitleCharset.lowTrailShare(traditionalBig5), 0.15)
        XCTAssertEqual(SubtitleCharset.lowTrailShare(simplifiedGB), 0, accuracy: 0.001)
    }

    func testSingleByteTextIsNotMistakenForADoubleByteCodePage() {
        XCTAssertNil(SubtitleCharset.guessDoubleByte(french1252))
        XCTAssertNil(SubtitleCharset.guessDoubleByte(russian1251))
    }

    // MARK: - mpv's sub-codepage

    func testMpvTriesUTF8ThenTheLanguagesCodePage() {
        XCTAssertEqual(SubtitleCharset.mpvCodepage(forLanguage: "ru"), "utf-8:cp1251")
        XCTAssertEqual(SubtitleCharset.mpvCodepage(forLanguage: "ar"), "utf-8:cp1256")
        XCTAssertEqual(SubtitleCharset.mpvCodepage(forLanguage: "ja"), "utf-8:cp932")
        XCTAssertEqual(SubtitleCharset.mpvCodepage(forLanguage: "ko"), "utf-8:cp949")
        XCTAssertEqual(SubtitleCharset.mpvCodepage(forLanguage: "zh-CN"), "utf-8:gb18030")
        XCTAssertEqual(SubtitleCharset.mpvCodepage(forLanguage: "zh-TW"), "utf-8:big5")
    }

    func testMpvKeepsItsOwnDetectionForOtherLanguages() {
        XCTAssertNil(SubtitleCharset.mpvCodepage(forLanguage: "en"))
        XCTAssertNil(SubtitleCharset.mpvCodepage(forLanguage: "fr"))
        XCTAssertNil(SubtitleCharset.mpvCodepage(forLanguage: nil))
        XCTAssertNil(SubtitleCharset.mpvCodepage(forLanguage: ""))
    }

    // MARK: - Mojibake

    func testMusicNoteReadAsWindows1252IsRepaired() {
        XCTAssertEqual(SubtitleTextNormalizer.repairMojibake("\u{00E2}\u{2122}\u{00AA} Hello \u{00E2}\u{2122}\u{00AA}"),
                       "\u{266A} Hello \u{266A}")
    }

    func testAccentsReadAsWindows1252AreRepaired() {
        XCTAssertEqual(SubtitleTextNormalizer.repairMojibake("Caf\u{00C3}\u{00A9} d\u{00C3}\u{00A9}j\u{00C3}\u{00A0}"),
                       "Café déjà")
    }

    func testCurlyQuotesAndDashesReadAsWindows1252AreRepaired() {
        XCTAssertEqual(SubtitleTextNormalizer.repairMojibake("It\u{00E2}\u{20AC}\u{2122}s \u{00E2}\u{20AC}\u{201C} fine"),
                       "It\u{2019}s \u{2013} fine")
    }

    func testCorrectTextIsLeftAlone() {
        for line in ["Café déjà vu", "Ça va ? Très bien, merci.", "NÃO", "¿Qué pasa?", "Привет", "Hello"] {
            XCTAssertEqual(SubtitleTextNormalizer.repairMojibake(line), line, line)
        }
    }

    func testMojibakeMixedWithOtherTextFallsBackToThePatterns() {
        // A character that was never Windows-1252 keeps the line from being reversed as a whole.
        XCTAssertEqual(SubtitleTextNormalizer.repairMojibake("\u{00C2}\u{00BF}Qué \u{0142}?"), "\u{00BF}Qué \u{0142}?")
    }

    // MARK: - Right-to-left

    func testHebrewAndArabicLinesGetOneRightToLeftEmbedding() {
        XCTAssertEqual(SubtitleTextNormalizer.wrapRightToLeft("שלום עולם!"), "\u{202B}שלום עולם!\u{202C}")
        XCTAssertEqual(SubtitleTextNormalizer.wrapRightToLeft("- مرحبا (John)"), "\u{202B}- مرحبا (John)\u{202C}")
    }

    func testWrappingTwiceChangesNothing() {
        let once = SubtitleTextNormalizer.wrapRightToLeft("שלום עולם!")
        XCTAssertEqual(SubtitleTextNormalizer.wrapRightToLeft(once), once)
        // Marks the file brought are replaced, not stacked.
        XCTAssertEqual(SubtitleTextNormalizer.wrapRightToLeft("\u{200F}שלום"), "\u{202B}שלום\u{202C}")
    }

    func testLeftToRightAndNumberOnlyLinesAreNotTouched() {
        for line in ["Hello, world!", "12:30", "١٢٣", "♪ ♪", ""] {
            XCTAssertEqual(SubtitleTextNormalizer.wrapRightToLeft(line), line, line)
        }
    }

    func testTheCarriageReturnStaysOutsideTheEmbedding() {
        XCTAssertEqual(SubtitleTextNormalizer.wrapRightToLeft("שלום\r"), "\u{202B}שלום\u{202C}\r")
    }

    // MARK: - WebVTT documents

    func testOnlyCuePayloadLinesAreRepaired() {
        let vtt = "WEBVTT\n\n1\n00:00:01.000 --> 00:00:02.000\nשלום\n\nNOTE\nהערה\n\n2\n00:00:03.000 --> 00:00:04.000\nHello\nCaf\u{00C3}\u{00A9}\n"
        let expected = "WEBVTT\n\n1\n00:00:01.000 --> 00:00:02.000\n\u{202B}שלום\u{202C}\n\nNOTE\nהערה\n\n2\n00:00:03.000 --> 00:00:04.000\nHello\nCafé\n"
        XCTAssertEqual(SubtitleTextNormalizer.normalizeVTT(vtt), expected)
    }

    func testAnSrtInWindows1251BecomesWebVTTInCyrillic() {
        var srt = Data("1\n00:00:01,000 --> 00:00:03,000\n".utf8)
        srt.append(russian1251)
        srt.append(Data("\n".utf8))
        let vtt = SubtitleVTT.webVTT(from: srt, languageHint: "ru")
        XCTAssertNotNil(vtt)
        XCTAssertTrue(vtt?.contains(russianText) ?? false, vtt ?? "nil")
        XCTAssertTrue(vtt?.hasPrefix("WEBVTT") ?? false)
    }
}
