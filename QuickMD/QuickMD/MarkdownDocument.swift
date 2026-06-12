import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var markdown: UTType {
        UTType(importedAs: "net.daringfireball.markdown")
    }
}

struct MarkdownDocument: FileDocument, Sendable {
    var text: String

    static var readableContentTypes: [UTType] { [.markdown, .plainText] }

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = Self.decode(data)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = Self.normalizeLineEndings(string)
    }

    /// Decode file data: UTF-8 first (also covers plain ASCII), then UTF-16
    /// when a byte-order mark is present (common for files saved by Windows
    /// editors), then Latin-1 as a lossless last resort so legacy text files
    /// still open instead of failing with a corrupt-file error.
    static func decode(_ data: Data) -> String? {
        if let string = String(data: data, encoding: .utf8) {
            return string
        }
        if data.count >= 2 {
            let b0 = data[data.startIndex]
            let b1 = data[data.index(after: data.startIndex)]
            let hasUTF16BOM = (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF)
            if hasUTF16BOM, let string = String(data: data, encoding: .utf16) {
                return string
            }
        }
        return String(data: data, encoding: .isoLatin1)
    }

    /// The parser, the Mermaid bridge, and section extraction all assume LF
    /// line endings. Normalize once at the document boundary: CRLF (Windows)
    /// and lone CR (classic Mac) both become LF. Without this, `\r` survives
    /// `trimmingCharacters(in: .whitespaces)` and breaks suffix checks like
    /// the single-line `$$...$$` math detection.
    static func normalizeLineEndings(_ string: String) -> String {
        // NOTE: the scalar view is load-bearing. Swift treats "\r\n" as ONE
        // grapheme cluster, so both `contains("\r")` (Character comparison)
        // and `range(of: "\r")` (must land on a Character boundary) report
        // false for a pure-CRLF file and would skip normalization entirely.
        guard string.unicodeScalars.contains("\r") else { return string }
        return string
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return .init(regularFileWithContents: data)
    }
}
