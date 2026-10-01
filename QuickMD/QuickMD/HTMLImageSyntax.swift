import Foundation

// MARK: - HTML <img> Lines (v1.11 T-C)
//
// READMEs centre their logos with raw HTML:
//
//     <p align="center">
//       <img src="logo.png" width="200" alt="Logo">
//     </p>
//
// QuickMD never renders HTML (no WebKit for document content), so before this
// every such line was literal text. This scanner recognises exactly one narrow
// shape: a line that, after trimming, is NOTHING BUT `<img>` tags and a fixed
// set of layout wrapper tags, separated by whitespace or no-break spaces.
// Each `<img>` becomes an ordinary `.image` block (same `ImageSource`/
// `ImageLoader` path as a Markdown image); a line of wrappers alone produces
// no block at all. Any other HTML — another tag name,
// text next to a tag, an `<img>` inside a paragraph — is not recognised and
// stays literal text, exactly as before.
//
// The tag grammar follows CommonMark's raw-HTML definitions (tag names
// `[A-Za-z][A-Za-z0-9-]*`, attribute names `[A-Za-z_:][A-Za-z0-9_.:-]*`,
// double/single-quoted or unquoted values), case-insensitive.
//
// Why bytes: an `<img src="data:…">` line can be megabytes. Every delimiter
// here is ASCII, so the scan runs once over the UTF-8 buffer (no regex, no
// backtracking), and a line that does not START with `<` is rejected before
// its buffer is touched at all.

enum HTMLImageSyntax {

    /// One `<img>` tag of a recognised line.
    struct Tag: Sendable, Equatable {
        /// `src`, entities decoded, surrounding whitespace trimmed. Never empty.
        let url: String
        /// `alt`, entities decoded, whitespace runs collapsed ("" when absent).
        let alt: String
        /// `width` when it is one of the understood forms (see `width(from:)`).
        let width: ImageWidth?
        /// Line breaks between the start of the scanned text and this tag's
        /// `<` — the parser maps it to the line the tag STARTS on, which is
        /// the block's `sourceLine` (a multi-line tag is scanned joined).
        let lineOffset: Int
    }

    enum LineScan: Equatable {
        /// Nothing but recognised tags and whitespace. `images` is EMPTY for a
        /// wrapper-only line (`<p align="center">`, `</p>`, …);
        /// `lineBreakOnly` is true when that line is nothing but `<br>` tags —
        /// the parser turns it into a hard break of the paragraph above.
        case tags(images: [Tag], lineBreakOnly: Bool)
        /// Recognised tags so far, then the text ends INSIDE an `<img` tag
        /// (no closing `>` yet): the parser may join following lines and scan
        /// again. Any other unterminated tag is simply not recognised.
        case unterminatedImage
    }

    /// Wrapper tags that may surround or sit next to `<img>` and are dropped.
    /// Opening forms may carry attributes (`<p align="center">`, `<a href=…>`,
    /// `<source srcset=…>`). `<a href>` is ignored for now: clicking the image
    /// keeps opening the preview.
    private static let openingWrappers: Set<String> = ["p", "div", "center", "a", "picture", "source", "br"]
    private static let closingWrappers: Set<String> = ["p", "div", "center", "a", "picture"]

    /// Classifies a line (or several joined with `\n`), see `LineScan`. Nil
    /// when the text is anything else — including an empty or blank line.
    static func scan(_ line: Substring) -> LineScan? {
        // Unicode-whitespace trim like `InlineSyntaxScanner.standaloneImages`;
        // only the two ends are walked.
        let scalars = line.unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
              let last = scalars.lastIndex(where: { !$0.properties.isWhitespace }) else { return nil }
        let trimmed = Substring(scalars[first...last])
        // Cheap reject for every non-HTML line, BEFORE any buffer access
        // (which may have to copy a bridged multi-MB string).
        guard trimmed.utf8.first == UInt8(ascii: "<") else { return nil }
        return withBytes(trimmed) { scanTags($0) }
    }

