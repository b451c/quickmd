import Foundation

// MARK: - Inline Link / Image Syntax Scanner
//
// ONE scanner for the bracket/paren/destination grammar of Markdown links and
// images, shared by `MarkdownBlockParser` (standalone image lines, and the
// definition-list term predicate) and `MarkdownRenderer` (inline images and
// links). Before it existed the parser matched images with a lazy regex
// (`![a](x.png) ![b](y.png)` became ONE image with url `x.png) ![b](y.png`)
// and the renderer had its own first-`]` / raw-destination scans, so the two
// could disagree about what an image even was.
//
// Why bytes: an image line can hold a multi-megabyte `data:` URL. Every
// delimiter this grammar cares about is ASCII, and in UTF-8 an ASCII byte
// never occurs inside a multi-byte sequence, so the scan runs over the raw
// UTF-8 buffer — once, linearly, no regex, no backtracking, no per-Character
// grapheme breaking — and only the final destination/alt are copied out.

enum InlineSyntaxScanner {

    /// An image recognised at the start of a piece of text.
    struct ImageSyntax: Sendable {
        /// Raw alt text (between the brackets), exactly as written.
        let alt: String
        /// The destination: a parsed inline destination (D8) or the URL of the
        /// reference definition it resolved through (D10).
        let url: String
        /// Index just past the image syntax in the scanned text.
        let end: String.Index
    }

    // MARK: Pair table

    /// Every matching `[`→`]` and `(`→`)` of one text, found in ONE stack pass
    /// over its bytes (escapes respected) and then looked up.
    ///
    /// Why: the renderer tries a link/image at every `[` it meets. Scanning
    /// forward by depth from each one is quadratic when brackets don't close
    /// (`[[a] ` × 20 000 took 11 s). Stack matching gives, for every opener,
    /// exactly the closer a depth scan starting there would find, so lookups
    /// are equivalent — and the whole line costs O(n). Built lazily: most
    /// lines never reach a `[`.
    final class PairTable {
        private let text: String
        private lazy var pairs: (brackets: [Int: Int], parens: [Int: Int]) = Self.build(text)

        /// `text` should be native contiguous UTF-8 (the renderer ensures it);
        /// substrings handed to the scanner later must be slices of it.
        init(_ text: String) { self.text = text }

        fileprivate func lookup(for slice: Substring) -> Lookup {
            Lookup(table: self, base: text.utf8.distance(from: text.startIndex, to: slice.startIndex))
        }
        fileprivate func closingBracket(atAbsolute offset: Int) -> Int? { pairs.brackets[offset] }
        fileprivate func closingParen(atAbsolute offset: Int) -> Int? { pairs.parens[offset] }

        private static func build(_ text: String) -> (brackets: [Int: Int], parens: [Int: Int]) {
            InlineSyntaxScanner.withBytes(text[...]) { bytes in
                var brackets: [Int: Int] = [:], parens: [Int: Int] = [:]
                var openBrackets: [Int] = [], openParens: [Int] = []
                var i = 0
                while i < bytes.count {
                    if isEscape(bytes, at: i, before: bytes.count) { i += 2; continue }
                    switch bytes[i] {
                    case UInt8(ascii: "["): openBrackets.append(i)
                    case UInt8(ascii: "]"): if let open = openBrackets.popLast() { brackets[open] = i }
                    case UInt8(ascii: "("): openParens.append(i)
                    case UInt8(ascii: ")"): if let open = openParens.popLast() { parens[open] = i }
                    default: break
                    }
                    i += 1
                }
                return (brackets, parens)
            }
        }
    }

    /// A pair table seen from a slice: offsets in the slice's byte buffer are
    /// `base` bytes into the table's text.
    fileprivate struct Lookup {
        let table: PairTable
        let base: Int
        func closingBracket(_ open: Int) -> Int? { table.closingBracket(atAbsolute: base + open).map { $0 - base } }
        func closingParen(_ open: Int) -> Int? { table.closingParen(atAbsolute: base + open).map { $0 - base } }
    }

    // MARK: Public API

    /// The link destination inside `( … )`: surrounding whitespace trimmed;
    /// `<…>` → the text between the pointy brackets (spaces allowed).
    /// Otherwise CommonMark's destination-then-title split is applied
    /// LENIENTLY: `dest "title"` / `dest 'title'` / `dest (title)` → `dest`
    /// (title discarded), but when what follows the first space is not exactly
    /// one title, the whole trimmed text is the destination — so
    /// `Screenshot 2024-10-01 at 10.00.00.png`, `My Notes.md` and a base64
    /// payload with spaces keep working as they always did. Backslash escapes
    /// of ASCII punctuation are unescaped.
    static func linkDestination(_ inner: Substring) -> String {
        withBytes(inner) { destination($0, 0..<$0.count) }
    }

