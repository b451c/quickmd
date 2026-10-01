//
//  ImageLoader.swift
//  QuickMD
//
//  One loading path for every image source a Markdown image can name — a
//  local file, an http(s) URL or an inline `data:` URL (#32) — shared by the
//  on-screen block (`ImageBlockView`), the click-to-enlarge preview and the
//  print/PDF path (`PrintableImageView`).
//
//  Why one loader instead of the previous three code paths:
//  - Remote images used SwiftUI `AsyncImage`, which never downsampled, kept
//    nothing across row re-creation (NSTableView cell reuse resets `@State`,
//    so every scroll-back re-downloaded and flashed the placeholder) and
//    cannot decode SVG — and shields.io badges are SVG.
//  - `data:` URLs were not handled at all.
//  - PDF export loaded only absolute file paths, so relative images (the
//    common case) always printed as a placeholder.
//
//  Decoding happens off the main thread for on-screen images; the main thread
//  only ever does a cache lookup. Kept out of the view files (AppKit is fine,
//  as in `SVGImageDecoder`) so the unit-test target can compile it.
//

import AppKit
import ImageIO

// MARK: - Image source

/// Where an image URL from the document points. Resolution is pure — no I/O —
/// so it is cheap enough to run in a view's `init` on every body evaluation.
enum ImageSource: Sendable {
    case file(URL)
    case remote(URL)
    case data(DataImageURI)

    /// Order matters: `data:` first (a payload may contain anything, including
    /// "http://"), then the network schemes, then file URLs and paths.
    ///
    /// Paths are CommonMark link destinations, i.e. URLs: `a%20b.png` names the
    /// file "a b.png", so `%XX` escapes are decoded here. A file literally
    /// called `a%20b.png` is still found — `ImageLoader.fileCandidates` adds
    /// the undecoded path as a fallback.
    ///
    /// Defensive against what the parser may hand over (`![]( data:…)`,
    /// `![](<data:…>)`): classification runs on `normalized(raw)`, a slice —
    /// never a copy — of the string. Without it such a `data:` URL fell
    /// through to the path branch, i.e. `removingPercentEncoding` +
    /// `appendingPathComponent` over megabytes on the main thread (~50 ms per
    /// row init). For the same reason the non-`data:` branches refuse strings
    /// no real path or URL is that long.
    static func resolve(_ raw: String, documentURL: URL?) -> ImageSource? {
        let trimmed = normalized(raw)
        if DataImageURI.hasDataScheme(trimmed) {
            return DataImageURI.parse(trimmed).map { .data($0) }
        }
        let byteCount = trimmed.utf8.count
        if hasASCIIPrefix(trimmed, "http://") || hasASCIIPrefix(trimmed, "https://") {
            guard byteCount <= maxURLBytes else { return nil }
            return URL(string: String(trimmed)).map { .remote($0) }
        }
        guard byteCount <= maxPathBytes else { return nil }
        let destination = String(trimmed)
        if hasASCIIPrefix(destination, "file://") {
            guard let url = URL(string: destination), url.isFileURL else { return nil }
            return .file(url)
        }
        let path = destination.removingPercentEncoding ?? destination
        if destination.hasPrefix("/") {
            return .file(URL(fileURLWithPath: path))
        }
        guard let documentURL else { return nil }
        return .file(documentURL.deletingLastPathComponent().appendingPathComponent(path))
    }

    /// No file path is longer than this (PATH_MAX is 1024 on macOS; 4096 leaves
    /// room for percent-escapes).
    static let maxPathBytes = 4096
    /// Remote URLs get more room (signed CDN URLs run to a few KB), still far
    /// below anything that would make `URL(string:)` a measurable cost.
    static let maxURLBytes = 32 * 1024

