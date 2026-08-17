import SwiftUI
import AppKit
import os

// MARK: - Focused Value Keys (multi-window document context)

struct FocusedDocumentTextKey: FocusedValueKey {
    typealias Value = String
}

struct FocusedSearchActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct FocusedToggleToCKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct FocusedCopyDocumentActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct FocusedToggleDocumentListKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct FocusedOpenInExternalEditorKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct FocusedZoomActionKey: FocusedValueKey {
    typealias Value = (MarkdownZoom) -> Void
}

/// File name (without extension) the export save panel should suggest — the
/// focused document's own name, or "document" for an untitled buffer. Published
/// as a non-optional String because the optional `focusedSceneValue(_:_:)`
/// overload is macOS 14+.
struct FocusedExportNameKey: FocusedValueKey {
    typealias Value = String
}

extension FocusedValues {
    var documentText: String? {
        get { self[FocusedDocumentTextKey.self] }
        set { self[FocusedDocumentTextKey.self] = newValue }
    }
    var exportName: String? {
        get { self[FocusedExportNameKey.self] }
        set { self[FocusedExportNameKey.self] = newValue }
    }
    var searchAction: (() -> Void)? {
        get { self[FocusedSearchActionKey.self] }
        set { self[FocusedSearchActionKey.self] = newValue }
    }
    var toggleToCAction: (() -> Void)? {
        get { self[FocusedToggleToCKey.self] }
        set { self[FocusedToggleToCKey.self] = newValue }
    }
    var copyDocumentAction: (() -> Void)? {
        get { self[FocusedCopyDocumentActionKey.self] }
        set { self[FocusedCopyDocumentActionKey.self] = newValue }
    }
    var toggleDocumentListAction: (() -> Void)? {
        get { self[FocusedToggleDocumentListKey.self] }
        set { self[FocusedToggleDocumentListKey.self] = newValue }
    }
    var openInExternalEditorAction: (() -> Void)? {
        get { self[FocusedOpenInExternalEditorKey.self] }
        set { self[FocusedOpenInExternalEditorKey.self] = newValue }
    }
    var zoomAction: ((MarkdownZoom) -> Void)? {
        get { self[FocusedZoomActionKey.self] }
        set { self[FocusedZoomActionKey.self] = newValue }
    }
}

// MARK: - Printable View (Light mode, white background)
// NOTE: ImageRenderer uses DEFAULT environment, not app's environment
// So we must explicitly set ALL colors, not rely on colorScheme

struct MarkdownPrintableView: View {
    let documentText: String

    /// Parsed blocks with light theme - computed once on init
    private let lightBlocks: [MarkdownBlock]

