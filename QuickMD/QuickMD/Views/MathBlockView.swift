import SwiftUI

// MARK: - Math Block View

/// Renders display math ($$...$$) using SwiftMath's MTMathUILabel.
/// The label is wrapped via NSViewRepresentable for SwiftUI integration.
struct MathBlockView: View {
    let latex: String
    let theme: MarkdownTheme
    var fontScale: CGFloat = 1.0

    /// Font size and padding — see `BlockLayout.Math` (shared with
    /// `BlockHeightMeasurer`).
    typealias Layout = BlockLayout.Math

    var body: some View {
        MathLabelView(latex: latex, fontSize: Layout.fontSize * fontScale,
                      textColor: NSColor(theme.textColor))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Layout.verticalPadding)
    }
}

// MARK: - Math Engine Seam

extension MathRendering {
    /// The production math engine (vendored SwiftMath). Lives here rather than in
    /// `BlockHeightMeasurer.swift` so that file — which the test target compiles —
    /// does not pull in the SwiftMath sources or its font bundle.
    ///
    /// `displayHeight` mirrors `MTMathUILabel.intrinsicContentSize`: both typeset
    /// through `MTTypesetter` with `maxWidth = 0` and zero content insets, so the
    /// height is `ascent + descent` of the same display list (`MathImage`
    /// additionally rounds up, which is the safe direction for a row height).
    static let swiftMath = MathRendering(
        inlineImage: { latex, theme, fontScale in
            var mathImage = MathImage(
                latex: latex,
                fontSize: 14 * fontScale,
                textColor: NSColor(theme.textColor),
                labelMode: .text,
                textAlignment: .left
            )
            let (error, image, _) = mathImage.asImage()
            guard error == nil, let image = image else { return nil }
            return image
        },
        displayHeight: { latex, theme, fontScale in
            var mathImage = MathImage(
                latex: latex,
                fontSize: BlockLayout.Math.fontSize * fontScale,
                textColor: NSColor(theme.textColor)
            )
            let (error, image, _) = mathImage.asImage()
            guard error == nil, let image = image else { return 0 }
            return image.size.height
        }
    )
}

// MARK: - NSViewRepresentable Wrapper

/// Wraps MTMathUILabel for use in SwiftUI.
/// MTMathUILabel renders LaTeX via Core Graphics — native, fast, offline.
private struct MathLabelView: NSViewRepresentable {
    let latex: String
    let fontSize: CGFloat
    let textColor: NSColor

    func makeNSView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        label.latex = latex
        label.fontSize = fontSize
        label.textColor = textColor
        label.textAlignment = .center
        return label
    }

    func updateNSView(_ label: MTMathUILabel, context: Context) {
        label.latex = latex
        label.fontSize = fontSize
        label.textColor = textColor
    }
}
