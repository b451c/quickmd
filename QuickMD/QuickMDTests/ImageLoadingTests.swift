import XCTest
import AppKit

/// #32 — image loading: `data:` URLs, one loader + cache for every source,
/// and the "no payload in any visible string" rule. All offline: remote
/// sources are only resolved, never fetched (`loadSync` must not touch the
/// network, which is exactly what one test pins).
final class ImageLoadingTests: XCTestCase {

    /// A valid 1×1 PNG.
    private let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
    private var pngData: Data { Data(base64Encoded: pngBase64)! }
    private var pngURI: String { "data:image/png;base64,\(pngBase64)" }

    // MARK: - DataImageURI parsing / decoding

    func testBase64PNGRoundTrip() throws {
        let uri = try XCTUnwrap(DataImageURI.parse(pngURI))
        XCTAssertEqual(uri.mediaType, "image/png")
        XCTAssertTrue(uri.isBase64)
        XCTAssertTrue(uri.isImage)
        XCTAssertEqual(uri.encodedByteCount, pngBase64.utf8.count)
        XCTAssertEqual(try uri.decodeData().get(), pngData)
    }

    func testSchemeAndMediaTypeAreCaseInsensitive() throws {
        let uri = try XCTUnwrap(DataImageURI.parse("DATA:Image/PNG;BASE64,\(pngBase64)"))
        XCTAssertEqual(uri.mediaType, "image/png")
        XCTAssertTrue(uri.isBase64)
        XCTAssertEqual(try uri.decodeData().get(), pngData)
    }

    func testBase64ToleratesSpacesAndNewlines() throws {
        var wrapped = ""
        for (offset, character) in pngBase64.enumerated() {
            wrapped.append(character)
            if offset % 7 == 6 { wrapped.append(offset % 2 == 0 ? " " : "\n") }
        }
        let uri = try XCTUnwrap(DataImageURI.parse("data:image/png;base64, \(wrapped)\n"))
        XCTAssertEqual(try uri.decodeData().get(), pngData)
    }

    func testBase64URLAlphabet() throws {
        // 0xFB 0xFF 0xBF encodes to "+/+/" — the characters base64url replaces.
        let bytes = Data([0xFB, 0xFF, 0xBF, 0x01])
        XCTAssertEqual(bytes.base64EncodedString(), "+/+/AQ==")
        let uri = try XCTUnwrap(DataImageURI.parse("data:image/png;base64,-_-_AQ"))
        XCTAssertEqual(try uri.decodeData().get(), bytes)
    }

    func testBase64MissingPadding() throws {
        let unpadded = pngBase64.replacingOccurrences(of: "=", with: "")
        XCTAssertNotEqual(unpadded.utf8.count % 4, 0, "fixture must actually lack padding")
        let uri = try XCTUnwrap(DataImageURI.parse("data:image/png;base64,\(unpadded)"))
        XCTAssertEqual(try uri.decodeData().get(), pngData)
        XCTAssertEqual(try DataImageURI.parse("data:image/png;base64,AQ")?.decodeData().get(), Data([1]))
    }

