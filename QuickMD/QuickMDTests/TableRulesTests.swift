import XCTest
import SwiftUI
import AppKit

/// #56: on macOS 27.2 a table showed its header band, outline and column
/// dividers, but no horizontal rules — AppKit stopped painting the cells'
/// bottom borders. Since then the rules are OUR drawing: the blocks keep their
/// border widths (layout) with a clear colour, and `paintTableRules` fills the
/// rects from the laid-out cells after everything else (`drawTable`).
///
/// These tests never rely on AppKit painting a border. They pin:
/// - the geometry (`tableRuleRects`): which rules exist and where — the rects
///   AppKit itself filled on macOS 27.0 (logged via `fillBackgroundRectArray`);
/// - that the string asks AppKit to paint nothing (clear borders), so a rule
///   is never painted twice and nothing but our pass draws it;
/// - the pixels: a table drawn through `drawTable` (the steps `TableTextView`
///   runs) has rule-coloured pixels on every rule, with and without a
///   selection, at 1× and 2×, light and dark, 100 % and 150 %;
/// - device-pixel alignment of a rule.
final class TableRulesTests: XCTestCase {

    /// Draws as `TableTextView` does: `drawTable` around `super.draw`, and the
    /// document selection under the text (`SelfSizingTextView.drawBackground`).
    /// `TableTextView` itself is not compiled into the test target.
    private final class RulesTestView: DocumentCellTextView {
        var tableBackground: NSColor = .clear
        var tableLayout: TableTextLayout?
        var ruleColor: NSColor = .clear

        override func draw(_ dirtyRect: NSRect) {
            drawTable(in: dirtyRect, background: tableBackground, layout: tableLayout, ruleColor: ruleColor) {
                super.draw(dirtyRect)
            }
        }

        override func drawBackground(in rect: NSRect) {
            super.drawBackground(in: rect)
            (layoutManager as? DocumentSelectionLayoutManager)?.drawSelection(in: rect, of: self)
        }
    }

    private static let simple = """
    | Name | Role | Since |
    |------|------|-------|
    | Ada | Engineer | 2019 |
    | Grace | Admiral | 1943 |
    | Linus | Maintainer | 1991 |
    """
    private static let headerless = """
    | | | |
    |---|---|---|
    | a | b | c |
    | d | e | f |
    """
    private static let headerOnly = """
    | Lonely | Header |
    |---|---|
    """
    private static let oneRow = """
    | Name | Value |
    |---|---|
    | alpha | beta |
    """
    private static let wrapped = """
    | Feature | Description | Status |
    |:--|:-:|--:|
    | **Search** | Finds every occurrence across the document, including text inside tables, and highlights the focused one | `done` |
    | Links | See [the docs](https://example.com/docs) for the full list of supported inline syntax which wraps | **beta** |
    """
    private static let frontMatter = """
    ---
    title: A title
    tags: [one, two, three]
    author: Someone with a rather long name
    ---

    body
    """

    private func table(_ markdown: String, theme: MarkdownTheme = .cached(for: .light),
                       fontScale: CGFloat = 1) throws -> TableText {
        for block in MarkdownBlockParser(theme: theme, fontScale: fontScale).parse(markdown) {
            if case .table(let headers, let rows, let alignments, let style) = block.content {
                return TableTextBuilder.build(headers: headers, rows: rows, alignments: alignments, style: style,
                                              theme: theme, fontScale: fontScale)
            }
        }
        XCTFail("no table in fixture")
        throw CocoaError(.featureUnsupported)
    }

    /// A laid-out table view at `width`, as tall as the measured table.
    /// `withRules: false` leaves out our pass (no layout → no rules).
    private func view(_ text: TableText, theme: MarkdownTheme, width: CGFloat = 420,
                      withRules: Bool = true) -> RulesTestView {
        let view = RulesTestView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        view.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        view.configureForSelfSizing()
        view.installDocumentSelectionLayoutManager()
        view.textStorage?.setAttributedString(text.string)
        view.tableBackground = NSColor(theme.backgroundColor)
        view.tableLayout = withRules ? text.layout : nil
        view.ruleColor = text.ruleColor
        let height = TableTextBuilder.tableHeight(layoutManager: view.layoutManager!, container: view.textContainer!)
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        return view
    }

