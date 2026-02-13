import SwiftUI

// MARK: - Main View

/// Main Markdown document view
/// Renders parsed markdown blocks in a scrollable container with support button
struct MarkdownView: View {
    let document: MarkdownDocument
    let documentURL: URL?
    @Environment(\.colorScheme) private var colorScheme
    @State private var cachedBlocks: [MarkdownBlock] = []
    @State private var searchText: String = ""
    @State private var isSearchVisible: Bool = false
    @State private var currentMatchIndex: Int = 0
    @State private var matchBlockIds: [String] = []
    @State private var scrollTrigger: Int = 0
    @State private var keyMonitor: Any?
    @State private var isToCVisible: Bool = false
    @State private var headings: [ToCEntry] = []
    @State private var tocScrollTarget: String?
    @AppStorage("selectedTheme") private var selectedThemeName: String = "Auto"

    /// Resolved theme from user selection + system color scheme
    private var theme: MarkdownTheme {
        let name = ThemeName(rawValue: selectedThemeName) ?? .auto
        return MarkdownTheme.theme(named: name, colorScheme: colorScheme)
    }

    private struct DocumentIdentity: Equatable {
        let text: String
        let colorScheme: ColorScheme
        let themeName: String
    }

    var body: some View {
        HStack(spacing: 0) {
            // Table of Contents sidebar
            if isToCVisible && !headings.isEmpty {
                TableOfContentsView(headings: headings) { targetId in
                    tocScrollTarget = targetId
                }
                .frame(width: 220)
                Divider()
            }

            // Main content
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    // Search bar at top
                    if isSearchVisible {
                        SearchBar(
                            searchText: $searchText,
                            isVisible: $isSearchVisible,
                            matchCount: matchBlockIds.count,
                            currentMatch: currentMatchIndex,
                            onNext: { navigateMatch(forward: true) },
                            onPrevious: { navigateMatch(forward: false) }
                        )
                    }

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(cachedBlocks) { block in
                                    blockView(for: block)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 24)
                        }
                        .onChange(of: scrollTrigger) { _ in
                            scrollToMatch(proxy: proxy, index: currentMatchIndex)
                        }
                        .onChange(of: tocScrollTarget) { target in
                            guard let target = target else { return }
                            tocScrollTarget = nil
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(target, anchor: .top)
                            }
                        }
                    }
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
        }
        .background(theme.backgroundColor)
        .focusedSceneValue(\.documentText, document.text)
        .focusedSceneValue(\.searchAction, { toggleSearch() })
        .focusedSceneValue(\.toggleToCAction, { withAnimation(.easeInOut(duration: 0.2)) { isToCVisible.toggle() } })
        .frame(minWidth: 400, minHeight: 300)
        .task(id: DocumentIdentity(text: document.text, colorScheme: colorScheme, themeName: selectedThemeName)) {
            let text = document.text
            let currentTheme = theme
            let blocks = await Task.detached(priority: .userInitiated) {
                MarkdownBlockParser(theme: currentTheme).parse(text)
            }.value
            cachedBlocks = blocks
            headings = blocks.compactMap { block in
                if case .heading(_, let level, let title) = block {
                    return ToCEntry(id: block.id, level: level, title: title)
                }
                return nil
            }
        }
        .onChange(of: searchText) { newValue in
            updateMatchResults(for: newValue)
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags.contains(.command) && event.charactersIgnoringModifiers == "f" {
                    toggleSearch()
                    return nil
                }
                if flags.contains(.command) && flags.contains(.shift) && event.charactersIgnoringModifiers == "t" {
                    withAnimation(.easeInOut(duration: 0.2)) { isToCVisible.toggle() }
                    return nil
                }
                if flags.contains(.command) && event.charactersIgnoringModifiers == "g" {
                    if isSearchVisible {
                        if flags.contains(.shift) {
                            navigateMatch(forward: false)
                        } else {
                            navigateMatch(forward: true)
                        }
                        return nil
                    }
                }
                if event.keyCode == 53 && isSearchVisible {
                    isSearchVisible = false
                    searchText = ""
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    // MARK: - Block Rendering

    @ViewBuilder
    private func blockView(for block: MarkdownBlock) -> some View {
        let view = Group {
            switch block {
            case .text(_, let attributedString):
                if searchText.isEmpty {
                    Text(attributedString)
                        .textSelection(.enabled)
                } else {
                    Text(highlightSearchInText(attributedString))
                        .textSelection(.enabled)
                }

            case .table(_, let headers, let rows, let alignments):
                TableBlockView(headers: headers, rows: rows, alignments: alignments, theme: theme)
                    .padding(.vertical, 8)

            case .codeBlock(_, let code, let language):
                CodeBlockView(code: code, language: language, theme: theme)
                    .padding(.vertical, 4)

            case .image(_, let url, let alt):
                ImageBlockView(url: url, alt: alt, theme: theme, documentURL: documentURL)
                    .padding(.vertical, 8)

            case .blockquote(_, let content, let level):
                BlockquoteView(content: content, level: level, theme: theme)
                    .padding(.vertical, 4)

            case .heading(_, let level, let title):
                Text(MarkdownRenderer(theme: theme).renderHeader(title, level: level))
                    .textSelection(.enabled)
            }
        }

        view.id(block.id)
    }

    // MARK: - Search Helpers

    private func toggleSearch() {
        isSearchVisible.toggle()
        if !isSearchVisible { searchText = "" }
    }

    private func scrollToMatch(proxy: ScrollViewProxy, index: Int) {
        guard !matchBlockIds.isEmpty, index >= 0, index < matchBlockIds.count else { return }
        let targetId = matchBlockIds[index]
        // Small delay to ensure layout is stable after .id() registration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(targetId, anchor: .top)
            }
        }
    }

    private func navigateMatch(forward: Bool) {
        guard !matchBlockIds.isEmpty else { return }
        if forward {
            currentMatchIndex = (currentMatchIndex + 1) % matchBlockIds.count
        } else {
            currentMatchIndex = (currentMatchIndex - 1 + matchBlockIds.count) % matchBlockIds.count
        }
        scrollTrigger += 1
    }

    private func updateMatchResults(for term: String) {
        guard !term.isEmpty else {
            matchBlockIds = []
            currentMatchIndex = 0
            return
        }

        let searchLower = term.lowercased()
        var matches: [String] = []

        for block in cachedBlocks {
            let blockText: String
            switch block {
            case .text(_, let attr):
                blockText = String(attr.characters)
            case .table(_, let headers, let rows, _):
                blockText = (headers + rows.flatMap { $0 }).joined(separator: " ")
            case .codeBlock(_, let code, _):
                blockText = code
            case .blockquote(_, let content, _):
                blockText = content
            case .image(_, _, let alt):
                blockText = alt
            case .heading(_, _, let title):
                blockText = title
            }

            if blockText.lowercased().contains(searchLower) {
                matches.append(block.id)
            }
        }

        matchBlockIds = matches
        currentMatchIndex = 0
        if !matches.isEmpty {
            scrollTrigger += 1
        }
    }

    private func highlightSearchInText(_ attributed: AttributedString) -> AttributedString {
        guard !searchText.isEmpty else { return attributed }
        var result = attributed
        let plainText = String(result.characters)
        let textLower = plainText.lowercased()
        let searchLower = searchText.lowercased()

        // Build a mapping from String indices to AttributedString indices
        var stringToAttr: [String.Index: AttributedString.Index] = [:]
        var sIdx = plainText.startIndex
        var aIdx = result.startIndex
        while sIdx < plainText.endIndex && aIdx < result.endIndex {
            stringToAttr[sIdx] = aIdx
            sIdx = plainText.index(after: sIdx)
            aIdx = result.characters.index(after: aIdx)
        }
        stringToAttr[plainText.endIndex] = result.endIndex

        var searchStart = textLower.startIndex
        while let range = textLower.range(of: searchLower, range: searchStart..<textLower.endIndex) {
            if let attrLower = stringToAttr[range.lowerBound],
               let attrUpper = stringToAttr[range.upperBound] {
                result[attrLower..<attrUpper].backgroundColor = Color.yellow.opacity(0.6)
            }
            searchStart = range.upperBound
        }
        return result
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
        .focusable(false)
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
                NSWorkspace.shared.open(AppURLs.website)
            } label: {
                Label("Visit qmd.app", systemImage: "globe")
            }
            Divider()
            Button {
                NSWorkspace.shared.open(AppURLs.buyMeCoffee)
            } label: {
                Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
            }
            Button {
                NSWorkspace.shared.open(AppURLs.kofi)
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
        .menuStyle(.button)
        .opacity(isHovered ? 1.0 : 0.5)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Support QuickMD development")
    }
}
#endif

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

    ## Table Example

    | Feature | Status | Notes |
    |:--------|:------:|------:|
    | Headers | Done | Left |
    | Tables  | Done | Center |
    | Align   | Done | Right |

    ## Code with Highlighting

    ```swift
    func greet(_ name: String) -> String {
        let message = "Hello, \\(name)!"
        return message // Returns greeting
    }
    ```

    ![SwiftUI Logo](https://developer.apple.com/assets/elements/icons/swiftui/swiftui-96x96_2x.png)

    [Visit Apple](https://apple.com)
    """), documentURL: nil)
}