    func testPercentEncodedSVG() throws {
        let raw = "data:image/svg+xml;utf8,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%2240%22 height=%2220%22%3E%3Crect width=%2240%22 height=%2220%22/%3E%3C/svg%3E"
        let uri = try XCTUnwrap(DataImageURI.parse(raw))
        XCTAssertEqual(uri.mediaType, "image/svg+xml")
        XCTAssertFalse(uri.isBase64)
        let data = try uri.decodeData().get()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\""), text)

        let image = try XCTUnwrap(ImageLoader.decodeImage(data: data, mediaType: uri.mediaType,
                                                          maxPixel: ImageLoader.displayMaxPixel))
        XCTAssertEqual(image.size, NSSize(width: 40, height: 20))
    }

    func testRawSVGWithSpacesAndPlusSigns() throws {
        let markup = "<svg xmlns='http://www.w3.org/2000/svg' width='30' height='10'><rect width='30' height='10'/></svg>"
        let uri = try XCTUnwrap(DataImageURI.parse("data:image/svg+xml,\(markup)"))
        XCTAssertEqual(try uri.decodeData().get(), Data(markup.utf8))
        // '+' is NOT a space in a URL; `%41` is 'A'; a stray '%' stays literal.
        let plus = try XCTUnwrap(DataImageURI.parse("data:image/svg+xml,a+b%41%zz%4"))
        XCTAssertEqual(try plus.decodeData().get(), Data("a+bA%zz%4".utf8))
    }

    func testPercentDecodingProducesBytesNotUTF8() throws {
        // %FF%D8 is not valid UTF-8 — it must survive as raw bytes.
        let uri = try XCTUnwrap(DataImageURI.parse("data:image/jpeg,%FF%D8%FF"))
        XCTAssertEqual(try uri.decodeData().get(), Data([0xFF, 0xD8, 0xFF]))
    }

    func testMissingCommaIsNotADataURI() {
        XCTAssertNil(DataImageURI.parse("data:image/png;base64"))
        XCTAssertNil(DataImageURI.parse("http://example.com/a.png"))
        XCTAssertNil(DataImageURI.parse("dat"))
    }

    func testCommaSplitsAtTheFirstOne() throws {
        let uri = try XCTUnwrap(DataImageURI.parse("data:image/svg+xml,a,b,c"))
        XCTAssertEqual(try uri.decodeData().get(), Data("a,b,c".utf8))
    }

    func testTextPlainIsNotAnImage() throws {
        let defaulted = try XCTUnwrap(DataImageURI.parse("data:,hello"))
        XCTAssertEqual(defaulted.mediaType, "text/plain")
        XCTAssertEqual(defaulted.decodeData(), .failure(.notAnImage))

        let explicit = try XCTUnwrap(DataImageURI.parse("data:text/plain;base64,aGk="))
        XCTAssertEqual(explicit.decodeData(), .failure(.notAnImage))

        // Parameters without a type still default to text/plain (RFC 2397).
        let paramsOnly = try XCTUnwrap(DataImageURI.parse("data:;base64,aGk="))
        XCTAssertEqual(paramsOnly.mediaType, "text/plain")
        XCTAssertEqual(paramsOnly.decodeData(), .failure(.notAnImage))
    }

    func testOverCapIsTooLargeBeforeDecoding() throws {
        // Garbage that would be .undecodable: the cap must win, i.e. be checked first.
        let uri = try XCTUnwrap(DataImageURI.parse("data:image/png;base64,A"))
        XCTAssertEqual(uri.decodeData(maxEncodedBytes: 0), .failure(.tooLarge))

        let png = try XCTUnwrap(DataImageURI.parse(pngURI))
        XCTAssertEqual(png.decodeData(maxEncodedBytes: pngBase64.utf8.count - 1), .failure(.tooLarge))
        XCTAssertNoThrow(try png.decodeData(maxEncodedBytes: pngBase64.utf8.count).get())
    }

    func testUndecodablePayloads() throws {
        // A single leftover base64 character cannot encode a byte.
        XCTAssertEqual(DataImageURI.parse("data:image/png;base64,A")?.decodeData(), .failure(.undecodable))
        XCTAssertEqual(DataImageURI.parse("data:image/png;base64,")?.decodeData(), .failure(.undecodable))
        XCTAssertEqual(DataImageURI.parse("data:image/png,")?.decodeData(), .failure(.undecodable))
    }

    func testDisplayLabelNeverContainsPayload() throws {
        let marker = "QUICKMDPAYLOADMARKER"
        let raw = "data:image/jpeg;base64,\(marker)\(String(repeating: "A", count: 4000))"
        let uri = try XCTUnwrap(DataImageURI.parse(raw))
        let label = uri.displayLabel
        XCTAssertTrue(label.hasPrefix("embedded JPEG image, "), label)
        XCTAssertFalse(label.contains(marker), label)
        XCTAssertLessThan(label.count, 60, label)

        let svg = try XCTUnwrap(DataImageURI.parse("data:image/svg+xml;utf8,\(marker)"))
        XCTAssertTrue(svg.displayLabel.hasPrefix("embedded SVG image, "), svg.displayLabel)
        XCTAssertFalse(svg.displayLabel.contains(marker))

        // A hostile "subtype" is not echoed either.
        let hostile = try XCTUnwrap(DataImageURI.parse("data:image/\(marker)<script>;base64,AAAA"))
        XCTAssertEqual(hostile.displayLabel.hasPrefix("embedded image, "), true, hostile.displayLabel)
        XCTAssertFalse(hostile.displayLabel.contains(marker))

        // An over-long header is refused outright.
        let longHeader = "data:image/png;" + String(repeating: "x", count: DataImageURI.maxHeaderBytes + 10) + ",AAAA"
        XCTAssertNil(DataImageURI.parse(longHeader))
    }

    // MARK: - ImageSource.resolve

    func testResolveTable() throws {
        let doc = URL(fileURLWithPath: "/docs/notes/readme.md")

        guard case .data(let uri)? = ImageSource.resolve(pngURI, documentURL: doc) else {
            return XCTFail("data: → .data")
        }
        XCTAssertEqual(uri.mediaType, "image/png")
        XCTAssertNil(ImageSource.resolve("data:image/png;base64", documentURL: doc), "no comma → nil")

        guard case .remote(let http)? = ImageSource.resolve("http://example.com/a.png", documentURL: doc),
              case .remote(let https)? = ImageSource.resolve("HTTPS://example.com/b.svg", documentURL: nil) else {
            return XCTFail("http/https → .remote")
        }
        XCTAssertEqual(http.absoluteString, "http://example.com/a.png")
        XCTAssertEqual(https.host, "example.com")

        XCTAssertEqual(filePath(ImageSource.resolve("file:///tmp/pic%20one.png", documentURL: nil)),
                       "/tmp/pic one.png")
        XCTAssertEqual(filePath(ImageSource.resolve("/abs/pic.png", documentURL: nil)), "/abs/pic.png")
        XCTAssertEqual(filePath(ImageSource.resolve("/abs/a%20b.png", documentURL: nil)), "/abs/a b.png")
        XCTAssertEqual(filePath(ImageSource.resolve("img/a%20b.png", documentURL: doc)),
                       "/docs/notes/img/a b.png")
        XCTAssertEqual(filePath(ImageSource.resolve("pic.png", documentURL: doc)), "/docs/notes/pic.png")
        // Not a valid escape — kept as written.
        XCTAssertEqual(filePath(ImageSource.resolve("100%.png", documentURL: doc)), "/docs/notes/100%.png")
        // Relative with no document → nothing to resolve against.
        XCTAssertNil(ImageSource.resolve("pic.png", documentURL: nil))
    }

    func testFileCandidatesAddUndecodedFallback() {
        let doc = URL(fileURLWithPath: "/docs/readme.md")
        guard case .file(let url)? = ImageSource.resolve("img/a%20b.png", documentURL: doc) else {
            return XCTFail()
        }
        XCTAssertEqual(ImageLoader.fileCandidates(for: url, raw: "img/a%20b.png").map(\.path),
                       ["/docs/img/a b.png", "/docs/img/a%20b.png"])

        let plain = URL(fileURLWithPath: "/docs/pic.png")
        XCTAssertEqual(ImageLoader.fileCandidates(for: plain, raw: "pic.png"), [plain])
        let fileURL = URL(string: "file:///docs/a%20b.png")!
        XCTAssertEqual(ImageLoader.fileCandidates(for: fileURL, raw: "file:///docs/a%20b.png"), [fileURL])
    }

    // MARK: - Decoder

    func testDataDecoderPNGIsPixelSized() throws {
        let image = try XCTUnwrap(ImageLoader.decodeImage(data: pngData, mediaType: "image/png",
                                                          maxPixel: ImageLoader.displayMaxPixel))
        XCTAssertEqual(image.size, NSSize(width: 1, height: 1))
    }

    func testDataDecoderSVGKeepsDeclaredSize() throws {
        let markup = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"120\" height=\"20\"><rect width=\"120\" height=\"20\" fill=\"#4c1\"/></svg>"
        // Sniffed from the bytes (no media type — e.g. a server sending text/plain).
        let sniffed = try XCTUnwrap(ImageLoader.decodeImage(data: Data(markup.utf8), mediaType: nil,
                                                            maxPixel: ImageLoader.displayMaxPixel))
        XCTAssertEqual(sniffed.size, NSSize(width: 120, height: 20))
        XCTAssertNil(ImageLoader.decodeImage(data: Data("not an image".utf8), mediaType: "image/png",
                                             maxPixel: ImageLoader.displayMaxPixel))
        XCTAssertNil(SVGImageDecoder.decode(data: Data("plain text".utf8)))
    }

    // MARK: - Loader

    func testLoadSyncDataURIAndCache() throws {
        // A raw string no other test uses, so the cache state is this test's own.
        let raw = "data:image/png;base64,\(pngBase64)\n"
        let source = try XCTUnwrap(ImageSource.resolve(raw, documentURL: nil))
        let image = try XCTUnwrap(ImageLoader.loadSync(raw: raw, source: source, maxPixel: ImageLoader.printMaxPixel))
        XCTAssertEqual(image.size, NSSize(width: 1, height: 1))
        XCTAssertTrue(ImageLoader.loadSync(raw: raw, source: source, maxPixel: ImageLoader.printMaxPixel) === image,
                      "second call is a cache hit")

        // The display tier is a separate cache: seeded only once something loads at that tier.
        XCTAssertNil(ImageLoader.cachedImage(for: raw, source: source, maxPixel: ImageLoader.displayMaxPixel))
        let shown = try XCTUnwrap(ImageLoader.loadSync(raw: raw, source: source, maxPixel: ImageLoader.displayMaxPixel))
        XCTAssertTrue(ImageLoader.cachedImage(for: raw, source: source, maxPixel: ImageLoader.displayMaxPixel) === shown)
        // The preview tier is never cached.
        _ = ImageLoader.loadSync(raw: raw, source: source, maxPixel: ImageLoader.previewMaxPixel)
        XCTAssertNil(ImageLoader.cachedImage(for: raw, source: source, maxPixel: ImageLoader.previewMaxPixel))
    }

    /// `ImageBlockView.init` runs `resolve` + `cachedImage` on the main thread on
    /// every body evaluation of its row. On a 5 MB `data:` URL both must stay
    /// independent of the payload size (header-only parse, O(1) byte count,
    /// NSString-bridged cache key on the same storage).
    func testMainThreadPathIsCheapOnHugeDataURI() throws {
        // 5 MB of payload that still decodes (base64 ignores whitespace), so it gets cached.
        let raw = "data:image/png;base64," + pngBase64 + String(repeating: " ", count: 5_000_000)
        let source = try XCTUnwrap(ImageSource.resolve(raw, documentURL: nil))
        _ = ImageLoader.loadSync(raw: raw, source: source, maxPixel: ImageLoader.displayMaxPixel)

        let started = Date()
        var hits = 0
        for _ in 0..<200 {
            guard let resolved = ImageSource.resolve(raw, documentURL: nil) else { continue }
            if ImageLoader.cachedImage(for: raw, source: resolved, maxPixel: ImageLoader.displayMaxPixel) != nil {
                hits += 1
            }
        }
        XCTAssertEqual(hits, 200)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "200 × (resolve + lookup) on a 5 MB data: URL")
    }

    func testLoadSyncRemoteNeverFetches() throws {
        // An address that would fail anyway; the point is that nothing is attempted.
        let raw = "https://quickmd.invalid/never-fetched.png"
        let source = try XCTUnwrap(ImageSource.resolve(raw, documentURL: nil))
        XCTAssertNil(ImageLoader.loadSync(raw: raw, source: source, maxPixel: ImageLoader.printMaxPixel))
    }

    func testAsyncLoadOfDataURIAndFailures() async throws {
        let raw = "data:image/png;base64,\(pngBase64) "
        let source = try XCTUnwrap(ImageSource.resolve(raw, documentURL: nil))
        let image = try await ImageLoader.load(raw: raw, source: source, maxPixel: ImageLoader.displayMaxPixel).get()
        XCTAssertEqual(image.size, NSSize(width: 1, height: 1))

        let textRaw = "data:text/plain,hello"
        let textSource = try XCTUnwrap(ImageSource.resolve(textRaw, documentURL: nil))
        let textResult = await ImageLoader.load(raw: textRaw, source: textSource, maxPixel: ImageLoader.displayMaxPixel)
        XCTAssertEqual(textResult.failureValue, .notAnImage)

        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quickmd-missing-\(UUID().uuidString).png")
        let missingResult = await ImageLoader.load(raw: missing.path, source: .file(missing),
                                                   maxPixel: ImageLoader.displayMaxPixel)
        XCTAssertEqual(missingResult.failureValue, .notFound)
    }

    func testLocalFileLiterallyNamedWithPercentEscape() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quickmd-img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try pngData.write(to: dir.appendingPathComponent("a%20b.png"))
        try pngData.write(to: dir.appendingPathComponent("c d.png"))
        let doc = dir.appendingPathComponent("doc.md")

        for raw in ["a%20b.png", "c%20d.png"] {
            let source = try XCTUnwrap(ImageSource.resolve(raw, documentURL: doc))
            let image = ImageLoader.loadSync(raw: raw, source: source, maxPixel: ImageLoader.printMaxPixel)
            XCTAssertEqual(image?.size, NSSize(width: 1, height: 1), raw)
        }
    }

    // MARK: - Review fixes (original size, normalisation, known failures, sniffing, print cache)

    /// `kCGImageSourceThumbnailMaxPixelSize` caps the LONGER side: an 800×4000
    /// bitmap is decoded at 240×1200, but `size` must stay 800×4000 so D4 caps
    /// its width at the column, and the screen and print tiers agree.
    func testDownsampledBitmapKeepsOriginalPixelSize() throws {
        let png = try makeImageData(width: 800, height: 4000, type: "public.png")
        let raw = "data:image/png;base64,\(png.base64EncodedString())"
        let source = try XCTUnwrap(ImageSource.resolve(raw, documentURL: nil))

        let shown = try XCTUnwrap(ImageLoader.loadSync(raw: raw, source: source, maxPixel: ImageLoader.displayMaxPixel))
        XCTAssertEqual(shown.size, NSSize(width: 800, height: 4000))
        let held = shown.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
        XCTAssertLessThanOrEqual(held, ImageLoader.displayMaxPixel, "the bitmap itself stays downsampled")

        let printed = try XCTUnwrap(ImageLoader.loadSync(raw: raw, source: source, maxPixel: ImageLoader.printMaxPixel))
        XCTAssertEqual(printed.size, shown.size, "screen and print tiers agree")
        ImageLoader.clearPrintCache()
    }

    /// EXIF orientation 6 (rotate 90°): the thumbnail is created with the
    /// transform applied, so the reported size is swapped too.
    func testEXIFRotationSwapsOriginalSize() throws {
        let jpeg = try makeImageData(width: 200, height: 100, type: "public.jpeg", orientation: 6)
        let image = try XCTUnwrap(ImageLoader.decodeImage(data: jpeg, mediaType: "image/jpeg",
                                                          maxPixel: ImageLoader.displayMaxPixel))
        XCTAssertEqual(image.size, NSSize(width: 100, height: 200))
    }

    func testResolveNormalisesWhitespaceAndAngleBrackets() throws {
        let doc = URL(fileURLWithPath: "/docs/readme.md")
        guard case .data(let spaced)? = ImageSource.resolve("  \(pngURI) \n", documentURL: doc),
              case .data(let bracketed)? = ImageSource.resolve("<\(pngURI)>", documentURL: doc) else {
            return XCTFail("leading space / <…> data: URLs must still classify as .data")
        }
        XCTAssertEqual(try spaced.decodeData().get(), pngData)
        XCTAssertEqual(try bracketed.decodeData().get(), pngData)
        XCTAssertEqual(filePath(ImageSource.resolve("<img/a b.png>", documentURL: doc)), "/docs/img/a b.png")
        XCTAssertEqual(filePath(ImageSource.resolve(" pic.png ", documentURL: doc)), "/docs/pic.png")
        XCTAssertEqual(ImageLoader.fileCandidates(for: URL(fileURLWithPath: "/docs/a b.png"), raw: "<a%20b.png>").map(\.path),
                       ["/docs/a b.png", "/docs/a%20b.png"])

        // No real path is megabytes long: refused, not percent-decoded on main.
        let huge = String(repeating: "A", count: 5_000_000)
        XCTAssertNil(ImageSource.resolve(huge, documentURL: doc))
        XCTAssertNil(ImageSource.resolve("https://x/" + huge, documentURL: doc))
    }

    func testMalformedDataURIsAreCheapAndNeverLabelledWithPayload() throws {
        let marker = "QUICKMDPAYLOADMARKER"
        let payload = marker + String(repeating: "A", count: 5_000_000)
        let doc = URL(fileURLWithPath: "/docs/readme.md")

        let started = Date()
        for raw in [" data:image/png;base64,\(payload)", "<data:image/png;base64,\(payload)>"] {
            for _ in 0..<50 { _ = ImageSource.resolve(raw, documentURL: doc) }
            let label = ImageLabel.errorText(alt: "", raw: raw, source: ImageSource.resolve(raw, documentURL: doc))
            XCTAssertFalse(label.contains(marker), label)
            XCTAssertFalse(label.contains("AAAAAAAA"), label)
        }
        // No comma at all, behind a space: still recognised as data:, no payload shown.
        let unparsed = " data:image/png;base64" + payload
        XCTAssertNil(ImageSource.resolve(unparsed, documentURL: doc))
        XCTAssertEqual(ImageLabel.errorText(alt: "", raw: unparsed, source: nil), "Embedded image could not be shown")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testKnownFailuresWithoutIO() async throws {
        let text = "data:text/plain,hello"
        XCTAssertEqual(ImageLoader.knownFailure(for: text, source: try XCTUnwrap(ImageSource.resolve(text, documentURL: nil))),
                       .notAnImage)

        // Decode failures of data: URLs are remembered (negative cache)…
        let garbage = "data:image/png;base64,\(Data("not a png at all".utf8).base64EncodedString())"
        let garbageSource = try XCTUnwrap(ImageSource.resolve(garbage, documentURL: nil))
        XCTAssertNil(ImageLoader.knownFailure(for: garbage, source: garbageSource))
        let result = await ImageLoader.load(raw: garbage, source: garbageSource, maxPixel: ImageLoader.displayMaxPixel)
        XCTAssertEqual(result.failureValue, .undecodable)
        XCTAssertEqual(ImageLoader.knownFailure(for: garbage, source: garbageSource), .undecodable)

        // …local files never are: the file may appear later.
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("quickmd-\(UUID().uuidString).png")
        _ = await ImageLoader.load(raw: missing.path, source: .file(missing), maxPixel: ImageLoader.displayMaxPixel)
        XCTAssertNil(ImageLoader.knownFailure(for: missing.path, source: .file(missing)))
    }

    func testSVGSniffingRequiresMarkupAtTheStart() {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"12\" height=\"8\"><rect width=\"12\" height=\"8\"/></svg>"
        let accepted: [Data] = [
            Data(svg.utf8),
            Data(" \n\t\(svg)".utf8),
            Data([0xEF, 0xBB, 0xBF]) + Data("<?xml version=\"1.0\"?>\(svg)".utf8),
            Data("<!-- badge -->\(svg)".utf8),
            Data("<!doctype SVG PUBLIC \"-//W3C//DTD SVG 1.1//EN\" \"x\">\(svg)".utf8),
            Data("<SVG".utf8),
        ]
        for data in accepted {
            XCTAssertTrue(SVGImageDecoder.looksLikeSVG(data), String(decoding: data, as: UTF8.self))
        }
        XCTAssertEqual(SVGImageDecoder.decode(data: Data(" \n\(svg)".utf8))?.size, NSSize(width: 12, height: 8))

        let rejected: [Data] = [
            Data("<html><body>error page mentioning \(svg)</body></html>".utf8),
            Data("hello \(svg)".utf8),
            Data("<!DOCTYPE html>\(svg)".utf8),
            Data(),
        ]
        for data in rejected {
            XCTAssertFalse(SVGImageDecoder.looksLikeSVG(data), String(decoding: data, as: UTF8.self))
            XCTAssertNil(ImageLoader.decodeImage(data: data, mediaType: "image/svg+xml",
                                                 maxPixel: ImageLoader.displayMaxPixel))
        }
    }

    func testPrintCacheIsClearedAfterExport() throws {
        let raw = "data:image/png;base64,\(pngBase64)\t"
        let source = try XCTUnwrap(ImageSource.resolve(raw, documentURL: nil))
        let first = try XCTUnwrap(ImageLoader.loadSync(raw: raw, source: source, maxPixel: ImageLoader.printMaxPixel))
        XCTAssertTrue(ImageLoader.cachedImage(for: raw, source: source, maxPixel: ImageLoader.printMaxPixel) === first)
        ImageLoader.clearPrintCache()
        XCTAssertNil(ImageLoader.cachedImage(for: raw, source: source, maxPixel: ImageLoader.printMaxPixel))
    }

    // MARK: - Labels

    func testMiddleTruncation() {
        XCTAssertEqual(DisplayString.middleTruncated("short", maxLength: 80), "short")
        let exact = String(repeating: "a", count: 80)
        XCTAssertEqual(DisplayString.middleTruncated(exact, maxLength: 80), exact)

        let long = String(repeating: "a", count: 50) + String(repeating: "b", count: 950) + String(repeating: "c", count: 50)
        let truncated = DisplayString.middleTruncated(long, maxLength: 80)
        XCTAssertEqual(truncated.count, 80)
        XCTAssertTrue(truncated.hasPrefix(String(repeating: "a", count: 40)))
        XCTAssertTrue(truncated.hasSuffix(String(repeating: "c", count: 39)))
        XCTAssertTrue(truncated.contains("\u{2026}"))

        let eightyOne = String(repeating: "x", count: 81)
        XCTAssertEqual(DisplayString.middleTruncated(eightyOne, maxLength: 80).count, 80)

        // More than 80 UTF-8 bytes but only 50 characters: not truncated.
        let polish = String(repeating: "ż", count: 50)
        XCTAssertEqual(DisplayString.middleTruncated(polish, maxLength: 80), polish)
        let polishLong = String(repeating: "ż", count: 300)
        XCTAssertEqual(DisplayString.middleTruncated(polishLong, maxLength: 200).count, 200)
    }

    func testMiddleTruncationIsBoundedOnHugeStrings() {
        let huge = "data:image/png;base64," + String(repeating: "A", count: 5_000_000)
        let started = Date()
        let truncated = DisplayString.middleTruncated(huge, maxLength: 200)
        XCTAssertEqual(truncated.count, 200)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
    }

    func testErrorTextNeverShowsPayload() throws {
        let marker = "QUICKMDPAYLOADMARKER"
        let raw = "data:image/png;base64,\(marker)"
        let source = ImageSource.resolve(raw, documentURL: nil)

        XCTAssertEqual(ImageLabel.errorText(alt: "Logo", raw: raw, source: source), "Image: Logo")

        let failed = ImageLabel.errorText(alt: "", raw: raw, source: source, failure: .undecodable)
        XCTAssertTrue(failed.hasPrefix("Embedded image could not be shown (embedded PNG image, "), failed)
        XCTAssertFalse(failed.contains(marker))

        let tooLarge = ImageLabel.errorText(alt: "", raw: raw, source: source, failure: .tooLarge)
        XCTAssertTrue(tooLarge.hasPrefix("Embedded image too large (embedded PNG image, "), tooLarge)

        let unparsed = "data:image/png;base64\(marker)"  // no comma
        XCTAssertEqual(ImageLabel.errorText(alt: "", raw: unparsed, source: nil), "Embedded image could not be shown")

        let longURL = "https://example.com/" + String(repeating: "x", count: 500) + ".png"
        let urlText = ImageLabel.errorText(alt: "", raw: longURL, source: ImageSource.resolve(longURL, documentURL: nil))
        XCTAssertEqual(urlText.count, "Image: ".count + ImageLabel.maxURLLength)
        XCTAssertTrue(urlText.hasSuffix(".png"))
    }

    // MARK: - Helpers

    /// A solid-colour bitmap encoded with ImageIO, optionally tagged with an
    /// EXIF orientation.
    private func makeImageData(width: Int, height: Int, type: String, orientation: Int? = nil) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func filePath(_ source: ImageSource?, file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard case .file(let url)? = source else {
            XCTFail("expected .file, got \(String(describing: source))", file: file, line: line)
            return nil
        }
        return url.path
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
