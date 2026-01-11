import Foundation
import SwiftUI

struct MarkdownRenderer {
    let theme: MarkdownTheme

    init(colorScheme: ColorScheme) {
        self.theme = MarkdownTheme(colorScheme: colorScheme)
    }

    // MARK: - Main Render

    func render(_ markdown: String) -> AttributedString {
        var result = AttributedString()

        for line in markdown.components(separatedBy: "\n") {
            result.append(renderLine(line))
            result.append(AttributedString("\n"))
        }

        return result
    }

    // MARK: - Line Rendering

    private func renderLine(_ line: String) -> AttributedString {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Header (using regex instead of 6 if-else branches)
        if line.range(of: MarkdownTheme.headerPattern, options: .regularExpression) != nil,
           let hashEnd = line.firstIndex(of: " ") {
            let level = line.distance(from: line.startIndex, to: hashEnd)
            let content = String(line[line.index(after: hashEnd)...]).trimmingCharacters(in: .whitespaces)
            return renderHeader(content, level: min(level, 6))
        }

        // Horizontal rule
        if trimmed.range(of: MarkdownTheme.horizontalRulePattern, options: .regularExpression) != nil {
            return renderHorizontalRule()
        }

        // Blockquote
        if line.hasPrefix(">") {
            return renderBlockquote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
        }

        // Task list (must check before unordered list)
        if let taskMatch = parseTaskList(line) {
            return renderTaskItem(taskMatch.content, indent: taskMatch.indent, checked: taskMatch.checked)
        }

        // Unordered list
        if let bullet = ["- ", "* ", "+ "].first(where: { trimmed.hasPrefix($0) }) {
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            let content = String(trimmed.dropFirst(bullet.count))
            return renderListItem(content, indent: indent, ordered: false, number: 0)
        }

        // Ordered list
        if let match = trimmed.range(of: #"^(\d+)\.\s"#, options: .regularExpression) {
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            let number = Int(trimmed.prefix(while: { $0.isNumber })) ?? 1
            let content = String(trimmed[match.upperBound...])
            return renderListItem(content, indent: indent, ordered: true, number: number)
        }

        // Empty line
        if trimmed.isEmpty {
            return AttributedString("\n")
        }

        // Regular paragraph
        return renderInlineFormatting(line)
    }

    // MARK: - Block Renderers

    private func renderHeader(_ text: String, level: Int) -> AttributedString {
        var attr = renderInlineFormatting(text)
        let sizes: [CGFloat] = [32, 26, 22, 18, 16, 14]
        attr.font = .system(size: sizes[level - 1], weight: .bold)
        attr.foregroundColor = theme.textColor
        return attr
    }

    private func renderBlockquote(_ text: String) -> AttributedString {
        var attr = AttributedString("  " + text)
        attr.font = .system(size: 14).italic()
        attr.foregroundColor = theme.blockquoteColor
        return attr
    }

    private func renderListItem(_ text: String, indent: Int, ordered: Bool, number: Int) -> AttributedString {
        let indentStr = String(repeating: "    ", count: indent / 4 + (indent % 4 > 0 ? 1 : 0))
        let prefix = indentStr + (ordered ? "\(number). " : "• ")
        var attr = AttributedString(prefix)
        attr.font = .system(size: 14)
        attr.foregroundColor = theme.textColor
        attr.append(renderInlineFormatting(text))
        return attr
    }

    private func renderTaskItem(_ text: String, indent: Int, checked: Bool) -> AttributedString {
        let indentStr = String(repeating: "    ", count: indent / 4 + (indent % 4 > 0 ? 1 : 0))
        let checkbox = checked ? "☑ " : "☐ "
        var attr = AttributedString(indentStr + checkbox)
        attr.font = .system(size: 14)
        attr.foregroundColor = checked ? theme.checkboxColor : theme.textColor

        var content = renderInlineFormatting(text)
        if checked {
            content.strikethroughStyle = .single
            content.foregroundColor = theme.secondaryTextColor
        }
        attr.append(content)
        return attr
    }

    private func parseTaskList(_ line: String) -> (content: String, indent: Int, checked: Bool)? {
        guard let regex = try? NSRegularExpression(pattern: MarkdownTheme.taskListPattern) else { return nil }
        let nsRange = NSRange(line.startIndex..., in: line)

        guard let match = regex.firstMatch(in: line, range: nsRange),
              let indentRange = Range(match.range(at: 1), in: line),
              let checkRange = Range(match.range(at: 2), in: line),
              let contentRange = Range(match.range(at: 3), in: line) else { return nil }

        let indent = line[indentRange].count
        let checked = line[checkRange].lowercased() == "x"
        let content = String(line[contentRange])

        return (content: content, indent: indent, checked: checked)
    }

    private func renderHorizontalRule() -> AttributedString {
        var attr = AttributedString("────────────────────────────────")
        attr.font = .system(size: 14)
        attr.foregroundColor = theme.secondaryTextColor
        return attr
    }

