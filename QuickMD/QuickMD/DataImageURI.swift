//
//  DataImageURI.swift
//  QuickMD
//
//  `data:` URLs (RFC 2397) as image sources (#32). Documents exported from
//  note apps and LLM tools embed pictures as multi-megabyte base64 strings;
//  before this type existed the image block handed such a string to
//  `URL(string:)`/`AsyncImage`, failed, and printed the raw payload in its
//  placeholder — megabytes of base64 in the window and in the PDF.
//
//  Everything here is pure Foundation and works on the parser's String
//  storage without copying it: the payload stays a `Substring`, the byte
//  count is an index distance on the UTF-8 view (O(1) for native strings), and
//  the payload is only walked when the image is actually decoded, off-main.
//  Kept out of the view files so the unit-test target, which compiles model
//  files but no views, can exercise it.
//

import Foundation

struct DataImageURI: Sendable {
    enum Failure: Error, Equatable {
        /// The encoded payload exceeds the cap — rejected before any decoding.
        case tooLarge
        /// Not valid base64 / percent-encoding, or decodes to nothing.
        case undecodable
        /// The media type is not `image/*` (RFC 2397's default is `text/plain`).
        case notAnImage
    }

    /// 64 MiB of ENCODED payload. A document carrying more than that inline is
    /// pathological. Decoding holds, besides the parser's string, a cleaned
    /// copy of the payload plus the decoded bytes — about 1.75× the encoded
    /// size in transient memory for base64, up to 2× for percent-encoding.
    static let maxEncodedBytes = 64 * 1024 * 1024

    /// A header longer than this (everything between `data:` and the first
    /// comma) is not a media type with a few parameters — it is a malformed
    /// URL whose "header" would be payload. Refusing it keeps payload bytes out
    /// of `mediaType` and therefore out of `displayLabel`.
    static let maxHeaderBytes = 1024

    /// Lowercased media type without parameters, e.g. `image/png`; `text/plain`
    /// when the URL omits it (RFC 2397).
    let mediaType: String
    let isBase64: Bool
    /// The text after the first comma — a slice of the caller's string, never
    /// copied until `decodeData` walks it.
    let payload: Substring
    /// UTF-8 byte count of the encoded payload, computed once at parse time
    /// from index positions (O(1) on native strings — no walk over megabytes).
    let encodedByteCount: Int

    var isImage: Bool { mediaType.hasPrefix("image/") }

    /// True when `raw` starts with the `data:` scheme (case-insensitive). Looks
    /// at five bytes only, so it is safe on a multi-megabyte string.
    static func hasDataScheme<S: StringProtocol>(_ raw: S) -> Bool {
        let scheme = Array("data:".utf8)
        var iterator = raw.utf8.makeIterator()
        for expected in scheme {
            guard let byte = iterator.next(), lowercasedASCII(byte) == expected else { return false }
        }
        return true
    }

    /// `data:[<mediatype>][;params][;base64],<payload>` → parts, or nil when the
    /// scheme is not `data:` or there is no comma within the header limit.
    /// Splits at the FIRST comma: commas inside the payload (legal in the
    /// percent-encoded form) belong to the payload.
    static func parse(_ raw: String) -> DataImageURI? {
        parse(raw[...])
    }

    /// Same, on a slice — `ImageSource.resolve` hands over the destination
    /// with surrounding whitespace / `<…>` removed WITHOUT copying the
    /// multi-megabyte string; the payload stays a slice of the parser's storage.
    static func parse(_ raw: Substring) -> DataImageURI? {
        guard hasDataScheme(raw) else { return nil }
        let utf8 = raw.utf8
        let headerStart = utf8.index(utf8.startIndex, offsetBy: 5)
        let searchEnd = utf8.index(headerStart, offsetBy: maxHeaderBytes + 1,
                                   limitedBy: utf8.endIndex) ?? utf8.endIndex
        guard let comma = utf8[headerStart..<searchEnd].firstIndex(of: UInt8(ascii: ",")) else {
            return nil
        }

        let header = String(raw[headerStart..<comma])
        let parts = header.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let declared = parts.first ?? ""
        let mediaType = declared.isEmpty ? "text/plain" : declared
        // RFC 2397 puts `base64` last; accepting it anywhere among the
        // parameters costs nothing and matches what browsers tolerate.
        let isBase64 = parts.dropFirst().contains("base64")

        let payloadStart = utf8.index(after: comma)
        let payload = raw[payloadStart...]
        return DataImageURI(mediaType: mediaType,
                            isBase64: isBase64,
                            payload: payload,
                            encodedByteCount: utf8.distance(from: payloadStart, to: utf8.endIndex))
    }

