import SwiftUI

// MARK: - Content Block Types

enum MarkdownBlock: Identifiable {
    case text(AttributedString)
    case table(headers: [String], rows: [[String]], alignments: [TextAlignment])
    case codeBlock(code: String, language: String)
    case image(url: String, alt: String)

    var id: String {
        switch self {
        case .text(let str): return "text-\(str.hashValue)"
        case .table(let h, _, _): return "table-\(h.joined())"
        case .codeBlock(let c, _): return "code-\(c.hashValue)"
        case .image(let url, _): return "image-\(url.hashValue)"
        }
    }
}

// MARK: - Main View

struct MarkdownView: View {
    let document: MarkdownDocument
    let documentURL: URL?
    @Environment(\.colorScheme) var colorScheme
    @State private var cachedBlocks: [MarkdownBlock] = []

    private var theme: MarkdownTheme {
        MarkdownTheme(colorScheme: colorScheme)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(cachedBlocks) { block in
                        switch block {
                        case .text(let attributedString):
                            Text(attributedString)
                                .textSelection(.enabled)
                                .id(block.id)

                        case .table(let headers, let rows, let alignments):
                            TableBlockView(headers: headers, rows: rows, alignments: alignments, theme: theme)
                                .padding(.vertical, 8)
                                .id(block.id)

                        case .codeBlock(let code, let language):
                            CodeBlockView(code: code, language: language, theme: theme)
                                .padding(.vertical, 4)
                                .id(block.id)

                        case .image(let url, let alt):
                            ImageBlockView(url: url, alt: alt, theme: theme, documentURL: documentURL)
                                .padding(.vertical, 8)
                                .id(block.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
            }

            #if APPSTORE
            // Tip Jar button (App Store version)
            TipJarButton(theme: theme)
                .padding(16)
            #else
            // Donation button (GitHub version)
            SupportButton(theme: theme)
                .padding(16)
            #endif
        }
        .background(theme.backgroundColor)
        .frame(minWidth: 400, minHeight: 300)
        .task(id: document.text.hashValue ^ colorScheme.hashValue) {
            cachedBlocks = MarkdownBlockParser(colorScheme: colorScheme).parse(document.text)
            // Update shared state for export/print menu commands
            ExportStateManager.shared.currentBlocks = cachedBlocks
            ExportStateManager.shared.currentDocumentText = document.text
        }
    }
}

// MARK: - Tip Jar Button (App Store version)

#if APPSTORE
struct TipJarButton: View {
    let theme: MarkdownTheme
    @Environment(\.openWindow) private var openWindow
    @State private var isHovered = false

    var body: some View {
        Button {
            openWindow(id: "tip-jar")
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11))
                if isHovered {
                    Text("Tip Jar")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, isHovered ? 10 : 6)
            .padding(.vertical, 4)
            .background(theme.codeBackgroundColor.opacity(isHovered ? 0.9 : 0.6))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundColor(.pink)
        .opacity(isHovered ? 1.0 : 0.5)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Support QuickMD")
    }
}
#endif

// MARK: - Support Button (GitHub version)

#if !APPSTORE
struct SupportButton: View {
    let theme: MarkdownTheme
    @State private var isHovered = false

