import Foundation
import SwiftUI
import AppKit

// MARK: - Dual-Scope Styling
//
// Rendered AttributedStrings travel down TWO pipelines:
//  • SwiftUI Text — the printable/PDF views (`PrintableTableView` included)
//    read the SwiftUI-scope attributes;
//  • NSTextView (TextBlockView, TableTextView) — text/heading/blockquote
//    blocks and on-screen table cells (since v1.13) convert via
//    `NSAttributedString(_, including: \.appKit)`, which only carries
//    AppKit-scope (+ Foundation) attributes.
// Every style the renderer sets MUST stamp both scopes, or one pipeline
// silently loses formatting. Use these helpers — never set `.font` /
// `.foregroundColor` directly in renderer code.
// The one exception is NSParagraphStyle (list indents): SwiftUI `Text` has no
// equivalent, so it is AppKit-only by necessity — see "List Indentation".
extension AttributedString {

    /// Set font in both SwiftUI and AppKit scopes. `fonts` supplies the family
    /// (body, or code when `monospaced`) — the theme's `DocumentFonts`, which
    /// already has the user's Settings choice merged in. Required on purpose:
    /// a call site that forgets it would silently render in the system font.
    mutating func setDualFont(size: CGFloat, bold: Bool = false, italic: Bool = false,
                              monospaced: Bool = false, fonts: DocumentFonts) {
        self.font = fonts.swiftUI(size: size, weight: bold ? .bold : .regular,
                                  italic: italic, monospaced: monospaced)
        self[AttributeScopes.AppKitAttributes.FontAttribute.self] =
            fonts.appKit(size: size, weight: bold ? .bold : .regular,
                         italic: italic, monospaced: monospaced)
    }

    /// Set foreground color in both scopes.
    mutating func setDualForeground(_ color: Color) {
        self.foregroundColor = color
        self[AttributeScopes.AppKitAttributes.ForegroundColorAttribute.self] = NSColor(color)
    }

    /// Set background color in both scopes (inline code chips).
    mutating func setDualBackground(_ color: Color) {
        self.backgroundColor = color
        self[AttributeScopes.AppKitAttributes.BackgroundColorAttribute.self] = NSColor(color)
    }

    /// Set single underline in both scopes (links).
    mutating func setDualUnderline() {
        self.underlineStyle = .single
        self[AttributeScopes.AppKitAttributes.UnderlineStyleAttribute.self] = .single
    }

    /// Set single strikethrough in both scopes (~~text~~, checked tasks).
    mutating func setDualStrikethrough() {
        self.strikethroughStyle = .single
        self[AttributeScopes.AppKitAttributes.StrikethroughStyleAttribute.self] = .single
    }
}

// MARK: - Zoom (⌘+ / ⌘- / ⌘0)

/// One step of the text-size ladder. Deliberately NOT a theme property and the
/// window's level is NOT persisted: zoom belongs to the window you're reading
/// in, so adjusting one tab leaves the others alone. Each window STARTS at the
/// default from Settings ▸ Fonts (`DefaultZoom`, #48), and ⌘0 returns to it.
enum MarkdownZoom {
    case bigger, smaller, actualSize

    static let steps: [Double] = [0.7, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    /// Applies this step to `current`, clamped at both ends of the ladder.
    /// Bigger / Smaller step from wherever the window is; Actual Size (⌘0)
    /// goes back to `defaultScale` — the user's default, not a fixed 100%
    /// (Safari's Actual Size does the same with its default page zoom).
    /// `defaultScale` is required on purpose: a defaulted 1.0 would let a new
    /// caller silently bring back "⌘0 = 100%".
    func applied(to current: Double, defaultScale: Double) -> Double {
        guard self != .actualSize else { return defaultScale }
        // Snap to the nearest rung first so we never get stuck between steps.
        let index = Self.steps.enumerated()
            .min(by: { abs($0.element - current) < abs($1.element - current) })?.offset ?? 0
        let target = self == .bigger ? index + 1 : index - 1
        return Self.steps[min(max(target, 0), Self.steps.count - 1)]
    }
}

/// The size every document window opens at (Settings ▸ Fonts ▸ Default zoom,
/// #48). One stored value, read by the Settings picker and by `MarkdownView`;
/// print and PDF export ignore it and always render at 1.0.
///
/// Every choice is a rung of `MarkdownZoom.steps`, so ⌘+ / ⌘− from the
/// default land on the neighbouring rungs instead of snapping first.
enum DefaultZoom {
    static let defaultsKey = "defaultZoom"
    static let choices: [Double] = [0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

    /// The nearest value in `choices`. A missing key reads as 0 and garbage
    /// from `defaults write` can be anything, so non-finite or non-positive
    /// values mean 1.0 — the Picker never shows an empty selection and a
    /// document never opens unreadably small. Out-of-range values clamp to the
    /// nearest end. Ties (1.05 between 1.0 and 1.1) go to the SMALLER choice;
    /// the 1e-9 tolerance keeps that true despite binary floating point.
    static func normalized(_ stored: Double) -> Double {
        guard stored.isFinite, stored > 0 else { return 1.0 }
        var best = choices[0]
        var bestDistance = abs(best - stored)
        for choice in choices.dropFirst() {
            let distance = abs(choice - stored)
            if distance < bestDistance - 1e-9 {
                best = choice
                bestDistance = distance
            }
        }
        return best
    }

    /// "125%" — the Picker label and the zoom pill's help text.
    static func title(for scale: Double) -> String {
        "\(Int((scale * 100).rounded()))%"
    }

    /// The stored default from `defaults`, normalized (missing key → 1.0).
    /// Separate from `current` so tests can use their own suite.
    static func stored(in defaults: UserDefaults) -> Double {
        normalized(defaults.double(forKey: defaultsKey))
    }

    /// The default for a window being created now.
    static var current: Double { stored(in: .standard) }
}

struct MarkdownRenderer: Sendable {
    let theme: MarkdownTheme
    /// ⌘+ / ⌘- zoom multiplier for this render pass. 1.0 = design sizes.
    let fontScale: CGFloat
    let referenceDefinitions: [String: String]
    let footnoteDefinitions: [(id: String, content: String)]
    /// True while rendering a LINK'S TEXT: links cannot contain links
    /// (CommonMark), so `tryParseLink` declines and nesting stays at depth 1.
    /// Without it `[[[…![a](b)…](u)](u)](u)` recursed once per bracket level
    /// (makeLink → renderInlineFormatting → tryParseLink → makeLink …) and
    /// overflowed the parse task's stack at a few hundred levels.
    private var linksDisabled = false
    /// True for a front-matter VALUE (`renderInline(_:literalBackslashes:)`):
    /// YAML has no Markdown escapes — a plain scalar's backslash is a
    /// character (`C:\_tmp`) — so `\` starts no escape there and shows as
    /// written; every other inline form still renders. Copied into the link
    /// text renderer with the rest of `self`.
    private var escapesDisabled = false
    /// Character references (`AT&amp;T`, `&copy;`, `&#169;`) are decoded in
    /// every piece of inline TEXT this renderer draws — plain runs, emphasis,
    /// link text, image alt — as on GitHub (`HTMLEntities`, full HTML5 table),
    /// so a heading's id slugs `Q&A`, not `Q&amp;A`. AFTER inline parsing:
    /// `&#42;` is a literal `*`, never emphasis; code spans keep the reference
    /// as written. True only for a front-matter value
    /// (`renderInline(_:literalBackslashes:literalEntities:)`): GitHub shows
    /// front matter as plain text, references included.
    private var entitiesLiteral = false

