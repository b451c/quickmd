import SwiftUI
import os

// MARK: - Debug instrumentation
//
// Console.app filter: subsystem == "pl.falami.studio.QuickMD"
// Or terminal:
//   log stream --predicate 'subsystem == "pl.falami.studio.QuickMD"' --level debug
private let viewLog = Logger(subsystem: "pl.falami.studio.QuickMD", category: "MarkdownView")
private let viewSignpost = OSSignposter(subsystem: "pl.falami.studio.QuickMD", category: "MarkdownView")

// MARK: - Shared Search Highlighting

/// Applies search term highlighting to an AttributedString.
/// `focusedOccurrence` = which occurrence (0-based) in this text gets orange.
/// `nil` means no occurrence is focused — all matches get yellow.
func searchHighlight(_ attributed: AttributedString, term: String, focusedOccurrence: Int? = nil) -> AttributedString {
    guard !term.isEmpty else { return attributed }
    let plainText = String(attributed.characters)
    let textLower = plainText.lowercased()
    let searchLower = term.lowercased()

    // Find all match ranges in the lowercased text
    var matchRanges: [(lowerBound: String.Index, upperBound: String.Index)] = []
    var searchStart = textLower.startIndex
    while let range = textLower.range(of: searchLower, range: searchStart..<textLower.endIndex) {
        matchRanges.append((range.lowerBound, range.upperBound))
        searchStart = range.upperBound
    }
    guard !matchRanges.isEmpty else { return attributed }

    // Convert String ranges → AttributedString ranges via single-pass parallel iteration
    var result = attributed
    var sIdx = plainText.startIndex
    var aIdx = result.startIndex
    for (matchIndex, matchRange) in matchRanges.enumerated() {
        while sIdx < matchRange.lowerBound {
            sIdx = plainText.index(after: sIdx)
            aIdx = result.characters.index(after: aIdx)
        }
        let attrStart = aIdx
        while sIdx < matchRange.upperBound {
            sIdx = plainText.index(after: sIdx)
            aIdx = result.characters.index(after: aIdx)
        }
        let color = (focusedOccurrence == matchIndex) ? Color.orange : Color.yellow.opacity(0.55)
        result[attrStart..<aIdx].backgroundColor = color
    }
    return result
}

/// Count occurrences of `term` in `text` (case-insensitive)
func countOccurrences(in text: String, of term: String) -> Int {
    guard !term.isEmpty else { return 0 }
    let textLower = text.lowercased()
    let termLower = term.lowercased()
    var count = 0
    var start = textLower.startIndex
    while let range = textLower.range(of: termLower, range: start..<textLower.endIndex) {
        count += 1
        start = range.upperBound
    }
    return count
}

// MARK: - Parser Output

/// Per-text-block precomputed metadata. Built on the parser's background thread so
/// the main thread doesn't have to do `String(attr.characters)` + regex per render.
struct TextBlockMeta: Sendable {
    let plain: String
    let hasInlineMath: Bool
}

/// Bundle of parser results so the background-detached parse returns one value.
struct ParsedDocument: Sendable {
    let blocks: [MarkdownBlock]
    let textMeta: [String: TextBlockMeta]
}

// MARK: - Main View

/// Main Markdown document view
/// Renders parsed markdown blocks in a scrollable container with support button
struct MarkdownView: View {
    let document: MarkdownDocument
    let documentURL: URL?
    @Environment(\.colorScheme) private var colorScheme
    @State private var cachedBlocks: [MarkdownBlock] = []
    /// Per-text-block precomputed plain string + inline-math flag. Built once at parse
    /// time so per-render `blockView(_:)` doesn't repeatedly call
    /// `String(attributedString.characters)` and an `NSRegularExpression` on every body
    /// re-evaluation (window resize, focus return, theme switch were thrashing this).
    @State private var textBlockMeta: [String: TextBlockMeta] = [:]
    @State private var isParsing: Bool = false
    @State private var searchText: String = ""
    @State private var isSearchVisible: Bool = false
    @State private var currentMatchIndex: Int = 0
    @State private var matchBlockIds: [String] = []
    @State private var scrollTrigger: Int = 0
    @State private var keyMonitor: Any?
    @AppStorage("isToCVisible") private var isToCVisible: Bool = false
    @AppStorage("isDocumentListVisible") private var isDocumentListVisible: Bool = false
    @AppStorage("documentListWidth") private var documentListWidth: Double = 220
    @State private var headings: [ToCEntry] = []
    @State private var tocScrollTarget: String?
    @State private var showCopiedToast: Bool = false
    /// Pre-computed focused block ID — updated only in navigateMatch/updateMatchResults
    @State private var focusedBlockId: String? = nil
    /// Pre-computed focused occurrence within the block — updated only in navigateMatch/updateMatchResults
    @State private var focusedOccInBlock: Int? = nil
    /// Cache of yellow-highlighted text blocks (keyed by block ID), rebuilt when searchText changes
    @State private var baseHighlightCache: [String: AttributedString] = [:]
    /// Debounce so that rapid typing in the search bar coalesces into a single recompute
    @State private var searchDebounce: DispatchWorkItem?
    @AppStorage("selectedTheme") private var selectedThemeName: String = "Auto"

