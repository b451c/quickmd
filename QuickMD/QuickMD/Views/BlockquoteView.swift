import SwiftUI

// MARK: - Blockquote View

/// Renders a blockquote block with left border indicator and nested level support
struct BlockquoteView: View {
    let content: String
    let level: Int
    let theme: MarkdownTheme

    /// Cached renderer - created once per view
    private let renderer: MarkdownRenderer

    init(content: String, level: Int, theme: MarkdownTheme) {
        self.content = content
        self.level = level
        self.theme = theme
        self.renderer = MarkdownRenderer(colorScheme: theme.colorScheme)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left border bars - one per nesting level
            ForEach(0..<level, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.blockquoteColor.opacity(0.5))
                    .frame(width: 3)
                    .padding(.trailing, 10)
            }

            // Content
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(content.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    if line.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(" ")
                            .font(.system(size: 14))
                    } else {
                        Text(renderer.renderInline(line))
                            .font(.system(size: 14).italic())
                            .foregroundColor(theme.blockquoteColor)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.codeBackgroundColor.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
