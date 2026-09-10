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
}