    /// Resolved theme from user selection + system color scheme
    private var theme: MarkdownTheme {
        MarkdownTheme.theme(named: selectedThemeName, colorScheme: colorScheme)
    }

    private struct DocumentIdentity: Equatable {
        let text: String
        let colorScheme: ColorScheme
        let themeName: String
    }

    var body: some View {
        HStack(spacing: 0) {
            // Recent documents sidebar (leftmost)
            if isDocumentListVisible {
                RecentDocumentsSidebar(theme: theme, currentURL: documentURL)
                    .frame(width: documentListWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                SidebarResizeHandle(width: $documentListWidth, minWidth: 160, maxWidth: 500)
            }

            // Table of Contents sidebar
            if isToCVisible && !headings.isEmpty {
                TableOfContentsView(headings: headings, onSelect: { targetId in
                    tocScrollTarget = targetId
                }, onCopy: { entry in
                    if let section = extractSection(from: document.text, entry: entry) {
                        copyToClipboard(section)
                    }
                })
                .frame(width: 220)
                Divider()
            }

            // Main content — overlays use .overlay() to avoid blocking scroll events
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
                        // VStack (eager) — NOT LazyVStack.
                        // We tried LazyVStack in Sprint 4.2 (after refactoring
                        // CodeBlockView to NSTextView, which fixed the original
                        // 890MB box-drawing-Unicode freeze). It surfaced a SECOND
                        // SwiftUI bug: rapid scroll instantiates/tears down
                        // SelectionOverlay (the NSTextField-backed shim that
                        // implements Text(...).textSelection(.enabled)) for every
                        // visible block; setFont/invalidateEffectiveFont cascades
                        // saturate the main thread. Sample showed 99% CPU on
                        // SelectionOverlay.updateNSView during scroll.
                        // VStack keeps all views alive — no lifecycle churn.
                        // Trade-off: opening huge docs (>5K blocks) is slower —
                        // tracked as Issue #10, target v1.6.0 (full NSTextView
                        // migration for text blocks too).
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(cachedBlocks) { block in
                                blockView(for: block)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 24)
                    }
                    .onChange(of: scrollTrigger) { _ in
                        scrollToCurrentMatch(proxy: proxy)
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
            .overlay(alignment: .topLeading) {
                // Reveal sidebar when hidden (sits at top-leading; out of the way of content)
                if !isDocumentListVisible {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isDocumentListVisible = true
                        }
                    } label: {
                        Image(systemName: "sidebar.leading")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(theme.codeBackgroundColor.opacity(0.6))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .opacity(0.5)
                    .help("Show recent documents (⇧⌘D)")
                    .padding(.top, isSearchVisible ? 44 : 8)
                    .padding(.leading, 8)
                }
            }
            .overlay(alignment: .topTrailing) {
                CopySourceButton(theme: theme) {
                    copyToClipboard(document.text)
                }
                .padding(.top, isSearchVisible ? 44 : 8)
                .padding(.trailing, 24)
            }
            .overlay(alignment: .bottomTrailing) {
                Group {
                    #if APPSTORE
                    TipJarButton(theme: theme)
                    #else
                    SupportButton(theme: theme)
                    #endif
                }
                .padding(16)
            }
            .overlay(alignment: .center) {
                if isParsing && cachedBlocks.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Parsing…")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(theme.codeBackgroundColor.opacity(0.85))
                    .clipShape(Capsule())
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if showCopiedToast {
                    Text("Copied!")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.75))
                        .clipShape(Capsule())
                        .padding(.bottom, 16)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .background(theme.backgroundColor)
        .background(WindowConfigurator { window in
            // Make every QuickMD document window prefer to join existing windows
            // as tabs (rather than as standalone windows), regardless of the
            // system-wide "Prefer tabs" preference. All windows share one
            // tabbingIdentifier so AppKit groups them in a single tabbed window.
            window.tabbingMode = .preferred
            window.tabbingIdentifier = "pl.falami.studio.QuickMD.Document"
        })
        .focusedSceneValue(\.documentText, document.text)
        .focusedSceneValue(\.searchAction, { toggleSearch() })
        .focusedSceneValue(\.toggleToCAction, { withAnimation(.easeInOut(duration: 0.2)) { isToCVisible.toggle() } })
        .focusedSceneValue(\.copyDocumentAction, { copyToClipboard(document.text) })
        .focusedSceneValue(\.toggleDocumentListAction, { withAnimation(.easeInOut(duration: 0.2)) { isDocumentListVisible.toggle() } })
        .environment(\.openURL, OpenURLAction { url in
            handleLinkActivation(url)
            return .handled
        })
        .frame(minWidth: 400, minHeight: 300)
        .task(id: DocumentIdentity(text: document.text, colorScheme: colorScheme, themeName: selectedThemeName)) {
            let text = document.text
            let currentTheme = theme
            isParsing = true
            let parsed: ParsedDocument = await Task.detached(priority: .userInitiated) {
                let blocks = MarkdownBlockParser(theme: currentTheme).parse(text)
                // Pre-compute per-text-block metadata on the background thread so the
                // main thread never has to do it later.
                var meta: [String: TextBlockMeta] = [:]
                let mathRegex = try? NSRegularExpression(pattern: #"\$[^\s$].*?\$"#)
                for block in blocks {
                    if case .text(let attr) = block.content {
                        let plain = String(attr.characters)
                        var hasMath = false
                        if plain.contains("$"), let regex = mathRegex {
                            let range = NSRange(plain.startIndex..., in: plain)
                            hasMath = regex.firstMatch(in: plain, range: range) != nil
                        }
                        meta[block.id] = TextBlockMeta(plain: plain, hasInlineMath: hasMath)
                    }
                }
                return ParsedDocument(blocks: blocks, textMeta: meta)
            }.value
            cachedBlocks = parsed.blocks
            textBlockMeta = parsed.textMeta
            headings = parsed.blocks.compactMap { block in
                if case .heading(let level, let title) = block.content {
                    return ToCEntry(id: block.id, level: level, title: title)
                }
                return nil
            }
            isParsing = false
        }
        .onChange(of: searchText) { newValue in
            searchDebounce?.cancel()
            // Empty search is cheap and the user expects instant clear
            if newValue.isEmpty {
                updateMatchResults(for: newValue)
                return
            }
            let work = DispatchWorkItem { updateMatchResults(for: newValue) }
            searchDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        .onAppear {
            if let url = documentURL {
                RecentDocumentsStore.shared.register(url)
            }
            // NSEvent.addLocalMonitorForEvents is GLOBAL for the app process —
            // every visible MarkdownView (one per open tab) registers its own
            // monitor, and ALL of them fire on every keypress. So we can't
            // toggle per-view state here for shortcuts that have menu equivalents
            // (⌘F, ⌘⇧T, ⌘⇧D, ⌘⇧C) — those are routed through `@FocusedValue`
            // in QuickMDApp.swift, which correctly targets the active tab.
            //
            // Only handle the search-bar-specific keys here (⌘G next match,
            // ⇧⌘G previous, Escape close). These already gate on the per-view
            // `isSearchVisible` flag, so inactive tabs return the event
            // unchanged and the active tab consumes it.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

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
        let _ = viewSignpost.emitEvent("blockView", "id=\(block.id, privacy: .public)")
        let focusedOcc = (block.id == focusedBlockId) ? focusedOccInBlock : nil
        let view = Group {
            switch block.content {
            case .text(let attributedString):
                // hasInlineMath is precomputed at parse time (see textBlockMeta);
                // avoids per-render String(attr.characters) + regex on every body eval.
                let hasInlineMath = textBlockMeta[block.id]?.hasInlineMath ?? false
                if searchText.isEmpty && hasInlineMath {
                    InlineMathTextView(attributedString: attributedString, theme: theme)
                } else if searchText.isEmpty {
                    Text(attributedString)
                        .textSelection(.enabled)
                } else if focusedOcc != nil {
                    // Focused block — compute orange highlight for specific occurrence
                    Text(searchHighlight(attributedString, term: searchText, focusedOccurrence: focusedOcc))
                        .textSelection(.enabled)
                } else if let cached = baseHighlightCache[block.id] {
                    // Non-focused block — use pre-computed yellow highlights (no work per render)
                    Text(cached)
                        .textSelection(.enabled)
                } else {
                    Text(attributedString)
                        .textSelection(.enabled)
                }

            case .table(let headers, let rows, let alignments):
                TableBlockView(headers: headers, rows: rows, alignments: alignments, theme: theme,
                               searchText: searchText, focusedOccurrence: focusedOcc)
                    .padding(.vertical, 8)

            case .codeBlock(let code, let language):
                CodeBlockView(code: code, language: language, theme: theme,
                              searchText: searchText, focusedOccurrence: focusedOcc)
                    .padding(.vertical, 4)

            case .image(let url, let alt):
                ImageBlockView(url: url, alt: alt, theme: theme, documentURL: documentURL)
                    .padding(.vertical, 8)

            case .blockquote(let content, let level):
                BlockquoteView(content: content, level: level, theme: theme,
                               searchText: searchText, focusedOccurrence: focusedOcc)
                    .padding(.vertical, 4)

            case .heading(let level, let title):
                HeadingBlockView(
                    id: block.id,
                    level: level,
                    title: title,
                    theme: theme,
                    searchText: searchText,
                    focusedOccurrence: focusedOcc,
                    onCopySection: {
                        if let entry = headings.first(where: { $0.id == block.id }),
                           let section = extractSection(from: document.text, entry: entry) {
                            copyToClipboard(section)
                        }
                    }
                )

            case .mathBlock(let latex):
                MathBlockView(latex: latex, theme: theme)
                    .padding(.vertical, 4)

            case .mermaidDiagram(let source):
                MermaidBlockView(source: source, theme: theme)
                    .padding(.vertical, 4)
            }
        }

        view
            .id(block.id)
    }

    // MARK: - Search Helpers

    private func toggleSearch() {
        isSearchVisible.toggle()
        if !isSearchVisible { searchText = "" }
    }

    // MARK: - Clipboard Helpers

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.easeIn(duration: 0.15)) { showCopiedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.3)) { showCopiedToast = false }
        }
    }

