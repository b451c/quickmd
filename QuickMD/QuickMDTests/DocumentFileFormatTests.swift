import XCTest

/// Source Edit's byte-faithful format (S-D8). The core invariant, per
/// fixture: `encode(normalize(decode(bytes))) == bytes` for a file with
/// uniform line endings — a save without edits must not change one byte.
final class DocumentFileFormatTests: XCTestCase {

    private func utf8(_ string: String) -> Data { Data(string.utf8) }

    /// Decodes, checks the detected format, and checks the round trip.
    private func assertRoundTrip(_ bytes: Data,
                                 encoding: DocumentFileFormat.Encoding,
                                 hasBOM: Bool,
                                 lineEnding: DocumentFileFormat.LineEnding,
                                 text expectedText: String? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard let decoded = DocumentFileFormat.decode(bytes) else {
            return XCTFail("decode returned nil", file: file, line: line)
        }
        XCTAssertEqual(decoded.format.encoding, encoding, file: file, line: line)
        XCTAssertEqual(decoded.format.hasBOM, hasBOM, file: file, line: line)
        XCTAssertEqual(decoded.format.lineEnding, lineEnding, file: file, line: line)
        XCTAssertFalse(decoded.text.unicodeScalars.contains("\r"), "text must be LF-normalized",
                       file: file, line: line)
        XCTAssertNotEqual(decoded.text.unicodeScalars.first, "\u{FEFF}", "text must not carry a BOM",
                          file: file, line: line)
        if let expectedText {
            XCTAssertEqual(decoded.text, expectedText, file: file, line: line)
        }
        XCTAssertEqual(decoded.format.encode(decoded.text), bytes, "round trip changed the bytes",
                       file: file, line: line)
        XCTAssertTrue(decoded.isByteExact, file: file, line: line)
        XCTAssertTrue(decoded.isLosslessDecode, file: file, line: line)
        XCTAssertFalse(decoded.hasMixedLineEndings, file: file, line: line)
    }

    // MARK: - Round trips

    func testUTF8LF() {
        assertRoundTrip(utf8("# Zażółć\n\ngęślą jaźń\n"), encoding: .utf8, hasBOM: false, lineEnding: .lf)
    }

    func testUTF8CRLF() {
        assertRoundTrip(utf8("# Title\r\n\r\nbody\r\n"), encoding: .utf8, hasBOM: false, lineEnding: .crlf,
                        text: "# Title\n\nbody\n")
    }

    func testUTF8CR() {
        assertRoundTrip(utf8("# Title\r\rbody\r"), encoding: .utf8, hasBOM: false, lineEnding: .cr,
                        text: "# Title\n\nbody\n")
    }

    func testUTF8WithBOM() {
        let bytes = Data([0xEF, 0xBB, 0xBF]) + utf8("---\ntitle: x\n---\nbody\n")
        assertRoundTrip(bytes, encoding: .utf8, hasBOM: true, lineEnding: .lf,
                        text: "---\ntitle: x\n---\nbody\n")
    }

    func testUTF8WithBOMAndCRLF() {
        let bytes = Data([0xEF, 0xBB, 0xBF]) + utf8("a\r\nb\r\n")
        assertRoundTrip(bytes, encoding: .utf8, hasBOM: true, lineEnding: .crlf, text: "a\nb\n")
    }

    func testUTF16LittleEndian() {
        let bytes = Data([0xFF, 0xFE]) + "# Łódź\nok 😀\n".data(using: .utf16LittleEndian)!
        assertRoundTrip(bytes, encoding: .utf16LittleEndian, hasBOM: true, lineEnding: .lf,
                        text: "# Łódź\nok 😀\n")
    }

    func testUTF16BigEndian() {
        let bytes = Data([0xFE, 0xFF]) + "# Łódź\nok 😀\n".data(using: .utf16BigEndian)!
        assertRoundTrip(bytes, encoding: .utf16BigEndian, hasBOM: true, lineEnding: .lf,
                        text: "# Łódź\nok 😀\n")
    }

    func testUTF16LittleEndianCRLF() {
        let bytes = Data([0xFF, 0xFE]) + "a\r\nb\r\n".data(using: .utf16LittleEndian)!
        assertRoundTrip(bytes, encoding: .utf16LittleEndian, hasBOM: true, lineEnding: .crlf, text: "a\nb\n")
    }

