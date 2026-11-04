//
//  SVGBlockView.swift
//  QuickMD
//
//  Fenced ```svg blocks rendered natively: the block's text goes to NSImage
//  as data and CoreSVG draws it — no WebKit, no bundled libraries, scripts
//  and external references inside the markup are ignored by the decoder.
//  Sizing follows ImageBlockView (#29): the image scales with the document
//  zoom and never exceeds the column, but unlike a bitmap an SVG's declared
//  size is meaningful, so it is honoured at 100 % instead of being blown up
//  to the column cap. Clicking opens the same window-filling preview as
//  images and Mermaid diagrams.
//

import SwiftUI
import AppKit

struct SVGBlockView: View {
    let source: String
    let theme: MarkdownTheme
    let fontScale: CGFloat
    let contentWidth: CGFloat
    var onEnlarge: (GraphicPreview) -> Void = { _ in }

    @State private var image: NSImage?
    @State private var decodeFailed = false

    init(source: String, theme: MarkdownTheme, fontScale: CGFloat, contentWidth: CGFloat,
         onEnlarge: @escaping (GraphicPreview) -> Void = { _ in }) {
        self.source = source
        self.theme = theme
        self.fontScale = fontScale
        self.contentWidth = contentWidth
        self.onEnlarge = onEnlarge
        // A re-created row (cell reuse resets `@State`) shows the decoded image
        // at once — at the size the measurer gave its row — not the loading view.
        _image = State(initialValue: SVGImageDecoder.cachedImage(source))
    }

    /// Display width cap and the pre-decode placeholder height — shared with
    /// bitmap images and `BlockHeightMeasurer` (`.reported` row, like images).
    typealias Metrics = BlockLayout.ImageBlock

    var body: some View {
        Group {
            if let image {
                Button {
                    onEnlarge(.image(Image(nsImage: image), title: "SVG", fileURL: nil))
                } label: {
                    let size = pictureSize(for: image.size)
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size.width, height: size.height)
                }
                .buttonStyle(.plain)
                .help("Click to enlarge image")
                .accessibilityLabel("Enlarge SVG image")
            } else if decodeFailed {
                Label("SVG could not be decoded", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12 * fontScale))
                    .foregroundColor(theme.secondaryTextColor)
                    .padding(.vertical, 12)
            } else if let known = SVGImageDecoder.cachedSize(source) {
                // Decoded before, evicted since: hold the picture's place.
                let size = pictureSize(for: known)
                ProgressView()
                    .frame(width: size.width, height: size.height)
            } else {
                ProgressView()
                    .frame(height: Metrics.placeholderHeight)
            }
        }
        .task(id: source) {
            decodeFailed = false
            // The current markup's cached image, if any (the id also changes
            // when the markup of a live view does).
            image = SVGImageDecoder.cachedImage(source)
            guard image == nil else { return }
            let decoded = await Task.detached(priority: .userInitiated) {
                SVGImageDecoder.decodeCached(source)
            }.value
            guard !Task.isCancelled else { return }
            if let decoded { image = decoded } else { decodeFailed = true }
        }
    }

    /// The column cap from `ImageBlock.displayWidth` (fitted width × zoom, never
    /// wider than the column), further capped at the SVG's own declared size ×
    /// zoom so icons stay icon-sized — `ImageBlock.pictureSize`, the rule the
    /// measurer sizes the row with.
    private func pictureSize(for imageSize: CGSize) -> CGSize {
        Metrics.pictureSize(imageSize: imageSize, htmlWidth: nil, fontScale: fontScale,
                            contentWidth: contentWidth)
    }
}
