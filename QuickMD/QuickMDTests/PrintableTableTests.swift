import XCTest
import SwiftUI
import AppKit

/// The PDF / print table (`PrintableTableView`) draws each cell as SwiftUI
/// `Text(TableTextBuilder.printableCell(...))`. Until 1.14.1 the header asked
/// for semibold with a view-level `.font` modifier, which loses to the font
/// `renderInline` stamps on every run, so exported headers were REGULAR while
/// the screen's (`TableTextBuilder.build`) have been semibold since 1.13.
///
/// `MarkdownExport.swift` is not compiled into this target (it pulls in
/// SwiftMath, WebKit and the sandbox manager), so the export itself is not
/// driven here. Instead each cell goes through the same two steps the export
/// takes: the attributed string `PrintableTableView` hands to `Text`, and that
/// `Text` drawn by `ImageRenderer` into a PDF context (what
/// `PDFExportManager.generateMultiPagePDF` does per block). The drawn faces are
/// read back from the PDF's font resources in drawing order and compared with
/// reference `Text`s whose weight is known, so no OS-specific font name is
/// hard-coded.
final class PrintableTableTests: XCTestCase {

    private let renderer = MarkdownRenderer(theme: MarkdownTheme.cached(for: .light))

    private func cell(_ markdown: String, header: Bool) -> AttributedString {
        TableTextBuilder.printableCell(markdown, isHeader: header, renderer: renderer)
    }