    /// `text` with its character references decoded, unless `entitiesLiteral`.
    private func decodedText(_ text: String) -> String {
        entitiesLiteral ? text : HTMLEntities.decode(text)
    }

    // Static precompiled regex for parsing (avoid recompilation per line)
    private static let taskListRegex = try! NSRegularExpression(pattern: MarkdownTheme.taskListPattern)
    private static let autolinkRegex = try! NSRegularExpression(pattern: MarkdownTheme.autolinkPattern)
    private static let headerRegex = try! NSRegularExpression(pattern: MarkdownTheme.headerPattern)

    init(theme: MarkdownTheme, fontScale: CGFloat = 1.0, referenceDefinitions: [String: String] = [:], footnoteDefinitions: [(id: String, content: String)] = []) {
        self.theme = theme
        self.fontScale = fontScale
        self.referenceDefinitions = referenceDefinitions
        self.footnoteDefinitions = footnoteDefinitions
    }

    /// Print/PDF convenience: Auto palette + the user's Settings fonts.
    init(colorScheme: ColorScheme, referenceDefinitions: [String: String] = [:]) {
        self.theme = MarkdownTheme.exportTheme(for: colorScheme)
        self.fontScale = 1.0
        self.referenceDefinitions = referenceDefinitions
        self.footnoteDefinitions = []
    }

    /// Scales a design-time point size to this render pass's zoom level.
    func scaled(_ size: CGFloat) -> CGFloat { size * fontScale }

    // MARK: - Main Render

    func render(_ markdown: String) -> AttributedString {
        let lines = Self.joinSoftBreaks(markdown.components(separatedBy: "\n"))
        // Ordered items of one list line up on the WIDEST marker of that list:
        // the body font is not monospaced, so "1. " and "10. " have different
        // widths and each item's text would otherwise start at a different x.
        // The run is known before any rendering, so the widest prefix is too.
        return render(joined: lines, hangs: widestOrderedPrefixes(lines))
    }

    /// Renders lines that are ALREADY soft-break joined (`joinSoftBreaks`),
    /// each ordered item hanging under `hangs[i]` (`widestOrderedPrefixes`).
    ///
    /// The parser's entry point: it joins and computes the hangs over a whole
    /// text run, then renders the run one block at a time — so the items of a
    /// loose list, one row each, still share their list's widest marker.
    func render(joined lines: [String], hangs: [String?]) -> AttributedString {
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            result.append(renderLine(line, hangingPrefix: index < hangs.count ? hangs[index] : nil))
            result.append(AttributedString("\n"))
        }
        return result
    }

    /// For every line, the widest marker prefix (indent spaces + "N. ") of the
    /// ordered list the line belongs to — `nil` for lines that are not ordered
    /// items. "Widest" is measured in the body font, not counted in characters:
    /// "9. " is wider than "1. " although both are three characters.
    ///
    /// A list is a run of ordered items at one indent level. Blank lines and
    /// deeper-indented lines between its items (a loose list, a nested list, a
    /// continuation paragraph) do not end it; any other line does. Nested
    /// ordered lists form their own runs.
    func widestOrderedPrefixes(_ lines: [String]) -> [String?] {
        let items = lines.map(Self.orderedItem)
        var out = [String?](repeating: nil, count: lines.count)
        var widths: [String: CGFloat] = [:]
        func measured(_ prefix: String) -> CGFloat {
            if let w = widths[prefix] { return w }
            let w = width(of: prefix)
            widths[prefix] = w
            return w
        }
        for start in lines.indices {
            guard out[start] == nil, let first = items[start] else { continue }
            var members = [start]
            var widest = first.prefix
            var i = start + 1
            while i < lines.count {
                if let item = items[i] {
                    if item.level < first.level { break }
                    if item.level == first.level {
                        members.append(i)
                        if measured(item.prefix) > measured(widest) { widest = item.prefix }
                    }
                } else if !Self.lineContinuesList(lines[i], atLevel: first.level) {
                    break
                }
                i += 1
            }
            for m in members { out[m] = widest }
        }
        return out
    }

    /// `(prefix, level)` of an ordered list item, prefix exactly as
    /// `renderListItem` will emit it (indent spaces + normalised number).
    private static func orderedItem(_ line: String) -> (prefix: String, level: Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: Self.orderedMarkerPattern, options: .regularExpression) != nil else { return nil }
        let level = listLevel(for: line.prefix(while: { $0 == " " || $0 == "\t" }))
        let number = Int(trimmed.prefix(while: { $0.isNumber })) ?? 1
        return (indentSpaces(level) + "\(number). ", level)
    }

    /// A blank line or a line indented deeper than the list's own items keeps
    /// a run of ordered items together (loose lists, nested content).
    private static func lineContinuesList(_ line: String, atLevel level: Int) -> Bool {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        return indent.count == line.count || listLevel(for: indent) > level
    }

    // MARK: - Soft Breaks

    /// CommonMark renders a single newline inside a paragraph as a space (a
    /// soft break), not a line break. The renderer is line-based, so this
    /// pre-pass joins consecutive paragraph lines into one logical line before
    /// they reach `renderLine`. A list item also absorbs the plain lines that
    /// follow it (lazy continuation), so wrapped item text stays inside the
    /// item and gets its hanging indent instead of dropping to the left
    /// margin as a bogus paragraph. A hard break — two or more trailing
    /// spaces, or a trailing backslash — still ends the visual line, and
    /// headers, rules, and blanks always keep their own line.
    static func joinSoftBreaks(_ lines: [String]) -> [String] {
        joinSoftBreaksIndexed(lines).map(\.line)
    }

