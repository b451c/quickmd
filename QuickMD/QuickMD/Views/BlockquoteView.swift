import SwiftUI

// MARK: - Blockquote View

/// Renders a blockquote block with left border indicator and nested level support
struct BlockquoteView: View {
    let content: String
    let level: Int
    let theme: MarkdownTheme
    var searchText: String = ""
    var focusedOccurrence: Int? = nil

    /// Cached renderer - created once per view
    private let renderer: MarkdownRenderer

    init(content: String, level: Int, theme: MarkdownTheme,
         searchText: String = "", focusedOccurrence: Int? = nil) {
        self.content = content
        self.level = level
        self.theme = theme
        self.searchText = searchText
        self.focusedOccurrence = focusedOccurrence
        self.renderer = MarkdownRenderer(theme: theme)
    }

    var body: some View {
        let lines = content.components(separatedBy: "\n")
        let lineData = computeLineData(lines: lines)

        HStack(alignment: .top, spacing: 0) {
            // Left border bars - one per nesting level
            ForEach(0..<level, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.blockquoteColor.opacity(0.5))
                    .frame(width: 3)
                    .padding(.trailing, 8)
            }

            // Content
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lineData.enumerated()), id: \.offset) { _, data in
                    if data.line.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(" ")
                            .font(.system(size: 14))
                    } else {
                        let rendered = renderer.renderInline(data.line)
                        Text(searchText.isEmpty ? rendered : searchHighlight(rendered, term: searchText, focusedOccurrence: data.localFocused))
                            .font(.system(size: 14).italic())
                            .foregroundColor(theme.blockquoteColor)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.leading, 16)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Per-Line Occurrence Tracking

    private struct LineData {
        let line: String
        let localFocused: Int?
    }

    /// Compute per-line focused occurrence by tracking cumulative offset
    private func computeLineData(lines: [String]) -> [LineData] {
        guard !searchText.isEmpty else {
            return lines.map { LineData(line: $0, localFocused: nil) }
        }
        var offset = 0
        return lines.map { line in
            let count = countOccurrences(in: line, of: searchText)
            let local: Int?
            if let fo = focusedOccurrence, fo >= offset && fo < offset + count {
                local = fo - offset
            } else {
                local = nil
            }
            offset += count
            return LineData(line: line, localFocused: local)
        }
    }
}