    var body: some View {
        Menu {
            Button {
                NSWorkspace.shared.open(URL(string: "https://qmd.app/")!)
            } label: {
                Label("Visit qmd.app", systemImage: "globe")
            }
            Divider()
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
#endif

// MARK: - Table View

struct TableBlockView: View {
    let headers: [String]
    let rows: [[String]]
    let alignments: [TextAlignment]
    let theme: MarkdownTheme

    private var renderer: MarkdownRenderer {
        MarkdownRenderer(colorScheme: theme.colorScheme)
    }

    private func alignmentFor(_ index: Int) -> Alignment {
        guard index < alignments.count else { return .leading }
        switch alignments[index] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        @unknown default: return .leading
        }
    }

    private func textAlignmentFor(_ index: Int) -> TextAlignment {
        guard index < alignments.count else { return .leading }
        return alignments[index]
    }

    private var columnCount: Int { headers.count }

    // Overlay for vertical dividers on a row
    private func verticalDividers() -> some View {
        GeometryReader { geo in
            let cellWidth = geo.size.width / CGFloat(columnCount)
            ForEach(1..<columnCount, id: \.self) { i in
                Rectangle()
                    .fill(theme.borderColor)
                    .frame(width: 1, height: geo.size.height)
                    .position(x: cellWidth * CGFloat(i), y: geo.size.height / 2)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                ForEach(0..<columnCount, id: \.self) { index in
                    Text(renderer.renderInline(headers[index]))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.textColor)
                        .multilineTextAlignment(textAlignmentFor(index))
                        .frame(maxWidth: .infinity, alignment: alignmentFor(index))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
            .background(theme.headerBackgroundColor)
            .overlay(verticalDividers())

            // Header separator
            Rectangle().fill(theme.borderColor).frame(height: 1)

            // Data rows
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { colIndex in
                        let cell = colIndex < row.count ? row[colIndex] : ""
                        Text(renderer.renderInline(cell))
                            .font(.system(size: 13))
                            .foregroundColor(theme.textColor)
                            .multilineTextAlignment(textAlignmentFor(colIndex))
                            .frame(maxWidth: .infinity, alignment: alignmentFor(colIndex))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                }
                .overlay(verticalDividers())

                // Row separator (except for last row)
                if rowIndex < rows.count - 1 {
                    Rectangle().fill(theme.borderColor).frame(height: 1)
                }
            }
        }
        .background(theme.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.borderColor, lineWidth: 1))
    }
}

// MARK: - Code Block View

struct CodeBlockView: View {
    let code: String
    let language: String
    let theme: MarkdownTheme