    /// `joinSoftBreaks`, with the index in `lines` of each joined line's FIRST
    /// input line — how the parser maps a row back to its source line.
    static func joinSoftBreaksIndexed(_ lines: [String]) -> [(line: String, first: Int)] {
        var joined: [(line: String, first: Int)] = []
        var openParagraph = false  // last joined line can absorb a continuation
        // Inside a paragraph that is not a list item's, until a blank or
        // structural line — across hard breaks too.
        var inPlainParagraph = false

        for (index, line) in lines.enumerated() {
            let kind = classify(line)
            guard kind != .structural else {
                joined.append((line, index))
                openParagraph = false
                inPlainParagraph = false
                continue
            }

            let hardBreak = endsWithHardBreak(line)
            var text = line
            while text.last == " " || text.last == "\t" { text.removeLast() }
            if hardBreak && text.hasSuffix("\\") { text.removeLast() }

            if kind == .listItem && inPlainParagraph && !canInterruptParagraph(line) {
                // CommonMark: only a bullet or an ordered item numbered 1 may
                // interrupt a paragraph. `1984. A year` after paragraph text
                // is more of that text — drawn, copied and searched as such.
                if openParagraph {
                    joined[joined.count - 1].line += " " + continuationText(text)
                } else {
                    // After a hard break: its own visual line, still text.
                    joined.append((asParagraphText(text), index))
                }
            } else if kind == .paragraph && openParagraph {
                joined[joined.count - 1].line += " " + continuationText(text)
            } else {
                joined.append((text, index))
                inPlainParagraph = kind == .paragraph
            }
            openParagraph = !hardBreak
        }

        return joined
    }

    private enum LineKind {
        /// Blank, header, or horizontal rule — never joins with anything.
        case structural
        /// Bullet/ordered/task item — always starts its own joined line, but
        /// leaves its paragraph open so following plain lines merge into the
        /// item (CommonMark lazy continuation).
        case listItem
        /// Regular paragraph text — continues an open paragraph, or opens one.
        case paragraph
    }

    /// A bullet, ordered or task list item — `renderLine` renders it as one.
    static func isListItem(_ line: String) -> Bool { classify(line) == .listItem }

    /// CommonMark's blank line: nothing but spaces and tabs — the ONE blank
    /// test of the parser and the renderers. Not "any white space":
    /// `CharacterSet.whitespaces` is every Unicode space separator, so it
    /// counted a line of no-break spaces (U+00A0) blank. Such a line is
    /// paragraph text (how authors write an empty-looking paragraph): after
    /// text it continues the paragraph, alone it is a paragraph of its own;
    /// it never ends a block or separates two.
    static func isBlankLine<S: StringProtocol>(_ line: S) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// A continuation line's text: CommonMark strips its leading spaces and
    /// tabs, and nothing else (a no-break space is text).
    private static func continuationText(_ text: String) -> String {
        String(text.drop(while: { $0 == " " || $0 == "\t" }))
    }

    /// An ordered item's marker (CommonMark): one to nine digits, then `.` or
    /// `)`, then white space. Drawn as `n.` whichever delimiter it had, as
    /// GitHub draws both (an HTML list).
    static let orderedMarkerPattern = #"^(\d{1,9})[.)]\s"#

