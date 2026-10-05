import Foundation

/// How a text file is stored on disk: encoding, byte-order mark, line ending.
///
/// Source Edit (v1.12) writes the user's fix back IN the file's own format, so
/// a one-character edit produces a one-character diff — never a re-encoded or
/// re-terminated file. The invariant (pinned per fixture in
/// `DocumentFileFormatTests`): for a file with uniform line endings,
/// `encode(normalizeLineEndings(decode(bytes))) == bytes`.
///
/// Pure value type, no actor isolation (the CI SDK is older — see constraints).
struct DocumentFileFormat: Equatable, Sendable {

    /// The encodings `MarkdownDocument.decode` can produce. UTF-16 only ever
    /// comes from a file with a BOM, so its byte order is always known.
    enum Encoding: Equatable, Sendable {
        case utf8
        case utf16LittleEndian
        case utf16BigEndian
        case isoLatin1

        /// The Foundation encoding, e.g. for `String.localizedName(of:)` in
        /// the "cannot store some of the characters" prompt.
        var stringEncoding: String.Encoding {
            switch self {
            case .utf8: return .utf8
            case .utf16LittleEndian: return .utf16LittleEndian
            case .utf16BigEndian: return .utf16BigEndian
            case .isoLatin1: return .isoLatin1
            }
        }

        var byteOrderMark: Data {
            switch self {
            case .utf8: return Data([0xEF, 0xBB, 0xBF])
            case .utf16LittleEndian: return Data([0xFF, 0xFE])
            case .utf16BigEndian: return Data([0xFE, 0xFF])
            case .isoLatin1: return Data()
            }
        }
    }

    enum LineEnding: String, Equatable, Sendable {
        case lf = "\n"
        case crlf = "\r\n"
        case cr = "\r"
    }

    /// Fresh file bytes, read once: the format to write back AND the
    /// LF-normalized text the editor starts from. Returned together so the
    /// decoding, BOM handling and normalization behind both can never drift.
    struct Decoded: Equatable, Sendable {
        let format: DocumentFileFormat
        let text: String
        /// More than one line-ending style in the file. Saving writes them
        /// all as `format.lineEnding` — the one accepted, documented way a
        /// save may change bytes the user did not touch.
        let hasMixedLineEndings: Bool
        /// Saving the unchanged text would reproduce the file byte for byte
        /// (`format.encode(text) == data`). False when the decoder repaired
        /// or dropped something (odd-length UTF-16, …) or the line endings
        /// are mixed; the edit session refuses to edit in the first case
        /// rather than silently rewrite bytes the user never saw.
        let isByteExact: Bool
        /// The decoded text, BEFORE line-ending normalization, re-encodes to
        /// exactly the file's bytes (with the BOM): nothing was repaired or
        /// dropped. Unlike `isByteExact` this ignores line endings, so it
        /// tells "mixed line endings" (true — saving only unifies them) apart
        /// from "mixed AND repaired by the decoder" (false). The edit session
        /// refuses exactly when this is false.
        let isLosslessDecode: Bool
    }

    var encoding: Encoding
    /// True for UTF-8 files that start with EF BB BF, and always for UTF-16
    /// (it is only detected with a BOM, and is written back with one).
    var hasBOM: Bool
    var lineEnding: LineEnding

    /// The single entry point for the edit session. Reuses
    /// `MarkdownDocument.decodeDetectingEncoding` (the viewer's own decoder,
    /// which decodes past the BOM) and `normalizeLineEndings`. Nil only when
    /// `decode` would be nil too.
    static func decode(_ data: Data) -> Decoded? {
        guard let decoded = MarkdownDocument.decodeDetectingEncoding(data) else { return nil }
        let raw = decoded.text
        let encoding: Encoding
        let hasBOM: Bool
        switch decoded.encoding {
        case .utf16LittleEndian:
            encoding = .utf16LittleEndian
            hasBOM = true
        case .utf16BigEndian:
            encoding = .utf16BigEndian
            hasBOM = true
        case .isoLatin1:
            encoding = .isoLatin1
            hasBOM = false
        case .utf8:
            encoding = .utf8
            hasBOM = data.starts(with: Encoding.utf8.byteOrderMark)
        default:
            assertionFailure("decodeDetectingEncoding returned \(decoded.encoding)")
            encoding = .utf8
            hasBOM = data.starts(with: Encoding.utf8.byteOrderMark)
        }
        let counts = LineEndingCounts(raw)
        let format = DocumentFileFormat(encoding: encoding, hasBOM: hasBOM, lineEnding: counts.dominant)
        let text = MarkdownDocument.normalizeLineEndings(raw)
        // Two extra encodes per edit session (≤ 2 MB) — cheap insurance.
        // `.lf` passes the raw text through, line endings and all.
        let asRead = DocumentFileFormat(encoding: encoding, hasBOM: hasBOM, lineEnding: .lf)
        return Decoded(format: format, text: text,
                       hasMixedLineEndings: counts.isMixed,
                       isByteExact: format.encode(text) == data,
                       isLosslessDecode: asRead.encode(raw) == data)
    }

    /// Mixed files get the dominant style; ties and break-free text get LF
    /// (VS Code's policy).
    static func dominantLineEnding(in text: String) -> LineEnding {
        LineEndingCounts(text).dominant
    }

    /// Line breaks counted on the NOT yet normalized text. The scalar view is
    /// load-bearing: "\r\n" is one Character, so a Character scan would never
    /// see its "\r" (constraints: "Line endings normalized ONCE"). Only CR and
    /// LF count — U+0085, U+2028 and U+2029 are content, exactly as
    /// `normalizeLineEndings` (and the parser) treat them.
    private struct LineEndingCounts {
        var lf = 0, crlf = 0, cr = 0

        init(_ text: String) {
            var pendingCR = false
            for scalar in text.unicodeScalars {
                if pendingCR {
                    pendingCR = false
                    if scalar == "\n" {
                        crlf += 1
                        continue
                    }
                    cr += 1
                }
                if scalar == "\r" {
                    pendingCR = true
                } else if scalar == "\n" {
                    lf += 1
                }
            }
            if pendingCR { cr += 1 }
        }

        var dominant: LineEnding {
            if crlf > lf && crlf > cr { return .crlf }
            if cr > lf && cr > crlf { return .cr }
            return .lf
        }

        var isMixed: Bool { [lf, crlf, cr].filter { $0 > 0 }.count > 1 }
    }

    /// LF-normalized text → file bytes: LF becomes the file's line ending,
    /// then encode, then the BOM. Nil when the encoding cannot represent the
    /// text (a Latin-1 file and "ł") — the caller offers `utf8Fallback`.
    /// Trailing newlines and trailing whitespace pass through untouched.
    func encode(_ text: String) -> Data? {
        let terminated = lineEnding == .lf
            ? text
            : text.replacingOccurrences(of: "\n", with: lineEnding.rawValue)
        let body: Data
        if encoding == .utf8 {
            body = Data(terminated.utf8)
        } else {
            guard let encoded = terminated.data(using: encoding.stringEncoding,
                                                allowLossyConversion: false) else {
                return nil
            }
            body = encoded
        }
        return hasBOM ? encoding.byteOrderMark + body : body
    }

    /// "Save as UTF-8": UTF-8 without a BOM, keeping the line ending — the
    /// only thing that changes is what had to.
    var utf8Fallback: DocumentFileFormat {
        DocumentFileFormat(encoding: .utf8, hasBOM: false, lineEnding: lineEnding)
    }
}
