import XCTest

/// Document decoding/normalization + custom-theme validation tests.
final class DocumentAndThemeTests: XCTestCase {

    // MARK: - Line ending normalization (single point: MarkdownDocument)

    func testCRLFNormalizedToLF() {
        XCTAssertEqual(MarkdownDocument.normalizeLineEndings("a\r\nb\r\n"), "a\nb\n")
    }

    func testLoneCRNormalizedToLF() {
        XCTAssertEqual(MarkdownDocument.normalizeLineEndings("a\rb"), "a\nb")
    }

    func testLFOnlyInputUntouched() {
        let input = "a\nb\nc"
        XCTAssertEqual(MarkdownDocument.normalizeLineEndings(input), input)
    }

    func testMixedLineEndings() {
        XCTAssertEqual(MarkdownDocument.normalizeLineEndings("a\r\nb\rc\nd"), "a\nb\nc\nd")
    }

    // MARK: - Encoding fallbacks

    func testDecodeUTF8() {
        let data = "zażółć # heading".data(using: .utf8)!
        XCTAssertEqual(MarkdownDocument.decode(data), "zażółć # heading")
    }

    func testDecodeUTF16LittleEndianWithBOM() {
        var data = Data([0xFF, 0xFE])  // UTF-16 LE BOM
        data.append("hello".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(MarkdownDocument.decode(data), "hello")
    }

    func testDecodeUTF16BigEndianWithBOM() {
        var data = Data([0xFE, 0xFF])  // UTF-16 BE BOM
        data.append("hello".data(using: .utf16BigEndian)!)
        XCTAssertEqual(MarkdownDocument.decode(data), "hello")
    }

    func testDecodeLatin1Fallback() {
        // 0xE9 = "é" in Latin-1; invalid as standalone UTF-8
        let data = Data([0x63, 0x61, 0x66, 0xE9])  // "café" in Latin-1
        XCTAssertEqual(MarkdownDocument.decode(data), "café")
    }

    // MARK: - Custom theme hex validation

    func testValidHexFormats() {
        XCTAssertTrue(CustomThemeDTO.isValidHexColor("AABBCC"))
        XCTAssertTrue(CustomThemeDTO.isValidHexColor("#AABBCC"))
        XCTAssertTrue(CustomThemeDTO.isValidHexColor("aabbccdd"))
        XCTAssertTrue(CustomThemeDTO.isValidHexColor(" #AABBCC "))
    }

    func testInvalidHexFormats() {
        XCTAssertFalse(CustomThemeDTO.isValidHexColor("AABBC"))      // 5 digits
        XCTAssertFalse(CustomThemeDTO.isValidHexColor("AABBCCD"))    // 7 digits
        XCTAssertFalse(CustomThemeDTO.isValidHexColor("GGHHII"))     // non-hex chars
        XCTAssertFalse(CustomThemeDTO.isValidHexColor(""))
    }

    // MARK: - Custom theme DTO validation

    private func dto(name: String, background: String = "FFFFFF") throws -> CustomThemeDTO {
        let json = """
        {
            "name": "\(name)", "isDark": false,
            "textColor": "000000", "secondaryTextColor": "666666",
            "linkColor": "0000FF", "blockquoteColor": "888888",
            "backgroundColor": "\(background)", "codeBackgroundColor": "F0F0F0",
            "headerBackgroundColor": "E0E0E0", "borderColor": "CCCCCC",
            "keywordColor": "990099", "stringColor": "996600",
            "commentColor": "666666", "numberColor": "229922",
            "typeColor": "116699", "checkboxColor": "00AA00"
        }
        """
        return try JSONDecoder().decode(CustomThemeDTO.self, from: Data(json.utf8))
    }

    func testValidThemePassesValidation() throws {
        XCTAssertNil(try dto(name: "My Theme").validationError)
    }

    func testInvalidColorFieldIsNamedInError() throws {
        let error = try dto(name: "My Theme", background: "ZZZ").validationError
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("backgroundColor") == true)
    }

    func testBuiltInNameCollisionRejected() throws {
        XCTAssertNotNil(try dto(name: "Dracula").validationError,
            "custom theme shadowed by a built-in name must be rejected, not silently unselectable")
        XCTAssertNotNil(try dto(name: "Auto").validationError)
    }

    // MARK: - Built-in theme resolution

    func testBuiltInThemeResolution() {
        XCTAssertEqual(MarkdownTheme.theme(named: "Dracula", colorScheme: .light).name, "Dracula")
        XCTAssertTrue(MarkdownTheme.theme(named: "Dracula", colorScheme: .light).isDark)
        XCTAssertEqual(MarkdownTheme.theme(named: "Auto", colorScheme: .dark).isDark, true)
        XCTAssertEqual(MarkdownTheme.theme(named: "Auto", colorScheme: .light).isDark, false)
    }
}