    init(documentText: String) {
        self.documentText = documentText
        self.lightBlocks = MarkdownBlockParser(colorScheme: .light).parse(documentText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(lightBlocks) { block in
                switch block.content {
                case .text(let attributedString):
                    // Force black text color
                    Text(attributedString)
                        .foregroundColor(.black)

                case .table(let headers, let rows, let alignments):
                    PrintableTableView(headers: headers, rows: rows, alignments: alignments)
                        .padding(.vertical, 8)

                case .codeBlock(let code, let language):
                    PrintableCodeBlockView(code: code, language: language)
                        .padding(.vertical, 4)

                case .image(let url, let alt):
                    PrintableImageView(url: url, alt: alt)
                        .padding(.vertical, 8)

                case .blockquote(let content, let level):
                    PrintableBlockquoteView(content: content, level: level)
                        .padding(.vertical, 4)

                case .alert(let kind, let content):
                    PrintableAlertView(kind: kind, content: content)
                        .padding(.vertical, 4)

                case .heading(let level, let title, _):
                    let renderer = MarkdownRenderer(colorScheme: .light)
                    Text(renderer.renderHeader(title, level: level))
                        .foregroundColor(.black)

                case .mathBlock(let latex):
                    MathBlockView(latex: latex, theme: MarkdownTheme.theme(named: ThemeName.auto, colorScheme: .light))
                        .padding(.vertical, 4)

                case .mermaidDiagram(let source):
                    // Graceful degradation: render as styled code block in PDF
                    PrintableCodeBlockView(code: source, language: "mermaid")
                        .padding(.vertical, 4)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
    }
}

// MARK: - Printable Table View

/// Table view optimized for PDF export and printing
/// Uses simple HStack layout (no GeometryReader) for ImageRenderer compatibility
struct PrintableTableView: View, TableAlignmentProvider {
    let headers: [String]
    let rows: [[String]]
    let alignments: [TextAlignment]

    /// Cached renderer instance - created once on init
    private let renderer: MarkdownRenderer

    /// Cached theme instance for consistent colors + the user's document fonts
    private let theme = MarkdownTheme.exportTheme(for: .light)

    /// Stored column count - computed once on init for efficiency
    private let columnCount: Int

    /// Headerless tables (`| | |`) skip the header band entirely
    private let showsHeader: Bool

    init(headers: [String], rows: [[String]], alignments: [TextAlignment]) {
        self.headers = headers
        self.rows = rows
        self.alignments = alignments
        self.renderer = MarkdownRenderer(colorScheme: .light)
        self.columnCount = max(headers.count, alignments.count, rows.map(\.count).max() ?? 0)
        self.showsHeader = headers.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                // Header row
                HStack(spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { index in
                        Text(renderer.renderInline(index < headers.count ? headers[index] : ""))
                            .font(theme.fonts.swiftUI(size: 12, weight: .semibold))
                            .foregroundColor(.black)
                            .multilineTextAlignment(textAlignmentFor(index))
                            .frame(maxWidth: .infinity, alignment: alignmentFor(index))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)

                        if index < columnCount - 1 {
                            Rectangle().fill(theme.borderColor).frame(width: 1)
                        }
                    }
                }
                .background(theme.headerBackgroundColor)

                // Header separator
                Rectangle().fill(theme.borderColor).frame(height: 1)
            }

            // Data rows
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { colIndex in
                        let cell = colIndex < row.count ? row[colIndex] : ""
                        Text(renderer.renderInline(cell))
                            .font(theme.fonts.swiftUI(size: 11))
                            .foregroundColor(.black)
                            .multilineTextAlignment(textAlignmentFor(colIndex))
                            .frame(maxWidth: .infinity, alignment: alignmentFor(colIndex))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)

                        if colIndex < columnCount - 1 {
                            Rectangle().fill(theme.borderColor).frame(width: 1)
                        }
                    }
                }

                if rowIndex < rows.count - 1 {
                    Rectangle().fill(theme.borderColor).frame(height: 1)
                }
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.borderColor, lineWidth: 1))
    }
}

// MARK: - Printable Code Block View

struct PrintableCodeBlockView: View {
    let code: String
    let language: String
    /// User's document fonts (Settings) — code family for the block body.
    private let fonts = MarkdownTheme.exportTheme(for: .light).fonts

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                Text(language)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(white: 0.5))
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }

            Text(code)
                .font(fonts.swiftUI(size: 11, monospaced: true))
                .foregroundColor(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, language.isEmpty ? 10 : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(white: 0.95))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Printable Image View

struct PrintableImageView: View {
    let url: String
    let alt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let imageURL = resolvedURL, let nsImage = loadImage(from: imageURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 500, maxHeight: 700)
            } else {
                HStack {
                    Image(systemName: "photo")
                        .foregroundColor(Color(white: 0.5))
                    Text("Image: \(alt.isEmpty ? url : alt)")
                        .foregroundColor(Color(white: 0.5))
                }
                .font(.system(size: 11))
                .padding(8)
                .background(Color(white: 0.95))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            if !alt.isEmpty {
                Text(alt)
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.5))
                    .italic()
            }
        }
    }

    private var resolvedURL: URL? {
        if url.hasPrefix("http://") || url.hasPrefix("https://") {
            return URL(string: url)
        } else if url.hasPrefix("file://") {
            return URL(string: url)
        } else if url.hasPrefix("/") {
            return URL(fileURLWithPath: url)
        } else {
            return URL(string: url)
        }
    }

    private func loadImage(from url: URL) -> NSImage? {
        // Only load local file images - remote URLs would block main thread
        guard url.isFileURL else { return nil }
        return NSImage(contentsOf: url)
    }
}