    // Static precompiled regex patterns (compiled once, reused for all lines)
    private static let commentRegex = try! NSRegularExpression(pattern: #"(//.*|#.*|--.*)"#)
    private static let stringRegex = try! NSRegularExpression(pattern: #"\"[^\"]*\"|'[^']*'"#)
    private static let numberRegex = try! NSRegularExpression(pattern: #"\b\d+\.?\d*\b"#)
    private static let keywordRegex = try! NSRegularExpression(pattern: #"\b(func|function|def|class|struct|enum|let|var|const|if|else|for|while|return|import|from|pub|fn|async|await|try|catch|throw|new|self|this|nil|null|true|false|None|True|False)\b"#)
    private static let typeRegex = try! NSRegularExpression(pattern: #"\b[A-Z][a-zA-Z0-9]*\b"#)

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
        let nsRange = NSRange(line.startIndex..., in: line)

        // Comments - if found, return early (entire line is comment-colored)
        if let match = Self.commentRegex.firstMatch(in: line, range: nsRange),
           let range = Range(match.range, in: line) {
            applyColor(to: &result, range: range, in: line, color: theme.commentColor)
            return result
        }

        // Strings
        applyRegexColor(to: &result, in: line, regex: Self.stringRegex, nsRange: nsRange, color: theme.stringColor)

        // Numbers
        applyRegexColor(to: &result, in: line, regex: Self.numberRegex, nsRange: nsRange, color: theme.numberColor)

        // Keywords
        applyRegexColor(to: &result, in: line, regex: Self.keywordRegex, nsRange: nsRange, color: theme.keywordColor)

        // Types (capitalized words)
        applyRegexColor(to: &result, in: line, regex: Self.typeRegex, nsRange: nsRange, color: theme.typeColor)

        return result
    }

    private func applyRegexColor(to result: inout AttributedString, in line: String, regex: NSRegularExpression, nsRange: NSRange, color: Color) {
        for match in regex.matches(in: line, range: nsRange) {
            if let range = Range(match.range, in: line) {
                applyColor(to: &result, range: range, in: line, color: color)
            }
        }
    }

    private func applyColor(to result: inout AttributedString, range: Range<String.Index>, in line: String, color: Color) {
        // O(1) index calculation using direct offset computation
        let startOffset = line.distance(from: line.startIndex, to: range.lowerBound)
        let endOffset = line.distance(from: line.startIndex, to: range.upperBound)

        let characters = result.characters
        guard startOffset < characters.count, endOffset <= characters.count else { return }

        let attrStart = characters.index(characters.startIndex, offsetBy: startOffset)
        let attrEnd = characters.index(characters.startIndex, offsetBy: endOffset)

        if attrStart < attrEnd {
            result[attrStart..<attrEnd].foregroundColor = color
        }
    }
}

// MARK: - Image Block View

struct ImageBlockView: View {
    let url: String
    let alt: String
    let theme: MarkdownTheme
    let documentURL: URL?

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
        } else if let docURL = documentURL {
            // Relative path - resolve relative to document directory
            return docURL.deletingLastPathComponent().appendingPathComponent(url)
        } else {
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

            // Setext headers (underlined headers)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if i + 1 < lines.count && !trimmed.isEmpty && !trimmed.contains("|") {
                let nextLine = lines[i + 1].trimmingCharacters(in: .whitespaces)

                if nextLine.range(of: MarkdownTheme.setextH1Pattern, options: .regularExpression) != nil {
                    flushTextBuffer(&textBuffer, to: &blocks)
                    blocks.append(.text(renderSetextHeader(trimmed, level: 1)))
                    i += 2
                    continue
                }

                if nextLine.range(of: MarkdownTheme.setextH2Pattern, options: .regularExpression) != nil &&
                   !isTableSeparator(nextLine) {
                    flushTextBuffer(&textBuffer, to: &blocks)
                    blocks.append(.text(renderSetextHeader(trimmed, level: 2)))
                    i += 2
                    continue
                }
            }

            // Table detection
            if line.contains("|") && !trimmed.isEmpty {
                if !isTableSeparator(trimmed) && i + 1 < lines.count && isTableSeparator(lines[i + 1]) {
                    flushTextBuffer(&textBuffer, to: &blocks)

                    let headers = parseTableRow(line)
                    let columnCount = headers.count
                    var alignments = parseTableAlignments(lines[i + 1])
                    var rows: [[String]] = []
                    i += 2 // Skip header and separator

                    while i < lines.count && lines[i].contains("|") && !isTableSeparator(lines[i]) {
                        rows.append(parseTableRow(lines[i]))
                        i += 1
                    }

                    // Normalize: ensure all rows and alignments match column count
                    alignments = normalizeArray(alignments, to: columnCount, default: .leading)
                    rows = rows.map { normalizeArray($0, to: columnCount, default: "") }

                    blocks.append(.table(headers: headers, rows: rows, alignments: alignments))
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

    private func parseTableAlignments(_ separatorLine: String) -> [TextAlignment] {
        let cells = parseTableRow(separatorLine)
        return cells.map { cell in
            let t = cell.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let hasLeft = t.hasPrefix(":")
            let hasRight = t.hasSuffix(":")
            if hasLeft && hasRight { return .center }
            if hasRight { return .trailing }
            return .leading
        }
    }

    /// Normalize array to exact count - pad with default or trim excess
    private func normalizeArray<T>(_ array: [T], to count: Int, default defaultValue: T) -> [T] {
        if array.count == count { return array }
        if array.count > count { return Array(array.prefix(count)) }
        return array + Array(repeating: defaultValue, count: count - array.count)
    }

    private func flushTextBuffer(_ buffer: inout [String], to blocks: inout [MarkdownBlock]) {
        guard !buffer.isEmpty else { return }
        let renderer = MarkdownRenderer(colorScheme: colorScheme)
        blocks.append(.text(renderer.render(buffer.joined(separator: "\n"))))
        buffer = []
    }

    private func renderSetextHeader(_ text: String, level: Int) -> AttributedString {
        let renderer = MarkdownRenderer(colorScheme: colorScheme)
        var attr = renderer.renderInline(text)
        attr.font = .system(size: level == 1 ? 32 : 26, weight: .bold)
        return attr
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
    """), documentURL: nil)
}