    /// The destination with ASCII whitespace trimmed (at most 64 bytes per
    /// side, so a payload that ENDS in megabytes of whitespace is not walked)
    /// and one surrounding `<…>` pair removed. O(1) in the string's length;
    /// the result is a slice of `raw`'s storage.
    static func normalized(_ raw: String) -> Substring {
        let utf8 = raw.utf8
        var start = utf8.startIndex
        var end = utf8.endIndex
        var steps = 0
        while start < end, steps < 64, isASCIIWhitespace(utf8[start]) {
            start = utf8.index(after: start)
            steps += 1
        }
        steps = 0
        while start < end, steps < 64, isASCIIWhitespace(utf8[utf8.index(before: end)]) {
            end = utf8.index(before: end)
            steps += 1
        }
        if start < end, utf8[start] == UInt8(ascii: "<"),
           utf8[utf8.index(before: end)] == UInt8(ascii: ">"),
           utf8.index(after: start) < end {
            start = utf8.index(after: start)
            end = utf8.index(before: end)
        }
        return raw[start..<end]
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    /// Case-insensitive ASCII prefix test over the first `prefix.utf8.count`
    /// bytes only — `raw` may be a multi-megabyte `data:` string.
    static func hasASCIIPrefix<S: StringProtocol>(_ raw: S, _ prefix: String) -> Bool {
        var iterator = raw.utf8.makeIterator()
        for expected in prefix.utf8 {
            guard let byte = iterator.next() else { return false }
            let lower = (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
            guard lower == expected else { return false }
        }
        return true
    }
}

// MARK: - Failures

enum ImageLoadFailure: Error, Equatable {
    /// No file at the resolved path (nor at the undecoded fallback).
    case notFound
    /// The file exists but could not be loaded — usually the sandbox. Carries
    /// the file that exists, so the view can ask for access to ITS folder.
    case unreadable(URL)
    /// Bytes arrived but are not an image ImageIO or CoreSVG can draw.
    case undecodable
    /// `data:` payload or remote response over the 64 MiB cap.
    case tooLarge
    /// A `data:` URL whose media type is not `image/*`.
    case notAnImage
    /// Transport error or a non-2xx HTTP status.
    case network
}

// MARK: - Loader

enum ImageLoader {
    /// On-screen tier: 2× the 600 pt column cap. Cached.
    static let displayMaxPixel = 1200
    /// Print/PDF tier. Cached separately — `generateMultiPagePDF` renders every
    /// block twice (measure, then draw), so the second pass is a cache hit.
    static let printMaxPixel = 2000
    /// Click-to-enlarge tier. Deliberately NOT cached: one image at a time,
    /// up to 64 MB of bitmap each.
    static let previewMaxPixel = 4096
    /// Same cap as `DataImageURI.maxEncodedBytes`, for remote responses.
    static let maxRemoteBytes = 64 * 1024 * 1024

    /// What the caches hold: the image, plus — for local files — which file was
    /// decoded and its modification date, so an image edited on disk is
    /// re-decoded the next time its row loads (the behaviour before the cache,
    /// when every row re-creation decoded from disk).
    final class Entry {
        let image: NSImage
        let fileURL: URL?
        let fileDate: Date?

        init(image: NSImage, fileURL: URL? = nil, fileDate: Date? = nil) {
            self.image = image
            self.fileURL = fileURL
            self.fileDate = fileDate
        }
    }

    /// `NSCache` keyed by `NSString`: a lookup bridges the caller's String
    /// without copying it, and when that String is the parser's own storage
    /// the hash/compare is cheap (measured 2026-10-01: 0.3 µs per lookup for a
    /// 5 MB `data:` URL vs 4 ms for a Swift `Dictionary<String, _>`, which
    /// hashes every byte). For the same reason keys are never built by string
    /// concatenation, and each pixel tier has its own cache instead of a
    /// composite "tier|url" key.
    private static let displayCache = makeCache()
    private static let printCache = makeCache()

    /// Failures of `data:` and remote images, keyed like the image caches
    /// (raw string bridged to NSString), so a re-created failing row starts at
    /// the error view instead of the 100 pt spinner — which would report one
    /// height, then another, and make the list compensate on every
    /// scroll-back. Local files are never negatively cached: a missing file
    /// may appear later. Network failures expire (the machine may have been
    /// offline for a moment); undecodable bytes do not change.
    private final class FailureEntry {
        let failure: ImageLoadFailure
        let expires: Date?
        init(_ failure: ImageLoadFailure, expires: Date?) {
            self.failure = failure
            self.expires = expires
        }
    }

    private static let failureCache: NSCache<NSString, FailureEntry> = {
        let cache = NSCache<NSString, FailureEntry>()
        cache.countLimit = 512
        return cache
    }()

    static let networkFailureLifetime: TimeInterval = 60

    /// A failure known WITHOUT I/O: a `data:` URL whose header says it is not
    /// an image or whose byte count is over the cap, or a recorded failure of
    /// a `data:` / remote image. Cheap enough for a view's `init`.
    static func knownFailure(for raw: String, source: ImageSource) -> ImageLoadFailure? {
        switch source {
        case .file:
            return nil
        case .data(let uri):
            if !uri.isImage { return .notAnImage }
            if uri.encodedByteCount > DataImageURI.maxEncodedBytes { return .tooLarge }
        case .remote:
            break
        }
        guard let entry = failureCache.object(forKey: raw as NSString) else { return nil }
        if let expires = entry.expires, expires < Date() { return nil }
        return entry.failure
    }

    private nonisolated static func recordFailure(_ failure: ImageLoadFailure, raw: String) {
        let expires = failure == .network ? Date().addingTimeInterval(networkFailureLifetime) : nil
        failureCache.setObject(FailureEntry(failure, expires: expires), forKey: raw as NSString)
    }

    /// Called when a print / PDF generation finishes: the 2000 px tier exists
    /// to serve the two render passes of ONE export, not to keep up to 256 MB
    /// of bitmaps resident afterwards.
    static func clearPrintCache() {
        printCache.removeAllObjects()
    }

    private static func makeCache() -> NSCache<NSString, Entry> {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }

    private static func cache(for maxPixel: Int) -> NSCache<NSString, Entry>? {
        switch maxPixel {
        case displayMaxPixel: return displayCache
        case printMaxPixel: return printCache
        default: return nil
        }
    }

    /// Local files are keyed by their RESOLVED path, not the raw string: two
    /// documents in different folders can both say `![](image.png)`. Remote
    /// and `data:` URLs are absolute, so the raw string is the identity — and
    /// for `data:` it must be the raw string (the parser's storage), never a
    /// derived copy of megabytes.
    private static func cacheKey(raw: String, source: ImageSource) -> NSString {
        if case .file(let url) = source { return url.path as NSString }
        return raw as NSString
    }

    /// Main-thread fast path: what the row can show immediately when it is
    /// re-created (cell reuse resets `@State`), so it lands at its real height
    /// instead of flashing the 100 pt placeholder. No I/O; a stale local file
    /// is caught by the `load` that follows.
    static func cachedImage(for raw: String, source: ImageSource, maxPixel: Int) -> NSImage? {
        cache(for: maxPixel)?.object(forKey: cacheKey(raw: raw, source: source))?.image
    }

    /// Loads (or returns the cached) image, decoding off the main thread.
    ///
    /// The decode runs in an explicit detached task rather than relying on
    /// this function being `nonisolated async` (which today also runs off the
    /// caller's actor): a future language mode where nonisolated async code
    /// inherits the caller's actor must not quietly move decoding onto main.
    static func load(raw: String, source: ImageSource, maxPixel: Int) async -> Result<NSImage, ImageLoadFailure> {
        switch source {
        case .file(let url):
            return await Task.detached(priority: .userInitiated) {
                Handoff(loadFile(raw: raw, url: url, maxPixel: maxPixel))
            }.value.value

        case .data(let uri):
            if let known = knownFailure(for: raw, source: source) { return .failure(known) }
            return await Task.detached(priority: .userInitiated) {
                Handoff(loadData(raw: raw, uri: uri, maxPixel: maxPixel))
            }.value.value

        case .remote(let url):
            let key = raw as NSString
            if let hit = cache(for: maxPixel)?.object(forKey: key) { return .success(hit.image) }
            if let known = knownFailure(for: raw, source: source) { return .failure(known) }
            let data: Data
            let mimeType: String?
            switch await fetchRemote(url) {
            case .failure(let failure):
                // A fetch cancelled because the row scrolled away is not a
                // failure of the image — do not remember it.
                if !Task.isCancelled { recordFailure(failure, raw: raw) }
                return .failure(failure)
            case .success(let fetched):
                (data, mimeType) = fetched
            }
            let image = await Task.detached(priority: .userInitiated) {
                Handoff(decodeImage(data: data, mediaType: mimeType, maxPixel: maxPixel))
            }.value.value
            guard let image else {
                recordFailure(.undecodable, raw: raw)
                return .failure(.undecodable)
            }
            store(Entry(image: image), key: key, maxPixel: maxPixel)
            return .success(image)
        }
    }

    /// Print/PDF: `ImageRenderer` needs the image NOW. Files and `data:` URLs
    /// decode synchronously (through the cache); remote images are a cache
    /// hit or nothing — PDF export never touches the network (a deliberate,
    /// pre-existing rule: export must not stall on, or leak to, a server).
    /// The on-screen tier is accepted for remote hits, since print never
    /// downloads at its own tier. Never prompts for sandbox access.
    static func loadSync(raw: String, source: ImageSource, maxPixel: Int) -> NSImage? {
        switch source {
        case .file(let url):
            return try? loadFile(raw: raw, url: url, maxPixel: maxPixel).get()
        case .data(let uri):
            guard knownFailure(for: raw, source: source) == nil else { return nil }
            return try? loadData(raw: raw, uri: uri, maxPixel: maxPixel).get()
        case .remote:
            let key = raw as NSString
            return (cache(for: maxPixel)?.object(forKey: key) ?? displayCache.object(forKey: key))?.image
        }
    }

    // MARK: Files

    /// The resolved file, plus the undecoded path when the raw destination had
    /// `%XX` escapes (`ImageSource.resolve` decodes them; a file literally
    /// named `a%20b.png` needs the original). Pure — no I/O.
    static func fileCandidates(for url: URL, raw original: String) -> [URL] {
        // Same normalisation as `resolve`; a `.file` source is ≤ maxPathBytes.
        let raw = String(ImageSource.normalized(original))
        guard !ImageSource.hasASCIIPrefix(raw, "file://"), raw.contains("%"),
              let decoded = raw.removingPercentEncoding, decoded != raw else { return [url] }
        let path = url.path
        guard path.hasSuffix(decoded) else { return [url] }
        return [url, URL(fileURLWithPath: String(path.dropLast(decoded.count)) + raw)]
    }

    private nonisolated static func loadFile(raw: String, url: URL, maxPixel: Int) -> Result<NSImage, ImageLoadFailure> {
        let key = url.path as NSString
        let tierCache = cache(for: maxPixel)
        if let entry = tierCache?.object(forKey: key), let loadedURL = entry.fileURL,
           let date = entry.fileDate, modificationDate(of: loadedURL) == date {
            return .success(entry.image)
        }

        var existing: URL?
        for candidate in fileCandidates(for: url, raw: raw) {
            if let image = decodeFile(candidate, maxPixel: maxPixel) {
                store(Entry(image: image, fileURL: candidate, fileDate: modificationDate(of: candidate)),
                      key: key, maxPixel: maxPixel)
                return .success(image)
            }
            if existing == nil, FileManager.default.fileExists(atPath: candidate.path) {
                existing = candidate
            }
        }
        // A file that exists but did not load is most likely the sandbox —
        // the view turns `.unreadable` into the folder-access prompt.
        return .failure(existing.map { .unreadable($0) } ?? .notFound)
    }

    /// ImageIO thumbnail (downsampled, EXIF orientation applied), falling back
    /// to `NSImage(contentsOf:)` — the fallback is what renders `.svg` links
    /// (CoreSVG through NSImage) and anything else ImageIO declines.
    private nonisolated static func decodeFile(_ url: URL, maxPixel: Int) -> NSImage? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = downsampledBitmap(from: source, maxPixel: maxPixel) {
            return image
        }
        return NSImage(contentsOf: url)
    }

    /// The bitmap is downsampled to `maxPixel`, but the NSImage's `size` is the
    /// ORIGINAL pixel size. `kCGImageSourceThumbnailMaxPixelSize` caps the
    /// LONGER side, so sizing from the thumbnail made an 800×4000 PNG 240 pt
    /// wide instead of the 600 pt cap (D4 compares against `size.width`), and
    /// the screen (1200) and print (2000) tiers disagreed. Drawing a smaller
    /// bitmap into the original size is just scaling — the view caps the width
    /// far below the original anyway.
    private nonisolated static func downsampledBitmap(from source: CGImageSource, maxPixel: Int) -> NSImage? {
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions(maxPixelSize: maxPixel)) else { return nil }
        let size = originalPixelSize(of: source)
            ?? NSSize(width: cgImage.width, height: cgImage.height)
        // An explicit bitmap rep, not `NSImage(cgImage:size:)`: that one
        // reports `pixelsWide/High` derived from `size`, which would hide the
        // real (downsampled) bitmap from the cache-cost computation.
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// Pixel width/height from the image properties, swapped for EXIF
    /// orientations 5–8 (90° rotations) because the thumbnail is created WITH
    /// the transform applied (`kCGImageSourceCreateThumbnailWithTransform`).
    nonisolated static func originalPixelSize(of source: CGImageSource) -> NSSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation)
            ? NSSize(width: height, height: width)
            : NSSize(width: width, height: height)
    }

    /// Downsampled decode: a 4K photo never exists in memory at full size.
    /// Also used by the preview overlay at `previewMaxPixel`.
    nonisolated static func loadThumbnail(from url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions(maxPixelSize: maxPixelSize))
    }

    private nonisolated static func thumbnailOptions(maxPixelSize: Int) -> CFDictionary {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return options as CFDictionary
    }

    private nonisolated static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    // MARK: data: URLs

    private nonisolated static func loadData(raw: String, uri: DataImageURI, maxPixel: Int) -> Result<NSImage, ImageLoadFailure> {
        let key = raw as NSString
        if let hit = cache(for: maxPixel)?.object(forKey: key) { return .success(hit.image) }
        switch uri.decodeData() {
        case .failure(.tooLarge): return .failure(.tooLarge)
        case .failure(.notAnImage): return .failure(.notAnImage)
        case .failure(.undecodable):
            recordFailure(.undecodable, raw: raw)
            return .failure(.undecodable)
        case .success(let data):
            guard let image = decodeImage(data: data, mediaType: uri.mediaType, maxPixel: maxPixel) else {
                recordFailure(.undecodable, raw: raw)
                return .failure(.undecodable)
            }
            store(Entry(image: image), key: key, maxPixel: maxPixel)
            return .success(image)
        }
    }

    // MARK: Remote

    /// Streams the response so the 64 MiB cap bounds memory: a declared
    /// `Content-Length` over the cap is refused before the body arrives, an
    /// undeclared one is cut off as soon as it crosses the cap. (`data(from:)`
    /// would buffer the whole body before any check could run.)
    private static func fetchRemote(_ url: URL) async -> Result<(Data, String?), ImageLoadFailure> {
        do {
            let (bytes, response) = try await URLSession.shared.bytes(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                bytes.task.cancel()
                return .failure(.network)
            }
            if response.expectedContentLength > Int64(maxRemoteBytes) {
                bytes.task.cancel()
                return .failure(.tooLarge)
            }
            var data = Data()
            if response.expectedContentLength > 0 {
                data.reserveCapacity(Int(response.expectedContentLength))
            }
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxRemoteBytes {
                    bytes.task.cancel()
                    return .failure(.tooLarge)
                }
            }
            return .success((data, response.mimeType?.lowercased()))
        } catch {
            return .failure(.network)
        }
    }

    // MARK: Bytes → image (remote + data:)

    /// ImageIO first (every bitmap format, downsampled like files, `size` =
    /// original pixel size); SVG — which ImageIO does not decode — goes to
    /// `SVGImageDecoder` when the bytes start like SVG markup
    /// (`SVGImageDecoder.looksLikeSVG`, which `decode(data:)` enforces whatever
    /// the declared media type). SVGs keep their declared size, which the D4
    /// sizing rule honours.
    nonisolated static func decodeImage(data: Data, mediaType: String?, maxPixel: Int) -> NSImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = downsampledBitmap(from: source, maxPixel: maxPixel) {
            return image
        }
        return SVGImageDecoder.decode(data: data)
    }

    /// Carries a decoder result out of its detached task. `NSImage` is declared
    /// `Sendable` only from macOS 14 on; ours are created inside the task,
    /// never mutated afterwards and handed over exactly once — the same
    /// contract the 1.x view code relied on implicitly.
    private struct Handoff<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private nonisolated static func store(_ entry: Entry, key: NSString, maxPixel: Int) {
        guard let cache = cache(for: maxPixel) else { return }
        // Cost = the bitmap actually held (the downsampled one), not `size`,
        // which is the original pixel size since D4 needs it.
        let pixels = entry.image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 0
        let size = entry.image.size
        let cost = max(1, pixels > 0 ? pixels * 4 : Int(size.width) * Int(size.height) * 4)
        cache.setObject(entry, forKey: key, cost: cost)
    }
}

