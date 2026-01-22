import SwiftUI
import AppKit

// MARK: - Export State Manager (Shared state for menu commands)

@MainActor
class ExportStateManager: ObservableObject {
    static let shared = ExportStateManager()

    @Published var currentBlocks: [MarkdownBlock] = []
    @Published var currentDocumentText: String = ""

    private init() {}

    var hasContent: Bool {
        !currentBlocks.isEmpty
    }
}

// MARK: - Printable View (Light mode, white background)
// NOTE: ImageRenderer uses DEFAULT environment, not app's environment
// So we must explicitly set ALL colors, not rely on colorScheme

struct MarkdownPrintableView: View {
    let blocks: [MarkdownBlock]
    let documentText: String

    // Re-parse with light theme for proper colors
    private var lightBlocks: [MarkdownBlock] {
        MarkdownBlockParser(colorScheme: .light).parse(documentText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(lightBlocks) { block in
                switch block {
                case .text(_, let attributedString):
                    // Force black text color
                    Text(attributedString)
                        .foregroundColor(.black)

                case .table(_, let headers, let rows, let alignments):
                    PrintableTableView(headers: headers, rows: rows, alignments: alignments)
                        .padding(.vertical, 8)

                case .codeBlock(_, let code, let language):
                    PrintableCodeBlockView(code: code, language: language)
                        .padding(.vertical, 4)

                case .image(_, let url, let alt):
                    PrintableImageView(url: url, alt: alt)
                        .padding(.vertical, 8)
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

    private var columnCount: Int { headers.count }
    private let borderColor = Color.gray.opacity(0.3)

    init(headers: [String], rows: [[String]], alignments: [TextAlignment]) {
        self.headers = headers
        self.rows = rows
        self.alignments = alignments
        self.renderer = MarkdownRenderer(colorScheme: .light)
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
                        Rectangle().fill(borderColor).frame(width: 1)
                    }
                }
            }
            .background(Color.gray.opacity(0.15))

            // Header separator
            Rectangle().fill(borderColor).frame(height: 1)

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
                            Rectangle().fill(borderColor).frame(width: 1)
                        }
                    }
                }

                if rowIndex < rows.count - 1 {
                    Rectangle().fill(borderColor).frame(height: 1)
                }
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(borderColor, lineWidth: 1))
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
                    .frame(maxWidth: 500)
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
        if url.isFileURL {
            return NSImage(contentsOf: url)
        }
        if let data = try? Data(contentsOf: url) {
            return NSImage(data: data)
        }
        return nil
    }
}

// MARK: - PDF Export Manager

@MainActor
class PDFExportManager {

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
                if let pdfData = Self.generateMultiPagePDF(documentText: documentText) {
                    do {
                        try pdfData.write(to: url)
                    } catch {
                        Self.showError("Failed to save PDF: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    static func generateMultiPagePDF(documentText: String) -> Data? {
        let blocks = MarkdownBlockParser(colorScheme: .light).parse(documentText)

        // Create view - simple, with explicit size
        let printableView = MarkdownPrintableView(blocks: blocks, documentText: documentText)
            .frame(width: contentWidth)
            .fixedSize(horizontal: false, vertical: true)

        let renderer = ImageRenderer(content: printableView)
        renderer.scale = 1.0

        // Get the rendered size first
        guard let testImage = renderer.nsImage else {
            return nil
        }
        let contentSize = testImage.size

        // Calculate pages
        let totalHeight = contentSize.height
        let pageCount = max(1, Int(ceil(totalHeight / contentHeight)))

        // Get NSImage from renderer
        guard let fullImage = renderer.nsImage else {
            return nil
        }

        // Create PDF data
        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        guard let consumer = CGDataConsumer(data: pdfData),
              let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return nil
        }

        // Get CGImage for drawing
        guard let cgImage = fullImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        for pageIndex in 0..<pageCount {
            pdfContext.beginPDFPage(nil)

            // White background
            pdfContext.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            pdfContext.fill(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

            pdfContext.saveGState()

            // Clip to content area
            pdfContext.clip(to: CGRect(x: margin, y: margin, width: contentWidth, height: contentHeight))

            // Calculate which portion of the image to show
            let yOffset = CGFloat(pageIndex) * contentHeight

            // Draw the full image, positioned so the correct portion shows in the clip area
            // In PDF coordinates, Y=0 is at bottom, so we need to position the image
            // such that the portion we want appears in the content area
            let imageRect = CGRect(
                x: margin,
                y: margin + contentHeight - totalHeight + yOffset,
                width: contentWidth,
                height: totalHeight
            )

            pdfContext.draw(cgImage, in: imageRect)

            pdfContext.restoreGState()
            pdfContext.endPDFPage()
        }

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
        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
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
        printOperation.run()
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
    @ObservedObject private var exportState = ExportStateManager.shared

    var body: some View {
        Button("Export as PDF...") {
            PDFExportManager.exportToPDF(documentText: exportState.currentDocumentText)
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(!exportState.hasContent)
    }
}

struct PrintCommand: View {
    @ObservedObject private var exportState = ExportStateManager.shared

    var body: some View {
        Button("Print...") {
            PrintManager.printDocument(documentText: exportState.currentDocumentText)
        }
        .keyboardShortcut("p", modifiers: .command)
        .disabled(!exportState.hasContent)
    }
}
