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
    /// True for a front-matter VALUE (`renderInline(_:literalBackslashes:)`):
    /// YAML has no Markdown escapes — a plain scalar's backslash is a
    /// character (`C:\_tmp`) — so `\` starts no escape there and shows as
    /// written; every other inline form still renders.
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
    ///
    /// `itemColumns[i]` (when given) is the list item that owns line `i` — a
    /// paragraph of the item after its first (`ListNesting`): that line is
    /// drawn at the item's text column (`renderItemParagraph`).
    func render(joined lines: [String], hangs: [String?], itemColumns: [ListItemColumn?] = []) -> AttributedString {
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            if index < itemColumns.count, let column = itemColumns[index] {
                result.append(renderItemParagraph(line, column: column))
            } else {
                result.append(renderLine(line, hangingPrefix: index < hangs.count ? hangs[index] : nil))
            }
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
        let trimmed = markerLine(line)
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
        // Inside any paragraph (an item's or not): a hard break does not end
        // it, only a blank or structural line does.
        var inParagraph = false

        for (index, line) in lines.enumerated() {
            let kind = classify(line)
            guard kind != .structural else {
                joined.append((line, index))
                openParagraph = false
                inPlainParagraph = false
                inParagraph = false
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
                // A line after a hard break is more of the SAME paragraph: an
                // item's stays the item's, so `2. b` after it is the next
                // item (GitHub), not text (`ListNesting` reads it so too).
                let continuesAfterHardBreak = kind == .paragraph && inParagraph
                if !continuesAfterHardBreak { inPlainParagraph = kind == .paragraph }
            }
            inParagraph = true
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

    /// CommonMark's white space around block and list markers: spaces and
    /// tabs only. A no-break, em or ideographic space before a marker (or
    /// after `#`, a list marker or a rule) leaves the line paragraph text, as
    /// on GitHub; the patterns in `MarkdownTheme` say `[ \t]` for the same
    /// reason. `MarkdownBlockParser.markerLine` trims with it too.
    static let markerWhitespace = CharacterSet(charactersIn: " \t")

    /// `line` without the spaces and tabs around it — what every list,
    /// rule and heading marker is looked for in.
    private static func markerLine(_ line: String) -> String {
        line.trimmingCharacters(in: markerWhitespace)
    }

    /// A continuation line's text: CommonMark strips its leading spaces and
    /// tabs, and nothing else (a no-break space is text).
    private static func continuationText(_ text: String) -> String {
        String(text.drop(while: { $0 == " " || $0 == "\t" }))
    }

    /// An ordered item's marker (CommonMark): one to nine digits, then `.` or
    /// `)`, then white space. Drawn as `n.` whichever delimiter it had, as
    /// GitHub draws both (an HTML list).
    static let orderedMarkerPattern = #"^(\d{1,9})[.)][ \t]"#

    /// `line` (an ordered item line that may not interrupt a paragraph) as
    /// paragraph text: its delimiter backslash-escaped, so `renderLine` draws
    /// `1984. A year` as the words it is and never as an item.
    static func asParagraphText(_ line: String) -> String {
        line.replacingOccurrences(of: #"^([ \t]*\d{1,9})([.)])"#, with: "$1\\\\$2", options: .regularExpression)
    }

    /// Whether this item line may interrupt a paragraph (CommonMark): a
    /// bullet or task item, or an ordered item numbered 1 (`1.` or `1)`) —
    /// and not an empty one. Any other item line after paragraph text
    /// (`1984. was a year`) continues the paragraph: `joinSoftBreaks` makes
    /// it paragraph text, so it is no item and no block boundary.
    static func canInterruptParagraph(_ line: String) -> Bool {
        guard isListItem(line) else { return false }
        let trimmed = markerLine(line)
        if let marker = trimmed.range(of: #"^\d{1,9}[.)]"#, options: .regularExpression) {
            guard Int(trimmed[marker].dropLast()) == 1 else { return false }
            return !isBlankLine(trimmed[marker.upperBound...])
        }
        return !isBlankLine(trimmed.dropFirst(2))
    }

    /// A thematic break (`---`, `***`, `___`) — `renderLine` draws it as a rule.
    static func isThematicBreak(_ line: String) -> Bool {
        markerLine(line)
            .range(of: MarkdownTheme.horizontalRulePattern, options: .regularExpression) != nil
    }

    /// Must mirror the dispatch in `renderLine`, or a structural line could
    /// get glued into the paragraph before it.
    private static func classify(_ line: String) -> LineKind {
        if isBlankLine(line) { return .structural }
        let trimmed = markerLine(line)
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
        let trimmed = Self.markerLine(line)

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

    /// A heading's title as shown: a Setext title keeps its paragraph's line
    /// breaks (`MarkdownBlockParser.setextTitle`) and each reads as a space,
    /// like a soft break in a paragraph — in the heading, the Contents
    /// sidebar and search alike.
    static func shownHeadingTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "\n", with: " ")
    }

    /// The text GitHub takes a heading's id from: the rendered title with a
    /// Setext title's line breaks KEPT — the slug drops them (`Alpha⏎Beta`
    /// is `alphabeta`), where the space shown would be a `-`.
    /// A footnote reference counts as its number in ASCII digits: GitHub's
    /// slug reads the heading's text, `Note<sup>1</sup>` is `note1`, and the
    /// superscript digit drawn here is not a word character for the slug.
    func headingAnchorText(_ title: String) -> String {
        let attributed = Self.formulaSourceWithEscapes(renderInlineFormatting(title), softBreaks: true)
        var text = ""
        for run in attributed.runs {
            if let number = run[FootnoteNumberAttribute.self] {
                text += String(number)
            } else {
                text += String(attributed[run.range].characters)
            }
        }
        return text
    }

    func renderHeader(_ text: String, level: Int) -> AttributedString {
        headingLook(Self.formulaSourceWithEscapes(renderInlineFormatting(Self.shownHeadingTitle(text))),
                    size: headerFontSize(level: level))
    }

    /// A heading is bold throughout, like an emphasis over its whole title,
    /// and follows the same switch (`emphasisKeepsContentLook`):
    /// - on (1.15): each run keeps its look and gains bold at the heading
    ///   size — code stays monospaced on its chip at 13/14 of the heading
    ///   size (the body ratio), a footnote number at 11/14, italic stays
    ///   italic, colours stay (a link keeps the link colour);
    /// - off: the whole title in the bold body font and the text colour
    ///   (every release before 1.15).
    /// Only attributes change, never the characters: ids, Contents and
    /// search read the same text either way.
    private func headingLook(_ title: AttributedString, size: CGFloat) -> AttributedString {
        guard Self.emphasisKeepsContentLook else {
            var attr = title
            attr.setDualFont(size: size, bold: true, fonts: theme.fonts)
            attr.setDualForeground(theme.textColor)
            return attr
        }
        var result = AttributedString()
        for run in title.runs {
            var piece = AttributedString(title[run.range])
            let isCode = run[AttributeScopes.AppKitAttributes.BackgroundColorAttribute.self] != nil
            let ratio: CGFloat = isCode ? 13.0 / 14.0 : run[FootnoteNumberAttribute.self] != nil ? 11.0 / 14.0 : 1
            let italic = run[AttributeScopes.AppKitAttributes.FontAttribute.self]?
                .fontDescriptor.symbolicTraits.contains(.italic) ?? false
            piece.setDualFont(size: size * ratio, bold: true, italic: italic, monospaced: isCode, fonts: theme.fonts)
            result.append(piece)
        }
        return result
    }

    /// A heading's formulas keep their LaTeX escapes, which the Markdown
    /// escape pass removed: `# H \% $a\,b$` reads "H % $a\,b$" (text outside
    /// the formula loses its backslash as everywhere). The same split as math
    /// paragraphs (`InlineMathSegmenter.pieces(of:)`). Since v1.15 the title
    /// view typesets the formulas (`BlockTextConverter.makeMathString`, which
    /// splits this text the same way); the heading's id and the Contents
    /// sidebar still read these characters, so they keep the source.
    private static func formulaSourceWithEscapes(_ attributed: AttributedString,
                                                 softBreaks: Bool = false) -> AttributedString {
        guard attributed.characters.contains("$") else { return attributed }
        let pieces = InlineMathSegmenter.pieces(of: attributed, softBreaks: softBreaks)
        guard pieces.contains(where: { if case .math = $0.segment { return true } else { return false } }) else {
            return attributed
        }
        var result = AttributedString()
        var index = attributed.startIndex
        for piece in pieces {
            guard let end = attributed.characters.index(index, offsetBy: piece.length,
                                                        limitedBy: attributed.endIndex) else { break }
            switch piece.segment {
            case .text:
                result.append(attributed[index..<end])
            case .math(let latex):
                // The formula's own attributes (its first run), its source with
                // escapes — except an escaped `$` (`\$` in the LaTeX: inside a
                // formula every `$` is one), which stays a `$` TAGGED as
                // escaped: written back as `\$` it would be a delimiter when
                // the title view splits this text again.
                let attributes = attributed[index..<end].runs.first?.attributes ?? AttributeContainer()
                var source = AttributedString(piece.delimiter, attributes: attributes)
                for (offset, part) in latex.components(separatedBy: "\\$").enumerated() {
                    if offset > 0 {
                        var dollar = AttributedString("$", attributes: attributes)
                        dollar[EscapedCharacterAttribute.self] = true
                        source.append(dollar)
                    }
                    source.append(AttributedString(part, attributes: attributes))
                }
                source.append(AttributedString(piece.delimiter, attributes: attributes))
                result.append(source)
            }
            index = end
        }
        return result
    }

    /// Point size of a level-`level` heading at this renderer's scale.
    func headerFontSize(level: Int) -> CGFloat {
        let sizes: [CGFloat] = [32, 26, 22, 18, 16, 14]
        // Safety guard: ensure level is within bounds to prevent crash
        let safeLevel = max(1, min(level, 6))
        return scaled(sizes[safeLevel - 1])
    }

    /// The AppKit font `renderHeader` sets on a heading's text (the same
    /// `DocumentFonts.appKit` call `setDualFont(bold: true)` makes; code spans
    /// and footnote numbers are smaller, italic runs keep their slant).
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
    ///
    /// A paragraph that is only `$$…$$` formulas (`quotedBodyLines`) becomes
    /// one line per formula: its source on one line, tagged with
    /// `DisplayMathAttribute`, which `BlockTextConverter.makeMathString`
    /// typesets as a display formula.
    func renderQuotedBody(_ content: String) -> AttributedString {
        var result = AttributedString()
        let lines = Self.quotedBodyLines(content)
        for (index, line) in lines.enumerated() {
            switch line {
            case .blank:
                result.append(AttributedString(" "))
            case .text(let text):
                result.append(renderInline(text))
            case .displayMath(let latex):
                // One line whatever the source's line breaks: the converter
                // replaces the whole run, and every other consumer reads lines.
                var source = AttributedString("$$" + latex.replacingOccurrences(of: "\n", with: " ") + "$$")
                source.setDualFont(size: scaled(14), fonts: theme.fonts)
                source.setDualForeground(theme.textColor)
                source[DisplayMathAttribute.self] = latex
                result.append(source)
            }
            if index < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }

    /// One shown line of a quote or alert body.
    enum QuotedBodyLine: Equatable {
        /// A blank source line (a paragraph break).
        case blank
        /// Inline Markdown, soft breaks already joined (`joinSoftBreaks`).
        case text(String)
        /// A display formula: its LaTeX, line breaks as written.
        case displayMath(latex: String)
    }

    /// The lines a quote or alert body shows — screen (`renderQuotedBody`)
    /// and print (`PrintableBlockquoteView`, `PrintableAlertView`) alike.
    ///
    /// Display math inside a quote, as GitHub decides it (v1.15, checked with
    /// `gh api markdown`): a PARAGRAPH (lines between blank lines) made only
    /// of `$$…$$` formulas — `$$a+b$$`, or `$$` / LaTeX lines / `$$`, or
    /// several formulas — shows each formula as display math. A `$$…$$` that
    /// shares its paragraph with text stays in the text, where the segmenter
    /// reads it as an INLINE formula ("Before⏎$$E$$⏎after", as GitHub's
    /// `js-inline-math`), or as text when its `$$` stands alone on a line
    /// ("Text⏎$$⏎x⏎$$": joined, the opener is followed by a space — text on
    /// GitHub too). The formula is read from the RAW lines, before the
    /// soft-break join, so a LaTeX `\\` at a line end stays LaTeX (the join
    /// would read it as a hard break).
    ///
    /// Without `$$` in the body this is exactly `joinSoftBreaks` (blank lines
    /// reset its state, so joining paragraph by paragraph equals joining the
    /// whole body).
    static func quotedBodyLines(_ content: String) -> [QuotedBodyLine] {
        let raw = content.components(separatedBy: "\n")
        guard content.contains("$$") else {
            return joinSoftBreaks(raw).map { isBlankLine($0) ? .blank : .text($0) }
        }
        var result: [QuotedBodyLine] = []
        var paragraph: [String] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            if let formulas = displayFormulas(paragraph) {
                result.append(contentsOf: formulas.map { .displayMath(latex: $0) })
            } else {
                result.append(contentsOf: joinSoftBreaks(paragraph).map { isBlankLine($0) ? .blank : .text($0) })
            }
            paragraph = []
        }
        for line in raw {
            if isBlankLine(line) {
                flush()
                result.append(.blank)
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return result
    }

    /// The formulas of a paragraph made only of `$$…$$` formulas (white space
    /// between them), each trimmed; nil when anything else is in it or a
    /// formula is empty.
    static func displayFormulas(_ paragraph: [String]) -> [String]? {
        var rest = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)[...]
        guard rest.hasPrefix("$$") else { return nil }
        var formulas: [String] = []
        while !rest.isEmpty {
            guard rest.hasPrefix("$$") else { return nil }
            let body = rest.dropFirst(2)
            guard let close = body.range(of: "$$") else { return nil }
            let latex = body[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !latex.isEmpty else { return nil }
            formulas.append(latex)
            rest = body[close.upperBound...].drop(while: { $0.isWhitespace || $0.isNewline })
        }
        return formulas.isEmpty ? nil : formulas
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

    /// Where a list item's text starts: its nesting level and the x of its
    /// text in points from the text margin (the gutter plus its hang — its
    /// list's widest marker for an ordered item, its own marker otherwise).
    /// What a block the item owns lines up with (`ListNesting`).
    struct ListItemColumn: Equatable, Sendable {
        let level: Int
        let textIndent: CGFloat
    }

    /// The text column of the item `itemLine` renders (`renderLine`), hanging
    /// under `hang` when it is an ordered item (`widestOrderedPrefixes`).
    /// Nil for a line that is not an item.
    func listItemColumn(itemLine: String, hang: String?) -> ListItemColumn? {
        let indent = itemLine.prefix(while: { $0 == " " || $0 == "\t" })
        let level = Self.listLevel(for: indent)
        let prefix: String
        if let task = parseTaskList(itemLine) {
            prefix = Self.indentSpaces(task.level) + (task.checked ? "☑ " : "☐ ")
        } else if let ordered = Self.orderedItem(itemLine) {
            prefix = hang ?? ordered.prefix
        } else if Self.isListItem(itemLine) {
            prefix = Self.indentSpaces(level) + "• "
        } else {
            return nil
        }
        return ListItemColumn(level: level, textIndent: scaled(Self.listGutter) + width(of: prefix))
    }

    /// `MarkdownBlock.listIndent` for print/PDF, which parses at 1.0 and
    /// draws text through SwiftUI `Text`: that ignores the paragraph style,
    /// so there is no list gutter and an item's text starts after its
    /// marker characters alone. A code block under the item lines up with
    /// that text by leaving the gutter out.
    static func printedListIndent(_ listIndent: CGFloat) -> CGFloat {
        max(0, listIndent - listGutter)
    }

    /// A paragraph of a list item after its first (CommonMark: indented to
    /// the item's content) — on GitHub it starts where the item's text does.
    /// The nesting lives in the CHARACTERS as for an item (one indent unit
    /// deeper than the item's, so print/PDF shows it under the item text);
    /// on screen the paragraph style puts every line at the item's text x,
    /// the first one pulled back by the width of those spaces.
    private func renderItemParagraph(_ line: String, column: ListItemColumn) -> AttributedString {
        let spaces = Self.indentSpaces(column.level + 1)
        var attr = AttributedString(spaces)
        attr.setDualFont(size: scaled(14), fonts: theme.fonts)
        attr.setDualForeground(theme.textColor)
        attr.append(renderInlineFormatting(Self.continuationText(line)))
        let lead = width(of: spaces)
        applyHangingIndent(&attr, indent: max(0, column.textIndent - lead), firstLineLead: 0,
                           hangWidth: column.textIndent - max(0, column.textIndent - lead))
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

    /// One line of inline Markdown, CommonMark's way: ONE left-to-right pass
    /// cuts the line into nodes — text, finished atoms (escape, code span,
    /// footnote number, image placeholder, autolink) and delimiter runs —
    /// while a bracket stack resolves links at their `]` and the delimiter
    /// stack (`InlineDelimiterStack`) resolves emphasis and strikethrough;
    /// then the nodes are drawn with the styles of the spans covering them.
    ///
    /// Why not "find the closing marker": precedence. A code span outranks
    /// emphasis (`*a `*`*`), a link outranks emphasis (`*[foo*](u)`), the
    /// INNER link wins (`[a [b](x) c](y)` links only "b"), and a run's
    /// neighbours decide whether it may open or close (`a * b*`, `5__6__78`).
    /// Linear in the line, no recursion (a link's text is part of the same
    /// pass), so 10 000 `[` or `*` cannot overflow the parse task's stack.
    private func renderInlineFormatting(_ text: String) -> AttributedString {
        // Native contiguous UTF-8 storage up front (a no-op unless the line is
        // a lazily bridged NSString, e.g. from `components(separatedBy:)`):
        // `InlineSyntaxScanner` reads that storage directly, and would
        // otherwise copy the rest of the line at every `[` / `![`.
        var text = text
        text.makeContiguousUTF8()
        var parse = InlineParse(text: text)
        var remaining = text[...]
        let utf8 = text.utf8

        while let byte = remaining.utf8.first {
            switch byte {
            case UInt8(ascii: "\\"):
                if !escapesDisabled, let (attr, rest) = tryParseEscape(&remaining) {
                    parse.append(.atom(attr, .body))
                    remaining = rest
                    continue
                }
            case UInt8(ascii: "`"):
                let span = parse.codeSpans.span(at: remaining)
                if let content = span.content {
                    parse.append(.atom(codeSpan(content), .code))
                } else {
                    parse.addPlain(remaining.startIndex..<span.end)  // a run that closes nowhere is text
                }
                remaining = text[span.end...]
                continue
            case UInt8(ascii: "*"), UInt8(ascii: "_"), UInt8(ascii: "~"):
                let length = remaining.utf8.prefix(while: { $0 == byte }).count
                let end = utf8.index(remaining.startIndex, offsetBy: length)
                parse.pushDelimiter(byte, length: length, from: remaining.startIndex, to: end)
                remaining = text[end...]
                continue
            case UInt8(ascii: "!"):
                if let (attr, rest) = tryParseImage(&remaining, pairs: parse.pairs) {
                    parse.append(.atom(attr, .imagePlaceholder))
                    remaining = rest
                    continue
                }
            case UInt8(ascii: "["):
                if let (attr, rest) = tryParseFootnoteRef(&remaining, closing: parse.closingBrackets) {
                    parse.append(.atom(attr, .footnoteNumber))
                    remaining = rest
                    continue
                }
                let afterOpen = utf8.index(after: remaining.startIndex)
                parse.openBracket(labelStart: afterOpen)
                remaining = text[afterOpen...]
                continue
            case UInt8(ascii: "]"):
                let afterClose = utf8.index(after: remaining.startIndex)
                if let end = parse.closeBracket(at: remaining.startIndex, rest: text[afterClose...],
                                                references: referenceDefinitions) {
                    remaining = text[end...]
                } else {
                    parse.addPlain(remaining.startIndex..<afterClose)
                    remaining = text[afterClose...]
                }
                continue
            case UInt8(ascii: "<"):
                if let (attr, rest) = tryParseAngleAutolink(remaining) {
                    parse.append(.atom(attr, .body))
                    remaining = rest
                    continue
                }
            case UInt8(ascii: "h"), UInt8(ascii: "w"):
                if let (attr, rest) = tryParseAutolink(remaining, in: text, scan: parse.autolinks) {
                    parse.append(.atom(attr, .body))
                    remaining = rest
                    continue
                }
            default:
                break
            }
            // Plain text up to the next byte some parser starts on (all of
            // them ASCII, so the cut is never inside a multi-byte scalar).
            let next = remaining.utf8.dropFirst().firstIndex(where: Self.startsInlineSyntax) ?? remaining.endIndex
            parse.addPlain(remaining.startIndex..<next)
            remaining = text[next...]
        }
        return draw(parse.finished())
    }

    /// Bytes the loop in `renderInlineFormatting` dispatches on.
    private static func startsInlineSyntax(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "\\"), UInt8(ascii: "`"), UInt8(ascii: "*"), UInt8(ascii: "_"), UInt8(ascii: "~"),
             UInt8(ascii: "!"), UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "<"),
             UInt8(ascii: "h"), UInt8(ascii: "w"):
            return true
        default:
            return false
        }
    }

    // MARK: - Inline parse state

    /// One piece of a line between parsing and drawing.
    private enum InlineNode {
        /// Source text, drawn in the body style (character references decoded).
        case text(Substring)
        /// A finished piece: escape, code span, footnote number, image
        /// placeholder, autolink — with the font it was drawn in, so
        /// emphasis can add its traits to that font (`restyle`).
        case atom(AttributedString, AtomFont)
        /// A delimiter run (index into the stack's runs): the characters no
        /// match used are text.
        case delimiter(Int)
    }

    /// Nodes `start..<end` are one link's text.
    private struct LinkSpan {
        let start: Int
        let end: Int
        let url: URL?
    }

    /// The state of one `renderInlineFormatting` pass (parsing only; no
    /// fonts or colours).
    private struct InlineParse {
        let text: String
        /// Bracket/paren matches of this text, computed once (lazily) so every
        /// `![` and `](` is a lookup, not a forward scan — O(n) per call.
        let pairs: InlineSyntaxScanner.PairTable
        let codeSpans: InlineSyntaxScanner.CodeSpanTable
        let closingBrackets: InlineSyntaxScanner.NextClosingBracket
        let autolinks = AutolinkScan()
        private(set) var nodes: [InlineNode] = []
        private(set) var delimiters = InlineDelimiterStack()
        private(set) var links: [LinkSpan] = []
        /// Source text not yet made a node — always one contiguous stretch,
        /// so a node is a slice of the line, never a copy per character.
        private var plain: Range<String.Index>?

        private struct Opener {
            /// The "[" text node (emptied when the link is made).
            let node: Int
            let labelStart: String.Index
            /// The delimiter stack's size at the "[": emphasis inside the
            /// link text is processed above it, never across it.
            let delimiterBottom: Int
        }
        private var openers: [Opener] = []
        /// Openers below this stack position are inactive: a link closed
        /// after them, and links never contain links.
        private var activeFrom = 0

        init(text: String) {
            self.text = text
            pairs = InlineSyntaxScanner.PairTable(text)
            codeSpans = InlineSyntaxScanner.CodeSpanTable(text)
            closingBrackets = InlineSyntaxScanner.NextClosingBracket(text)
        }

        private mutating func flush() {
            guard let range = plain else { return }
            nodes.append(.text(text[range]))
            plain = nil
        }

        /// `range` of the source as text (it continues the pending stretch).
        mutating func addPlain(_ range: Range<String.Index>) {
            if let pending = plain, pending.upperBound == range.lowerBound {
                plain = pending.lowerBound..<range.upperBound
            } else {
                flush()
                plain = range
            }
        }

        mutating func append(_ node: InlineNode) {
            flush()
            nodes.append(node)
        }

        /// A run of `byte` (`*`, `_`, `~`) over `start..<end`, classified by
        /// the source scalars around it.
        mutating func pushDelimiter(_ byte: UInt8, length: Int, from start: String.Index, to end: String.Index) {
            flush()
            let scalars = text.unicodeScalars
            let beforeIndex = start > text.startIndex ? scalars.index(before: start) : nil
            let before = beforeIndex.map { scalars[$0] }
            let after = end < text.endIndex ? scalars[end] : nil
            // A variation selector's base character decides CJK-ness.
            var cjkBefore = before
            if let selector = beforeIndex, let scalar = before, InlineDelimiterStack.isVariationSelector(scalar),
               selector > text.startIndex {
                cjkBefore = scalars[scalars.index(before: selector)]
            }
            if let run = delimiters.push(character: byte, length: length, node: nodes.count,
                                         before: before, after: after,
                                         beforeIsCJK: cjkBefore.map(InlineDelimiterStack.isCJK) ?? false,
                                         afterIsCJK: after.map(InlineDelimiterStack.isCJK) ?? false) {
                nodes.append(.delimiter(run))
            } else {
                nodes.append(.text(text[start..<end]))
            }
        }

        mutating func openBracket(labelStart: String.Index) {
            flush()
            openers.append(Opener(node: nodes.count, labelStart: labelStart, delimiterBottom: delimiters.count))
            nodes.append(.text("["))
        }

        /// A `]` at `close`: the end of the link it completes, or nil (the
        /// `]` is text). CommonMark: the nearest opener; an inactive one is
        /// dropped; else `InlineSyntaxScanner.linkTail` decides, and a link
        /// deactivates every opener before it.
        mutating func closeBracket(at close: String.Index, rest: Substring,
                                   references: [String: String]) -> String.Index? {
            guard let opener = openers.popLast() else { return nil }
            defer { activeFrom = min(activeFrom, openers.count) }
            guard openers.count >= activeFrom,
                  let tail = InlineSyntaxScanner.linkTail(after: rest, label: text[opener.labelStart..<close],
                                                          references: references, pairs: pairs) else { return nil }
            flush()
            delimiters.process(above: opener.delimiterBottom)
            nodes[opener.node] = .text("")
            let url: String
            let end: String.Index
            switch tail {
            case .inline(let destination, let tailEnd): (url, end) = (destination, tailEnd)
            case .reference(let destination, let tailEnd): (url, end) = (destination, tailEnd)
            }
            links.append(LinkSpan(start: opener.node + 1, end: nodes.count, url: MarkdownRenderer.linkURL(for: url)))
            activeFrom = openers.count
            return end
        }

        /// Flushes the text and resolves the emphasis outside links.
        mutating func finished() -> InlineParse {
            flush()
            delimiters.process(above: 0)
            return self
        }
    }

    // MARK: - Inline drawing

    /// What covers one node.
    private struct InlineStyle: Equatable {
        var bold = false
        var italic = false
        var strikethrough = false
        /// Index into `InlineParse.links`, -1 outside links.
        var link = -1
    }

    /// The nodes as one AttributedString: consecutive text with one style is
    /// ONE run (decoded once), atoms keep their own look under the rules of
    /// `restyle`.
    private func draw(_ parse: InlineParse) -> AttributedString {
        let nodes = parse.nodes
        var strong = [Int](repeating: 0, count: nodes.count + 1)
        var emphasis = strong
        var strike = strong
        for span in parse.delimiters.spans {
            switch span.style {
            case .strong: strong[span.start] += 1; strong[span.end] -= 1
            case .emphasis: emphasis[span.start] += 1; emphasis[span.end] -= 1
            case .strikethrough: strike[span.start] += 1; strike[span.end] -= 1
            }
        }
        // Links never nest or overlap, so filling them is linear.
        var linkOf = [Int](repeating: -1, count: nodes.count)
        for (index, link) in parse.links.enumerated() {
            for node in link.start..<link.end { linkOf[node] = index }
        }

        var styles: [InlineStyle] = []
        styles.reserveCapacity(nodes.count)
        var depth = (strong: 0, emphasis: 0, strike: 0)
        for index in nodes.indices {
            depth.strong += strong[index]
            depth.emphasis += emphasis[index]
            depth.strike += strike[index]
            styles.append(InlineStyle(bold: depth.strong > 0, italic: depth.emphasis > 0,
                                      strikethrough: depth.strike > 0, link: linkOf[index]))
        }
        // Whether a link sits INSIDE emphasis (only option A draws it in the
        // text colour, see `finish`): emphasis covers the link's emptied "["
        // node exactly then.
        let linkInEmphasis = parse.links.map { link in
            link.start > 0 && (styles[link.start - 1].bold || styles[link.start - 1].italic)
        }

        var result = AttributedString()
        var pending = ""
        var pendingStyle = InlineStyle()
        func flushText() {
            guard !pending.isEmpty else { return }
            let decoded = decodedText(pending)
            pending = ""
            // E-mail addresses in text outside links are links (GFM).
            let emails = pendingStyle.link < 0 && decoded.utf8.contains(UInt8(ascii: "@"))
                ? Self.emailAutolinks(in: decoded) : []
            var start = decoded.startIndex
            for email in emails + [decoded.endIndex..<decoded.endIndex] {
                if start < email.lowerBound {
                    var attr = AttributedString(String(decoded[start..<email.lowerBound]))
                    attr.setDualFont(size: scaled(14), bold: pendingStyle.bold, italic: pendingStyle.italic,
                                     fonts: theme.fonts)
                    attr.setDualForeground(theme.textColor)
                    finish(&attr, pendingStyle, parse.links, linkInEmphasis)
                    result.append(attr)
                }
                if !email.isEmpty {
                    let address = String(decoded[email])
                    var attr = autolinkText(address, url: URL(string: "mailto:" + address))
                    restyle(&attr, .body, pendingStyle)
                    finish(&attr, pendingStyle, parse.links, linkInEmphasis)
                    result.append(attr)
                }
                start = email.upperBound
            }
        }
        for (index, node) in nodes.enumerated() {
            let style = styles[index]
            switch node {
            case .text(let text):
                guard !text.isEmpty else { continue }
                if style != pendingStyle { flushText(); pendingStyle = style }
                pending += text
            case .delimiter(let run):
                let count = parse.delimiters.runs[run].count
                guard count > 0 else { continue }
                if style != pendingStyle { flushText(); pendingStyle = style }
                pending += String(repeating: Character(Unicode.Scalar(parse.delimiters.runs[run].character)),
                                  count: count)
            case .atom(var attr, let font):
                flushText()
                restyle(&attr, font, style)
                finish(&attr, style, parse.links, linkInEmphasis)
                result.append(attr)
            }
        }
        flushText()
        return result
    }

    /// The font an atom was drawn in (its own parser's `setDualFont` call),
    /// so emphasis can ADD traits to it instead of replacing it.
    private struct AtomFont {
        let size: CGFloat
        var bold = false
        var italic = false
        var monospaced = false

        /// Escapes, autolinks, e-mail links: the body font.
        static let body = AtomFont(size: 14)
        /// `codeSpan`.
        static let code = AtomFont(size: 13, monospaced: true)
        /// `tryParseFootnoteRef`'s superscript number.
        static let footnoteNumber = AtomFont(size: 11, bold: true)
        /// `tryParseImage`'s "[Image: alt]" placeholder.
        static let imagePlaceholder = AtomFont(size: 14, italic: true)
    }

    /// THE switch for what emphasis does to what it covers (decided for
    /// 1.15, option B; set to false to get the pre-1.15 look back, A):
    /// - true: emphasis only ADDS bold / italic to each piece's own font —
    ///   code stays monospaced on its chip, a footnote number keeps its
    ///   size, a link keeps the link colour (`**see [docs](u)**`);
    /// - false: emphasis re-stamps everything inside it with the body font
    ///   and the text colour, as every release before 1.15 did (code lost
    ///   its monospace, a bold link was drawn in the text colour).
    /// Nested emphasis combines its traits either way.
    private static let emphasisKeepsContentLook = true

    /// Emphasis over an atom (code span, footnote number, image placeholder,
    /// autolink, escape) — see `emphasisKeepsContentLook`. Fonts come from
    /// `DocumentFonts` (the Settings / theme family; a family without a
    /// bold-italic cut resolves to its closest face, never NSFontManager),
    /// both scopes; colours stay the atom's own.
    private func restyle(_ attr: inout AttributedString, _ font: AtomFont, _ style: InlineStyle) {
        guard style.bold || style.italic else { return }
        guard Self.emphasisKeepsContentLook else {
            attr.setDualFont(size: scaled(14), bold: style.bold, italic: style.italic, fonts: theme.fonts)
            attr.setDualForeground(theme.textColor)
            return
        }
        attr.setDualFont(size: scaled(font.size), bold: font.bold || style.bold, italic: font.italic || style.italic,
                         monospaced: font.monospaced, fonts: theme.fonts)
    }

    /// Strikethrough and the link over a styled piece: link colour (unless
    /// `emphasisKeepsContentLook` is off and the link sits inside emphasis —
    /// the pre-1.15 text colour), underline and URL; the OUTER link's URL
    /// replaces an inner autolink's or image's.
    private func finish(_ attr: inout AttributedString, _ style: InlineStyle,
                        _ links: [LinkSpan], _ linkInEmphasis: [Bool]) {
        if style.strikethrough { attr.setDualStrikethrough() }
        guard style.link >= 0 else { return }
        let textColored = !Self.emphasisKeepsContentLook && linkInEmphasis[style.link]
        attr.setDualForeground(textColored ? theme.textColor : theme.linkColor)
        attr.setDualUnderline()
        if let url = links[style.link].url { attr.link = url }
    }

    // MARK: - Inline Parsers

    /// A code span's look. The content as CommonMark reads it: a line break
    /// is a space (only a Setext title's anchor text still has one here —
    /// `code⏎span` is `code-span` on GitHub), and ONE space comes off both
    /// ends when it starts and ends with a space and is not all spaces
    /// (`` ` `` `` ` `` shows "``", `` `  ` `` keeps both spaces).
    private func codeSpan(_ content: Substring) -> AttributedString {
        var code = content.replacingOccurrences(of: "\n", with: " ")
        if code.count >= 2, code.hasPrefix(" "), code.hasSuffix(" "), code.contains(where: { $0 != " " }) {
            code = String(code.dropFirst().dropLast())
        }

        // A `$` in a code span is code, never a formula delimiter (GitHub:
        // "`$x$`" is `<code>$x$</code>` in paragraphs, quotes and cells
        // alike): tagged as an escaped `$` is, the one thing
        // `InlineMathSegmenter` reads to leave a dollar alone.
        var attr = AttributedString()
        for (index, part) in code.split(separator: "$", omittingEmptySubsequences: false).enumerated() {
            if index > 0 {
                var dollar = AttributedString("$")
                dollar[EscapedCharacterAttribute.self] = true
                attr.append(dollar)
            }
            attr.append(AttributedString(String(part)))
        }
        attr.setDualFont(size: scaled(13), monospaced: true, fonts: theme.fonts)
        attr.setDualForeground(theme.textColor)
        attr.setDualBackground(theme.codeBackgroundColor)
        return attr
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
        guard remaining.hasPrefix("\\"), remaining.utf8.count >= 2 else { return nil }  // O(1), not a Character count
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

    /// A CommonMark autolink, `<https://x.example>` or `<a@b.example>`: the
    /// address without its brackets, as a link (e-mail → `mailto:`). It
    /// outranks emphasis and links (`[a<https://x/?q=](u)>` is text + one
    /// autolink, as on GitHub).
    private func tryParseAngleAutolink(_ remaining: Substring) -> (AttributedString, Substring)? {
        guard let autolink = InlineSyntaxScanner.angleAutolink(atStartOf: remaining) else { return nil }
        // Character references are decoded in the text AND the URL, as on
        // GitHub (`<https://a.example/?a=1&amp;b=2>` opens `?a=1&b=2`);
        // bare autolinks keep them as written (GitHub does too).
        let address = decodedText(String(autolink.address))
        let url = autolink.isEmail ? URL(string: "mailto:" + address) : Self.linkURL(for: address)
        return (autolinkText(address, url: url), remaining[autolink.end...])
    }

    /// A bare URL — GFM's extended autolink for `http://`, `https://` and
    /// `www.` (linked as `http://`), with GitHub's edges: not inside a word
    /// (`www.` only after white space, `*`, `_`, `~`, `(`; a scheme not right
    /// after a letter); the domain must be valid (no `_` in its last two
    /// labels); the link runs to white space or `<` — and in QuickMD to `>`,
    /// `[`, `]`, so an autolink inside a link's text never eats its `]` —
    /// then loses trailing `?!.,:*_~'"`, a `)` it has no `(` for, and a
    /// trailing entity-like `&name;`. "See https://x.example." links
    /// without the period; `*https://x.example*` is emphasis around a link.
    private func tryParseAutolink(_ remaining: Substring, in text: String,
                                  scan: AutolinkScan) -> (AttributedString, Substring)? {
        guard let autolink = Self.bareAutolink(remaining, in: text, scan: scan) else { return nil }
        return (autolinkText(autolink.shown, url: Self.linkURL(for: autolink.url)), text[autolink.end...])
    }

    /// State of the bare-autolink attempts on ONE line (the renderer and
    /// `ReferenceLinks` keep one per line). A `www.` attempt whose domain
    /// failed (an `_` in its last two labels) is remembered: every later
    /// `www.` inside that domain runs to the same end and has the same last
    /// two labels (its own "www" label has no `_`), so it fails too —
    /// without rescanning. Without this `_www.a.` × N + `_x_` was quadratic
    /// (112 KB: 44 s). `work` counts the scalars examined, for the tests.
    final class AutolinkScan {
        fileprivate var failedDomain: Range<String.Index>?
        private(set) var work = 0
        fileprivate func examined(_ count: Int = 1) { work += count }
        init() {}
    }

    /// `tryParseAutolink`'s grammar: for `remaining` (a suffix of `text`)
    /// the link as shown, its URL as written, and its end. Static for
    /// `ReferenceLinks`, which must skip what the renderer links.
    static func bareAutolink(_ remaining: Substring, in text: String,
                             scan: AutolinkScan) -> (shown: String, url: String, end: String.Index)? {
        let utf8 = remaining.utf8
        let www = utf8.starts(with: "www.".utf8)
        let hostStart: String.Index
        if www {
            hostStart = remaining.startIndex
        } else if utf8.starts(with: "http://".utf8) {
            hostStart = utf8.index(remaining.startIndex, offsetBy: 7)
        } else if utf8.starts(with: "https://".utf8) {
            hostStart = utf8.index(remaining.startIndex, offsetBy: 8)
        } else {
            return nil
        }
        let scalars = text.unicodeScalars
        if remaining.startIndex > text.startIndex {
            let previous = scalars[scalars.index(before: remaining.startIndex)]
            if www {
                guard InlineDelimiterStack.isWhitespace(previous) || "*_~(".unicodeScalars.contains(previous) else {
                    return nil
                }
            } else if previous.isASCII, previous.properties.isAlphabetic {
                return nil
            }
        }

        if www, let failed = scan.failedDomain, failed.contains(remaining.startIndex) { return nil }

        // The domain (cmark-gfm `check_domain`).
        var index = www ? utf8.index(hostStart, offsetBy: 4) : hostStart
        let domainStart = index
        var periods = www ? 1 : 0
        var underscores = (last: 0, previous: 0)
        while index < text.endIndex {
            let scalar = scalars[index]
            if scalar == "." {
                periods += 1
                underscores = (0, underscores.last)
            } else if scalar == "_" {
                underscores.last += 1
            } else if scalar != "-",
                      InlineDelimiterStack.isWhitespace(scalar) || InlineDelimiterStack.isPunctuation(scalar)
                        || scalar.properties.generalCategory == .control {
                break
            }
            scan.examined()
            index = scalars.index(after: index)
        }
        guard index > domainStart, underscores.last == 0, underscores.previous == 0, periods > 0 || !www else {
            if www { scan.failedDomain = remaining.startIndex..<index }
            return nil
        }

        // The rest of the link, then GitHub's trailing trim (`autolink_delim`).
        while index < text.endIndex {
            let scalar = scalars[index]
            if InlineDelimiterStack.isWhitespace(scalar) || scalar.properties.generalCategory == .control
                || "<>[]".unicodeScalars.contains(scalar) { break }
            scan.examined()
            index = scalars.index(after: index)
        }
        var end = index
        var parens = (open: 0, close: 0)
        for scalar in scalars[remaining.startIndex..<end] {
            scan.examined()
            if scalar == "(" { parens.open += 1 } else if scalar == ")" { parens.close += 1 }
        }
        trim: while end > domainStart {
            scan.examined()
            let lastIndex = scalars.index(before: end)
            switch scalars[lastIndex] {
            case "?", "!", ".", ",", ":", "*", "_", "~", "'", "\"":
                end = lastIndex
            case ";":
                var entityStart = lastIndex
                while entityStart > remaining.startIndex {
                    let before = scalars[scalars.index(before: entityStart)]
                    guard before.isASCII, before.properties.isAlphabetic else { break }
                    entityStart = scalars.index(before: entityStart)
                }
                if entityStart < lastIndex, entityStart > remaining.startIndex,
                   scalars[scalars.index(before: entityStart)] == "&" {
                    end = scalars.index(before: entityStart)
                } else {
                    end = lastIndex
                }
            case ")" where parens.close > parens.open:
                parens.close -= 1
                end = lastIndex
            default:
                break trim
            }
        }
        guard end > domainStart else { return nil }

        let shown = String(text[remaining.startIndex..<end])
        return (shown, www ? "http://" + shown : shown, end)
    }

    /// The e-mail addresses GFM links in plain text (cmark-gfm's autolink
    /// extension): a local part of letters, digits and `.+-_` before an
    /// `@`, a domain of letters, digits, `-`, `_` with at least one `.`
    /// followed by a letter or digit, ending in a letter (a final `.` is
    /// dropped by the trailing trim): `a.b-c_d@a.b.` links `a.b-c_d@a.b`,
    /// `x@y.z_` and `hello@mail+xyz.example` link nothing.
    static func emailAutolinks(in text: String) -> [Range<String.Index>] {
        var work = 0
        return emailAutolinks(in: text, work: &work)
    }

    /// `emailAutolinks`, counting in `work` the bytes looked at around each
    /// `@` (each byte is walked back at most once and forward at most once:
    /// a local part never contains `@`, a domain stops at the next one) —
    /// for the tests.
    static func emailAutolinks(in text: String, work: inout Int) -> [Range<String.Index>] {
        let bytes = Array(text.utf8)
        func isAlnum(_ byte: UInt8) -> Bool {
            (byte >= 0x30 && byte <= 0x39) || ((byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A)
        }
        var found: [Range<String.Index>] = []
        var searchFrom = 0  // nothing before here is part of an address any more
        var at = 0
        while at < bytes.count {
            guard bytes[at] == UInt8(ascii: "@") else { at += 1; continue }
            var start = at
            while start > searchFrom,
                  isAlnum(bytes[start - 1]) || ".+-_".utf8.contains(bytes[start - 1]) { start -= 1; work += 1 }
            var end = at + 1
            var periods = 0
            // A local part right after `/` is part of a URL (`ftp://user@host`
            // is text on GitHub).
            var valid = start < at && (start == 0 || bytes[start - 1] != UInt8(ascii: "/"))
            while end < bytes.count {
                work += 1
                let byte = bytes[end]
                if isAlnum(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") {
                    end += 1
                } else if byte == UInt8(ascii: "."), end + 1 < bytes.count, isAlnum(bytes[end + 1]) {
                    periods += 1
                    end += 1
                } else {
                    if byte == UInt8(ascii: "@") { valid = false }
                    break
                }
            }
            let last = bytes[end - 1]
            if valid, end - at > 1, periods > 0, (last | 0x20) >= 0x61, (last | 0x20) <= 0x7A {
                let utf8 = text.utf8
                found.append(utf8.index(text.startIndex, offsetBy: start)..<utf8.index(text.startIndex, offsetBy: end))
                searchFrom = end
            }
            at = end
        }
        return found
    }

    /// An autolink's look: body size, link colour, underlined.
    private func autolinkText(_ shown: String, url: URL?) -> AttributedString {
        var attr = AttributedString(shown)
        attr.setDualFont(size: scaled(14), fonts: theme.fonts)
        attr.setDualForeground(theme.linkColor)
        attr.setDualUnderline()
        if let url { attr.link = url }
        return attr
    }

    // MARK: - Footnote References

    /// Opens the id of a footnote reference whose NUMBER is already known
    /// (`[^\u{E000}2]`, written by `ReferenceLinks` into quote, alert and
    /// table-cell markdown). A private-use code point: no document's own
    /// footnote id starts with it in practice.
    static let numberedFootnoteMarker: Unicode.Scalar = "\u{E000}"

    private func tryParseFootnoteRef(_ remaining: inout Substring,
                                     closing: InlineSyntaxScanner.NextClosingBracket) -> (AttributedString, Substring)? {
        guard remaining.hasPrefix("[^") else { return nil }

        let afterBracket = remaining.dropFirst(2)
        // The first `]` — from the line's shared lookup, linear per line.
        guard let closeIndex = closing.at(orAfter: afterBracket.startIndex) else { return nil }

        let fnId = String(afterBracket[..<closeIndex])
        guard !fnId.isEmpty else { return nil }

        // Find the footnote number (1-based index in definitions order), or
        // the number a quote / alert / table cell already carries
        // (`ReferenceLinks`: those are rendered without the definitions).
        let number: Int
        let key = ReferenceLabel.normalized(fnId)  // ids are stored normalised
        if let idx = footnoteDefinitions.firstIndex(where: { $0.id == key }) {
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
        attr[FootnoteNumberAttribute.self] = number
        attr.setDualFont(size: scaled(11), bold: true, fonts: theme.fonts)
        attr.setDualForeground(theme.linkColor)
        return (attr, afterBracket[afterBracket.index(after: closeIndex)...])
    }

}

/// The number a footnote reference draws as superscript digits, for
/// `headingAnchorText` (GitHub's heading id reads it as plain digits). Not
/// part of the AppKit scope, so an installed NSAttributedString never
/// carries it.
enum FootnoteNumberAttribute: AttributedStringKey {
    typealias Value = Int
    static let name = "qmdFootnoteNumber"
}