    /// Extract a section from raw markdown: from the given heading to the next heading of same or higher level
    private func extractSection(from text: String, entry: ToCEntry) -> String? {
        guard let entryIndex = headings.firstIndex(where: { $0.id == entry.id }) else { return nil }

        let lines = text.components(separatedBy: "\n")
        var headingCount = 0
        var startLine: Int?
        let targetLevel = entry.level

        // Occurrence index: how many headings we've seen before this entry
        let targetOccurrence = entryIndex

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Detect ATX headings: # through ######
            if let match = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let hashes = trimmed[match].trimmingCharacters(in: .whitespaces)
                let level = hashes.count

                if let start = startLine {
                    // We're inside the target section — check if this heading ends it
                    if level <= targetLevel {
                        // Found a same-or-higher level heading — extract up to here
                        return trimTrailingBlankLines(Array(lines[start..<i]))
                    }
                } else if headingCount == targetOccurrence {
                    // Check level matches (it should, since we're tracking the same headings list)
                    if level == targetLevel {
                        startLine = i
                    }
                }

                headingCount += 1
                continue
            }

            // Detect setext headings: === (H1) or --- (H2), only if previous line is non-empty
            if i > 0 && !lines[i - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                if trimmed.allSatisfy({ $0 == "=" }) && trimmed.count >= 3 {
                    let level = 1
                    if let start = startLine, level <= targetLevel {
                        return trimTrailingBlankLines(Array(lines[start..<(i - 1)]))
                    } else if startLine == nil && headingCount == targetOccurrence && level == targetLevel {
                        startLine = i - 1
                    }
                    headingCount += 1
                } else if trimmed.allSatisfy({ $0 == "-" }) && trimmed.count >= 3 {
                    let level = 2
                    if let start = startLine, level <= targetLevel {
                        return trimTrailingBlankLines(Array(lines[start..<(i - 1)]))
                    } else if startLine == nil && headingCount == targetOccurrence && level == targetLevel {
                        startLine = i - 1
                    }
                    headingCount += 1
                }
            }
        }

        // If we started but never hit an ending heading, take everything to end of file
        if let start = startLine {
            let sectionLines = Array(lines[start...])
            return trimTrailingBlankLines(Array(sectionLines))
        }

        return nil
    }

    private func trimTrailingBlankLines(_ lines: [String]) -> String {
        var result = lines
        while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            result.removeLast()
        }
        return result.joined(separator: "\n")
    }

    private func scrollToCurrentMatch(proxy: ScrollViewProxy) {
        guard let targetId = focusedBlockId else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(targetId, anchor: .center)
            }
        }
    }

    /// Recompute focusedBlockId and focusedOccInBlock from currentMatchIndex
    private func updateFocusState() {
        guard !matchBlockIds.isEmpty, currentMatchIndex >= 0, currentMatchIndex < matchBlockIds.count else {
            focusedBlockId = nil
            focusedOccInBlock = nil
            return
        }
        let blockId = matchBlockIds[currentMatchIndex]
        var count = 0
        for i in 0..<currentMatchIndex {
            if matchBlockIds[i] == blockId { count += 1 }
        }
        focusedBlockId = blockId
        focusedOccInBlock = count
    }

    private func navigateMatch(forward: Bool) {
        guard !matchBlockIds.isEmpty else { return }
        let oldBlockId = focusedBlockId
        if forward {
            currentMatchIndex = (currentMatchIndex + 1) % matchBlockIds.count
        } else {
            currentMatchIndex = (currentMatchIndex - 1 + matchBlockIds.count) % matchBlockIds.count
        }
        updateFocusState()
        // Only scroll when moving to a different block
        if focusedBlockId != oldBlockId {
            scrollTrigger += 1
        }
    }

    private func updateMatchResults(for term: String) {
        guard !term.isEmpty else {
            matchBlockIds = []
            currentMatchIndex = 0
            focusedBlockId = nil
            focusedOccInBlock = nil
            baseHighlightCache = [:]
            return
        }

        let searchLower = term.lowercased()
        var matches: [String] = []
        var highlights: [String: AttributedString] = [:]

        for block in cachedBlocks {
            // Collect all text segments for this block (per-cell for tables, per-line for blockquotes)
            let segments: [String]
            switch block.content {
            case .text(let attr):
                segments = [String(attr.characters)]
                // Pre-compute yellow (base) highlight for text blocks
                let highlighted = searchHighlight(attr, term: term)
                highlights[block.id] = highlighted
            case .table(let headers, let rows, _):
                segments = headers + rows.flatMap { $0 }
            case .codeBlock(let code, _):
                segments = [code]
            case .blockquote(let content, _):
                segments = [content]
            case .image(_, let alt):
                segments = [alt]
            case .heading(_, let title):
                segments = [title]
            case .mathBlock(let latex):
                segments = [latex]
            case .mermaidDiagram(let source):
                segments = [source]
            }

            // Count individual occurrences across all segments
            for segment in segments {
                let textLower = segment.lowercased()
                var searchStart = textLower.startIndex
                while let range = textLower.range(of: searchLower, range: searchStart..<textLower.endIndex) {
                    matches.append(block.id)
                    searchStart = range.upperBound
                }
            }
        }

        baseHighlightCache = highlights
        matchBlockIds = matches
        currentMatchIndex = 0
        updateFocusState()
        if !matches.isEmpty {
            scrollTrigger += 1
        }
    }

    private func handleLinkActivation(_ url: URL) {
        // If it's a web link, open it normally
        if url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            return
        }
        
        // If it's a relative path or lacks a scheme, resolve it against the current document's directory
        var finalURL = url
        if url.scheme == nil || url.scheme == "file", let documentURL = documentURL {
            let documentDir = documentURL.deletingLastPathComponent()
            // If the URL has an absolute path but no scheme (rare in this context, but possible)
            if url.path.hasPrefix("/") {
                finalURL = URL(fileURLWithPath: url.path)
            } else {
                // It's a relative path, resolve it against the document's directory
                finalURL = documentDir.appendingPathComponent(url.path)
            }
        }
        
        // Open the resolved file URL
        let ext = finalURL.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" || ext == "mdown" || ext == "mkd" {
            // Force open with our own app
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([finalURL], withApplicationAt: Bundle.main.bundleURL, configuration: config)
        } else {
            // Open in the default application for that file type
            NSWorkspace.shared.open(finalURL)
        }
    }

}