    func testUTF16BigEndianCRLF() {
        let bytes = Data([0xFE, 0xFF]) + "a\r\nb\r\n".data(using: .utf16BigEndian)!
        assertRoundTrip(bytes, encoding: .utf16BigEndian, hasBOM: true, lineEnding: .crlf, text: "a\nb\n")
    }

    func testLatin1() {
        // 0xE9 = "é" in Latin-1; a lone 0xE9 is not valid UTF-8.
        let bytes = Data([0x63, 0x61, 0x66, 0xE9, 0x0A, 0x78, 0x0A])
        XCTAssertNil(String(data: bytes, encoding: .utf8), "fixture must not be valid UTF-8")
        assertRoundTrip(bytes, encoding: .isoLatin1, hasBOM: false, lineEnding: .lf, text: "café\nx\n")
    }

    func testLatin1CRLF() {
        let bytes = Data([0x63, 0x61, 0x66, 0xE9, 0x0D, 0x0A, 0x78, 0x0D, 0x0A])
        assertRoundTrip(bytes, encoding: .isoLatin1, hasBOM: false, lineEnding: .crlf, text: "café\nx\n")
    }

    func testEmptyFile() {
        assertRoundTrip(Data(), encoding: .utf8, hasBOM: false, lineEnding: .lf, text: "")
    }

    func testNoTrailingNewline() {
        assertRoundTrip(utf8("a\r\nlast line"), encoding: .utf8, hasBOM: false, lineEnding: .crlf,
                        text: "a\nlast line")
    }

    func testSeveralTrailingNewlines() {
        assertRoundTrip(utf8("a\r\n\r\n\r\n"), encoding: .utf8, hasBOM: false, lineEnding: .crlf,
                        text: "a\n\n\n")
    }

    func testTrailingSpaces() {
        // Two trailing spaces are a Markdown hard break — they must survive.
        assertRoundTrip(utf8("line  \r\nnext \t\r\n  "), encoding: .utf8, hasBOM: false, lineEnding: .crlf,
                        text: "line  \nnext \t\n  ")
    }

    func testLatin1C1ControlBytes() {
        // 0x80–0x9F are C1 controls in Latin-1 (0x85 = U+0085 NEL); invalid
        // as standalone UTF-8. They must come back as the same bytes, and NEL
        // is content, not a line break.
        let bytes = Data([0x61, 0x80, 0x85, 0x9F, 0x62, 0x0A])
        assertRoundTrip(bytes, encoding: .isoLatin1, hasBOM: false, lineEnding: .lf,
                        text: "a\u{80}\u{85}\u{9F}b\n")
    }

    func testLatin1LoneCR() {
        assertRoundTrip(Data([0x63, 0xE9, 0x0D, 0x78]), encoding: .isoLatin1, hasBOM: false, lineEnding: .cr,
                        text: "c\u{E9}\nx")
    }

    func testNULBytes() {
        assertRoundTrip(Data([0x61, 0x00, 0x62, 0x0A, 0x00]), encoding: .utf8, hasBOM: false, lineEnding: .lf,
                        text: "a\u{0}b\n\u{0}")
    }

    func testUnicodeLineSeparatorsAreContent() {
        // U+2028, U+2029 and U+0085 are neither counted nor normalized.
        let source = "a\u{2028}b\u{2029}c\u{0085}d\r\ne\u{2028}\u{2029}\u{0085}\r\n"
        assertRoundTrip(utf8(source), encoding: .utf8, hasBOM: false, lineEnding: .crlf,
                        text: "a\u{2028}b\u{2029}c\u{0085}d\ne\u{2028}\u{2029}\u{0085}\n")
        XCTAssertEqual(DocumentFileFormat.dominantLineEnding(in: "a\u{2028}b\u{2029}c\u{0085}d"), .lf)
    }

    // MARK: - Byte-exact safety net

    func testMixedLineEndingsAreFlaggedAndNotByteExact() throws {
        let decoded = try XCTUnwrap(DocumentFileFormat.decode(utf8("a\r\nb\r\nc\n")))
        XCTAssertTrue(decoded.hasMixedLineEndings)
        XCTAssertFalse(decoded.isByteExact)
        XCTAssertEqual(decoded.format.lineEnding, .crlf)
    }