    /// `width` attribute → `ImageWidth`: `120` / `120px` → 120 pt at 100 %
    /// zoom; `50%` → half the column cap. Decimals are accepted; zero,
    /// negative, empty or any other unit/garbage → nil (the attribute is
    /// ignored and the image's own width applies, like a Markdown image).
    static func width(from raw: String) -> ImageWidth? {
        var text = Substring(raw.trimmingCharacters(in: .whitespaces))
        var isPercent = false
        if text.hasSuffix("%") {
            isPercent = true
            text = text.dropLast()
        } else if text.lowercased().hasSuffix("px") {
            text = text.dropLast(2)
        }
        // Digits with at most one decimal point — `Double("1e3")`, "inf",
        // "0x10" and friends must not slip through.
        guard !text.isEmpty,
              text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              text.filter({ $0 == "." }).count <= 1,
              let value = Double(text), value > 0 else { return nil }
        return isPercent ? .fraction(CGFloat(value / 100)) : .points(CGFloat(value))
    }

    /// Decodes the character references an attribute value realistically
    /// carries: `&amp;` `&lt;` `&gt;` `&quot;` `&apos;` and numeric `&#NN;` /
    /// `&#xNN;`. Anything else (unknown names, invalid code points, a bare
    /// `&`) is kept literally. One linear pass; no `&` → the input unchanged.
    static func decodeEntities(_ text: String) -> String {
        guard text.utf8.contains(UInt8(ascii: "&")) else { return text }
        var out = String.UnicodeScalarView()
        let scalars = text.unicodeScalars
        var i = scalars.startIndex
        while i < scalars.endIndex {
            if scalars[i] == "&", let (decoded, next) = entity(in: scalars, at: i) {
                out.append(decoded)
                i = next
            } else {
                out.append(scalars[i])
                i = scalars.index(after: i)
            }
        }
        return String(out)
    }

    // MARK: Entities

    /// The reference starting at `start` (an `&`): its scalar and the index
    /// past the `;`. Names are at most a few characters, so the look-ahead is
    /// bounded — never a scan over a payload.
    private static func entity(in scalars: String.UnicodeScalarView,
                               at start: String.Index) -> (Unicode.Scalar, String.Index)? {
        var body = ""
        var i = scalars.index(after: start)
        while i < scalars.endIndex, body.unicodeScalars.count <= 10 {
            let scalar = scalars[i]
            if scalar == ";" {
                guard let decoded = decodeEntityBody(body) else { return nil }
                return (decoded, scalars.index(after: i))
            }
            body.unicodeScalars.append(scalar)
            i = scalars.index(after: i)
        }
        return nil
    }

    private static func decodeEntityBody(_ body: String) -> Unicode.Scalar? {
        switch body {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        // A real U+00A0: `alt` collapses it to a space with other whitespace;
        // between tags `skipSeparators` treats it as whitespace.
        case "nbsp": return "\u{00A0}"
        default: break
        }
        guard body.hasPrefix("#") else { return nil }
        let digits = body.dropFirst()
        let value: UInt32?
        if digits.first == "x" || digits.first == "X" {
            let hex = digits.dropFirst()
            value = hex.isEmpty || !hex.allSatisfy(\.isHexDigit) ? nil : UInt32(hex, radix: 16)
        } else {
            value = digits.isEmpty || !digits.allSatisfy({ $0.isASCII && $0.isNumber }) ? nil : UInt32(digits)
        }
        // U+0000 is not a character a URL or caption may contain.
        guard let value, value != 0 else { return nil }
        return Unicode.Scalar(value)
    }

    // MARK: Byte access

    private typealias Bytes = UnsafeBufferPointer<UInt8>

