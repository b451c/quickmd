import SwiftUI

// MARK: - Math Block View

/// Renders display math ($$...$$) using SwiftMath's MTMathUILabel.
/// The label is wrapped via NSViewRepresentable for SwiftUI integration.
struct MathBlockView: View {
    let latex: String
    let theme: MarkdownTheme

    var body: some View {
        MathLabelView(latex: latex, fontSize: 20, textColor: NSColor(theme.textColor))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
    }
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
