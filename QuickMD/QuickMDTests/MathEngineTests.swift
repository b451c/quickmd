import XCTest
import AppKit

/// The vendored SwiftMath engine, typeset for real (#59).
///
/// Every other test stands a stub in for the engine; these compile its sources
/// into the test target and read what a formula DRAWS: the text of every glyph
/// run in the display tree. They never read sizes or font names, only which
/// characters come out and in which order, so they do not depend on the OS.
///
/// The rule under test: TYPESETTING NEVER CHANGES ITS INPUT. Until 1.15.0 the
/// step that merges neighbouring characters ("2", "x" → "2x") rewrote the
/// caller's atoms, and `\left…\right` typeset its content twice (once to size
/// the delimiters, once to place it), so the second pass merged again:
/// "2x", "x" → "2xx". Every environment that draws delimiters (`cases`,
/// `pmatrix`, `bmatrix`, …) and every `\left…\right` repeated characters; the
/// measuring pass also used up the limits of a `\sum` inside delimiters.
///
/// Negative control: with the two engine changes reverted
/// (`MTTypesetter+Tokenization.swift` copies before preprocessing,
/// `makeLeftRight` typesets once) seven of the nine tests fail. The two that
/// pass guard what already held: the inline source path (fixed in 1.15.0) and
/// the public entry, which always typeset a copy.
final class MathEngineTests: XCTestCase {

    // MARK: - Fixtures

    /// No host app: the test runner's main bundle has no fonts, so the engine
    /// reads them from the source tree. Restored afterwards (process-wide state).
    override class func setUp() {
        super.setUp()
        MathFontsBundle.overrideURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // QuickMDTests
            .deletingLastPathComponent()   // the project folder
            .appendingPathComponent("QuickMD/SwiftMath/mathFonts.bundle")
    }

    override class func tearDown() {
        MathFontsBundle.overrideURL = nil
        super.tearDown()
    }

    private var font: MTFont { MathFont.latinModernFont.mtfont(size: 20) }

    private func build(_ latex: String, file: StaticString = #filePath, line: UInt = #line) -> MTMathList? {
        var error: NSError?
        let list = MTMathListBuilder.build(fromString: latex, error: &error)
        XCTAssertNil(error, "\(latex) must parse", file: file, line: line)
        XCTAssertNotNil(list, "\(latex) must parse", file: file, line: line)
        return list
    }

    /// What the formula draws, as the app typesets it (`MathImage` uses this
    /// public entry): every glyph run, in drawing-tree order, as plain text.
    private func drawn(_ latex: String, style: MTLineStyle = .display,
                       file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let list = build(latex, file: file, line: line),
              let display = MTTypesetter.createLineForMathList(list, font: font, style: style) else {
            XCTFail("\(latex) must typeset", file: file, line: line)
            return ""
        }
        return Self.text(of: display)
    }

    private static func text(of display: MTDisplay?) -> String {
        guard let display else { return "" }
        if let line = display as? MTCTLineDisplay { return plain(line.attributedString?.string ?? "") }
        if let list = display as? MTMathListDisplay { return list.subDisplays.map { text(of: $0) }.joined() }
        if let fraction = display as? MTFractionDisplay { return text(of: fraction.numerator) + text(of: fraction.denominator) }
        if let radical = display as? MTRadicalDisplay { return text(of: radical.degree) + text(of: radical.radicand) }
        if let accent = display as? MTAccentDisplay { return text(of: accent.accentee) }
        if let line = display as? MTLineDisplay { return text(of: line.inner) }
        if let limits = display as? MTLargeOpLimitsDisplay {
            return text(of: limits.nucleus) + text(of: limits.upperLimit) + text(of: limits.lowerLimit)
        }
        return ""   // a single glyph: a delimiter, a big operator, a radical sign
    }