    func testCRCRLFIsOneCROneCRLF() throws {
        // "\r\r\n" = a lone CR then a CRLF: a 1:1 tie → LF, and mixed.
        XCTAssertEqual(DocumentFileFormat.dominantLineEnding(in: "a\r\r\nb"), .lf)
        let decoded = try XCTUnwrap(DocumentFileFormat.decode(utf8("a\r\r\nb")))
        XCTAssertEqual(decoded.text, "a\n\nb")
        XCTAssertTrue(decoded.hasMixedLineEndings)
        XCTAssertFalse(decoded.isByteExact)
    }

    /// Whatever Foundation does with malformed UTF-16, the session must end up
    /// either with a byte-exact round trip or a `false` answer — never a
    /// "repaired" text that claims to match the file.
    func testMalformedUTF16IsByteExactOrRefused() throws {
        let cases: [(String, Data)] = [
            ("odd-length LE", Data([0xFF, 0xFE, 0x61, 0x00, 0x62])),
            ("odd-length BE", Data([0xFE, 0xFF, 0x00, 0x61, 0x00])),
            ("lone high surrogate LE", Data([0xFF, 0xFE, 0x00, 0xD8, 0x61, 0x00])),
            ("lone low surrogate BE", Data([0xFE, 0xFF, 0xDC, 0x00, 0x00, 0x61])),
        ]
        for (name, bytes) in cases {
            let decoded = try XCTUnwrap(DocumentFileFormat.decode(bytes), name)
            let roundTrip = decoded.format.encode(decoded.text)
            XCTAssertEqual(decoded.isByteExact, roundTrip == bytes, name)
            XCTAssertTrue(roundTrip == bytes || !decoded.isByteExact, name)
            print("MalformedUTF16 \(name): encoding=\(decoded.format.encoding) isByteExact=\(decoded.isByteExact)")
        }
    }

    // MARK: - Lossless decode (the edit session's entry check)

    func testMixedLineEndingFilesDecodeLosslessly() throws {
        for (name, bytes) in [("CRLF+LF", utf8("a\r\nb\r\nc\n")),
                              ("CR+CRLF", utf8("a\r\r\nb")),
                              ("LF+CR UTF-16 LE", Data([0xFF, 0xFE]) + "a\nb\rc".data(using: .utf16LittleEndian)!),
                              ("CRLF+LF Latin-1", "caf\u{E9}\r\nb\n".data(using: .isoLatin1)!),
                              ("CRLF+LF UTF-8 BOM", Data([0xEF, 0xBB, 0xBF]) + utf8("a\r\nb\n"))] {
            let decoded = try XCTUnwrap(DocumentFileFormat.decode(bytes), name)
            XCTAssertTrue(decoded.hasMixedLineEndings, name)
            XCTAssertFalse(decoded.isByteExact, name)
            XCTAssertTrue(decoded.isLosslessDecode, name)
        }
    }

    /// An odd number of UTF-16 bytes cannot be reproduced by any UTF-16
    /// encode: if the decoder took it as UTF-16 it repaired something, and the
    /// flag must say so — with or without mixed line endings. (Should
    /// Foundation refuse it and fall back to Latin-1, that decode IS
    /// lossless: every byte is one character.)
    func testOddLengthUTF16IsNotLossless() throws {
        let cases: [(String, Data)] = [
            ("odd LE", Data([0xFF, 0xFE, 0x61, 0x00, 0x62])),
            ("odd BE", Data([0xFE, 0xFF, 0x00, 0x61, 0x00])),
            ("odd LE mixed", Data([0xFF, 0xFE]) + "a\r\nb\nc".data(using: .utf16LittleEndian)! + Data([0x64])),
            ("odd BE mixed", Data([0xFE, 0xFF]) + "a\r\nb\nc".data(using: .utf16BigEndian)! + Data([0x00])),
        ]
        for (name, bytes) in cases {
            let decoded = try XCTUnwrap(DocumentFileFormat.decode(bytes), name)
            switch decoded.format.encoding {
            case .utf16LittleEndian, .utf16BigEndian:
                XCTAssertFalse(decoded.isLosslessDecode, name)
            case .isoLatin1:
                XCTAssertTrue(decoded.isLosslessDecode, name)
            case .utf8:
                XCTFail("\(name) cannot be UTF-8")
            }
            XCTAssertFalse(decoded.isByteExact && !decoded.isLosslessDecode, name)
        }
    }