    /// For `text` starting with `[`: the index of the `]` that closes it.
    /// Nested brackets count (`[a [b] c]`), backslash-escaped ones (`\[`, `\]`)
    /// do not. Nil when the bracket is never closed. `pairs` (the table of the
    /// text `text` is a suffix of) turns the scan into a lookup.
    static func closingBracket(in text: Substring, pairs: PairTable? = nil) -> String.Index? {
        guard text.utf8.first == UInt8(ascii: "[") else { return nil }
        let lookup = pairs?.lookup(for: text)
        guard let offset = withBytes(text, { matchBracket($0, open: 0, lookup) }) else { return nil }
        return text.utf8.index(text.startIndex, offsetBy: offset)
    }

    /// For `text` starting with `(`: the parsed destination (see
    /// `linkDestination`) and the index just past the matching `)`. The
    /// closing paren is found by paren depth (`Foo_(bar)` keeps its parens),
    /// escaped parens not counted. Nil when the paren is never closed.
    static func parenthesizedDestination(_ text: Substring, pairs: PairTable? = nil) -> (url: String, end: String.Index)? {
        guard text.utf8.first == UInt8(ascii: "(") else { return nil }
        let lookup = pairs?.lookup(for: text)
        guard let found = withBytes(text, { scanParenDestination($0, open: 0, lookup) }) else { return nil }
        return (found.url, text.utf8.index(text.startIndex, offsetBy: found.end))
    }

    /// An image at the very start of `text`: `![alt](dest)`, `![alt][ref]`,
    /// `![alt][]` (collapsed) or `![alt]` (shortcut — only when `alt` names a
    /// definition). Reference ids are looked up lowercased, as links do.
    /// An undefined `[ref]` / `[]` is NOT an image (CommonMark).
    static func image(atStartOf text: Substring, references: [String: String],
                      pairs: PairTable? = nil) -> ImageSyntax? {
        guard text.utf8.starts(with: "![".utf8) else { return nil }
        let lookup = pairs?.lookup(for: text)
        guard let found = withBytes(text, { scanImage($0, from: 0, references: references, lookup) }) else { return nil }
        return ImageSyntax(alt: found.alt, url: found.url,
                           end: text.utf8.index(text.startIndex, offsetBy: found.end))
    }

    /// The images of a standalone image line, in order — or nil when the line
    /// is not one. A standalone image line is, after trimming, ONE OR MORE
    /// images separated only by whitespace (none at all between them is fine,
    /// that is still "nothing but images"). Any other character → nil, so
    /// `![a](x.png) caption` stays paragraph text.
    static func standaloneImages(in line: Substring, references: [String: String]) -> [ImageSyntax]? {
        // Trim with UNICODE whitespace, like the `.whitespaces` trim this
        // replaced (a trailing U+00A0 must not demote an image line). Only the
        // two ends are walked, never the payload.
        let scalars = line.unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
              let last = scalars.lastIndex(where: { !$0.properties.isWhitespace }) else { return nil }
        let trimmed = Substring(scalars[first...last])

        // Cheap reject for the 99 % of lines that aren't images, BEFORE any
        // buffer access (which may have to copy a bridged string).
        guard trimmed.utf8.starts(with: "![".utf8) else { return nil }

        guard let found = withBytes(trimmed, { bytes -> [(alt: String, url: String, end: Int)]? in
            var images: [(alt: String, url: String, end: Int)] = []
            var i = 0
            while i < bytes.count {
                // HTML `<img>` lines are a separate form (`HTMLImageSyntax`,
                // checked by the parser right after this one); the two are
                // not mixed on one line.
                guard let image = scanImage(bytes, from: i, references: references, nil) else { return nil }
                images.append(image)
                i = skipWhitespace(bytes, from: image.end)
            }
            return images.isEmpty ? nil : images
        }) else { return nil }

        return found.map {
            ImageSyntax(alt: $0.alt, url: $0.url, end: trimmed.utf8.index(trimmed.startIndex, offsetBy: $0.end))
        }
    }