    /// The engine draws variables with the mathematical italic letters; map
    /// them back so expectations read as the source does. Spaces are dropped:
    /// only the characters matter.
    private static func plain(_ string: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x1D434...0x1D44D: result.append(UnicodeScalar(scalar.value - 0x1D434 + 0x41)!)   // 𝐴…𝑍
            case 0x1D44E...0x1D467: result.append(UnicodeScalar(scalar.value - 0x1D44E + 0x61)!)   // 𝑎…𝑧
            case 0x210E: result.append("h")                                                         // ℎ
            case 0x2212: result.append("-")                                                         // −
            case 0x20, 0xA0: continue
            default: result.append(scalar)
            }
        }
        return String(result)
    }

    /// Every nucleus in the list, through scripts and nested lists.
    private static func nuclei(of list: MTMathList?) -> [String] {
        guard let list else { return [] }
        var result: [String] = []
        for atom in list.atoms {
            result.append(atom.nucleus)
            result += nuclei(of: atom.superScript) + nuclei(of: atom.subScript)
            if let inner = atom as? MTInner { result += nuclei(of: inner.innerList) }
            if let fraction = atom as? MTFraction { result += nuclei(of: fraction.numerator) + nuclei(of: fraction.denominator) }
            if let radical = atom as? MTRadical { result += nuclei(of: radical.degree) + nuclei(of: radical.radicand) }
            if let accent = atom as? MTAccent { result += nuclei(of: accent.innerList) }
            if let over = atom as? MTOverLine { result += nuclei(of: over.innerList) }
            if let under = atom as? MTUnderLine { result += nuclei(of: under.innerList) }
            if let table = atom as? MTMathTable {
                for row in table.cells { for cell in row { result += nuclei(of: cell) } }
            }
        }
        return result
    }

    // MARK: - The report (#59)

    /// The reporter's file, case by case. Before the fix: `200`, `122`,
    /// `80x0x`, `15x²5x²`.
    func testTheReportedFormulasDrawEachCharacterOnce() {
        // A. cases, display
        XCTAssertEqual(drawn(#"\begin{cases} \frac{20}{x + y} = 12 \\ 80x = 15x^2 \end{cases}"#),
                       "20x+y=1280x=15x2")
        // C. aligned inside \left\{ … \right.
        XCTAssertEqual(drawn(#"\left\{\begin{aligned} \frac{20}{x + y} &= 12 \\ 80x &= 15x^2 \end{aligned}\right."#),
                       "20x+y=1280x=15x2")
        // D. matrix (was right: it draws no delimiters)
        XCTAssertEqual(drawn(#"\begin{matrix} 20 & 12 \\ 80x & 15x^2 \end{matrix}"#), "201280x15x2")
        // E. cases in a line of text (text style)
        XCTAssertEqual(drawn(#"\begin{cases} 20 = 12 \\ 80x = 15 \end{cases}"#, style: .text), "20=1280x=15")
        // The tokens quoted from the reporter's longer document.
        XCTAssertEqual(drawn(#"\begin{cases} x + 2y = 7{,}5 \\ 40(x - y) = 48y^2 \end{cases}"#),
                       "x+2y=7,540(x-y)=48y2")
    }

    /// Case E of the report also ran its two rows together: its picture is
    /// exactly what the engine draws when `\ ` arrives in place of the source's
    /// `\\`. A formula is an atom decided on the source line (constraints.md
    /// "Inline math"), so the row break must reach the engine as written, in
    /// every text kind that typesets inline formulas.
    @MainActor
    func testAnInlineFormulaReachesTheEngineWithItsRowBreak() {
        let formula = #"\begin{cases} 20 = 12 \\ 80x = 15 \end{cases}"#
        let theme = MarkdownTheme.cached(for: .light)
        for markdown in ["E. Inline cases: $\(formula)$", "> quoted $\(formula)$", "# Heading $\(formula)$",
                         "| a |\n|---|\n| $\(formula)$ |"] {
            var asked: [String] = []
            let engine = MathRendering(inlineImage: { latex, _, _ in
                asked.append(latex)
                return NSImage(size: NSSize(width: 40, height: 30))
            }, displayHeight: { _, _, _ in 40 })
            let blocks = MarkdownBlockParser(theme: theme, fontScale: 1).parse(markdown)
            let raw = BlockHeightMeasurer.measure(blocks: blocks, theme: theme, fontScale: 1,
                                                  contentWidth: 600, math: nil)
            _ = BlockHeightMeasurer.measureMathRows(raw.mathPendingRows, in: raw, blocks: blocks, theme: theme,
                                                    fontScale: 1, contentWidth: 600, math: engine)
            XCTAssertFalse(asked.isEmpty, markdown)
            XCTAssertTrue(asked.allSatisfy { $0 == formula }, "\(markdown): \(asked)")
        }
    }

    // MARK: - Delimiters never change what is inside

    private static let bodies = [
        "80x", "2x+1", "ab", "12ab", #"\frac{12ab}{cd}"#, #"\sqrt{2xy}"#, "x^{2ab}", #"3y - 40z"#,
        #"\text{clip}(x)"#, #"\sin 2x"#, #"\hat{ab} + \vec{cd}"#, #"a_{12n}b"#
    ]

    func testLeftRightDrawsItsContentAsWithoutDelimiters() {
        let pairs = [(#"\left("#, #"\right)"#), (#"\left["#, #"\right]"#), (#"\left|"#, #"\right|"#),
                     (#"\left\{"#, #"\right."#), (#"\left."#, #"\right\}"#), (#"\left\langle "#, #"\right\rangle"#)]
        for style in [MTLineStyle.display, .text] {
            for body in Self.bodies {
                let expected = drawn(body, style: style)
                XCTAssertFalse(expected.isEmpty, body)
                for (open, close) in pairs {
                    XCTAssertEqual(drawn(open + body + close, style: style), expected, "\(open) \(body) \(close)")
                }
            }
        }
    }

    /// Each level used to double the damage: two levels drew `12abababab`.
    func testNestedDelimitersDrawTheirContentOnce() {
        for body in Self.bodies {
            let expected = drawn(body)
            XCTAssertEqual(drawn(#"\left(\left("# + body + #"\right)\right)"#), expected, body)
            XCTAssertEqual(drawn(#"\left(\left[\left\{"# + body + #"\right\}\right]\right)"#), expected, body)
        }
        XCTAssertEqual(drawn(#"\left(\left(12ab\right)\right)"#), "12ab")
    }

    /// Delimiters in every place a list is typeset from: scripts, fractions,
    /// radicals, the rows of an environment.
    func testDelimitersInsideOtherStructuresDrawTheirContentOnce() {
        XCTAssertEqual(drawn(#"\sqrt{\left(2x\right)^2 + \left(3y\right)^2}"#), "2x2+3y2")
        XCTAssertEqual(drawn(#"\frac{\left(2ab\right)}{\left(3cd\right)}"#), "2ab3cd")
        XCTAssertEqual(drawn(#"x_{\left(2ab\right)}^{\left[3cd\right]}"#), drawn(#"x_{2ab}^{3cd}"#))
        XCTAssertEqual(drawn(#"\lim_{n \to \infty} \left(1 + \frac{1}{2n}\right)^{2n}"#),
                       drawn(#"\lim_{n \to \infty} 1 + \frac{1}{2n}^{2n}"#))
        XCTAssertEqual(drawn(#"f(x) = \begin{cases} 2x & \text{if } x > 10 \\ 15x^2 & \text{otherwise} \end{cases}"#),
                       "f(x)=2xifx>1015x2otherwise")
    }

    /// The measuring pass used up a big operator's limits, so the placed pass
    /// drew `∑` bare: the bounds vanished inside `\left…\right`.
    func testLimitsOfABigOperatorSurviveDelimiters() {
        for body in [#"\sum_{i=1}^{n} x_i"#, #"\prod_{k=1}^{12} ab"#, #"\int_{0}^{2\pi} f(x)"#, #"\lim_{n \to 0} 2n"#] {
            let expected = drawn(body)
            XCTAssertEqual(drawn(#"\left("# + body + #"\right)"#), expected, body)
        }
        XCTAssertEqual(drawn(#"\left(\sum_{i=1}^{n} x_i\right)"#), "ni=1xi", "the bounds are drawn")
    }

    // MARK: - Environments

    /// Every environment that draws delimiters went through the same double
    /// pass; a cell draws what the same source draws on its own.
    func testEnvironmentCellsDrawTheirSourceOnce() {
        let cells = [["20", "12ab"], ["80x", "15x^2"], [#"\frac{2ab}{3cd}"#, "x + 2y"]]
        let expected = cells.flatMap { $0 }.map { drawn($0) }.joined()
        let rows = cells.map { $0.joined(separator: " & ") }.joined(separator: #" \\ "#)
        for environment in ["matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "cases"] {
            XCTAssertEqual(drawn("\\begin{\(environment)} \(rows) \\end{\(environment)}"), expected, environment)
            XCTAssertEqual(drawn("\\begin{\(environment)} \(rows) \\end{\(environment)}", style: .text), expected,
                           "\(environment), text style")
        }
        // Alignment environments, bare and inside delimiters.
        for environment in ["aligned", "split"] {
            let table = "\\begin{\(environment)} 80x &= 15x^2 \\\\ 12y &= 7ab \\end{\(environment)}"
            XCTAssertEqual(drawn(table), "80x=15x212y=7ab", environment)
            XCTAssertEqual(drawn(#"\left\{"# + table + #"\right."#), "80x=15x212y=7ab", environment)
            XCTAssertEqual(drawn(#"\left("# + table + #"\right)"#), "80x=15x212y=7ab", environment)
        }
    }

    // MARK: - The invariant

    private static let invariantCases = [
        #"\left(80x\right)"#, #"\left(\left(12ab\right)\right)"#, #"\left(\sum_{i=1}^{n} x_i\right)"#,
        #"\begin{cases} \frac{20}{x + y} = 12 \\ 80x = 15x^2 \end{cases}"#,
        #"\begin{pmatrix} 20 & 12ab \\ 80x & 15x^2 \end{pmatrix}"#,
        #"\begin{aligned} 80x &= 15x^2 \\ 12y &= 7ab \end{aligned}"#,
        #"\widehat{abc} + \overrightarrow{AB} + \vec{ab}"#, #"\sqrt[3]{80x} + \frac{80x}{12y}"#,
        #"\overline{80x} + \underline{12ab}"#, #"x^{12ab}_{34cd}"#, #"\text{clip}(2xy)"#
    ]

    /// The internal entry is the one nested lists go through, and it takes the
    /// caller's list as it is. Typesetting it must leave every atom alone, so a
    /// second pass over the same list draws the same thing.
    func testTypesettingLeavesTheListUnchangedAndCanBeRepeated() {
        for latex in Self.invariantCases {
            guard let list = build(latex)?.finalized else { continue }
            let before = Self.nuclei(of: list)
            let first = MTTypesetter.createLineForMathList(list, font: font, style: .display, cramped: false)
            XCTAssertEqual(Self.nuclei(of: list), before, "the first pass changed the list: \(latex)")
            let second = MTTypesetter.createLineForMathList(list, font: font, style: .display, cramped: false)
            XCTAssertEqual(Self.nuclei(of: list), before, "the second pass changed the list: \(latex)")
            XCTAssertFalse(Self.text(of: first).isEmpty, latex)
            XCTAssertEqual(Self.text(of: second), Self.text(of: first), latex)
            XCTAssertEqual(second?.width, first?.width, latex)
            XCTAssertEqual(second?.ascent, first?.ascent, latex)
            XCTAssertEqual(second?.descent, first?.descent, latex)
        }
    }

    /// The same through the entry the app uses: one parsed list, typeset for
    /// the measurer and again for the view.
    func testAParsedListCanBeTypesetAgain() {
        for latex in Self.invariantCases {
            guard let list = build(latex) else { continue }
            let before = Self.nuclei(of: list)
            let first = MTTypesetter.createLineForMathList(list, font: font, style: .display)
            let second = MTTypesetter.createLineForMathList(list, font: font, style: .text)
            XCTAssertEqual(Self.nuclei(of: list), before, latex)
            XCTAssertEqual(Self.text(of: second), Self.text(of: first), latex)
        }
    }
}
