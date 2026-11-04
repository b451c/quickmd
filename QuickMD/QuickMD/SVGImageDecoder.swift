//
//  SVGImageDecoder.swift
//  QuickMD
//
//  Fenced ```svg blocks are decoded by macOS itself: NSImage understands SVG
//  data on every supported release (`public.svg-image` is in
//  `NSImage.imageTypes`), so the markup never goes through WebKit and no
//  library is bundled. Shared by the on-screen block (SVGBlockView) and the
//  print/PDF path (PrintableSVGView); kept out of the view file so the unit
//  test target, which compiles model files but no views, can exercise it.
//  Since #32 it also decodes SVG image links / data URIs (`decode(data:)`).
//

import AppKit

enum SVGImageDecoder {
    /// Width/height, viewBox-only and size-less markup all decode (size-less
    /// markup gets its content bounds); a `<script>` element is inert; text
    /// that is not SVG yields nil, which the callers turn into a notice on
    /// screen and a code block in PDF. Off-main safe — the data is immutable
    /// and the result is handed over once.
    nonisolated static func decode(_ source: String) -> NSImage? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("<svg") else { return nil }
        guard let image = NSImage(data: Data(trimmed.utf8)), image.isValid,
              image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    // MARK: - Fenced-block cache

    /// Decoded ```svg blocks, by their markup (an `NSString` key: hashing does
    /// not read the whole markup). NSCache is thread-safe and may evict;
    /// the sizes below never are, so a row keeps its height either way.
    private static let images = NSCache<NSString, NSImage>()
    private static let lock = NSLock()
    /// Decoded size per markup; `.zero` = the markup does not decode.
    private static var sizes: [NSString: CGSize] = [:]
    /// Entries are tiny; the cap only keeps a session-long store bounded.
    static let sizeLimit = 2048

    /// The decoded image if it is cached — what `SVGBlockView` shows at once
    /// when its row is re-created, instead of the loading view.
    nonisolated static func cachedImage(_ source: String) -> NSImage? {
        images.object(forKey: source as NSString)
    }

    /// The decoded size, if the markup was ever decoded and decodes.
    nonisolated static func cachedSize(_ source: String) -> CGSize? {
        lock.lock()
        defer { lock.unlock() }
        return sizes[source as NSString].flatMap { $0 == .zero ? nil : $0 }
    }

    /// `decode`, through the cache: the view's decode and the measurer's size
    /// share one decode per markup. Off-main safe.
    nonisolated static func decodeCached(_ source: String) -> NSImage? {
        let key = source as NSString
        if let hit = images.object(forKey: key) { return hit }
        lock.lock()
        let known = sizes[key]
        lock.unlock()
        if known == .zero { return nil }
        let image = decode(source)
        if let image { images.setObject(image, forKey: key) }
        lock.lock()
        if sizes.count >= sizeLimit, sizes[key] == nil { sizes.removeAll() }
        sizes[key] = image?.size ?? .zero
        lock.unlock()
        return image
    }

    /// The size `source` decodes to (decoding and caching it if need be), nil
    /// for markup that does not decode — what the measurer sizes the row by.
    nonisolated static func size(of source: String) -> CGSize? {
        if let known = cachedSize(source) { return known }
        return decodeCached(source)?.size
    }

    /// The same decode for SVG that arrives as bytes — a `data:image/svg+xml`
    /// image or a remote `.svg` (shields.io badges are SVG) — once ImageIO has
    /// declined it (`ImageLoader.decodeImage`). Only bytes that START like SVG
    /// markup (`looksLikeSVG`) are handed to `NSImage(data:)` here, never
    /// arbitrary data some other image rep might pick up. Same CoreSVG-only
    /// rule (constraints.md).
    nonisolated static func decode(data: Data) -> NSImage? {
        guard looksLikeSVG(data) else { return nil }
        guard let image = NSImage(data: data), image.isValid,
              image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    /// After an optional UTF-8 BOM and whitespace, the data begins with `<svg`,
    /// `<?xml`, `<!--` or `<!DOCTYPE svg` (ASCII case-insensitive). A `<svg`
    /// somewhere further in is NOT enough: that is how an HTML error page or
    /// any text mentioning SVG would reach the decoder.
    nonisolated static func looksLikeSVG(_ data: Data) -> Bool {
        var index = data.startIndex
        if data.count >= 3, data[index] == 0xEF, data[index + 1] == 0xBB, data[index + 2] == 0xBF {
            index += 3
        }
        while index < data.endIndex, [0x20, 0x09, 0x0A, 0x0D, 0x0C].contains(data[index]) {
            index += 1
        }
        let head = data[index..<min(index + 16, data.endIndex)].map { byte -> UInt8 in
            (0x41...0x5A).contains(byte) ? byte + 32 : byte
        }
        return ["<svg", "<?xml", "<!--", "<!doctype svg"].contains { head.starts(with: $0.utf8) }
    }
}