// MARK: - Single Block Printable View (for per-block PDF rendering)

struct MarkdownPrintableBlockView: View {
    let block: MarkdownBlock
    /// Pre-rendered Mermaid diagrams keyed by source (MermaidPDFRenderer).
    /// Sources without an entry fall back to the styled-code representation.
    var mermaidImages: [String: NSImage] = [:]
    private let theme = MarkdownTheme.exportTheme(for: .light)
    private let renderer = MarkdownRenderer(colorScheme: .light)

    var body: some View {
        Group {
            switch block.content {
            case .text(let attributedString):
                Text(attributedString)
                    .foregroundColor(.black)

            case .table(let headers, let rows, let alignments):
                PrintableTableView(headers: headers, rows: rows, alignments: alignments)

            case .codeBlock(let code, let language):
                PrintableCodeBlockView(code: code, language: language)

            case .image(let url, let alt):
                PrintableImageView(url: url, alt: alt)

            case .blockquote(let content, let level):
                PrintableBlockquoteView(content: content, level: level)

            case .alert(let kind, let content):
                PrintableAlertView(kind: kind, content: content)

            case .heading(let level, let title, _):
                Text(renderer.renderHeader(title, level: level))
                    .foregroundColor(.black)

            case .mathBlock(let latex):
                MathBlockView(latex: latex, theme: MarkdownTheme.theme(named: ThemeName.auto, colorScheme: .light))

            case .mermaidDiagram(let source):
                if let image = mermaidImages[source] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                } else {
                    // Graceful degradation: styled code block (no snapshot
                    // available within the render budget, or render failed)
                    PrintableCodeBlockView(code: source, language: "mermaid")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
    }
}

// MARK: - Printable Blockquote View

struct PrintableBlockquoteView: View {
    let content: String
    let level: Int
    private let renderer = MarkdownRenderer(colorScheme: .light)

    var body: some View {
        HStack(spacing: 0) {
            // Gray left border bars for each nesting level
            ForEach(0..<level, id: \.self) { _ in
                Rectangle()
                    .fill(Color.gray.opacity(0.4))
                    .frame(width: 3)
                    .padding(.trailing, 8)
            }

            // Same soft-break pre-pass as the on-screen BlockquoteView, so a
            // quote written one sentence per line prints as one paragraph.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(MarkdownRenderer.joinSoftBreaks(content.components(separatedBy: "\n")).enumerated()), id: \.offset) { _, line in
                    if line.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(" ").font(renderer.theme.fonts.swiftUI(size: 12))
                    } else {
                        Text(renderer.renderInline(line))
                            .font(renderer.theme.fonts.swiftUI(size: 12, italic: true))
                            .foregroundColor(Color(white: 0.3))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.96))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Printable Alert View

/// GFM alert for PDF/print — always the light-palette accent, white-page safe.
struct PrintableAlertView: View {
    let kind: AlertKind
    let content: String
    private let renderer = MarkdownRenderer(colorScheme: .light)

    private var accent: Color { kind.accentColor(isDark: false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                Text(kind.title)
                    .font(renderer.theme.fonts.swiftUI(size: 12, weight: .semibold))
            }
            .foregroundColor(accent)

            // Soft breaks joined first — mirrors AlertBlockView on screen.
            ForEach(Array(MarkdownRenderer.joinSoftBreaks(content.components(separatedBy: "\n")).enumerated()), id: \.offset) { _, line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(" ").font(renderer.theme.fonts.swiftUI(size: 12))
                } else {
                    Text(renderer.renderInline(line))
                        .font(renderer.theme.fonts.swiftUI(size: 12))
                        .foregroundColor(Color(white: 0.2))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.06))
        .overlay(alignment: .leading) {
            Rectangle().fill(accent).frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - PDF Export Manager

@MainActor
class PDFExportManager {

    private static let logger = Logger(subsystem: "pl.falami.studio.QuickMD", category: "PDFExport")

    // US Letter dimensions in points
    static let pageWidth: CGFloat = 612
    static let pageHeight: CGFloat = 792
    static let margin: CGFloat = 40
    static let contentWidth: CGFloat = pageWidth - (margin * 2)  // 532
    static let contentHeight: CGFloat = pageHeight - (margin * 2) // 712

    static func exportToPDF(documentText: String, suggestedName: String = "document") {
        guard !documentText.isEmpty else {
            showError("No document content to export")
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = "\(suggestedName).pdf"
        savePanel.title = "Export as PDF"
        savePanel.message = "Choose a location to save the PDF"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            Task { @MainActor in
                // Pre-render Mermaid diagrams (cached inline snapshot or
                // offscreen WebView). Whatever fails within the time budget
                // keeps the styled-code fallback — export never stalls on it.
                let blocks = MarkdownBlockParser(colorScheme: .light).parse(documentText)
                let mermaidSources = blocks.compactMap { block -> String? in
                    if case .mermaidDiagram(let source) = block.content { return source }
                    return nil
                }
                let mermaidImages = await MermaidPDFRenderer.renderAll(
                    sources: mermaidSources, width: contentWidth)

                guard let pdfData = Self.generateMultiPagePDF(blocks: blocks,
                                                              mermaidImages: mermaidImages) else {
                    Self.showError("Failed to generate PDF")
                    return
                }
                do {
                    try pdfData.write(to: url)
                } catch {
                    Self.showError("Failed to save PDF: \(error.localizedDescription)")
                }
            }
        }
    }

    struct BlockSegment {
        let block: MarkdownBlock
        let size: CGSize
        let sliceOffset: CGFloat
        let sliceHeight: CGFloat
    }

    struct PlacedSegment {
        let segment: BlockSegment
        let yOffset: CGFloat
    }

    static func generateMultiPagePDF(documentText: String) -> Data? {
        generateMultiPagePDF(blocks: MarkdownBlockParser(colorScheme: .light).parse(documentText))
    }

    static func generateMultiPagePDF(blocks: [MarkdownBlock],
                                     mermaidImages: [String: NSImage] = [:]) -> Data? {
        guard !blocks.isEmpty else {
            logger.error("No blocks parsed from document")
            return nil
        }

        // Measure each block's size in points
        var measuredBlocks: [(block: MarkdownBlock, size: CGSize)] = []

        for block in blocks {
            let blockView = MarkdownPrintableBlockView(block: block, mermaidImages: mermaidImages)
                .frame(width: contentWidth)
                .fixedSize(horizontal: false, vertical: true)

            let renderer = ImageRenderer(content: blockView)
            renderer.scale = 1.0

            guard let size = renderer.nsImage?.size else {
                continue
            }

            measuredBlocks.append((block: block, size: size))
        }

        guard !measuredBlocks.isEmpty else {
            logger.error("Failed to measure any blocks")
            return nil
        }

        // Paginate: distribute blocks/segments across pages
        var pages: [[PlacedSegment]] = [[]]
        var currentY: CGFloat = 0

        for (block, size) in measuredBlocks {
            let segments = sliceBlockIfOversized(block: block, size: size, maxHeight: contentHeight)
            for segment in segments {
                let blockHeight = segment.sliceHeight

                // If block doesn't fit on current page and page isn't empty, start new page
                if currentY + blockHeight > contentHeight && !pages[pages.count - 1].isEmpty {
                    pages.append([])
                    currentY = 0
                }

                pages[pages.count - 1].append(PlacedSegment(segment: segment, yOffset: currentY))
                currentY += blockHeight + 8  // 8pt spacing between blocks
            }
        }

        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        guard let consumer = CGDataConsumer(data: pdfData),
              let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            logger.error("Failed to create PDF context")
            return nil
        }

        // Render each page to the PDF context
        for pageSegments in pages {
            pdfContext.beginPDFPage(nil)

            // Draw white background
            pdfContext.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            pdfContext.fill(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

            // Draw each placed segment using the vector renderer
            for placed in pageSegments {
                let segment = placed.segment
                let blockView = MarkdownPrintableBlockView(block: segment.block, mermaidImages: mermaidImages)
                    .frame(width: contentWidth)
                    .fixedSize(horizontal: false, vertical: true)

                let renderer = ImageRenderer(content: blockView)
                renderer.render { size, renderInContext in
                    pdfContext.saveGState()

                    // Calculate drawing position and clip bounds in PDF coordinates
                    let pdfY = pageHeight - margin - placed.yOffset - segment.sliceHeight
                    let clipRect = CGRect(x: margin, y: pdfY, width: contentWidth, height: segment.sliceHeight)
                    pdfContext.clip(to: clipRect)

                    // Translate the context so the SwiftUI view draws upright (ImageRenderer handles vertical flip internally)
                    let translationY = pageHeight - margin - placed.yOffset - size.height + segment.sliceOffset
                    pdfContext.translateBy(x: margin, y: translationY)

                    // Draw the view vector commands directly into the PDF context
                    renderInContext(pdfContext)

                    pdfContext.restoreGState()
                }
            }

            pdfContext.endPDFPage()
        }

        pdfContext.closePDF()
        return pdfData as Data
    }

    private static func sliceBlockIfOversized(block: MarkdownBlock, size: CGSize, maxHeight: CGFloat) -> [BlockSegment] {
        guard size.height > maxHeight, size.height > 0 else {
            return [BlockSegment(block: block, size: size, sliceOffset: 0, sliceHeight: size.height)]
        }

        var segments: [BlockSegment] = []
        var offset: CGFloat = 0
        while offset < size.height {
            let sliceHeight = min(maxHeight, size.height - offset)
            segments.append(BlockSegment(
                block: block,
                size: size,
                sliceOffset: offset,
                sliceHeight: sliceHeight
            ))
            offset += sliceHeight
        }
        return segments
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Export Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Print Manager (uses PDFDocument.printOperation for reliable printing)

import PDFKit

@MainActor
class PrintManager {

    static func printDocument(documentText: String) {
        guard !documentText.isEmpty else { return }

        // Use the same multi-page PDF generation as export
        guard let pdfData = PDFExportManager.generateMultiPagePDF(documentText: documentText) else {
            showError("Failed to render document for printing")
            return
        }

        // Create PDFDocument from data
        guard let pdfDocument = PDFDocument(data: pdfData) else {
            showError("Failed to create PDF for printing")
            return
        }

        // Use PDFDocument's native print operation
        guard let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo else { return }
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        printInfo.isHorizontallyCentered = true
        printInfo.topMargin = 0
        printInfo.bottomMargin = 0
        printInfo.leftMargin = 0
        printInfo.rightMargin = 0

        guard let printOperation = pdfDocument.printOperation(
            for: printInfo,
            scalingMode: .pageScaleNone,
            autoRotate: false
        ) else {
            showError("Failed to create print operation")
            return
        }

        printOperation.showsPrintPanel = true
        printOperation.showsProgressPanel = true
        if let window = NSApp.keyWindow {
            printOperation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            printOperation.run()
        }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Print Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Menu Commands

struct ExportPDFCommand: View {
    @FocusedValue(\.documentText) private var documentText
    @FocusedValue(\.exportName) private var exportName

    var body: some View {
        Button("Export as PDF\u{2026}") {
            if let text = documentText {
                PDFExportManager.exportToPDF(documentText: text, suggestedName: exportName ?? "document")
            }
        }
        .disabled(documentText?.isEmpty ?? true)
        .keyboardShortcut("e", modifiers: [.command, .shift])
    }
}

struct PrintCommand: View {
    @FocusedValue(\.documentText) private var documentText

    var body: some View {
        Button("Print\u{2026}") {
            if let text = documentText {
                PrintManager.printDocument(documentText: text)
            }
        }
        .disabled(documentText?.isEmpty ?? true)
        .keyboardShortcut("p", modifiers: .command)
    }
}