    /// Same contract as `InlineSyntaxScanner.withBytes`: native strings hand
    /// out their storage, a bridged NSString is copied once.
    private static func withBytes<R>(_ text: Substring, _ body: (Bytes) -> R) -> R {
        if let result = text.utf8.withContiguousStorageIfAvailable(body) { return result }
        var copy = String(text)
        copy.makeContiguousUTF8()
        return copy.utf8.withContiguousStorageIfAvailable(body)!
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static func string(_ bytes: Bytes, _ range: Range<Int>) -> String {
        String(decoding: Bytes(rebasing: bytes[range]), as: UTF8.self)
    }

    // MARK: Scanner

    /// Raw attribute values of one `<img>` (first occurrence wins, as in HTML).
    private struct ImageAttributes {
        var src: Range<Int>?
        var alt: Range<Int>?
        var width: Range<Int>?
    }

    private enum TagResult {
        case wrapper(end: Int, isLineBreak: Bool)
        case image(ImageAttributes, end: Int)
        /// The text ended inside an `<img` tag.
        case unterminatedImage
        case invalid
    }

    private static func scanTags(_ bytes: Bytes) -> LineScan? {
        var images: [Tag] = []
        var i = 0
        // Line breaks are counted incrementally up to each tag start, so the
        // whole scan stays linear.
        var newlines = 0
        var counted = 0
        var onlyLineBreaks = true
        while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "<") else { return nil }
            while counted < i {
                if bytes[counted] == 0x0A { newlines += 1 }
                counted += 1
            }
            switch scanTag(bytes, at: i) {
            case .invalid:
                return nil
            case .unterminatedImage:
                return .unterminatedImage
            case .wrapper(let end, let isLineBreak):
                onlyLineBreaks = onlyLineBreaks && isLineBreak
                i = end
            case .image(let attributes, let end):
                guard let tag = makeTag(bytes, attributes, lineOffset: newlines) else { return nil }
                images.append(tag)
                i = end
            }
            i = skipSeparators(bytes, from: i)
        }
        return .tags(images: images, lineBreakOnly: images.isEmpty && onlyLineBreaks)
    }

    /// What may sit BETWEEN (or after) tags: ASCII whitespace, a literal
    /// U+00A0 (UTF-8 `C2 A0`), and the no-break-space references `&nbsp;`,
    /// `&#160;`, `&#xA0;` — the README logo row `<img …>&nbsp;<img …>`.
    private static func skipSeparators(_ bytes: Bytes, from start: Int) -> Int {
        var i = start
        while i < bytes.count {
            if isWhitespace(bytes[i]) { i += 1; continue }
            if bytes[i] == 0xC2, i + 1 < bytes.count, bytes[i + 1] == 0xA0 { i += 2; continue }
            if bytes[i] == UInt8(ascii: "&"), let length = nbspReferenceLength(bytes, at: i) { i += length; continue }
            break
        }
        return i
    }

    private static let nbspReferences: [[UInt8]] = ["&nbsp;", "&#160;", "&#xA0;", "&#xa0;", "&#Xa0;", "&#XA0;"]
        .map { Array($0.utf8) }

    private static func nbspReferenceLength(_ bytes: Bytes, at start: Int) -> Int? {
        for reference in nbspReferences where start + reference.count <= bytes.count {
            if bytes[start..<(start + reference.count)].elementsEqual(reference) { return reference.count }
        }
        return nil
    }

    /// An `<img>` without a usable `src` is not an image: the whole line then
    /// stays text (the conservative reading — it is HTML we cannot show).
    private static func makeTag(_ bytes: Bytes, _ attributes: ImageAttributes, lineOffset: Int) -> Tag? {
        guard let srcRange = attributes.src else { return nil }
        let url = decodeEntities(string(bytes, srcRange)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        let alt = attributes.alt.map {
            decodeEntities(string(bytes, $0))
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
        } ?? ""
        let width = attributes.width.flatMap { self.width(from: decodeEntities(string(bytes, $0))) }
        return Tag(url: url, alt: alt, width: width, lineOffset: lineOffset)
    }

    /// One tag starting at `start` (a `<`).
    private static func scanTag(_ bytes: Bytes, at start: Int) -> TagResult {
        var i = start + 1
        let isClosing = i < bytes.count && bytes[i] == UInt8(ascii: "/")
        if isClosing { i += 1 }

        let nameStart = i
        guard i < bytes.count, isLetter(bytes[i]) else { return .invalid }
        while i < bytes.count, isLetter(bytes[i]) || isDigit(bytes[i]) || bytes[i] == UInt8(ascii: "-") { i += 1 }
        let name = string(bytes, nameStart..<i).lowercased()

        if isClosing {
            guard closingWrappers.contains(name) else { return .invalid }
            while i < bytes.count, isWhitespace(bytes[i]) { i += 1 }
            guard i < bytes.count, bytes[i] == UInt8(ascii: ">") else { return .invalid }
            return .wrapper(end: i + 1, isLineBreak: false)
        }

        let isImage = name == "img"
        guard isImage || openingWrappers.contains(name) else { return .invalid }
        // Running off the end is only interesting for `<img`: the parser
        // joins the following lines and tries again.
        let unterminated: TagResult = isImage ? .unterminatedImage : .invalid
        var attributes = ImageAttributes()

        while true {
            let gapStart = i
            while i < bytes.count, isWhitespace(bytes[i]) { i += 1 }
            guard i < bytes.count else { return unterminated }

            if bytes[i] == UInt8(ascii: ">") {
                i += 1
                break
            }
            if bytes[i] == UInt8(ascii: "/") {
                guard i + 1 < bytes.count else { return unterminated }
                guard bytes[i + 1] == UInt8(ascii: ">") else { return .invalid }
                i += 2
                break
            }
            // Attributes are separated from the name and from each other by
            // whitespace (`<img"x">` / `<imgsrc=…>` are not tags).
            guard i > gapStart else { return .invalid }

            // Attribute name: [A-Za-z_:][A-Za-z0-9_.:-]*
            let attrStart = i
            guard isLetter(bytes[i]) || bytes[i] == UInt8(ascii: "_") || bytes[i] == UInt8(ascii: ":") else {
                return .invalid
            }
            while i < bytes.count, isLetter(bytes[i]) || isDigit(bytes[i])
                    || bytes[i] == UInt8(ascii: "_") || bytes[i] == UInt8(ascii: ".")
                    || bytes[i] == UInt8(ascii: ":") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            let attrEnd = i

            // Optional `= value` (whitespace allowed around `=`).
            var probe = i
            while probe < bytes.count, isWhitespace(bytes[probe]) { probe += 1 }
            var value: Range<Int>?
            if probe < bytes.count, bytes[probe] == UInt8(ascii: "=") {
                i = probe + 1
                while i < bytes.count, isWhitespace(bytes[i]) { i += 1 }
                guard i < bytes.count else { return unterminated }
                let quote = bytes[i]
                if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
                    var close = i + 1
                    while close < bytes.count, bytes[close] != quote { close += 1 }
                    guard close < bytes.count else { return unterminated }
                    value = (i + 1)..<close
                    i = close + 1
                } else {
                    // Unquoted: no whitespace, `"`, `'`, `=`, `<`, `>` or backtick.
                    let valueStart = i
                    while i < bytes.count, !isWhitespace(bytes[i]), !isForbiddenUnquoted(bytes[i]) { i += 1 }
                    guard i > valueStart else { return .invalid }
                    value = valueStart..<i
                }
            }

            // Compared in place (no String per attribute): a tag can carry
            // thousands of attributes. height, class, style, … are ignored
            // (the aspect ratio is kept).
            if isImage {
                let name = attrStart..<attrEnd
                let present = value ?? (attrEnd..<attrEnd)
                if attributes.src == nil, equalsLowercased(bytes, name, "src") {
                    attributes.src = present
                } else if attributes.alt == nil, equalsLowercased(bytes, name, "alt") {
                    attributes.alt = present
                } else if attributes.width == nil, equalsLowercased(bytes, name, "width") {
                    attributes.width = present
                }
            }
        }

        return isImage ? .image(attributes, end: i) : .wrapper(end: i, isLineBreak: name == "br")
    }

    /// ASCII case-insensitive `bytes[range] == name` (`name` is lowercase).
    private static func equalsLowercased(_ bytes: Bytes, _ range: Range<Int>, _ name: StaticString) -> Bool {
        guard range.count == name.utf8CodeUnitCount else { return false }
        let expected = UnsafeBufferPointer(start: name.utf8Start, count: name.utf8CodeUnitCount)
        for (offset, byte) in expected.enumerated() where (bytes[range.lowerBound + offset] | 0x20) != byte {
            return false
        }
        return true
    }

    private static func isForbiddenUnquoted(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: "="),
             UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: "`"):
            return true
        default:
            return false
        }
    }
}
