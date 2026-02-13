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

extension FocusedValues {
    var documentText: String? {
        get { self[FocusedDocumentTextKey.self] }
        set { self[FocusedDocumentTextKey.self] = newValue }
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

                case .heading(let level, let title):
                    let renderer = MarkdownRenderer(colorScheme: .light)
                    Text(renderer.renderHeader(title, level: level))
                        .foregroundColor(.black)
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

    /// Cached theme instance for consistent colors
    private let theme = MarkdownTheme.cached(for: .light)

    /// Stored column count - computed once on init for efficiency
    private let columnCount: Int

    init(headers: [String], rows: [[String]], alignments: [TextAlignment]) {
        self.headers = headers
        self.rows = rows
        self.alignments = alignments
        self.renderer = MarkdownRenderer(colorScheme: .light)
        self.columnCount = headers.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                ForEach(0..<columnCount, id: \.self) { index in
                    Text(renderer.renderInline(headers[index]))
                        .font(.system(size: 12, weight: .semibold))
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

            // Data rows
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { colIndex in
                        let cell = colIndex < row.count ? row[colIndex] : ""
                        Text(renderer.renderInline(cell))
                            .font(.system(size: 11))
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
                .font(.system(size: 11, design: .monospaced))
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
    private let theme = MarkdownTheme.cached(for: .light)
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

            case .heading(let level, let title):
                Text(renderer.renderHeader(title, level: level))
                    .foregroundColor(.black)
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

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(content.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    if line.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(" ").font(.system(size: 12))
                    } else {
                        Text(renderer.renderInline(line))
                            .font(.system(size: 12).italic())
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
                guard let pdfData = Self.generateMultiPagePDF(documentText: documentText) else {
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

    static func generateMultiPagePDF(documentText: String) -> Data? {
        let blocks = MarkdownBlockParser(colorScheme: .light).parse(documentText)
        guard !blocks.isEmpty else {
            logger.error("No blocks parsed from document")
            return nil
        }

        // Render each block to an image
        var blockImages: [(image: CGImage, size: CGSize)] = []

        for block in blocks {
            let blockView = MarkdownPrintableBlockView(block: block)
                .frame(width: contentWidth)
                .fixedSize(horizontal: false, vertical: true)

            let renderer = ImageRenderer(content: blockView)
            renderer.scale = 1.0

            guard let nsImage = renderer.nsImage,
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                continue
            }

            blockImages.append((image: cgImage, size: nsImage.size))
        }

        guard !blockImages.isEmpty else {
            logger.error("Failed to render any blocks")
            return nil
        }

        // Paginate: distribute blocks across pages
        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        guard let consumer = CGDataConsumer(data: pdfData),
              let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            logger.error("Failed to create PDF context")
            return nil
        }

        var currentY: CGFloat = 0  // Accumulated height on current page (from top)
        var pageBlocks: [(image: CGImage, size: CGSize, yOffset: CGFloat)] = []

        func flushPage() {
            guard !pageBlocks.isEmpty else { return }
            pdfContext.beginPDFPage(nil)

            // White background
            pdfContext.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            pdfContext.fill(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

            // Draw each block on this page
            // PDF Y=0 is at bottom, so we invert
            for entry in pageBlocks {
                let pdfY = pageHeight - margin - entry.yOffset - entry.size.height
                let rect = CGRect(x: margin, y: pdfY, width: entry.size.width, height: entry.size.height)
                pdfContext.draw(entry.image, in: rect)
            }

            pdfContext.endPDFPage()
            pageBlocks = []
            currentY = 0
        }

        for (image, size) in blockImages {
            let blockHeight = size.height

            // If block doesn't fit on current page and page isn't empty, start new page
            if currentY + blockHeight > contentHeight && !pageBlocks.isEmpty {
                flushPage()
            }

            pageBlocks.append((image: image, size: size, yOffset: currentY))
            currentY += blockHeight + 4  // 4pt spacing between blocks (matches LazyVStack spacing)
        }

        // Flush last page
        flushPage()

        pdfContext.closePDF()
        return pdfData as Data
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

    var body: some View {
        Button("Export as PDF\u{2026}") {
            if let text = documentText {
                PDFExportManager.exportToPDF(documentText: text)
            }
        }
        .disabled(documentText == nil || documentText!.isEmpty)
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
        .disabled(documentText == nil || documentText!.isEmpty)
        .keyboardShortcut("p", modifiers: .command)
    }
}