// MARK: - Labels

/// Text for image placeholders, on screen and in PDF. The one rule: no `data:`
/// payload, and no unbounded URL, ever reaches a user-visible string (#32 —
/// the placeholder used to print megabytes of base64).
enum ImageLabel {
    static let maxURLLength = 80

    static func errorText(alt: String, raw: String, source: ImageSource?,
                          failure: ImageLoadFailure? = nil) -> String {
        if !alt.isEmpty { return "Image: \(alt)" }
        if case .data(let uri)? = source {
            let tooLarge = failure == .tooLarge || uri.encodedByteCount > DataImageURI.maxEncodedBytes
            return tooLarge
                ? "Embedded image too large (\(uri.displayLabel))"
                : "Embedded image could not be shown (\(uri.displayLabel))"
        }
        // A `data:` URL that did not even parse (no comma): no label to offer,
        // and the text after `data:` is payload.
        if DataImageURI.hasDataScheme(ImageSource.normalized(raw)) { return "Embedded image could not be shown" }
        return "Image: \(DisplayString.middleTruncated(raw, maxLength: maxURLLength))"
    }
}

enum DisplayString {
    /// `head…tail` with at most `maxLength` characters including the ellipsis.
    /// The common case — a short string — is answered from the UTF-8 byte
    /// count without counting characters, so this is safe (O(maxLength)) on a
    /// multi-megabyte string.
    static func middleTruncated(_ text: String, maxLength: Int) -> String {
        guard maxLength > 1 else { return maxLength == 1 ? "\u{2026}" : "" }
        if text.utf8.count <= maxLength { return text }
        let keep = maxLength - 1
        let headCount = (keep + 1) / 2
        let tailCount = keep - headCount
        let head = text.prefix(headCount)
        // A long-in-bytes but short-in-characters string (e.g. non-Latin
        // text) may not need truncating after all — checked on the bounded
        // head/tail walks, never with a full `count`: it fits iff at most
        // `tailCount + 1` characters follow the head.
        guard text.index(head.endIndex, offsetBy: tailCount + 2, limitedBy: text.endIndex) != nil else {
            return text
        }
        return String(head) + "\u{2026}" + String(text.suffix(tailCount))
    }
}