    private func bitmap(width: Int, height: Int) -> NSBitmapImageRep {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                         bytesPerRow: 0, bitsPerPixel: 0)!
    }

    private func render(_ view: NSView, backing: Int) -> NSBitmapImageRep {
        let rep = bitmap(width: Int(view.bounds.width) * backing, height: Int(view.bounds.height) * backing)
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// `top` painted source-over on `bottom`, in the bitmap format and the
    /// appearance the view draws with — what a rule pixel must look like.
    private func composite(_ top: NSColor?, over bottom: NSColor, appearance: NSAppearance.Name) -> NSColor {
        let rep = bitmap(width: 1, height: 1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            bottom.setFill()
            NSRect(x: 0, y: 0, width: 1, height: 1).fill()
            if let top {
                top.setFill()
                NSRect(x: 0, y: 0, width: 1, height: 1).fill(using: .sourceOver)
            }
        }
        NSGraphicsContext.current = previous
        return rep.colorAt(x: 0, y: 0)!
    }

    private func distance(_ a: NSColor?, _ b: NSColor) -> CGFloat {
        guard let a else { return .infinity }
        return max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                   abs(a.blueComponent - b.blueComponent), abs(a.alphaComponent - b.alphaComponent))
    }

    /// Where a rule is sampled: on a divider half-way down, on a horizontal
    /// rule 6 pt in — away from the rounded corners and from any text.
    private func samplePoint(of rule: NSRect) -> NSPoint {
        rule.height > rule.width ? NSPoint(x: rule.minX, y: rule.midY) : NSPoint(x: rule.minX + 6, y: rule.minY)
    }

    // MARK: - The string paints nothing

    /// AppKit must not paint the rules (a translucent theme colour would be
    /// painted twice, and the rules would again depend on AppKit): every
    /// block's border colour is clear. The WIDTHS stay — they are layout.
    func testCellBordersKeepTheirWidthsButAreClear() throws {
        for markdown in [Self.simple, Self.headerless, Self.headerOnly, Self.frontMatter] {
            let text = try table(markdown)
            var blocks = 0
            text.string.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.string.length)) {
                value, _, _ in
                guard let block = (value as? NSParagraphStyle)?.textBlocks.first else { return }
                blocks += 1
                for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] {
                    let colour = block.borderColor(for: edge)?.usingColorSpace(.sRGB)
                    XCTAssertEqual(colour?.alphaComponent ?? 0, 0, "\(markdown.prefix(12)) edge \(edge.rawValue)")
                }
            }
            XCTAssertEqual(blocks, text.layout.bandCount * text.layout.columnCount)
        }
        let first = try table(Self.simple)
        let style = first.string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
        XCTAssertEqual(style.textBlocks[0].width(for: .border, edge: .maxX), BlockLayout.Table.dividerWidth)
        XCTAssertEqual(style.textBlocks[0].width(for: .border, edge: .maxY), BlockLayout.Table.separatorHeight)
    }

    /// The rule colour is the theme's border colour (what the borders were).
    func testRuleColourIsTheThemesBorderColour() throws {
        for scheme in [ColorScheme.light, .dark] {
            let theme = MarkdownTheme.cached(for: scheme)
            let text = try table(Self.simple, theme: theme)
            let appearance: NSAppearance.Name = theme.isDark ? .darkAqua : .aqua
            let drawn = composite(text.ruleColor, over: .white, appearance: appearance)
            XCTAssertLessThan(distance(drawn, composite(NSColor(theme.borderColor), over: .white,
                                                        appearance: appearance)), 0.5 / 255)
            XCTAssertGreaterThan(distance(drawn, composite(nil, over: .white, appearance: appearance)), 10 / 255,
                                 "\(scheme): the rule colour is visible on white")
        }
    }

    // MARK: - Geometry

    /// Every cell but the last column has its trailing divider (full cell
    /// height); every band but the last has its bottom rule (cell width up to
    /// the divider); a header band always has one (1.12's header separator).
    /// These are the rects AppKit filled itself on macOS 27.0, which is why
    /// the drawing is pixel-identical there.
    func testRuleRectsFollowTheLaidOutCells() throws {
        let theme = MarkdownTheme.cached(for: .light)
        for markdown in [Self.simple, Self.headerless, Self.headerOnly, Self.oneRow, Self.wrapped, Self.frontMatter] {
            for scale in [CGFloat(1), 1.5] {
                let text = try table(markdown, theme: theme, fontScale: scale)
                let view = view(text, theme: theme)
                XCTAssertEqual(view.tableRuleRects(layout: text.layout), try expectedRules(view, text.layout),
                               "\(markdown.prefix(20)) @\(scale)")
            }
        }
    }

    /// The rules a table must have, from its cells alone (not from
    /// `tableRuleRects`, so a rule that helper dropped is still expected).
    private func expectedRules(_ view: NSTextView, _ layout: TableTextLayout) throws -> [NSRect] {
        var expected: [NSRect] = []
        for band in 0..<layout.bandCount {
            for column in 0..<layout.columnCount {
                let bounds = try XCTUnwrap(view.tableCellBounds(band: band, column: column, layout: layout))
                let lastColumn = column == layout.columnCount - 1
                let divider = lastColumn ? 0 : BlockLayout.Table.dividerWidth
                if !lastColumn {
                    expected.append(NSRect(x: bounds.maxX - divider, y: bounds.minY,
                                           width: divider, height: bounds.height))
                }
                if band < layout.bandCount - 1 || (layout.showsHeader && band == 0) {
                    let height = BlockLayout.Table.separatorHeight
                    expected.append(NSRect(x: bounds.minX, y: bounds.maxY - height,
                                           width: bounds.width - divider, height: height))
                }
            }
        }
        return expected
    }

    /// A headerless table has no header rule, a header-only table keeps its
    /// separator, a properties table has a divider per row after the key.
    func testRuleCountsPerTableKind() throws {
        let theme = MarkdownTheme.cached(for: .light)
        func counts(_ markdown: String) throws -> [Int] {
            let text = try table(markdown, theme: theme)
            let rects = view(text, theme: theme).tableRuleRects(layout: text.layout)
            let dividers = rects.filter { $0.height > $0.width }.count
            return [dividers, rects.count - dividers]
        }
        XCTAssertEqual(try counts(Self.simple), [8, 9], "4 bands × 2 dividers; 3 rules × 3 cells")
        XCTAssertEqual(try counts(Self.headerless), [4, 3], "2 bands × 2 dividers; 1 rule × 3 cells")
        XCTAssertEqual(try counts(Self.headerOnly), [1, 2], "the header keeps its separator")
        XCTAssertEqual(try counts(Self.oneRow), [2, 2], "the header separator only")
        XCTAssertEqual(try counts(Self.frontMatter), [3, 4], "3 keys: a divider each; 2 rules × 2 cells")
    }

    /// A limited request returns the rules of the bands that reach into the
    /// rect (a draw costs only the visible bands of a long table), and slices
    /// covering the table add up to the whole set.
    func testLimitedRuleRectsAreTheVisibleBandsShare() throws {
        let theme = MarkdownTheme.cached(for: .light)
        var markdown = "| Name | Role | Since |\n|---|---|---|\n"
        for row in 0..<200 { markdown += "| Person \(row) | Engineer \(row) | \(1900 + row) |\n" }
        let text = try table(markdown, theme: theme)
        let view = view(text, theme: theme)
        let all = view.tableRuleRects(layout: text.layout)
        XCTAssertEqual(all.count, 201 * 2 + 200 * 3)

        let visible = NSRect(x: 0, y: 2_000, width: 420, height: 800)
        let limited = view.tableRuleRects(layout: text.layout, in: visible)
        XCTAssertLessThan(limited.count, all.count / 5)
        XCTAssertEqual(limited.filter { $0.intersects(visible) }, all.filter { $0.intersects(visible) })

        var union = Set<String>()
        var top: CGFloat = 0
        while top < view.bounds.height {
            let slice = NSRect(x: 0, y: top, width: 420, height: 333)
            union.formUnion(view.tableRuleRects(layout: text.layout, in: slice).map { NSStringFromRect($0) })
            top += 333
        }
        XCTAssertEqual(union, Set(all.map { NSStringFromRect($0) }))
    }

    // MARK: - Pixels

    /// Every rule shows in the rule colour over the table background — the
    /// header separator, the rules between rows, the dividers — and the
    /// padding right above a horizontal rule is not rule-coloured (a line, not
    /// a band). Light/dark, 100/150 %, 1×/2×, with and without ⌘A.
    func testEveryRuleIsPaintedByOurPass() throws {
        for scheme in [ColorScheme.light, .dark] {
            let theme = MarkdownTheme.cached(for: scheme)
            let appearance: NSAppearance.Name = theme.isDark ? .darkAqua : .aqua
            let background = NSColor(theme.backgroundColor)
            let ruleOnBackground = composite(NSColor(theme.borderColor), over: background, appearance: appearance)
            XCTAssertGreaterThan(distance(ruleOnBackground, composite(nil, over: background, appearance: appearance)),
                                 8 / 255, "\(scheme): the rule is visible at all")
            for scale in [CGFloat(1), 1.5] {
                for markdown in [Self.simple, Self.headerless, Self.wrapped, Self.frontMatter] {
                    let text = try table(markdown, theme: theme, fontScale: scale)
                    for selectAll in [false, true] {
                        let view = view(text, theme: theme)
                        if selectAll {
                            (view.layoutManager as! DocumentSelectionLayoutManager).selectionCoveredRange =
                                NSRange(location: 0, length: text.layout.length)
                        }
                        let rules = try expectedRules(view, text.layout)
                        XCTAssertFalse(rules.isEmpty)
                        for backing in [1, 2] {
                            let rep = render(view, backing: backing)
                            let k = CGFloat(backing)
                            let label = "\(scheme) @\(scale) \(backing)x ⌘A=\(selectAll) \(markdown.prefix(16))"
                            for rule in rules {
                                let point = samplePoint(of: rule)
                                let pixel = rep.colorAt(x: Int(point.x * k), y: Int(point.y * k))
                                XCTAssertLessThan(distance(pixel, ruleOnBackground), 2.5 / 255,
                                                  "\(label): rule \(rule)")
                                if rule.width > rule.height, !selectAll {
                                    let above = rep.colorAt(x: Int(point.x * k), y: Int((point.y - 2) * k))
                                    XCTAssertGreaterThan(distance(above, ruleOnBackground), 2.5 / 255,
                                                         "\(label): 2 pt above \(rule)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Without our pass the rules are not there: AppKit paints nothing on a
    /// rule (the borders are clear), so `paintTableRules` is the only painter
    /// — never a double paint of a translucent colour, never a rule that
    /// depends on AppKit's border drawing (#56).
    func testNothingButOurPassPaintsTheRules() throws {
        for scheme in [ColorScheme.light, .dark] {
            let theme = MarkdownTheme.cached(for: scheme)
            let appearance: NSAppearance.Name = theme.isDark ? .darkAqua : .aqua
            let plain = composite(nil, over: NSColor(theme.backgroundColor), appearance: appearance)
            let text = try table(Self.simple, theme: theme)
            let rules = try expectedRules(view(text, theme: theme), text.layout)
            let rep = render(view(text, theme: theme, withRules: false), backing: 2)
            for rule in rules {
                let point = samplePoint(of: rule)
                XCTAssertLessThan(distance(rep.colorAt(x: Int(point.x * 2), y: Int(point.y * 2)), plain), 1.5 / 255,
                                  "\(scheme): something else painted \(rule)")
            }
        }
    }

    // MARK: - Ragged rows and the suspected macOS 27.2 behaviour

    private static let ragged = """
    | Short | A cell long enough to wrap onto several lines in a narrow table column | x |
    |---|---|---|
    | a | This one wraps as well, over two or three lines at the test width, while its neighbours stay one line | b |
    | c | d | e |
    """

    /// The top of the band below `band` — where `band`'s rule must end —
    /// taken from the NEXT band's cells, i.e. without `tableRuleRects`.
    private func nextBandTop(_ view: NSTextView, _ layout: TableTextLayout, after band: Int) throws -> CGFloat {
        try (0..<layout.columnCount).map {
            try XCTUnwrap(view.tableCellBounds(band: band + 1, column: $0, layout: layout)).minY
        }.min()!
    }

    /// Pixels along the 1 pt row ending at `bottom`, every 3 pt across the
    /// table (dividers included — one rect covers the corner), must all be
    /// the rule colour: one straight rule, no gap, no step.
    /// `colours`: what a rule pixel may be (the rule over the table
    /// background, or — under a header whose band reaches the last point —
    /// over the header background).
    private func assertStraightRule(in rep: NSBitmapImageRep, bottom: CGFloat, width: CGFloat, backing: CGFloat,
                                    colours: [NSColor], _ label: String) {
        var x: CGFloat = 6
        while x < width - 6 {
            let pixel = rep.colorAt(x: Int(x * backing), y: Int((bottom - 0.5) * backing))
            let nearest = colours.map { distance(pixel, $0) }.min()!
            XCTAssertLessThan(nearest, 2.5 / 255, "\(label): x=\(x) y=\(bottom - 0.5)")
            x += 3
        }
    }

    /// A wrapped cell next to one-line cells: every bottom rule of that band
    /// sits on the band's last point (the top of the next band), and the
    /// drawn rule is one straight line across the whole table.
    func testWrappedCellNextToShortOnesGivesOneStraightRule() throws {
        let theme = MarkdownTheme.cached(for: .light)
        let text = try table(Self.ragged, theme: theme)
        let view = view(text, theme: theme, width: 300)
        let layout = text.layout
        let ruleOnBackground = composite(NSColor(theme.borderColor), over: NSColor(theme.backgroundColor),
                                         appearance: .aqua)
        let rules = view.tableRuleRects(layout: layout)
        let rep = render(view, backing: 2)
        for band in 0..<(layout.bandCount - 1) {
            let bottom = try nextBandTop(view, layout, after: band)
            let heights = try (0..<layout.columnCount).map {
                try XCTUnwrap(view.tableCellBounds(band: band, column: $0, layout: layout)).height
            }
            XCTAssertGreaterThan(heights.max()!, 40, "band \(band) wraps") // one line is ~30 pt
            let bandRules = rules.filter { $0.width > $0.height && abs($0.maxY - bottom) < 20 }
            XCTAssertEqual(bandRules.count, layout.columnCount, "band \(band): one rule piece per cell")
            for rule in bandRules {
                XCTAssertEqual(rule.maxY, bottom, "band \(band): \(rule)")
                XCTAssertEqual(rule.height, BlockLayout.Table.separatorHeight)
            }
            assertStraightRule(in: rep, bottom: bottom, width: view.bounds.width, backing: 2,
                               colours: [ruleOnBackground], "band \(band)")
        }
    }

    /// Simulates one suspected 27.2 behaviour: the blocks lose their bottom
    /// border widths (0 — AppKit neither reserves nor reports them). Our pass
    /// decides from the layout, not from the blocks, so every rule under a
    /// band is still painted, straight, on the band's last point — under the
    /// header over the header band's background, which now reaches that
    /// point (the look of the rule changes there, it does not vanish).
    func testRulesSurviveBlocksWithoutBottomBorders() throws {
        for scheme in [ColorScheme.light, .dark] {
            let theme = MarkdownTheme.cached(for: scheme)
            let appearance: NSAppearance.Name = theme.isDark ? .darkAqua : .aqua
            let ruleOnBackground = composite(NSColor(theme.borderColor), over: NSColor(theme.backgroundColor),
                                             appearance: appearance)
            let headerBand = composite(NSColor(theme.headerBackgroundColor), over: NSColor(theme.backgroundColor),
                                       appearance: appearance)
            let ruleOnHeader = composite(NSColor(theme.borderColor), over: headerBand, appearance: appearance)
            for markdown in [Self.simple, Self.ragged, Self.headerless, Self.frontMatter] {
                let text = try table(markdown, theme: theme)
                var stripped = 0
                text.string.enumerateAttribute(.paragraphStyle,
                                               in: NSRange(location: 0, length: text.string.length)) { value, _, _ in
                    guard let block = (value as? NSParagraphStyle)?.textBlocks.first else { return }
                    if block.width(for: .border, edge: .maxY) > 0 { stripped += 1 }
                    block.setWidth(0, type: .absoluteValueType, for: .border, edge: .maxY)
                }
                XCTAssertGreaterThan(stripped, 0)
                let view = view(text, theme: theme, width: 360)
                let layout = text.layout
                for backing in [1, 2] {
                    let rep = render(view, backing: backing)
                    for band in 0..<(layout.bandCount - 1) {
                        assertStraightRule(in: rep, bottom: try nextBandTop(view, layout, after: band),
                                           width: view.bounds.width, backing: CGFloat(backing),
                                           colours: layout.showsHeader && band == 0
                                               ? [ruleOnHeader, ruleOnBackground] : [ruleOnBackground],
                                           "\(scheme) \(backing)x \(markdown.prefix(12)) band \(band)")
                    }
                }
            }
        }
    }

    // MARK: - Device pixels

    /// A rule lands on whole device pixels of the context it is drawn into
    /// and never rounds away: thinner than a pixel → the pixel holding its
    /// centre. Whole-pixel rects (every table measured) stay as they are.
    func testPixelAlignmentSnapsToTheDeviceGrid() {
        for backing in [CGFloat(1), 2] {
            let rep = bitmap(width: Int(100 * backing), height: Int(100 * backing))
            rep.size = NSSize(width: 100, height: 100)
            let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
            let onGrid = NSRect(x: 10, y: 33, width: 80, height: 1)
            XCTAssertEqual(TableTextBuilder.pixelAligned(onGrid, in: context), onGrid, "\(backing)x")

            let fractional = NSRect(x: 10.2, y: 33.3, width: 80, height: 1)
            let aligned = TableTextBuilder.pixelAligned(fractional, in: context)
            for edge in [aligned.minX, aligned.maxX, aligned.minY, aligned.maxY] {
                XCTAssertEqual((edge * backing).rounded(), edge * backing, accuracy: 1e-9, "\(backing)x")
            }
            XCTAssertEqual(aligned.height, 1, accuracy: 1e-9, "\(backing)x: still one point thick")

            let hairline = NSRect(x: 10, y: 40.1, width: 80, height: 0.2)
            let thin = TableTextBuilder.pixelAligned(hairline, in: context)
            XCTAssertEqual(thin.height, 1 / backing, accuracy: 1e-9, "\(backing)x: one device pixel")
            XCTAssertLessThanOrEqual(thin.minY, hairline.midY)
            XCTAssertGreaterThanOrEqual(thin.maxY, hairline.midY)
        }
    }
}
