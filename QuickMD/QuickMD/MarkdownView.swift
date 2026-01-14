import SwiftUI

// MARK: - Content Block Types

enum MarkdownBlock: Identifiable {
    case text(AttributedString)
    case table(headers: [String], rows: [[String]])
    case codeBlock(code: String, language: String)
    case image(url: String, alt: String)

    var id: String {
        switch self {
        case .text(let str): return "text-\(str.hashValue)"
        case .table(let h, _): return "table-\(h.joined())"
        case .codeBlock(let c, _): return "code-\(c.hashValue)"
        case .image(let url, _): return "image-\(url.hashValue)"
        }
    }
}

// MARK: - Main View

struct MarkdownView: View {
    let document: MarkdownDocument
    @Environment(\.colorScheme) var colorScheme

    private var theme: MarkdownTheme {
        MarkdownTheme(colorScheme: colorScheme)
    }

    private var blocks: [MarkdownBlock] {
        MarkdownBlockParser(colorScheme: colorScheme).parse(document.text)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(blocks) { block in
                        switch block {
                        case .text(let attributedString):
                            Text(attributedString)
                                .textSelection(.enabled)

                        case .table(let headers, let rows):
                            TableBlockView(headers: headers, rows: rows, theme: theme)
                                .padding(.vertical, 8)

                        case .codeBlock(let code, let language):
                            CodeBlockView(code: code, language: language, theme: theme)
                                .padding(.vertical, 4)

                        case .image(let url, let alt):
                            ImageBlockView(url: url, alt: alt, theme: theme)
                                .padding(.vertical, 8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
            }

            // Subtle donation button
            SupportButton(theme: theme)
                .padding(16)
        }
        .background(theme.backgroundColor)
        .frame(minWidth: 400, minHeight: 300)
    }
}

// MARK: - Support Button

struct SupportButton: View {
    let theme: MarkdownTheme
    @State private var isHovered = false

    var body: some View {
        Menu {
            Button {
                NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/bsroczynskh")!)
            } label: {
                Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
            }

            Button {
                NSWorkspace.shared.open(URL(string: "https://ko-fi.com/quickmd")!)
            } label: {
                Label("Ko-fi", systemImage: "heart.fill")
            }
        } label: {
            HStack(spacing: 4) {
                Text("☕")
                    .font(.system(size: 12))
                if isHovered {
                    Text("Support")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, isHovered ? 10 : 6)
            .padding(.vertical, 4)
            .background(theme.codeBackgroundColor.opacity(isHovered ? 0.9 : 0.6))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .opacity(isHovered ? 1.0 : 0.5)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Support QuickMD development")
    }
}

// MARK: - Table View

struct TableBlockView: View {
    let headers: [String]
    let rows: [[String]]
    let theme: MarkdownTheme

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                    Text(header)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.textColor)
                        .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(theme.headerBackgroundColor)

                    if index < headers.count - 1 {
                        Rectangle().fill(theme.borderColor).frame(width: 1)
                    }
                }
            }
            .background(theme.headerBackgroundColor)

            Rectangle().fill(theme.borderColor).frame(height: 1)