    /// `line` (an ordered item line that may not interrupt a paragraph) as
    /// paragraph text: its delimiter backslash-escaped, so `renderLine` draws
    /// `1984. A year` as the words it is and never as an item.
    static func asParagraphText(_ line: String) -> String {
        line.replacingOccurrences(of: #"^(\s*\d{1,9})([.)])"#, with: "$1\\\\$2", options: .regularExpression)
    }

    /// Whether this item line may interrupt a paragraph (CommonMark): a
    /// bullet or task item, or an ordered item numbered 1 (`1.` or `1)`) —
    /// and not an empty one. Any other item line after paragraph text
    /// (`1984. was a year`) continues the paragraph: `joinSoftBreaks` makes
    /// it paragraph text, so it is no item and no block boundary.
    static func canInterruptParagraph(_ line: String) -> Bool {
        guard isListItem(line) else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let marker = trimmed.range(of: #"^\d{1,9}[.)]"#, options: .regularExpression) {
            guard Int(trimmed[marker].dropLast()) == 1 else { return false }
            return !trimmed[marker.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
        }
        return !trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A thematic break (`---`, `***`, `___`) — `renderLine` draws it as a rule.
    static func isThematicBreak(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces)
            .range(of: MarkdownTheme.horizontalRulePattern, options: .regularExpression) != nil
    }

    /// Must mirror the dispatch in `renderLine`, or a structural line could
    /// get glued into the paragraph before it.
    private static func classify(_ line: String) -> LineKind {
        if isBlankLine(line) { return .structural }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let nsRange = NSRange(line.startIndex..., in: line)
        if headerRegex.firstMatch(in: line, range: nsRange) != nil { return .structural }
        if trimmed.range(of: MarkdownTheme.horizontalRulePattern, options: .regularExpression) != nil { return .structural }
        if taskListRegex.firstMatch(in: line, range: nsRange) != nil { return .listItem }
        if ["- ", "* ", "+ "].contains(where: { trimmed.hasPrefix($0) }) { return .listItem }
        if trimmed.range(of: orderedMarkerPattern, options: .regularExpression) != nil { return .listItem }
        return .paragraph
    }

    /// Two-plus trailing spaces, or an odd run of trailing backslashes (an
    /// even run is escaped literal backslashes, e.g. `foo\\`).
    static func endsWithHardBreak(_ line: String) -> Bool {
        if line.hasSuffix("  ") { return true }
        return line.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1
    }

    // MARK: - Line Rendering

    private func renderLine(_ line: String, hangingPrefix: String? = nil) -> AttributedString {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Header - extract hash count from regex group, not space position
        let nsRange = NSRange(line.startIndex..., in: line)
        if let match = Self.headerRegex.firstMatch(in: line, range: nsRange),
           let hashRange = Range(match.range(at: 1), in: line),
           let contentRange = Range(match.range(at: 2), in: line) {
            let level = line[hashRange].count  // Count actual # characters
            let content = String(line[contentRange]).trimmingCharacters(in: .whitespaces)
            return renderHeader(content, level: min(max(level, 1), 6))
        }

        // Horizontal rule
        if trimmed.range(of: MarkdownTheme.horizontalRulePattern, options: .regularExpression) != nil {
            return renderHorizontalRule()
        }

        // Task list (must check before unordered list)
        if let taskMatch = parseTaskList(line) {
            return renderTaskItem(taskMatch.content, level: taskMatch.level, checked: taskMatch.checked)
        }

        // Unordered list
        if let bullet = ["- ", "* ", "+ "].first(where: { trimmed.hasPrefix($0) }) {
            let level = Self.listLevel(for: line.prefix(while: { $0 == " " || $0 == "\t" }))
            let content = String(trimmed.dropFirst(bullet.count))
            return renderListItem(content, level: level, ordered: false, number: 0)
        }

        // Ordered list
        if let match = trimmed.range(of: Self.orderedMarkerPattern, options: .regularExpression) {
            let level = Self.listLevel(for: line.prefix(while: { $0 == " " || $0 == "\t" }))
            let number = Int(trimmed.prefix(while: { $0.isNumber })) ?? 1
            let content = String(trimmed[match.upperBound...])
            return renderListItem(content, level: level, ordered: true, number: number,
                                  hangingPrefix: hangingPrefix)
        }

        // Empty line
        if Self.isBlankLine(line) {
            return AttributedString("\n")
        }

        // Regular paragraph
        return renderInlineFormatting(line)
    }

    // MARK: - Block Renderers

    func renderHeader(_ text: String, level: Int) -> AttributedString {
        var attr = renderInlineFormatting(text)
        attr.setDualFont(size: headerFontSize(level: level), bold: true, fonts: theme.fonts)
        attr.setDualForeground(theme.textColor)
        return attr
    }

    /// Point size of a level-`level` heading at this renderer's scale.
    func headerFontSize(level: Int) -> CGFloat {
        let sizes: [CGFloat] = [32, 26, 22, 18, 16, 14]
        // Safety guard: ensure level is within bounds to prevent crash
        let safeLevel = max(1, min(level, 6))
        return scaled(sizes[safeLevel - 1])
    }

    /// The AppKit font `renderHeader` sets on EVERY character of a heading
    /// (the same `DocumentFonts.appKit` call `setDualFont(bold: true)` makes).
    /// `HeadingBlockView` aligns its copy button to this font's first
    /// baseline; read here rather than back from the AttributedString run.
    func headerAppKitFont(level: Int) -> NSFont {
        theme.fonts.appKit(size: headerFontSize(level: level), weight: .bold)
    }

    /// Inline-renders a quoted body — a blockquote or a GFM alert — into ONE
    /// AttributedString: soft breaks joined first (a single newline inside a
    /// quote paragraph reads as a space, CommonMark), then each remaining line
    /// inline-rendered and joined with newlines. A blank line becomes a single
    /// space so it still occupies a line.
    ///
    /// Shared by `BlockquoteView`, `AlertBlockView` and `BlockHeightMeasurer`:
    /// the measured string has to be the rendered string, character for
    /// character, or the row height is wrong.
    func renderQuotedBody(_ content: String) -> AttributedString {
        var result = AttributedString()
        let lines = Self.joinSoftBreaks(content.components(separatedBy: "\n"))
        for (index, line) in lines.enumerated() {
            if Self.isBlankLine(line) {
                result.append(AttributedString(" "))
            } else {
                result.append(renderInline(line))
            }
            if index < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }

    // MARK: - List Indentation
    //
    // A list item is one paragraph: "<indent spaces><marker> <item text>".
    // Two things have to happen for it to read as a list:
    //
    //  1. Nesting — carried by the leading spaces in the marker prefix. It has
    //     to live in the CHARACTERS, not in the paragraph style, because the
    //     print/PDF pipeline renders blocks through SwiftUI `Text`, which
    //     ignores NSParagraphStyle entirely.
    //  2. A hanging indent so a wrapped item's continuation lines line up under
    //     the item text instead of falling back to the marker's own margin
    //     (which made bullets/numbers and body text share one left edge).
    //     Only the paragraph style can express that, so the NSTextView pipeline
    //     gets it and `Text` degrades to flush-left wrapping as before.

    /// Points between the text margin and a list marker, at 1.0 zoom. Separates
    /// the list from surrounding paragraphs at every nesting level.
    private static let listGutter: CGFloat = 16

    /// Spaces prepended per nesting level.
    private static let listIndentUnit = "    "

    /// Nesting level from a list line's leading whitespace, counting a tab as
    /// one nesting step.
    ///
    /// Authors nest with either two or four spaces and a single line can't say
    /// which, so we count one level per two columns: a two-space document keeps
    /// every level distinct (dividing by four would collapse its first two
    /// levels onto the same margin), and a four-space document simply indents a
    /// step deeper than authored. Capped so a pathological indent can't push
    /// text off the right edge.
    static func listLevel(for whitespace: Substring) -> Int {
        let columns = whitespace.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        return min(columns / 2, 8)
    }

    private func renderListItem(_ text: String, level: Int, ordered: Bool, number: Int,
                                hangingPrefix: String? = nil) -> AttributedString {
        let prefix = Self.indentSpaces(level) + (ordered ? "\(number). " : "• ")
        var attr = AttributedString(prefix)
        attr.setDualFont(size: scaled(14), fonts: theme.fonts)
        attr.setDualForeground(theme.textColor)
        attr.append(renderInlineFormatting(text))
        // Ordered items of one list hang under the WIDEST marker of the list and
        // push their own, narrower marker right by the difference, so the markers
        // are right-aligned and every item's text starts at the same x — on the
        // first line and on wrapped lines alike.
        let hangWidth = width(of: hangingPrefix ?? prefix)
        applyHangingIndent(&attr, indent: scaled(Self.listGutter),
                           firstLineLead: max(0, hangWidth - width(of: prefix)), hangWidth: hangWidth)
        return attr
    }

    private func renderTaskItem(_ text: String, level: Int, checked: Bool) -> AttributedString {
        let prefix = Self.indentSpaces(level) + (checked ? "☑ " : "☐ ")
        var attr = AttributedString(prefix)
        attr.setDualFont(size: scaled(14), fonts: theme.fonts)
        attr.setDualForeground(checked ? theme.checkboxColor : theme.textColor)

        var content = renderInlineFormatting(text)
        if checked {
            content.setDualStrikethrough()
            content.setDualForeground(theme.secondaryTextColor)
        }
        attr.append(content)
        applyListParagraphStyle(&attr, hangingUnder: prefix)
        return attr
    }

    private static func indentSpaces(_ level: Int) -> String {
        String(repeating: listIndentUnit, count: level)
    }

    /// Indents the whole item by the list gutter and hangs its wrapped lines
    /// under the item text, i.e. past `prefix` (the indent spaces + marker).
    private func applyListParagraphStyle(_ attr: inout AttributedString, hangingUnder prefix: String) {
        applyHangingIndent(&attr, indent: scaled(Self.listGutter), hangingUnder: prefix)
    }

    /// Indents a whole paragraph by `indent` points and hangs its wrapped lines
    /// past `prefix` — the characters only the FIRST line carries (a list
    /// marker, a definition's plain-text indent). Shared by list items and
    /// definition-list bodies so there is ONE hanging-indent mechanism.
    private func applyHangingIndent(_ attr: inout AttributedString, indent: CGFloat, hangingUnder prefix: String) {
        applyHangingIndent(&attr, indent: indent, firstLineLead: 0, hangWidth: width(of: prefix))
    }

    /// First line starts at `indent + firstLineLead`, wrapped lines at
    /// `indent + hangWidth`. `firstLineLead` is what right-aligns a narrow
    /// marker under a wider one; it is 0 whenever the item hangs under itself.
    private func applyHangingIndent(_ attr: inout AttributedString, indent: CGFloat,
                                    firstLineLead: CGFloat, hangWidth: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent + firstLineLead
        style.headIndent = indent + hangWidth
        attr[AttributeScopes.AppKitAttributes.ParagraphStyleAttribute.self] = style
    }

    /// Typeset width of body-font text — the marker prefix, to size the hang.
    /// Measured with the theme's body font (not the system font) so a custom
    /// family with wider markers still hangs wrapped lines under the text.
    private func width(of string: String) -> CGFloat {
        (string as NSString)
            .size(withAttributes: [.font: theme.fonts.appKit(size: scaled(14))])
            .width
    }

    private func parseTaskList(_ line: String) -> (content: String, level: Int, checked: Bool)? {
        let nsRange = NSRange(line.startIndex..., in: line)

        guard let match = Self.taskListRegex.firstMatch(in: line, range: nsRange),
              let indentRange = Range(match.range(at: 1), in: line),
              let checkRange = Range(match.range(at: 2), in: line),
              let contentRange = Range(match.range(at: 3), in: line) else { return nil }

        let level = Self.listLevel(for: line[indentRange])
        let checked = line[checkRange].lowercased() == "x"
        let content = String(line[contentRange])

        return (content: content, level: level, checked: checked)
    }

    // MARK: - Definition Lists (PHP Markdown Extra / Pandoc)
    //
    // ```
    // Apple
    // Orange
    // : The fruit          ← one definition shared by two terms
    // : A company          ← a second definition of the same terms
    //
    // Pear                 ← a new term group, still ONE block
    // : Another fruit
    //   that wraps         ← lazy continuation of the definition
    // ```
    //
    // A whole list renders into ONE AttributedString (a `.text` block), so
    // search, height measurement, print and PDF need no new block kind. Terms
    // sit at the text margin in semibold; definitions are indented, with the
    // same two-part trick list items use:
    //
    //  1. the indent lives in the CHARACTERS as spaces, because the print/PDF
    //     pipeline renders blocks through SwiftUI `Text`, which ignores
    //     NSParagraphStyle — without the spaces a printed definition would be
    //     indistinguishable from its term's own left edge;
    //  2. NSParagraphStyle adds the point-accurate indent for the on-screen
    //     NSTextView pipeline and hangs wrapped lines under the definition
    //     text, so a long definition stays visually inside its block.

    /// Points a definition body is indented from the text margin at 1.0 zoom.
    /// The visible indent is this plus the width of `definitionPrintIndent`,
    /// which the characters carry (see the note above).
    private static let definitionIndent: CGFloat = 24

    /// The definition indent as characters, for the print/PDF pipeline. Same
    /// unit list nesting uses, so a printed definition lines up with the text
    /// of a nested list item instead of inventing a second indent scale.
    private static let definitionPrintIndent = listIndentUnit

    /// One term group of a definition list: 1…N terms that share 1…N
    /// definitions. Both are still raw Markdown — inline formatting is applied
    /// here, at render time, exactly like table cells and quote bodies.
    struct DefinitionGroup: Sendable, Equatable {
        let terms: [String]
        let definitions: [String]
    }

    /// Renders a whole definition list into one AttributedString: every term on
    /// its own line, then its definitions, groups separated by a blank line.
    func renderDefinitionList(groups: [DefinitionGroup]) -> AttributedString {
        var result = AttributedString()

        for (groupIndex, group) in groups.enumerated() {
            // A blank line between groups rather than `paragraphSpacing`:
            // paragraph spacing is AppKit-only, so print/PDF would disagree
            // with the screen about how far apart the groups sit.
            if groupIndex > 0 {
                var gap = AttributedString("\n")
                gap.setDualFont(size: scaled(14), fonts: theme.fonts)
                result.append(gap)
            }

            for term in group.terms {
                result.append(renderDefinitionTerm(term))
                result.append(AttributedString("\n"))
            }

            for definition in group.definitions {
                // Soft breaks join like a paragraph's (CommonMark), so a
                // definition's lazy continuation lines read as one flow; a hard
                // break still starts a new — equally indented — line.
                for line in Self.joinSoftBreaks(definition.components(separatedBy: "\n")) {
                    result.append(renderDefinitionBody(line))
                    result.append(AttributedString("\n"))
                }
            }
        }

        return result
    }

    /// A term: body size, semibold, at the text margin.
    private func renderDefinitionTerm(_ text: String) -> AttributedString {
        var attr = renderInlineFormatting(text)
        // The weight is stamped over the whole line (as `renderHeader` does for
        // headings) so the term reads as a label whatever its inline runs came
        // back as. Colors and links are deliberately left alone.
        attr.setDualFont(size: scaled(14), bold: true, fonts: theme.fonts)
        return attr
    }

    /// One visual line of a definition body: the plain-text indent, the inline
    /// content, and the hanging indent for the NSTextView pipeline.
    private func renderDefinitionBody(_ text: String) -> AttributedString {
        var attr = AttributedString(Self.definitionPrintIndent)
        attr.setDualFont(size: scaled(14), fonts: theme.fonts)
        attr.setDualForeground(theme.textColor)
        attr.append(renderInlineFormatting(text))
        applyHangingIndent(&attr, indent: scaled(Self.definitionIndent),
                           hangingUnder: Self.definitionPrintIndent)
        return attr
    }

    private func renderHorizontalRule() -> AttributedString {
        var attr = AttributedString("────────────────────────────────")
        attr.setDualFont(size: scaled(14), fonts: theme.fonts)
        attr.setDualForeground(theme.secondaryTextColor)
        return attr
    }

    // MARK: - Inline Formatting (refactored into smaller methods)

    /// Public method for rendering inline formatting (table cells: `TableTextBuilder`, `PrintableTableView`)
    func renderInline(_ text: String) -> AttributedString {
        renderInlineFormatting(text)
    }

    /// `renderInline` with backslash escapes off when `literalBackslashes`
    /// (see `escapesDisabled`) and character references shown as written when
    /// `literalEntities` (see `entitiesLiteral`).
    func renderInline(_ text: String, literalBackslashes: Bool, literalEntities: Bool = false) -> AttributedString {
        guard literalBackslashes || literalEntities else { return renderInlineFormatting(text) }
        var literal = self
        literal.escapesDisabled = literalBackslashes
        literal.entitiesLiteral = literalEntities
        return literal.renderInlineFormatting(text)
    }

    private func renderInlineFormatting(_ text: String) -> AttributedString {
        var result = AttributedString()
        // Native contiguous UTF-8 storage up front (a no-op unless the line is
        // a lazily bridged NSString, e.g. from `components(separatedBy:)`):
        // `InlineSyntaxScanner` reads that storage directly, and would
        // otherwise copy the rest of the line at every `[` / `![`.
        var text = text
        text.makeContiguousUTF8()
        var remaining = text[...]
        // Bracket/paren matches of this text, computed once (lazily) so every
        // `[` is a lookup, not a forward scan — O(n) per call, not O(n²).
        let pairs = InlineSyntaxScanner.PairTable(text)
        var plainTextBuffer = ""

        // Helper to flush buffered plain text
        func flushPlainText() {
            guard !plainTextBuffer.isEmpty else { return }
            var attr = AttributedString(decodedText(plainTextBuffer))
            attr.setDualFont(size: scaled(14), fonts: theme.fonts)
            attr.setDualForeground(theme.textColor)
            result.append(attr)
            plainTextBuffer = ""
        }

        while !remaining.isEmpty {
            // Try each inline format in order (escape first, then bold+italic to catch ***)
            var parsed: (AttributedString, Substring)?

            if parsed == nil, !escapesDisabled { parsed = tryParseEscape(&remaining) }
            if parsed == nil { parsed = tryParseInlineCode(&remaining) }
            if parsed == nil { parsed = tryParseFootnoteRef(&remaining) }
            if parsed == nil { parsed = tryParseBoldItalic(&remaining) }
            if parsed == nil { parsed = tryParseBold(&remaining) }
            if parsed == nil { parsed = tryParseItalic(&remaining) }
            if parsed == nil { parsed = tryParseStrikethrough(&remaining) }
            if parsed == nil { parsed = tryParseImage(&remaining, pairs: pairs) }
            if parsed == nil { parsed = tryParseLink(&remaining, pairs: pairs) }
            if parsed == nil { parsed = tryParseAutolink(&remaining) }

            if let (attr, newRemaining) = parsed {
                flushPlainText()  // Flush buffer before formatted content
                result.append(attr)
                remaining = newRemaining
            } else {
                // Buffer plain characters instead of creating AttributedString per char
                plainTextBuffer.append(remaining.removeFirst())
            }
        }

        flushPlainText()  // Flush any remaining plain text
        return result
    }

    // MARK: - Inline Parsers

    private func tryParseInlineCode(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard remaining.hasPrefix("`") else { return nil }

        // Count opening backticks (support 1 or 2)
        let backtickCount = remaining.prefix(while: { $0 == "`" }).count
        guard backtickCount <= 2 else {
            // 3+ backticks in inline context — render as literal backtick characters
            let backticks = String(repeating: "`", count: backtickCount)
            var attr = AttributedString(backticks)
            attr.setDualFont(size: scaled(14), fonts: theme.fonts)
            attr.setDualForeground(theme.textColor)
            return (attr, remaining.dropFirst(backtickCount))
        }

        let closingMarker = String(repeating: "`", count: backtickCount)
        let afterOpening = remaining.dropFirst(backtickCount)

        // Find closing backticks of same count
        guard let closeRange = afterOpening.range(of: closingMarker) else { return nil }

        // For double-backtick, ensure we found exactly 2 closing backticks (not 3+)
        if backtickCount == 2 {
            let endIdx = closeRange.upperBound
            if endIdx < afterOpening.endIndex && afterOpening[endIdx] == "`" {
                return nil  // Part of a triple-backtick, skip
            }
        }

        var code = String(afterOpening[..<closeRange.lowerBound])

        // Strip one leading and one trailing space for double-backtick (CommonMark spec)
        if backtickCount == 2 && code.hasPrefix(" ") && code.hasSuffix(" ") && code.count > 1 {
            code = String(code.dropFirst().dropLast())
        }

        var attr = AttributedString(code)
        attr.setDualFont(size: scaled(13), monospaced: true, fonts: theme.fonts)
        attr.setDualForeground(theme.textColor)
        attr.setDualBackground(theme.codeBackgroundColor)
        return (attr, afterOpening[closeRange.upperBound...])
    }

    private func tryParseBoldItalic(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard remaining.hasPrefix("***") || remaining.hasPrefix("___") else { return nil }

        let marker = String(remaining.prefix(3))
        let afterMarker = remaining.dropFirst(3)
        guard let endRange = afterMarker.range(of: marker) else { return nil }

        let text = String(afterMarker[..<endRange.lowerBound])
        var attr = AttributedString(decodedText(text))
        attr.setDualFont(size: scaled(14), bold: true, italic: true, fonts: theme.fonts)
        attr.setDualForeground(theme.textColor)
        return (attr, afterMarker[endRange.upperBound...])
    }

    private func tryParseBold(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard (remaining.hasPrefix("**") && !remaining.hasPrefix("***")) ||
              (remaining.hasPrefix("__") && !remaining.hasPrefix("___")) else { return nil }

        let marker = String(remaining.prefix(2))
        let afterMarker = remaining.dropFirst(2)
        guard let endRange = afterMarker.range(of: marker) else { return nil }

        let boldText = String(afterMarker[..<endRange.lowerBound])
        // Recursively parse inner text for nested emphasis (e.g., **bold *and italic* text**)
        var attr = renderInlineFormatting(boldText)
        attr.setDualFont(size: scaled(14), bold: true, fonts: theme.fonts)
        attr.setDualForeground(theme.textColor)
        return (attr, afterMarker[endRange.upperBound...])
    }

    private func tryParseItalic(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard (remaining.hasPrefix("*") && !remaining.hasPrefix("**")) ||
              (remaining.hasPrefix("_") && !remaining.hasPrefix("__")),
              let marker = remaining.first else { return nil }

        // Word boundary check for underscore delimiter
        if marker == "_" {
            let fullText = remaining.base
            let indexInFull = fullText.distance(from: fullText.startIndex, to: remaining.startIndex)
            if indexInFull > 0 {
                let prevChar = fullText[fullText.index(fullText.startIndex, offsetBy: indexInFull - 1)]
                if prevChar.isLetter || prevChar.isNumber {
                    return nil  // Mid-word underscore, skip
                }
            }
        }

        let afterMarker = remaining.dropFirst()
        guard let endIndex = afterMarker.firstIndex(of: marker) else { return nil }

        // Word boundary check for closing underscore
        if marker == "_" {
            let closeIdx = afterMarker.index(after: endIndex)
            if closeIdx < remaining.endIndex {
                let afterClose = remaining[closeIdx]
                if afterClose.isLetter || afterClose.isNumber {
                    return nil  // Mid-word closing underscore, skip
                }
            }
        }

        let italicText = String(afterMarker[..<endIndex])
        // Recursively parse inner text for nested emphasis (e.g., *italic **and bold** text*)
        var attr = renderInlineFormatting(italicText)
        attr.setDualFont(size: scaled(14), italic: true, fonts: theme.fonts)
        attr.setDualForeground(theme.textColor)
        return (attr, afterMarker[afterMarker.index(after: endIndex)...])
    }

    private func tryParseStrikethrough(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard remaining.hasPrefix("~~") else { return nil }

        let afterMarker = remaining.dropFirst(2)
        guard let endRange = afterMarker.range(of: "~~") else { return nil }

        let strikeText = String(afterMarker[..<endRange.lowerBound])
        var attr = AttributedString(decodedText(strikeText))
        attr.setDualFont(size: scaled(14), fonts: theme.fonts)
        attr.setDualForeground(theme.textColor)
        attr.setDualStrikethrough()
        return (attr, afterMarker[endRange.upperBound...])
    }

    private func tryParseLink(_ remaining: inout Substring,
                              pairs: InlineSyntaxScanner.PairTable) -> (AttributedString, Substring)? {
        // The link text's `]` is found by bracket DEPTH (escaped brackets don't
        // count), so the text may itself contain an image — `[![b](img)](link)`,
        // the badge idiom. A first-`]` scan stopped inside the image and printed
        // `![b` as the link followed by a literal `](link)`.
        guard !linksDisabled, remaining.hasPrefix("["),
              let closeBracket = InlineSyntaxScanner.closingBracket(in: remaining, pairs: pairs) else { return nil }
        let afterBracket = remaining.index(after: closeBracket)

        let linkText = String(remaining[remaining.index(after: remaining.startIndex)..<closeBracket])

        // 1. Standard inline link: [text](url "title") — CommonMark destination,
        //    title discarded (InlineSyntaxScanner.linkDestination).
        if remaining[afterBracket...].hasPrefix("(") {
            guard let inline = InlineSyntaxScanner.parenthesizedDestination(remaining[afterBracket...], pairs: pairs) else { return nil }
            return makeLink(text: linkText, url: inline.url, remaining: remaining[inline.end...])
        }

        // 2. Reference link: [text][id] or [text][] (collapsed)
        if remaining[afterBracket...].hasPrefix("[") {
            let afterSecondOpen = remaining.index(after: afterBracket)
            if afterSecondOpen < remaining.endIndex,
               let closeSecondBracket = remaining[afterSecondOpen...].firstIndex(of: "]") {
                let refId = String(remaining[afterSecondOpen..<closeSecondBracket])
                let effectiveId = (refId.isEmpty ? linkText : refId).lowercased()
                if let url = referenceDefinitions[effectiveId] {
                    return makeLink(text: linkText, url: url,
                                    remaining: remaining[remaining.index(after: closeSecondBracket)...])
                }
            }
        }

        // 3. Shortcut reference: [text] where text matches a definition ID
        if let url = referenceDefinitions[linkText.lowercased()] {
            return makeLink(text: linkText, url: url, remaining: remaining[afterBracket...])
        }

        return nil
    }

    private func makeLink(text: String, url: String, remaining: Substring) -> (AttributedString, Substring) {
        var attr: AttributedString
        if text.contains("![") {
            // Link-wrapped image (`[![b](img)](link)`): the text is rendered
            // inline so the image becomes its "[Image: b]" placeholder, and the
            // whole run carries the OUTER link (set below, over the image's
            // own). Only for text holding an image, so every other link keeps
            // its exact plain-text rendering. Rendered with links disabled:
            // a link inside a link is literal text (bounds the recursion).
            var linkText = self
            linkText.linksDisabled = true
            attr = linkText.renderInlineFormatting(text)
        } else {
            attr = AttributedString(decodedText(text))
            attr.setDualFont(size: scaled(14), fonts: theme.fonts)
        }
        attr.setDualForeground(theme.linkColor)
        attr.setDualUnderline()

        if let parsedUrl = Self.linkURL(for: url) {
            attr.link = parsedUrl
        }
        return (attr, remaining)
    }

    /// The URL of a link destination as written.
    ///
    /// `URL(string:)` first, exactly as before 1.14.4: on macOS 14+ it encodes
    /// what needs encoding itself (spaces, non-ASCII, IDN hosts to punycode),
    /// and every destination it accepts keeps that behaviour. Only when it
    /// returns nil — macOS 13 rejects spaces, non-ASCII, `[` `]` in a path, a
    /// second `#` — do we encode, the part before the FIRST `#` and the
    /// fragment separately, so the `#` stays the fragment delimiter (the old
    /// `.urlPathAllowed` fallback encoded it too: `README.md#Install Guide`
    /// became a file named "README.md#Install Guide" and the jump failed).
    /// `parse` is `URL(string:)`; tests pass the strict (macOS 13) parser.
    static func linkURL(for destination: String,
                        parse: (String) -> URL? = { URL(string: $0) }) -> URL? {
        if let url = parse(destination) { return url }
        let scalars = destination.unicodeScalars[...]
        guard let hash = scalars.firstIndex(of: "#") else {
            return parse(percentEncoded(scalars))
        }
        return parse(percentEncoded(scalars[..<hash]) + "#"
                     + percentEncoded(scalars[scalars.index(after: hash)...]))
    }

    /// RFC 3986 unreserved + reserved characters — what a URL may contain as
    /// written (`%` only as the start of an escape, see `isEscape`).
    private static let urlCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/?#[]@!$&'()*+,;=")

    private typealias Scalars = Substring.UnicodeScalarView

    /// `%` followed by two hex digits.
    private static func isEscape(_ scalars: Scalars, at index: Scalars.Index) -> Bool {
        guard scalars[index] == "%" else { return false }
        let first = scalars.index(after: index)
        guard first < scalars.endIndex else { return false }
        let second = scalars.index(after: first)
        return second < scalars.endIndex
            && scalars[first].properties.isASCIIHexDigit && scalars[second].properties.isASCIIHexDigit
    }

    /// One part of a destination (no `#` delimiter inside): legal characters
    /// and valid escapes kept, everything else — `#`, `[`, `]` too, which a
    /// URL allows only in specific places — as UTF-8 `%XX`.
    private static func percentEncoded(_ scalars: Scalars) -> String {
        var out = ""
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            let keep = scalar == "%" ? isEscape(scalars, at: index)
                : scalar != "#" && scalar != "[" && scalar != "]" && urlCharacters.contains(scalar)
            if keep {
                out.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 { out += String(format: "%%%02X", byte) }
            }
            index = scalars.index(after: index)
        }
        return out
    }

    /// Inline images stay text — an italic "[Image: alt]" placeholder (real
    /// pictures inside a paragraph would break the `.exact` text rows). Same
    /// grammar as standalone image blocks (`InlineSyntaxScanner`): inline
    /// destinations with titles / `<…>`, and reference images through the
    /// document's definitions.
    private func tryParseImage(_ remaining: inout Substring,
                               pairs: InlineSyntaxScanner.PairTable) -> (AttributedString, Substring)? {
        guard remaining.hasPrefix("!["),
              let image = InlineSyntaxScanner.image(atStartOf: remaining, references: referenceDefinitions,
                                                    pairs: pairs) else { return nil }

        var attr = AttributedString(image.alt.isEmpty ? "[Image]" : "[Image: \(decodedText(image.alt))]")
        attr.setDualFont(size: scaled(14), italic: true, fonts: theme.fonts)
        attr.setDualForeground(theme.secondaryTextColor)
        // No link for an embedded `data:` image: clicking it would hand a
        // multi-megabyte URL to the "Open link?" alert.
        if !InlineSyntaxScanner.isDataURI(image.url), let url = Self.linkURL(for: image.url) {
            attr.link = url
        }
        return (attr, remaining[image.end...])
    }

    private func tryParseEscape(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard remaining.hasPrefix("\\"), remaining.count >= 2 else { return nil }
        let escaped = remaining[remaining.index(after: remaining.startIndex)]
        guard MarkdownTheme.escapableChars.contains(escaped) else { return nil }

        var attr = AttributedString(String(escaped))
        attr.setDualFont(size: scaled(14), fonts: theme.fonts)
        attr.setDualForeground(theme.textColor)
        // Inline math is found in the rendered text: tagged so `\$` is never
        // a delimiter and a formula gets its LaTeX escapes back.
        attr[EscapedCharacterAttribute.self] = true
        return (attr, remaining.dropFirst(2))
    }

    private func tryParseAutolink(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        // Quick prefix check to avoid expensive String conversion
        guard remaining.hasPrefix("http://") || remaining.hasPrefix("https://") else {
            return nil
        }
        let str = String(remaining)
        let nsRange = NSRange(str.startIndex..., in: str)

        guard let match = Self.autolinkRegex.firstMatch(in: str, range: nsRange),
              match.range.location == 0,
              let range = Range(match.range, in: str) else { return nil }

        let urlText = String(str[range])
        var attr = AttributedString(urlText)
        attr.setDualFont(size: scaled(14), fonts: theme.fonts)
        attr.setDualForeground(theme.linkColor)
        attr.setDualUnderline()
        if let url = URL(string: urlText) {
            attr.link = url
        }

        return (attr, remaining.dropFirst(urlText.count))
    }

    // MARK: - Footnote References

    /// Opens the id of a footnote reference whose NUMBER is already known
    /// (`[^\u{E000}2]`, written by `ReferenceLinks` into quote, alert and
    /// table-cell markdown). A private-use code point: no document's own
    /// footnote id starts with it in practice.
    static let numberedFootnoteMarker: Unicode.Scalar = "\u{E000}"

    private func tryParseFootnoteRef(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard remaining.hasPrefix("[^") else { return nil }

        let afterBracket = remaining.dropFirst(2)
        guard let closeIndex = afterBracket.firstIndex(of: "]") else { return nil }

        let fnId = String(afterBracket[..<closeIndex])
        guard !fnId.isEmpty else { return nil }

        // Find the footnote number (1-based index in definitions order), or
        // the number a quote / alert / table cell already carries
        // (`ReferenceLinks`: those are rendered without the definitions).
        let number: Int
        if let idx = footnoteDefinitions.firstIndex(where: { $0.id == fnId }) {
            number = idx + 1
        } else if fnId.unicodeScalars.first == Self.numberedFootnoteMarker,
                  let numbered = Int(String(fnId.unicodeScalars.dropFirst())), numbered > 0 {
            number = numbered
        } else {
            return nil // Unknown footnote reference, don't parse
        }

        // Render as superscript number
        let superscriptDigits: [Character: Character] = [
            "0": "\u{2070}", "1": "\u{00B9}", "2": "\u{00B2}", "3": "\u{00B3}",
            "4": "\u{2074}", "5": "\u{2075}", "6": "\u{2076}", "7": "\u{2077}",
            "8": "\u{2078}", "9": "\u{2079}"
        ]
        let superscript = String(String(number).map { superscriptDigits[$0] ?? $0 })

        var attr = AttributedString(superscript)
        attr.setDualFont(size: scaled(11), bold: true, fonts: theme.fonts)
        attr.setDualForeground(theme.linkColor)
        return (attr, afterBracket[afterBracket.index(after: closeIndex)...])
    }

}