    // MARK: - Inline Formatting (refactored into smaller methods)

    private func renderInlineFormatting(_ text: String) -> AttributedString {
        var result = AttributedString()
        var remaining = text[...]

        while !remaining.isEmpty {
            // Try each inline format in order
            if let (attr, newRemaining) = tryParseInlineCode(&remaining) ??
                                          tryParseBold(&remaining) ??
                                          tryParseItalic(&remaining) ??
                                          tryParseStrikethrough(&remaining) ??
                                          tryParseImage(&remaining) ??
                                          tryParseLink(&remaining) {
                result.append(attr)
                remaining = newRemaining
            } else {
                // Regular character
                result.append(makeChar(String(remaining.prefix(1))))
                remaining = remaining.dropFirst()
            }
        }

        return result
    }

    // MARK: - Inline Parsers

    private func tryParseInlineCode(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard remaining.hasPrefix("`"),
              let endIndex = remaining.dropFirst().firstIndex(of: "`") else { return nil }

        let code = String(remaining[remaining.index(after: remaining.startIndex)..<endIndex])
        var attr = AttributedString(code)
        attr.font = .system(size: 13, design: .monospaced)
        attr.foregroundColor = theme.textColor
        attr.backgroundColor = theme.codeBackgroundColor
        return (attr, remaining[remaining.index(after: endIndex)...])
    }

    private func tryParseBold(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard remaining.hasPrefix("**") || remaining.hasPrefix("__") else { return nil }

        let marker = String(remaining.prefix(2))
        let afterMarker = remaining.dropFirst(2)
        guard let endRange = afterMarker.range(of: marker) else { return nil }

        let boldText = String(afterMarker[..<endRange.lowerBound])
        var attr = AttributedString(boldText)
        attr.font = .system(size: 14, weight: .bold)
        attr.foregroundColor = theme.textColor
        return (attr, afterMarker[endRange.upperBound...])
    }

    private func tryParseItalic(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard (remaining.hasPrefix("*") && !remaining.hasPrefix("**")) ||
              (remaining.hasPrefix("_") && !remaining.hasPrefix("__")) else { return nil }

        let marker = remaining.first!
        let afterMarker = remaining.dropFirst()
        guard let endIndex = afterMarker.firstIndex(of: marker) else { return nil }

        let italicText = String(afterMarker[..<endIndex])
        var attr = AttributedString(italicText)
        attr.font = .system(size: 14).italic()
        attr.foregroundColor = theme.textColor
        return (attr, afterMarker[afterMarker.index(after: endIndex)...])
    }

    private func tryParseStrikethrough(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard remaining.hasPrefix("~~") else { return nil }

        let afterMarker = remaining.dropFirst(2)
        guard let endRange = afterMarker.range(of: "~~") else { return nil }

        let strikeText = String(afterMarker[..<endRange.lowerBound])
        var attr = AttributedString(strikeText)
        attr.font = .system(size: 14)
        attr.foregroundColor = theme.textColor
        attr.strikethroughStyle = .single
        return (attr, afterMarker[endRange.upperBound...])
    }

    private func tryParseLink(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard remaining.hasPrefix("["),
              let closeBracket = remaining.firstIndex(of: "]"),
              remaining[remaining.index(after: closeBracket)...].hasPrefix("("),
              let closeParen = remaining[remaining.index(after: closeBracket)...].firstIndex(of: ")") else { return nil }

        let linkText = String(remaining[remaining.index(after: remaining.startIndex)..<closeBracket])
        let urlText = String(remaining[remaining.index(closeBracket, offsetBy: 2)..<closeParen])

        var attr = AttributedString(linkText)
        attr.font = .system(size: 14)
        attr.foregroundColor = theme.linkColor
        attr.underlineStyle = .single
        if let url = URL(string: urlText) {
            attr.link = url
        }
        return (attr, remaining[remaining.index(after: closeParen)...])
    }

    private func tryParseImage(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard remaining.hasPrefix("!["),
              let closeBracket = remaining.dropFirst(2).firstIndex(of: "]"),
              let afterBracket = remaining.index(closeBracket, offsetBy: 1, limitedBy: remaining.endIndex),
              remaining[afterBracket...].hasPrefix("("),
              let closeParen = remaining[afterBracket...].firstIndex(of: ")") else { return nil }

        let altText = String(remaining[remaining.index(remaining.startIndex, offsetBy: 2)..<closeBracket])
        let urlText = String(remaining[remaining.index(closeBracket, offsetBy: 2)..<closeParen])

        var attr = AttributedString("[Image: \(altText)]")
        attr.font = .system(size: 14).italic()
        attr.foregroundColor = theme.secondaryTextColor
        if let url = URL(string: urlText) {
            attr.link = url
        }
        return (attr, remaining[remaining.index(after: closeParen)...])
    }

    private func makeChar(_ char: String) -> AttributedString {
        var attr = AttributedString(char)
        attr.font = .system(size: 14)
        attr.foregroundColor = theme.textColor
        return attr
    }
}