// MARK: - Window Configurator

/// Bridges into AppKit to configure the host NSWindow once it's available.
/// Used to opt every document window into native macOS tabbing — we set the
/// shared `tabbingIdentifier` and, if another QuickMD doc window is already
/// visible, programmatically merge the new window as a tab.
///
/// We can't rely on AppKit's auto-tabbing (controlled by the system-wide
/// "Prefer tabs" pref) because we want consistent tab UX regardless of user
/// settings. `addTabbedWindow` is the explicit override.
private struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TabAwareView()
        view.onWindowAttached = { window in
            configure(window)
            mergeIntoExistingTabIfPossible(window: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private func mergeIntoExistingTabIfPossible(window newWindow: NSWindow) {
        // Find another visible QuickMD document window already on screen and
        // merge the new window into its tab group.
        guard let identifier = newWindow.tabbingIdentifier as String?,
              !identifier.isEmpty else { return }

        let candidates = NSApp.windows.filter { other in
            other !== newWindow
                && other.isVisible
                && other.tabbingIdentifier == newWindow.tabbingIdentifier
                && other.tabGroup !== newWindow.tabGroup  // not already grouped
        }
        guard let host = candidates.first else { return }
        host.addTabbedWindow(newWindow, ordered: .above)
        newWindow.makeKeyAndOrderFront(nil)
    }
}

/// NSView subclass that fires `onWindowAttached` exactly once, when the host
/// NSWindow becomes available via `viewDidMoveToWindow`. More reliable than
/// `DispatchQueue.main.async` polling.
private final class TabAwareView: NSView {
    var onWindowAttached: ((NSWindow) -> Void)?
    private var fired = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !fired, let window = self.window else { return }
        fired = true
        onWindowAttached?(window)
    }
}

