import SwiftUI
import AppKit
import CoreText

// MARK: - Image rows (v1.15): a paragraph of pictures that wraps like words
//
// GitHub draws a paragraph made only of images (README badges one per line,
// `![a](x) ![b](y)`) as inline pictures: side by side, a space between them
// where the source has whitespace, wrapping onto the next line when the
// column is full, a `<br>` where the source has a hard line break, the
// pictures of a line sharing a baseline — here: bottom-aligned in the line
// (a line of pictures has no text whose descent would show the difference).
// `ImageRowView` (screen) and
// `PrintableImageRowView` (print/PDF) lay their pictures out with
// `ImageFlowLayout`; `BlockHeightMeasurer` sizes the row with the SAME line
// breaking (`BlockLayout.ImageRow.lines`), so a row whose picture sizes are
// known is measured exactly what it is drawn.
//
// Compiled into the app AND the test target (no view code beyond the Layout).

extension BlockLayout {
    enum ImageRow {
        /// Between two pictures the source separates with whitespace — a
        /// space of 14 pt body text — × zoom. None where they touch.
        static let spaceWidth: CGFloat = 4
        /// Between two lines of pictures, × zoom: GitHub's line box leaves
        /// about this much under a 20 px badge.
        static let lineSpacing: CGFloat = 4
        /// A picture whose size is not known yet — loading, failed, folder
        /// access denied — is a CHIP of its alt text at this height × zoom: a
        /// badge's height, so an offline README keeps its badge rows.
        static let placeholderSide: CGFloat = 20
        /// The chip's text, × zoom (system font, one line, truncated).
        static let chipFontSize: CGFloat = 11
        /// Text inset left and right, × zoom.
        static let chipHorizontalPadding: CGFloat = 6
        static let chipCornerRadius: CGFloat = 3
        /// The widest a chip gets, × zoom (never wider than the column).
        static let chipMaxWidth: CGFloat = 240

        /// What a chip shows: the alt text on one line, or "Image" without one.
        static func chipLabel(alt: String) -> String {
            let line = alt.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? "Image" : line
        }

        static func chipFont(fontScale: CGFloat) -> NSFont {
            NSFont.systemFont(ofSize: chipFontSize * fontScale)
        }

        /// The chip's frame: its label's width (CoreText, thread-safe — the
        /// measurer runs off-main) plus the insets and a 2 pt allowance for
        /// SwiftUI's own text width, capped; `placeholderSide` tall. The view
        /// FRAMES the chip with this, so the measurer's row is exact.
        static func chipSize(alt: String, fontScale: CGFloat, contentWidth: CGFloat) -> CGSize {
            let label = NSAttributedString(string: chipLabel(alt: alt),
                                           attributes: [.font: chipFont(fontScale: fontScale)])
            let line = CTLineCreateWithAttributedString(label)
            let text = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let width = (text + 2).rounded(.up) + 2 * chipHorizontalPadding * fontScale
            let cap = min(clampedWidth(contentWidth), chipMaxWidth * fontScale)
            return CGSize(width: min(width, cap), height: placeholderSide * fontScale)
        }

        /// One line of the row: the pictures in `range`, `height` the
        /// tallest of them.
        struct Line: Equatable {
            let range: Range<Int>
            let height: CGFloat
        }

        static func gap(before separator: RowImage.Separator, fontScale: CGFloat) -> CGFloat {
            separator == .space ? spaceWidth * fontScale : 0
        }

        /// Greedy line breaking, like words: a picture goes on the current
        /// line if it fits after the gap its separator asks for, else it
        /// starts the next one; a `.lineBreak` always starts one. A picture
        /// wider than the line gets a line of its own (pictures are capped
        /// at the column by `ImageBlock.pictureSize`, placeholders by the
        /// proposal, so that only happens below the cap's rounding).
        static func lines(sizes: [CGSize], separators: [RowImage.Separator], width: CGFloat,
                          fontScale: CGFloat) -> [Line] {
            var lines: [Line] = []
            var start = 0
            var x: CGFloat = 0
            var height: CGFloat = 0
            for (index, size) in sizes.enumerated() {
                let separator = index < separators.count ? separators[index] : .space
                if index > start {
                    let next = x + gap(before: separator, fontScale: fontScale) + size.width
                    if separator == .lineBreak || next > width + 0.5 {
                        lines.append(Line(range: start..<index, height: height))
                        start = index
                        x = size.width
                        height = size.height
                        continue
                    }
                    x = next
                    height = max(height, size.height)
                } else {
                    x = size.width
                    height = size.height
                }
            }
            if start < sizes.count { lines.append(Line(range: start..<sizes.count, height: height)) }
            return lines
        }