    func testLosslessDecodeMatchesARawReencode() throws {
        let cases = [Data([0xFF, 0xFE, 0x00, 0xD8, 0x61, 0x00]), Data([0xFE, 0xFF, 0xDC, 0x00, 0x00, 0x61]),
                     utf8(""), utf8("x"), Data([0xEF, 0xBB, 0xBF])]
        for bytes in cases {
            let decoded = try XCTUnwrap(DocumentFileFormat.decode(bytes))
            let raw = try XCTUnwrap(MarkdownDocument.decodeDetectingEncoding(bytes)).text
            let asRead = DocumentFileFormat(encoding: decoded.format.encoding, hasBOM: decoded.format.hasBOM,
                                            lineEnding: .lf)
            XCTAssertEqual(decoded.isLosslessDecode, asRead.encode(raw) == bytes)
            if decoded.isByteExact { XCTAssertTrue(decoded.isLosslessDecode) }
        }
    }

    // MARK: - Line-ending policy

    func testMixedLineEndingsPickDominant() {
        XCTAssertEqual(DocumentFileFormat.dominantLineEnding(in: "a\r\nb\r\nc\nd"), .crlf)
        XCTAssertEqual(DocumentFileFormat.dominantLineEnding(in: "a\nb\nc\r\nd"), .lf)
        XCTAssertEqual(DocumentFileFormat.dominantLineEnding(in: "a\rb\rc\nd\r\n"), .cr)
        XCTAssertEqual(DocumentFileFormat.decode(utf8("a\r\nb\r\nc\n"))?.format.lineEnding, .crlf)
    }

    func testLineEndingTieAndNoBreakPickLF() {
        XCTAssertEqual(DocumentFileFormat.dominantLineEnding(in: "a\r\nb\nc"), .lf)
        XCTAssertEqual(DocumentFileFormat.dominantLineEnding(in: "a\r\nb\rc"), .lf)
        XCTAssertEqual(DocumentFileFormat.dominantLineEnding(in: "no break"), .lf)
        XCTAssertEqual(DocumentFileFormat.dominantLineEnding(in: ""), .lf)
    }

    func testCRLFIsNotCountedAsCRPlusLF() {
        // "\r\n" is ONE Character; the scan must run on scalars and pair them.
        XCTAssertEqual(DocumentFileFormat.dominantLineEnding(in: "\r\n\r\n\r"), .crlf)
        XCTAssertEqual(DocumentFileFormat.dominantLineEnding(in: "a\r"), .cr)
    }

    // MARK: - Encoding limits and the UTF-8 fallback

    func testLatin1CannotRepresentPolishLetter() {
        let format = DocumentFileFormat(encoding: .isoLatin1, hasBOM: false, lineEnding: .lf)
        XCTAssertNil(format.encode("zażółć"))
        XCTAssertEqual(format.encode("café"), Data([0x63, 0x61, 0x66, 0xE9]))
    }

    func testUTF8FallbackKeepsLineEnding() {
        let latin1 = DocumentFileFormat(encoding: .isoLatin1, hasBOM: false, lineEnding: .crlf)
        let fallback = latin1.utf8Fallback
        XCTAssertEqual(fallback, DocumentFileFormat(encoding: .utf8, hasBOM: false, lineEnding: .crlf))
        XCTAssertEqual(fallback.encode("ł\nb\n"), utf8("ł\r\nb\r\n"))

        let utf16 = DocumentFileFormat(encoding: .utf16BigEndian, hasBOM: true, lineEnding: .cr)
        XCTAssertEqual(utf16.utf8Fallback.encode("a\n"), utf8("a\r"), "fallback drops the BOM")
    }

    // MARK: - MarkdownDocument.decode never returns the BOM