    /// The decoded bytes. The size cap is checked first, against the encoded
    /// count, so an oversized payload is rejected without touching it.
    func decodeData(maxEncodedBytes: Int = DataImageURI.maxEncodedBytes) -> Result<Data, Failure> {
        guard isImage else { return .failure(.notAnImage) }
        guard encodedByteCount <= maxEncodedBytes else { return .failure(.tooLarge) }
        let decoded = isBase64 ? Self.decodeBase64(payload) : Self.percentDecode(payload)
        guard let decoded, !decoded.isEmpty else { return .failure(.undecodable) }
        return .success(decoded)
    }

    /// "embedded JPEG image, 1.4 MB". Built only from the header (sanitised)
    /// and the byte count, so no payload text can reach a placeholder, a PDF
    /// or an alert through it.
    var displayLabel: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(estimatedDecodedByteCount),
                                             countStyle: .file)
        guard isImage else { return "embedded non-image data, \(size)" }
        let subtype = mediaType.dropFirst("image/".count)
            .split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        let clean = subtype.filter { allowed.contains($0) }
        guard !clean.isEmpty, clean.count <= 20, clean.count == subtype.count else {
            return "embedded image, \(size)"
        }
        return "embedded \(clean.uppercased()) image, \(size)"
    }

    /// Base64 encodes 3 bytes in 4 characters; percent-encoding is reported at
    /// its encoded size (an upper bound — good enough for a label).
    private var estimatedDecodedByteCount: Int {
        isBase64 ? encodedByteCount / 4 * 3 : encodedByteCount
    }

    // MARK: - Decoding

    /// Standard and base64url alphabets, any whitespace or line breaks inside
    /// the payload (Markdown authors wrap long lines), missing `=` padding.
    /// Unknown characters are dropped, as `.ignoreUnknownCharacters` would.
    /// The cleaned text is written straight into one `Data` (sized for the
    /// payload + padding, then shrunk) — no intermediate array and no second
    /// full-size copy before `Data(base64Encoded:)`.
    private static func decodeBase64(_ payload: Substring) -> Data? {
        var cleaned = Data(count: payload.utf8.count + 3)
        var count = 0
        cleaned.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            withBytes(of: payload) { bytes in
                for byte in bytes {
                    let mapped: UInt8
                    switch byte {
                    case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                         UInt8(ascii: "a")...UInt8(ascii: "z"),
                         UInt8(ascii: "0")...UInt8(ascii: "9"),
                         UInt8(ascii: "+"), UInt8(ascii: "/"):
                        mapped = byte
                    case UInt8(ascii: "-"):
                        mapped = UInt8(ascii: "+")
                    case UInt8(ascii: "_"):
                        mapped = UInt8(ascii: "/")
                    default:
                        continue  // whitespace, '=' (re-added below), anything unknown
                    }
                    out[count] = mapped
                    count += 1
                }
            }
            // A single dangling sextet cannot encode a byte — no padding fixes
            // it (checked by the caller below); otherwise pad to a quantum.
            if count % 4 != 1 {
                while count % 4 != 0 {
                    out[count] = UInt8(ascii: "=")
                    count += 1
                }
            }
        }
        guard count % 4 != 1 else { return nil }
        cleaned.count = count
        return Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters)
    }

    /// `%XX` → the byte XX, everything else verbatim — straight to BYTES, not
    /// through a String, because the payload may be binary. `+` stays `+`
    /// (that substitution belongs to form encoding, not URLs). A `%` not
    /// followed by two hex digits is kept literally, as browsers do.
    private static func percentDecode(_ payload: Substring) -> Data? {
        // Decoding never grows the text, so one buffer of the encoded size,
        // shrunk afterwards, holds the result without a second copy.
        var decoded = Data(count: payload.utf8.count)
        var written = 0
        decoded.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            withBytes(of: payload) { bytes in
                var index = 0
                while index < bytes.count {
                    let byte = bytes[index]
                    if byte == UInt8(ascii: "%"), index + 2 < bytes.count,
                       let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                        out[written] = high << 4 | low
                        index += 3
                    } else {
                        out[written] = byte
                        index += 1
                    }
                    written += 1
                }
            }
        }
        decoded.count = written
        return decoded
    }

    /// Contiguous access to the parser's UTF-8 storage when there is one
    /// (always, for native strings) — a per-byte walk over megabytes through
    /// the generic `UTF8View` iterator is several times slower in Debug.
    private static func withBytes(of payload: Substring, _ body: (UnsafeBufferPointer<UInt8>) -> Void) {
        let handled: Void? = payload.utf8.withContiguousStorageIfAvailable { body($0) }
        if handled == nil {
            Array(payload.utf8).withUnsafeBufferPointer { body($0) }
        }
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    private static func lowercasedASCII(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
    }
}