            // Data rows
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIndex, cell in
                        Text(cell)
                            .font(.system(size: 13))
                            .foregroundColor(theme.textColor)
                            .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)

                        if colIndex < row.count - 1 {
                            Rectangle().fill(theme.borderColor).frame(width: 1)
                        }
                    }
                }

                if rowIndex < rows.count - 1 {
                    Rectangle().fill(theme.borderColor).frame(height: 1)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.borderColor, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Code Block View

struct CodeBlockView: View {
    let code: String
    let language: String
    let theme: MarkdownTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                Text(language)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.secondaryTextColor)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }

            Text(highlightedCode)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, language.isEmpty ? 12 : 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.codeBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var highlightedCode: AttributedString {
        var result = AttributedString()
        let lines = code.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            result.append(highlightLine(line))
            if index < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }

    private func highlightLine(_ line: String) -> AttributedString {
        var result = AttributedString(line)
        result.foregroundColor = theme.textColor

        // Comments
        if let commentRange = findPattern(in: line, pattern: #"(//.*|#.*|--.*)"#) {
            applyColor(to: &result, range: commentRange, in: line, color: theme.commentColor)
            return result
        }

        // Strings
        applyPatternColor(to: &result, in: line, pattern: #"\"[^\"]*\"|'[^']*'"#, color: theme.stringColor)

        // Numbers
        applyPatternColor(to: &result, in: line, pattern: #"\b\d+\.?\d*\b"#, color: theme.numberColor)

        // Keywords (common across languages)
        let keywords = #"\b(func|function|def|class|struct|enum|let|var|const|if|else|for|while|return|import|from|pub|fn|async|await|try|catch|throw|new|self|this|nil|null|true|false|None|True|False)\b"#
        applyPatternColor(to: &result, in: line, pattern: keywords, color: theme.keywordColor)

        // Types (capitalized words)
        applyPatternColor(to: &result, in: line, pattern: #"\b[A-Z][a-zA-Z0-9]*\b"#, color: theme.typeColor)

        return result
    }

    private func findPattern(in text: String, pattern: String) -> Range<String.Index>? {
        text.range(of: pattern, options: .regularExpression)
    }

    private func applyPatternColor(to result: inout AttributedString, in line: String, pattern: String, color: Color) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let nsRange = NSRange(line.startIndex..., in: line)

        for match in regex.matches(in: line, range: nsRange) {
            if let range = Range(match.range, in: line) {
                applyColor(to: &result, range: range, in: line, color: color)
            }
        }
    }

    private func applyColor(to result: inout AttributedString, range: Range<String.Index>, in line: String, color: Color) {
        let start = line.distance(from: line.startIndex, to: range.lowerBound)
        let length = line.distance(from: range.lowerBound, to: range.upperBound)

        var currentIndex = result.startIndex
        for _ in 0..<start {
            guard currentIndex < result.endIndex else { return }
            currentIndex = result.index(afterCharacter: currentIndex)
        }

        var endIndex = currentIndex
        for _ in 0..<length {
            guard endIndex < result.endIndex else { break }
            endIndex = result.index(afterCharacter: endIndex)
        }

        if currentIndex < endIndex {
            result[currentIndex..<endIndex].foregroundColor = color
        }
    }
}

// MARK: - Image Block View

struct ImageBlockView: View {
    let url: String
    let alt: String
    let theme: MarkdownTheme

    var body: some View {
        Group {
            if let imageURL = resolvedURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(height: 100)
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 600)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    case .failure:
                        imageErrorView
                    @unknown default:
                        imageErrorView
                    }
                }
            } else {
                imageErrorView
            }
        }

        if !alt.isEmpty {
            Text(alt)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryTextColor)
                .italic()
        }
    }

    private var resolvedURL: URL? {
        if url.hasPrefix("http://") || url.hasPrefix("https://") {
            return URL(string: url)
        } else if url.hasPrefix("file://") {
            return URL(string: url)
        } else if url.hasPrefix("/") {
            return URL(fileURLWithPath: url)
        } else {
            // Relative path - could be expanded with document URL context
            return URL(string: url)
        }
    }

    private var imageErrorView: some View {
        HStack {
            Image(systemName: "photo")
            Text("Image: \(alt.isEmpty ? url : alt)")
        }
        .font(.system(size: 13))
        .foregroundColor(theme.secondaryTextColor)
        .padding(12)
        .background(theme.codeBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Block Parser

struct MarkdownBlockParser {
    let colorScheme: ColorScheme

    func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = markdown.components(separatedBy: "\n")
        var i = 0
        var textBuffer: [String] = []

        while i < lines.count {
            let line = lines[i]

            // Fenced code block
            if line.hasPrefix("```") {
                flushTextBuffer(&textBuffer, to: &blocks)
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1

                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }

                blocks.append(.codeBlock(code: codeLines.joined(separator: "\n"), language: language))
                i += 1
                continue
            }

            // Standalone image (on its own line)
            if let imageMatch = parseStandaloneImage(line) {
                flushTextBuffer(&textBuffer, to: &blocks)
                blocks.append(.image(url: imageMatch.url, alt: imageMatch.alt))
                i += 1
                continue
            }

            // Table detection
            if line.contains("|") && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if !isTableSeparator(trimmed) && i + 1 < lines.count && isTableSeparator(lines[i + 1]) {
                    flushTextBuffer(&textBuffer, to: &blocks)

                    let headers = parseTableRow(line)
                    var rows: [[String]] = []
                    i += 2 // Skip header and separator

                    while i < lines.count && lines[i].contains("|") && !isTableSeparator(lines[i]) {
                        rows.append(parseTableRow(lines[i]))
                        i += 1
                    }

                    blocks.append(.table(headers: headers, rows: rows))
                    continue
                }
            }

            textBuffer.append(line)
            i += 1
        }

        flushTextBuffer(&textBuffer, to: &blocks)
        return blocks
    }

    private func parseStandaloneImage(_ line: String) -> (url: String, alt: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let regex = try? NSRegularExpression(pattern: MarkdownTheme.imagePattern) else { return nil }
        let nsRange = NSRange(trimmed.startIndex..., in: trimmed)

        guard let match = regex.firstMatch(in: trimmed, range: nsRange),
              let altRange = Range(match.range(at: 1), in: trimmed),
              let urlRange = Range(match.range(at: 2), in: trimmed) else { return nil }

        return (url: String(trimmed[urlRange]), alt: String(trimmed[altRange]))
    }

    // MARK: - Helpers

    private func isTableSeparator(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces)
            .range(of: MarkdownTheme.tableSeparatorPattern, options: .regularExpression) != nil
    }

    private func parseTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed = String(trimmed.dropFirst()) }
        if trimmed.hasSuffix("|") { trimmed = String(trimmed.dropLast()) }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func flushTextBuffer(_ buffer: inout [String], to blocks: inout [MarkdownBlock]) {
        guard !buffer.isEmpty else { return }
        let renderer = MarkdownRenderer(colorScheme: colorScheme)
        blocks.append(.text(renderer.render(buffer.joined(separator: "\n"))))
        buffer = []
    }
}

// MARK: - Preview

#Preview {
    MarkdownView(document: MarkdownDocument(text: """
    # Welcome to QuickMD

    This is a **bold** and *italic* text example with `inline code`.

    ## Task Lists

    - [x] Image rendering
    - [x] Syntax highlighting
    - [x] Task lists
    - [ ] Future feature

    ## Nested Lists

    - First item
        - Nested item
        - Another nested
    - Second item
        1. Ordered nested
        2. Another ordered

    ## Table Example

    | Feature | Status | Notes |
    |---------|--------|-------|
    | Headers | Done | Working |
    | Tables  | Done | New! |

    ## Code with Highlighting

    ```swift
    func greet(_ name: String) -> String {
        let message = "Hello, \\(name)!"
        return message // Returns greeting
    }
    ```

    ```python
    def process(data):
        count = 42
        return "Result: " + str(count)
    ```

    ## Image

    ![SwiftUI Logo](https://developer.apple.com/assets/elements/icons/swiftui/swiftui-96x96_2x.png)

    [Visit Apple](https://apple.com)
    """))
}