    private func weight(of font: NSFont) -> CGFloat {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? CGFloat) ?? NSFont.Weight.regular.rawValue
    }

    private func appKitFonts(_ string: AttributedString) -> [NSFont] {
        string.runs.compactMap { $0[AttributeScopes.AppKitAttributes.FontAttribute.self] }
    }

    // MARK: - Attributed runs

    /// Header runs are raised in BOTH scopes (SwiftUI `Text` reads only the
    /// SwiftUI one) and keep their face; body cells are `renderInline` as is.
    func testHeaderRunsAreSemiboldInBothScopesBodyRunsUntouched() {
        let markdown = "plain **bold** *italic* `code` [link](https://example.com)"
        let header = cell(markdown, header: true)
        let original = renderer.renderInline(markdown)
        XCTAssertEqual(appKitFonts(header).count, header.runs.count, "every run carries an AppKit font")
        XCTAssertEqual(appKitFonts(original).count, header.runs.count, "one header run per rendered run")
        for (run, before) in zip(header.runs, original.runs) {
            let text = String(header[run.range].characters)
            guard let font = run[AttributeScopes.AppKitAttributes.FontAttribute.self],
                  let renderedFont = before[AttributeScopes.AppKitAttributes.FontAttribute.self] else { continue }
            XCTAssertGreaterThanOrEqual(weight(of: font), NSFont.Weight.semibold.rawValue, "header run \(text)")
            // The screen's header face for the same run.
            XCTAssertEqual(font, TableTextBuilder.headerWeightFont(renderedFont), text)
            if font === renderedFont {
                XCTAssertEqual(run.font, before.font, "\(text) was heavy already: untouched")
            } else {
                XCTAssertEqual(run.font, Font(font as CTFont), "\(text): SwiftUI scope wraps the raised face")
            }
        }
        func font(of text: String) -> NSFont {
            let range = header.range(of: text)!
            return header[range].runs.first![AttributeScopes.AppKitAttributes.FontAttribute.self]!
        }
        XCTAssertGreaterThanOrEqual(weight(of: font(of: "bold")), NSFont.Weight.bold.rawValue, "bold stays bold")
        XCTAssertTrue(font(of: "italic").fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertTrue(font(of: "code").fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertEqual(font(of: "plain").pointSize, BlockLayout.Table.cellFontSize, "screen size, not the old 12 pt")
        let link = header[header.range(of: "link")!].runs.first!
        XCTAssertEqual(link.link, URL(string: "https://example.com"), "link survives in the header")
        XCTAssertEqual(link.underlineStyle, .single)
        XCTAssertEqual(String(header.characters), String(original.characters))

        let bodyMarkdown = "plain **bold** *italic* `code`"
        let body = cell(bodyMarkdown, header: false)
        XCTAssertEqual(body, renderer.renderInline(bodyMarkdown))
        XCTAssertLessThan(weight(of: appKitFonts(body)[0]), NSFont.Weight.semibold.rawValue)
    }

    // MARK: - Drawn PDF

    /// What the export actually draws: header text in the semibold face (at
    /// the cell size), body text in the regular one; an italic or code run in
    /// the header is drawn heavier than the same run in the body.
    @MainActor
    func testExportedHeaderIsDrawnSemiboldBodyRegular() throws {
        let size = BlockLayout.Table.cellFontSize
        let semibold = try drawnFonts(reference(.system(size: size, weight: .semibold)))
        let regular = try drawnFonts(reference(.system(size: size)))
        XCTAssertEqual(semibold.count, 1)
        XCTAssertNotEqual(semibold, regular, "reference faces must differ for this test to mean anything")

        XCTAssertEqual(try drawnFonts(Text(cell("Abc", header: true))), semibold, "header cell is semibold")
        XCTAssertEqual(try drawnFonts(Text(cell("Abc", header: false))), regular, "body cell is regular")

        for markup in ["*Abc*", "`Abc`"] {
            let header = try drawnFonts(Text(cell(markup, header: true)))
            let body = try drawnFonts(Text(cell(markup, header: false)))
            XCTAssertEqual(header.count, 1, markup)
            XCTAssertNotEqual(header, body, "\(markup) in the header is raised")
        }
        // The raised italic / code runs are the faces SwiftUI itself picks for
        // a semibold italic / monospaced run, i.e. the slant and the
        // monospacing survived the raise.
        XCTAssertEqual(try drawnFonts(Text(cell("*Abc*", header: true))),
                       try drawnFonts(reference(.system(size: size, weight: .semibold).italic())))
        // Inline code's size has no named constant (the renderer stamps it
        // per run), so the reference takes it from the rendered run itself.
        let codeSize = try XCTUnwrap(renderer.renderInline("`Abc`").runs.first?[
            AttributeScopes.AppKitAttributes.FontAttribute.self]).pointSize
        XCTAssertEqual(try drawnFonts(Text(cell("`Abc`", header: true))),
                       try drawnFonts(reference(.system(size: codeSize, weight: .semibold, design: .monospaced))))
    }

    /// "Abc" in `font`, as a run attribute — the way every cell reaches `Text`.
    /// The colour is explicit like the cells' (theme text colour): without one
    /// `ImageRenderer` drew the text so that no font resource was found for it.
    private func reference(_ font: Font) -> Text {
        var string = AttributedString("Abc")
        string.font = font
        string.foregroundColor = .black
        return Text(string)
    }

    /// `view` drawn by `ImageRenderer` into a one-page PDF (as
    /// `generateMultiPagePDF` draws a block), then the `BaseFont` of every
    /// text-showing operator, in drawing order, subset prefix stripped.
    @MainActor
    private func drawnFonts(_ view: some View) throws -> [String] {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 100)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        ImageRenderer(content: view.fixedSize()).render { _, draw in draw(context) }
        context.endPDFPage()
        context.closePDF()

        let document = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        let page = try XCTUnwrap(document.page(at: 1))
        let scan = FontScan()
        let table = try XCTUnwrap(CGPDFOperatorTableCreate())
        scan.table = table
        CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
            let scan = Unmanaged<FontScan>.fromOpaque(info!).takeUnretainedValue()
            var size: CGPDFReal = 0
            var name: UnsafePointer<CChar>?
            CGPDFScannerPopNumber(scanner, &size)
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            let stream = CGPDFScannerGetContentStream(scanner)
            var font: CGPDFDictionaryRef?
            var base: UnsafePointer<CChar>?
            if let object = CGPDFContentStreamGetResource(stream, "Font", name),
               CGPDFObjectGetValue(object, .dictionary, &font), let font,
               CGPDFDictionaryGetName(font, "BaseFont", &base), let base {
                scan.current = String(cString: base)
            } else {
                scan.current = "?"
            }
        }
        let show: CGPDFOperatorCallback = { _, info in
            let scan = Unmanaged<FontScan>.fromOpaque(info!).takeUnretainedValue()
            scan.drawn.append(scan.current)
        }
        CGPDFOperatorTableSetCallback(table, "Tj", show)
        CGPDFOperatorTableSetCallback(table, "TJ", show)
        // SwiftUI may wrap its drawing in form XObjects: descend into them.
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let scan = Unmanaged<FontScan>.fromOpaque(info!).takeUnretainedValue()
            var name: UnsafePointer<CChar>?
            var stream: CGPDFStreamRef?
            let parent = CGPDFScannerGetContentStream(scanner)
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(parent, "XObject", name),
                  CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            let child = CGPDFContentStreamCreateWithStream(stream, dictionary, parent)
            CGPDFScannerScan(CGPDFScannerCreate(child, scan.table, info))
        }
        let info = Unmanaged.passUnretained(scan).toOpaque()
        CGPDFScannerScan(CGPDFScannerCreate(CGPDFContentStreamCreateWithPage(page), table, info))
        // Subset prefix "ABCDEF+" differs per embedding; the face is the rest.
        return scan.drawn.map { $0.split(separator: "+", maxSplits: 1).last.map(String.init) ?? $0 }
            .reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
    }

    private final class FontScan {
        var current = "?"
        var drawn: [String] = []
        var table: CGPDFOperatorTableRef?
    }
}