    /// Independent of Foundation's own BOM handling: the BOM is recognised on
    /// the bytes and only the remainder is decoded.
    func testDecodeNeverReturnsLeadingBOM() {
        let bom = Data([0xEF, 0xBB, 0xBF])
        XCTAssertEqual(MarkdownDocument.decode(bom + utf8("---\nx: 1\n---\n")), "---\nx: 1\n---\n")
        XCTAssertEqual(MarkdownDocument.decode(bom), "")

        var utf16 = Data([0xFF, 0xFE])
        utf16.append("# h".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(MarkdownDocument.decode(utf16), "# h")
    }

    // MARK: - BOM is handled on the bytes, never by Foundation

    /// A U+FEFF right after the BOM is CONTENT and must survive the round
    /// trip — `String(data:encoding: .utf8)` would strip it as a second BOM.
    func testUTF8DoubleBOMRoundTrip() {
        let bom = Data([0xEF, 0xBB, 0xBF])
        assertRoundTripKeepingFEFF(bom + bom + utf8("a\n"), encoding: .utf8, text: "\u{FEFF}a\n")
    }

    func testUTF16LittleEndianDoubleBOMRoundTrip() {
        let bytes = Data([0xFF, 0xFE, 0xFF, 0xFE]) + "a\r\n".data(using: .utf16LittleEndian)!
        assertRoundTripKeepingFEFF(bytes, encoding: .utf16LittleEndian, text: "\u{FEFF}a\n")
    }

    func testUTF16BigEndianDoubleBOMRoundTrip() {
        let bytes = Data([0xFE, 0xFF, 0xFE, 0xFF]) + "a\r\n".data(using: .utf16BigEndian)!
        assertRoundTripKeepingFEFF(bytes, encoding: .utf16BigEndian, text: "\u{FEFF}a\n")
    }

    func testFileThatIsOnlyABOM() {
        // Through `DocumentFileFormat.decode` (assertRoundTrip) — format,
        // empty text, byte-exact.
        assertRoundTrip(Data([0xEF, 0xBB, 0xBF]), encoding: .utf8, hasBOM: true, lineEnding: .lf, text: "")
        assertRoundTrip(Data([0xFF, 0xFE]), encoding: .utf16LittleEndian, hasBOM: true, lineEnding: .lf, text: "")
        assertRoundTrip(Data([0xFE, 0xFF]), encoding: .utf16BigEndian, hasBOM: true, lineEnding: .lf, text: "")
    }

    func testUTF8BOMWithInvalidBodyFallsBackToLatin1() {
        // Same outcome as before the BOM was handled on the bytes.
        let bytes = Data([0xEF, 0xBB, 0xBF, 0x63, 0xE9])
        assertRoundTrip(bytes, encoding: .isoLatin1, hasBOM: false, lineEnding: .lf)
    }

    /// `assertRoundTrip` minus its no-leading-U+FEFF check: here the
    /// U+FEFF is the point.
    private func assertRoundTripKeepingFEFF(_ bytes: Data, encoding: DocumentFileFormat.Encoding, text: String,
                                            file: StaticString = #filePath, line: UInt = #line) {
        guard let decoded = DocumentFileFormat.decode(bytes) else {
            return XCTFail("decode returned nil", file: file, line: line)
        }
        XCTAssertEqual(decoded.format.encoding, encoding, file: file, line: line)
        XCTAssertTrue(decoded.format.hasBOM, file: file, line: line)
        XCTAssertEqual(decoded.text, text, file: file, line: line)
        XCTAssertEqual(MarkdownDocument.decode(bytes).map(MarkdownDocument.normalizeLineEndings), text,
                       "viewer and editor must agree", file: file, line: line)
        XCTAssertEqual(decoded.format.encode(decoded.text), bytes, "round trip changed the bytes",
                       file: file, line: line)
        XCTAssertTrue(decoded.isByteExact, file: file, line: line)
    }

    func testDecodeKeepsFEFFInsideText() {
        XCTAssertEqual(MarkdownDocument.decode(utf8("a\u{FEFF}b")), "a\u{FEFF}b")
    }

    func testDecodeDetectingEncodingMatchesDecode() {
        let samples: [Data] = [
            utf8("plain"),
            Data([0xFF, 0xFE]) + "x".data(using: .utf16LittleEndian)!,
            Data([0xFE, 0xFF]) + "x".data(using: .utf16BigEndian)!,
            Data([0x63, 0xE9]),
        ]
        let expected: [String.Encoding] = [.utf8, .utf16LittleEndian, .utf16BigEndian, .isoLatin1]
        for (data, encoding) in zip(samples, expected) {
            let detected = MarkdownDocument.decodeDetectingEncoding(data)
            XCTAssertEqual(detected?.encoding, encoding)
            XCTAssertEqual(detected?.text, MarkdownDocument.decode(data))
        }
    }
}