        /// The pictures' height: every line's tallest picture plus
        /// `lineSpacing` between lines (no padding — the row's is
        /// `Document.imageOuterVerticalPadding`, as an image block's).
        static func height(of lines: [Line], fontScale: CGFloat) -> CGFloat {
            guard !lines.isEmpty else { return 0 }
            return lines.reduce(0) { $0 + $1.height } + CGFloat(lines.count - 1) * lineSpacing * fontScale
        }

        /// The size a picture is drawn at in a row: its picture size
        /// (`ImageBlock.pictureSize` — natural size × zoom, or the HTML
        /// `width`, capped at the column: the single image's rule) once
        /// known, else its chip.
        static func itemSize(imageSize: CGSize?, htmlWidth: ImageWidth? = nil, alt: String, fontScale: CGFloat,
                             contentWidth: CGFloat) -> CGSize {
            guard let imageSize, imageSize.width > 0, imageSize.height > 0 else {
                return chipSize(alt: alt, fontScale: fontScale, contentWidth: contentWidth)
            }
            return ImageBlock.pictureSize(imageSize: imageSize, htmlWidth: htmlWidth, fontScale: fontScale,
                                          contentWidth: contentWidth)
        }

        /// The row as the measurer sizes it: the pictures it knows the size
        /// of (`imageSizes`, by url as written), chips for the rest, broken into lines at `contentWidth`, plus the row's
        /// vertical padding. Exact once every size is known; the row is
        /// `.reported`, so a picture that arrives (or fails) corrects it.
        static func rowHeight(images: [RowImage], imageSizes: [NSString: CGSize], fontScale: CGFloat,
                              contentWidth: CGFloat) -> CGFloat {
            let sizes = images.map {
                itemSize(imageSize: imageSizes[$0.url as NSString], htmlWidth: $0.width, alt: $0.alt,
                         fontScale: fontScale, contentWidth: contentWidth)
            }
            let lines = lines(sizes: sizes, separators: images.map(\.separator),
                              width: clampedWidth(contentWidth), fontScale: fontScale)
            return height(of: lines, fontScale: fontScale) + 2 * Document.imageOuterVerticalPadding
        }
    }
}

// MARK: - Flow layout

/// Lays out an image row's pictures (one subview per `RowImage`, in order)
/// with `BlockLayout.ImageRow.lines`: left to right, wrapping at
/// `wrapWidth` (or the proposed width), each line's pictures bottom-aligned.
/// Every subview is offered that width and takes its own size.
///
/// On screen `wrapWidth` is the MEASURED `contentWidth` — the width the
/// measurer broke the lines at and the pictures are sized for — not the live
/// cell width: during a live resize the cell is wider or narrower for a few
/// frames until the next measure lands, and wrapping at it would rewrap and
/// report a new row height on every frame. Print passes nil (the page).
struct ImageFlowLayout: Layout {
    let separators: [RowImage.Separator]
    let fontScale: CGFloat
    var wrapWidth: CGFloat? = nil

    private func arrangement(width proposed: CGFloat, subviews: Subviews)
        -> (sizes: [CGSize], lines: [BlockLayout.ImageRow.Line]) {
        let width = wrapWidth ?? proposed
        let offer = ProposedViewSize(width: width.isFinite ? width : nil, height: nil)
        let sizes = subviews.map { $0.sizeThatFits(offer) }
        let lines = BlockLayout.ImageRow.lines(sizes: sizes, separators: separators, width: width,
                                               fontScale: fontScale)
        return (sizes, lines)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let (sizes, lines) = arrangement(width: width, subviews: subviews)
        let height = BlockLayout.ImageRow.height(of: lines, fontScale: fontScale)
        if width.isFinite { return CGSize(width: width, height: height) }
        // Unconstrained (an ideal-size query): the widest line.
        let widest = lines.map { line in
            line.range.reduce(CGFloat(0)) { x, index in
                x + (index > line.range.lowerBound
                     ? BlockLayout.ImageRow.gap(before: separators[safe: index], fontScale: fontScale) : 0)
                    + sizes[index].width
            }
        }.max() ?? 0
        return CGSize(width: widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (sizes, lines) = arrangement(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for index in line.range {
                if index > line.range.lowerBound {
                    x += BlockLayout.ImageRow.gap(before: separators[safe: index], fontScale: fontScale)
                }
                let size = sizes[index]
                subviews[index].place(at: CGPoint(x: x, y: y + line.height - size.height), anchor: .topLeading,
                                      proposal: ProposedViewSize(size))
                x += size.width
            }
            y += line.height + BlockLayout.ImageRow.lineSpacing * fontScale
        }
    }
}

private extension Array where Element == RowImage.Separator {
    /// A missing separator (more subviews than separators) reads as a space.
    subscript(safe index: Int) -> RowImage.Separator { index < count ? self[index] : .space }
}