// MARK: - Heading Block View (hover-to-copy section)

/// Heading with hover-to-reveal copy button that copies the section.
/// The copy icon is always in the layout (opacity-controlled) to avoid
/// view insertion/removal churn during fast scrolling in LazyVStack.
private struct HeadingBlockView: View {
    let id: String
    let level: Int
    let title: String
    let theme: MarkdownTheme
    let searchText: String
    let focusedOccurrence: Int?
    let onCopySection: () -> Void
    @State private var isHovered = false
    @State private var hideWorkItem: DispatchWorkItem?

    var body: some View {
        let headingAttr = MarkdownRenderer(theme: theme).renderHeader(title, level: level)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if searchText.isEmpty {
                Text(headingAttr)
                    .textSelection(.enabled)
            } else {
                Text(searchHighlight(headingAttr, term: searchText, focusedOccurrence: focusedOccurrence))
                    .textSelection(.enabled)
            }

            Button {
                onCopySection()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy section")
            .opacity(isHovered ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            hideWorkItem?.cancel()
            if hovering {
                isHovered = true
            } else {
                let work = DispatchWorkItem { isHovered = false }
                hideWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
            }
        }
    }
}

// MARK: - Copy Source Button

/// Subtle top-right button to copy the entire raw markdown
private struct CopySourceButton: View {
    let theme: MarkdownTheme
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                if isHovered {
                    Text("Copy source")
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
        .foregroundColor(.secondary)
        .opacity(isHovered ? 1.0 : 0.5)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Copy source")
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
