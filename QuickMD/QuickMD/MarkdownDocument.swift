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
        decodeDetectingEncoding(data)?.text
    }

    /// `decode` plus the encoding that produced the text — UTF-16 reported
    /// with its byte order (taken from the BOM). This is the ONE place that
    /// decides how a file is read: `DocumentFileFormat` derives the encoding
    /// it writes back from here, so viewing and saving can never disagree.
    ///
    /// The BOM is detected on the BYTES and only the rest is decoded, so the
    /// text never carries it no matter what Foundation does (`encode` re-adds
    /// it from `hasBOM`), and a U+FEFF right after the BOM stays content.
    static func decodeDetectingEncoding(_ data: Data) -> (text: String, encoding: String.Encoding)? {
        if data.starts(with: utf8BOM) {
            // Not `String(data:encoding: .utf8)`: it strips a BOM from the
            // remainder too, so EF BB BF EF BB BF would lose three bytes on a
            // round trip. Strict stdlib decode: invalid bytes would come back
            // as U+FFFD, i.e. not byte-equal, and fall through to Latin-1.
            let body = data.dropFirst(utf8BOM.count)
            let string = String(decoding: body, as: UTF8.self)
            if string.utf8.elementsEqual(body) {
                return (string, .utf8)
            }
        } else if let string = String(data: data, encoding: .utf8) {
            return (string, .utf8)
        }
        if data.count >= 2 {
            let b0 = data[data.startIndex]
            let b1 = data[data.index(after: data.startIndex)]
            let encoding: String.Encoding?
            switch (b0, b1) {
            case (0xFF, 0xFE): encoding = .utf16LittleEndian
            case (0xFE, 0xFF): encoding = .utf16BigEndian
            default: encoding = nil
            }
            // The byte-order-specific encodings keep a leading U+FEFF as text.
            if let encoding, let string = String(data: data.dropFirst(2), encoding: encoding) {
                return (string, encoding)
            }
        }
        guard let string = String(data: data, encoding: .isoLatin1) else { return nil }
        return (string, .isoLatin1)
    }

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

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
