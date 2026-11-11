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
    typealias Metrics = BlockLayout.Math

    var body: some View {
        MathLabelView(latex: latex, fontSize: Metrics.fontSize * fontScale,
                      textColor: NSColor(theme.textColor))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Metrics.verticalPadding)
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
        inlineImage: { latex, theme, fontSize in
            var mathImage = MathImage(
                latex: latex,
                fontSize: fontSize,
                textColor: NSColor(theme.textColor),
                labelMode: .text,
                textAlignment: .left
            )
            let (error, image, _) = mathImage.asImage()
            // Nothing drawn (an empty or spacing-only `$…$`, an accent over
            // nothing): the italic literal, like a formula that fails.
            guard error == nil, let image, MathInk.drawsSomething(latex, image: image) else { return nil }
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
        },
        // What leaves `MTMathUILabel` (and `MathImage`) with nothing to draw: a
        // parse error, a formula that parses to nothing, or one the typesetter
        // declines (`MathInk.typesetsToSomething`). No bitmap, so the check
        // costs a fraction of the `displayHeight` call that follows for the
        // same row.
        typesets: { latex in MathInk.typesetsToSomething(latex) },
        // A display formula inside a quote or alert body (v1.15): display
        // style, as `MTMathUILabel` draws a `$$` block; nothing drawn → nil
        // (the body shows the LaTeX instead).
        displayImage: { latex, theme, fontSize in
            var mathImage = MathImage(latex: latex, fontSize: fontSize, textColor: NSColor(theme.textColor))
            let (error, image, _) = mathImage.asImage()
            guard error == nil, let image, MathInk.drawsSomething(latex, image: image) else { return nil }
            return image
        }
    )
}

// MARK: - Formulas that typeset to nothing

/// `MTMathListBuilder` accepts formulas that draw nothing — empty, only
/// spacing or style changes (`\,`, `\quad`, `\displaystyle`), empty groups
/// (`{}`, `\mathrm{}`, `{}^{}_{}`), an accent or a line over nothing
/// (`\hat{}`, `\overline{}`), `\left. \right.` — and this SwiftMath's
/// typesetter declines some it parsed (`\color`, `\textcolor`,
/// `\colorbox`: no line at all). `MTMathUILabel` then draws an empty row,
/// which the display path replaces with the LaTeX source
/// (`substitutingUntypesettableMath`, screen and print) and the inline paths
/// with the italic literal. Checked against SwiftMath's own rendering (an
/// ink scan of `MathImage`) on 36 formulas: no disagreement.
enum MathInk {
    /// Parses, has something to draw, and the typesetter builds a line of some
    /// size from it.
    static func typesetsToSomething(_ latex: String) -> Bool {
        var error: NSError?
        guard let list = MTMathListBuilder.build(fromString: latex, error: &error), error == nil,
              draws(list),
              let line = MTTypesetter.createLineForMathList(
                  list, font: MathFont.latinModernFont.mtfont(size: BlockLayout.Math.fontSize), style: .display)
        else { return false }
        return line.width > 0 && line.ascent + line.descent > 0
    }

    /// For a formula `MathImage` already rendered (the inline paths, which
    /// must not typeset twice): a size, and something to draw in it.
    static func drawsSomething(_ latex: String, image: NSImage) -> Bool {
        guard image.size.width > 0, image.size.height > 0 else { return false }
        var error: NSError?
        return draws(MTMathListBuilder.build(fromString: latex, error: &error))
    }

    /// An atom with a visible glyph, a radical sign (drawn even over nothing),
    /// or content that has one — a fraction's parts or delimiters, what an
    /// accent, line, colour or table holds; scripts count on any atom. A
    /// fraction bar, accent or line over nothing is zero wide.
    static func draws(_ list: MTMathList?) -> Bool {
        guard let list else { return false }
        return list.atoms.contains(where: draws)
    }

    static func draws(_ atom: MTMathAtom) -> Bool {
        if draws(atom.subScript) || draws(atom.superScript) { return true }
        switch atom {
        case let fraction as MTFraction:
            return draws(fraction.numerator) || draws(fraction.denominator)
                || !fraction.leftDelimiter.isEmpty || !fraction.rightDelimiter.isEmpty
        case is MTRadical:
            return true
        case let accent as MTAccent:
            return draws(accent.innerList)
        case let inner as MTInner:
            return draws(inner.innerList)
                || inner.leftBoundary.map(draws) == true || inner.rightBoundary.map(draws) == true
        case let line as MTOverLine:
            return draws(line.innerList)
        case let line as MTUnderLine:
            return draws(line.innerList)
        case is MTMathSpace, is MTMathStyle:
            return false
        case let color as MTMathColor:
            return draws(color.innerList)
        case let color as MTMathTextColor:
            return draws(color.innerList)
        case let box as MTMathColorbox:
            return draws(box.innerList)
        case let table as MTMathTable:
            return table.cells.contains { row in row.contains { draws($0) } }
        default:
            // A glyph: ordinary, number, variable, operators, relations,
            // delimiters, punctuation, placeholder. `\left.` is an empty one.
            return !atom.nucleus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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
