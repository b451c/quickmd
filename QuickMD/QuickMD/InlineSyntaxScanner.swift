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

        /// Two linear passes. Parens first, everywhere (a destination is not
        /// code). Then brackets, skipping code spans (code spans outrank
        /// brackets) and the destination after a `](` — the renderer consumes
        /// it as the link's, so a backtick in a URL (`[a](u`x) [b](v)`) must
        /// not open a "span" that swallows a later link's `[`.
        private static func build(_ text: String) -> (brackets: [Int: Int], parens: [Int: Int]) {
            InlineSyntaxScanner.withBytes(text[...]) { bytes in
                var brackets: [Int: Int] = [:]
                let parens = pairParens(bytes)
                var openBrackets: [Int] = []
                var codeSpans = CodeSpanScanner()
                var i = 0
                while i < bytes.count {
                    if isEscape(bytes, at: i, before: bytes.count) { i += 2; continue }
                    if bytes[i] == backtick, let end = codeSpans.end(bytes, at: i) {
                        i = end
                        continue
                    }
                    switch bytes[i] {
                    case UInt8(ascii: "["): openBrackets.append(i)
                    case UInt8(ascii: "]"):
                        if let open = openBrackets.popLast() {
                            brackets[open] = i
                            if i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "("), let close = parens[i + 1] {
                                i = close + 1
                                continue
                            }
                        }
                    default: break
                    }
                    i += 1
                }
                return (brackets, parens)
            }
        }
    }

    /// Every `(` → its `)`, one stack pass, escapes respected — exactly the
    /// closer a depth scan from that `(` finds (`scanParenDestination`).
    fileprivate static func pairParens(_ bytes: Bytes) -> [Int: Int] {
        var parens: [Int: Int] = [:]
        var open: [Int] = []
        var i = 0
        while i < bytes.count {
            if isEscape(bytes, at: i, before: bytes.count) { i += 2; continue }
            switch bytes[i] {
            case UInt8(ascii: "("): open.append(i)
            case UInt8(ascii: ")"): if let start = open.popLast() { parens[start] = i }
            default: break
            }
            i += 1
        }
        return parens
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

    /// One picture of an image-only line (`imageOnlyLine`).
    struct LineImage: Sendable {
        /// Raw alt text, exactly as written.
        let alt: String
        /// The image destination (or its reference definition's URL).
        let url: String
        /// The link around it — `[![alt](img)](dest)` or a reference form —
        /// as written (inline destination parsed, reference resolved); nil
        /// for a plain image.
        let link: String?
        /// Whitespace between this picture and the one before it on the
        /// line (false for the first).
        let spaceBefore: Bool
    }

    /// The pictures of a line that is nothing but images, plain and/or
    /// linked, separated by whitespace or nothing — or nil for any other
    /// line. A plain image is any form `image(atStartOf:)` takes; a linked
    /// one is any link form `MarkdownRenderer.tryParseLink` accepts
    /// (`[![a](x)](url)`, `[![a][x]][site]`, `[![a][x]][]`, `[![a][x]]`)
    /// around exactly ONE image, spaces inside the brackets allowed. Text,
    /// two images in one link or a link that does not resolve → nil (the
    /// line is paragraph text, as before). The parser decides whether the
    /// line's paragraph is images only (`MarkdownBlockParser.imageParagraph`).
    ///
    /// One pair table per line: linear in the line's length (a `data:` line
    /// can be megabytes).
    static func imageOnlyLine(_ line: Substring, references: [String: String]) -> [LineImage]? {
        let scalars = line.unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
              let last = scalars.lastIndex(where: { !$0.properties.isWhitespace }) else { return nil }
        // Cheap reject before any copy: most lines are not this.
        let trimmed = Substring(scalars[first...last])
        guard trimmed.utf8.starts(with: "![".utf8) || trimmed.utf8.starts(with: "[![".utf8) else { return nil }
        let text = String(trimmed)
        let pairs = PairTable(text)
        var images: [LineImage] = []
        var index = text.startIndex
        var spaceBefore = false
        while index < text.endIndex {
            let rest = text[index...]
            let found: (alt: String, url: String, link: String?, end: String.Index)?
            if rest.utf8.starts(with: "![".utf8) {
                found = image(atStartOf: rest, references: references, pairs: pairs)
                    .map { ($0.alt, $0.url, nil, $0.end) }
            } else if rest.utf8.starts(with: "[![".utf8) {
                found = linkedImage(atStartOf: rest, in: text, references: references, pairs: pairs)
            } else {
                found = nil
            }
            guard let found else { return nil }
            images.append(LineImage(alt: found.alt, url: found.url, link: found.link,
                                    spaceBefore: !images.isEmpty && spaceBefore))
            index = found.end
            let afterSpace = text[index...].unicodeScalars.firstIndex { !isWhitespaceScalar($0) } ?? text.endIndex
            spaceBefore = afterSpace > index
            index = afterSpace
        }
        return images.isEmpty ? nil : images
    }

    /// CommonMark whitespace (`isWhitespace(_: UInt8)`) as a scalar.
    private static func isWhitespaceScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && isWhitespace(UInt8(scalar.value))
    }

    /// `[![alt](img)]` + a link destination or reference at the start of
    /// `rest` (a suffix of `text`, which `pairs` was built for), by
    /// `tryParseLink`'s rules: the link text is exactly one image, spaces
    /// around it allowed; a reference link must resolve.
    private static func linkedImage(atStartOf rest: Substring, in text: String, references: [String: String],
                                    pairs: PairTable) -> (alt: String, url: String, link: String?, end: String.Index)? {
        guard let close = closingBracket(in: rest, pairs: pairs) else { return nil }
        let linkText = text[text.index(after: rest.startIndex)..<close]
        let innerStart = linkText.firstIndex { !$0.isWhitespace } ?? linkText.endIndex
        guard let image = self.image(atStartOf: linkText[innerStart...], references: references, pairs: pairs),
              linkText[image.end...].allSatisfy(\.isWhitespace) else { return nil }

        let after = text[text.index(after: close)...]
        if after.hasPrefix("(") {
            guard let destination = parenthesizedDestination(after, pairs: pairs) else { return nil }
            return (image.alt, image.url, destination.url, destination.end)
        }
        if after.hasPrefix("[") {
            guard let labelClose = ReferenceLabel.closingBracket(in: after, from: after.index(after: after.startIndex))
            else { return nil }
            let label = String(after[after.index(after: after.startIndex)..<labelClose])
            guard let link = references[ReferenceLabel.normalized(label.isEmpty ? String(linkText) : label)]
            else { return nil }
            return (image.alt, image.url, link, text.index(after: labelClose))
        }
        guard let link = references[ReferenceLabel.normalized(linkText)] else { return nil }
        return (image.alt, image.url, link, after.startIndex)
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
    private static let backtick = UInt8(ascii: "`")

    /// Where `MarkdownRenderer.tryParseInlineCode` would end a code span
    /// starting at a backtick — so bracket matching skips what the renderer
    /// will draw as code (CommonMark: code spans outrank brackets;
    /// `[a `](` b](u)` is a link whose text holds the code "](").
    /// Its rules exactly: a run of 1 or 2 backticks closes at the FIRST later
    /// occurrence of that many backticks (a 2-run whose closer is followed by
    /// a third backtick opens nothing); a run of 3+ is literal and skipped
    /// whole. No span → nil (the caller moves on one byte, as the renderer
    /// moves on one character). A search that found no closer is remembered
    /// per run length, so many unclosed backticks stay linear.
    fileprivate struct CodeSpanScanner {
        private var noCloserAfter: [Int: Int] = [:]  // run length → offset searched from

        mutating func end(_ bytes: Bytes, at start: Int) -> Int? {
            var run = 0
            while start + run < bytes.count, bytes[start + run] == backtick { run += 1 }
            if run > 2 { return start + run }
            if let from = noCloserAfter[run], from <= start + run { return nil }
            var i = start + run
            while i + run <= bytes.count {
                if bytes[i] == backtick, run == 1 || bytes[i + 1] == backtick {
                    if run == 2, i + 2 < bytes.count, bytes[i + 2] == backtick { return nil }
                    return i + run
                }
                i += 1
            }
            noCloserAfter[run] = start + run
            return nil
        }
    }
    private static let ampersand = UInt8(ascii: "&")

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
        var codeSpans = CodeSpanScanner()
        /// Built on the first inner `](` only: a depth scan per `](` that
        /// never closes went to the end of the line each time (quadratic on
        /// `![x` + `[a](` × N, review round 7).
        var parens: [Int: Int]?
        while i < bytes.count {
            if isEscape(bytes, at: i, before: bytes.count) { i += 2; continue }
            if bytes[i] == backtick, let end = codeSpans.end(bytes, at: i) { i = end; continue }
            switch bytes[i] {
            case UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "]"):
                depth -= 1
                if depth == 0 { return i }
                // An inner link's destination is not scanned for code spans
                // (see `PairTable.build`).
                if i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "(") {
                    if parens == nil { parens = pairParens(bytes) }
                    if let close = parens?[i + 1] {
                        i = close + 1
                        continue
                    }
                }
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
    /// A destination's text: backslash escapes of ASCII punctuation removed
    /// and character references decoded (`a?b=1&amp;c=2` → `a?b=1&c=2`, as
    /// CommonMark and GitHub read a link's href) — but not the `&` of an
    /// escaped `\&`. One pass over the bytes when there is neither.
    private static func unescaped(_ bytes: Bytes, _ range: Range<Int>) -> String {
        let slice = Bytes(rebasing: bytes[range])
        guard slice.contains(where: { $0 == backslash || $0 == ampersand }) else {
            return String(decoding: slice, as: UTF8.self)
        }
        var out = ""
        var run: [UInt8] = []
        func flushRun() {
            guard !run.isEmpty else { return }
            out += HTMLEntities.decode(String(decoding: run, as: UTF8.self))
            run.removeAll(keepingCapacity: true)
        }
        var i = 0
        while i < slice.count {
            if isEscape(slice, at: i, before: slice.count) {
                flushRun()
                out += String(decoding: [slice[i + 1]], as: UTF8.self)
                i += 2
            } else {
                run.append(slice[i])
                i += 1
            }
        }
        flushRun()
        return out
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
            guard let url = references[ReferenceLabel.normalized(string(bytes, labelRange))] else { return nil }
            return (string(bytes, altRange), url, labelClose + 1)
        }

        // Shortcut reference: ![alt]
        let alt = string(bytes, altRange)
        guard let url = references[ReferenceLabel.normalized(alt)] else { return nil }
        return (alt, url, next)
    }
}