    /// `data:` scheme (case-insensitive) — the destination of an embedded
    /// image. Looks at five bytes, never at the payload.
    static func isDataURI(_ url: String) -> Bool {
        var bytes = url.utf8.makeIterator()
        for expected in "data:".utf8 {
            guard let byte = bytes.next() else { return false }
            let lowered = (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) ? byte | 0x20 : byte
            guard lowered == expected else { return false }
        }
        return true
    }

    // MARK: Byte access

    fileprivate typealias Bytes = UnsafeBufferPointer<UInt8>

    /// Runs `body` over the UTF-8 bytes of `text`; offsets in the buffer are
    /// UTF-8 offsets from `text.startIndex`. Native Swift strings hand out
    /// their storage directly; a lazily bridged NSString is copied once.
    fileprivate static func withBytes<R>(_ text: Substring, _ body: (Bytes) -> R) -> R {
        if let result = text.utf8.withContiguousStorageIfAvailable(body) { return result }
        var copy = String(text)
        copy.makeContiguousUTF8()
        return copy.utf8.withContiguousStorageIfAvailable(body)!
    }

    private static let backslash = UInt8(ascii: "\\")

    /// CommonMark whitespace for these purposes: space, tab, LF, VT, FF, CR.
    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }

    /// ASCII punctuation — the only characters a backslash escapes (CommonMark).
    private static func isPunctuation(_ byte: UInt8) -> Bool {
        (byte >= 0x21 && byte <= 0x2F) || (byte >= 0x3A && byte <= 0x40)
            || (byte >= 0x5B && byte <= 0x60) || (byte >= 0x7B && byte <= 0x7E)
    }

    /// Is `bytes[i]` a backslash that escapes the next byte?
    fileprivate static func isEscape(_ bytes: Bytes, at i: Int, before end: Int) -> Bool {
        bytes[i] == backslash && i + 1 < end && isPunctuation(bytes[i + 1])
    }

    private static func skipWhitespace(_ bytes: Bytes, from start: Int) -> Int {
        var i = start
        while i < bytes.count, isWhitespace(bytes[i]) { i += 1 }
        return i
    }

    private static func string(_ bytes: Bytes, _ range: Range<Int>) -> String {
        String(decoding: Bytes(rebasing: bytes[range]), as: UTF8.self)
    }

    // MARK: Scanners

    /// `]` closing the `[` at `open`, by bracket depth, escapes skipped —
    /// or the pair table's answer when there is one.
    private static func matchBracket(_ bytes: Bytes, open: Int, _ lookup: Lookup?) -> Int? {
        if let lookup { return lookup.closingBracket(open).flatMap { $0 < bytes.count ? $0 : nil } }
        var depth = 0
        var i = open
        while i < bytes.count {
            if isEscape(bytes, at: i, before: bytes.count) { i += 2; continue }
            switch bytes[i] {
            case UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "]"):
                depth -= 1
                if depth == 0 { return i }
            default: break
            }
            i += 1
        }
        return nil
    }

    /// A reference label `[ref]` at `open`: the first unescaped `]`. An
    /// unescaped `[` inside makes it not a label (CommonMark), → nil.
    private static func matchLabel(_ bytes: Bytes, open: Int) -> Int? {
        var i = open + 1
        while i < bytes.count {
            if isEscape(bytes, at: i, before: bytes.count) { i += 2; continue }
            switch bytes[i] {
            case UInt8(ascii: "]"): return i
            case UInt8(ascii: "["): return nil
            default: i += 1
            }
        }
        return nil
    }

    /// `( … )` at `open`: destination + offset just past the `)`.
    private static func scanParenDestination(_ bytes: Bytes, open: Int, _ lookup: Lookup?) -> (url: String, end: Int)? {
        if let lookup {
            guard let close = lookup.closingParen(open), close < bytes.count else { return nil }
            return (destination(bytes, (open + 1)..<close), close + 1)
        }
        var depth = 0
        var i = open
        while i < bytes.count {
            if isEscape(bytes, at: i, before: bytes.count) { i += 2; continue }
            switch bytes[i] {
            case UInt8(ascii: "("): depth += 1
            case UInt8(ascii: ")"):
                depth -= 1
                if depth == 0 { return (destination(bytes, (open + 1)..<i), i + 1) }
            default: break
            }
            i += 1
        }
        return nil
    }

    /// D8 — the destination inside the parens (see `linkDestination`).
    private static func destination(_ bytes: Bytes, _ range: Range<Int>) -> String {
        var lo = range.lowerBound
        var hi = range.upperBound
        while lo < hi, isWhitespace(bytes[lo]) { lo += 1 }
        while hi > lo, isWhitespace(bytes[hi - 1]) { hi -= 1 }
        guard lo < hi else { return "" }

        if bytes[lo] == UInt8(ascii: "<") {
            var i = lo + 1
            scan: while i < hi {
                if isEscape(bytes, at: i, before: hi) { i += 2; continue }
                switch bytes[i] {
                case UInt8(ascii: ">"): return unescaped(bytes, (lo + 1)..<i)
                case UInt8(ascii: "<"), 0x0A, 0x0D: break scan
                default: i += 1
                }
            }
            // No valid closing `>`: not the pointy form — fall through and
            // read it as a plain destination (which then starts with `<`).
        }

        var i = lo
        while i < hi, !isWhitespace(bytes[i]) {
            i += isEscape(bytes, at: i, before: hi) ? 2 : 1
        }
        let tokenEnd = min(i, hi)
        // Nothing after the token, or exactly one title → the token. Anything
        // else (`Screenshot 2024-… .png`, a spaced base64 payload) → the whole
        // trimmed text, as before D8.
        if tokenEnd == hi || isSingleTitle(bytes, skipWhitespace(bytes, from: tokenEnd)..<hi) {
            return unescaped(bytes, lo..<tokenEnd)
        }
        return unescaped(bytes, lo..<hi)
    }

    /// Is `range` (trimmed) exactly one link title: `"…"`, `'…'` or `(…)`,
    /// the closing delimiter last, none unescaped inside (and no unescaped
    /// `(` inside the paren form)?
    private static func isSingleTitle(_ bytes: Bytes, _ range: Range<Int>) -> Bool {
        guard range.count >= 2 else { return false }
        let closer: UInt8
        switch bytes[range.lowerBound] {
        case UInt8(ascii: "\""): closer = UInt8(ascii: "\"")
        case UInt8(ascii: "'"): closer = UInt8(ascii: "'")
        case UInt8(ascii: "("): closer = UInt8(ascii: ")")
        default: return false
        }
        let opener = bytes[range.lowerBound]
        var i = range.lowerBound + 1
        while i < range.upperBound {
            if isEscape(bytes, at: i, before: range.upperBound) { i += 2; continue }
            if bytes[i] == closer { return i == range.upperBound - 1 }
            if opener == UInt8(ascii: "("), bytes[i] == opener { return false }
            i += 1
        }
        return false
    }

    /// The bytes as a String with `\<punctuation>` → `<punctuation>`. Other
    /// backslashes stay literal (`C:\dir\x.png`). One copy when there is
    /// nothing to unescape — the common case, and the multi-MB `data:` case.
    private static func unescaped(_ bytes: Bytes, _ range: Range<Int>) -> String {
        let slice = Bytes(rebasing: bytes[range])
        guard slice.contains(backslash) else { return String(decoding: slice, as: UTF8.self) }
        var out: [UInt8] = []
        out.reserveCapacity(slice.count)
        var i = 0
        while i < slice.count {
            if isEscape(slice, at: i, before: slice.count) {
                out.append(slice[i + 1])
                i += 2
            } else {
                out.append(slice[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// An image starting at `start` (`![`), see `image(atStartOf:references:)`.
    private static func scanImage(_ bytes: Bytes, from start: Int, references: [String: String],
                                  _ lookup: Lookup?) -> (alt: String, url: String, end: Int)? {
        guard start + 1 < bytes.count,
              bytes[start] == UInt8(ascii: "!"), bytes[start + 1] == UInt8(ascii: "["),
              let close = matchBracket(bytes, open: start + 1, lookup) else { return nil }
        let altRange = (start + 2)..<close
        let next = close + 1

        // Inline: ![alt](dest "title")
        if next < bytes.count, bytes[next] == UInt8(ascii: "("),
           let inline = scanParenDestination(bytes, open: next, lookup) {
            return (string(bytes, altRange), inline.url, inline.end)
        }

        guard !references.isEmpty else { return nil }

        // Full / collapsed reference: ![alt][ref], ![alt][]
        if next < bytes.count, bytes[next] == UInt8(ascii: "["),
           let labelClose = matchLabel(bytes, open: next) {
            let labelRange = labelClose == next + 1 ? altRange : (next + 1)..<labelClose
            guard let url = references[string(bytes, labelRange).lowercased()] else { return nil }
            return (string(bytes, altRange), url, labelClose + 1)
        }

        // Shortcut reference: ![alt]
        let alt = string(bytes, altRange)
        guard let url = references[alt.lowercased()] else { return nil }
        return (alt, url, next)
    }
}
