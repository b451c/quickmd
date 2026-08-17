import SwiftUI
#if DEBUG
import os

// MARK: - Debug instrumentation (DEBUG builds only — stripped from Release)
//
// Console.app filter: subsystem == "pl.falami.studio.QuickMD"
// Or terminal:
//   log stream --predicate 'subsystem == "pl.falami.studio.QuickMD"' --level debug
private let viewLog = Logger(subsystem: "pl.falami.studio.QuickMD", category: "MarkdownView")
private let viewSignpost = OSSignposter(subsystem: "pl.falami.studio.QuickMD", category: "MarkdownView")
#endif

// Search highlighting helpers + TextBlockMeta/ParsedDocument live in
// DocumentSearch.swift; section copy logic lives in SectionExtractor.swift.

// MARK: - Main View

/// Main Markdown document view
/// Renders parsed markdown blocks in a scrollable container with support button
struct MarkdownView: View {
    let document: MarkdownDocument
    let documentURL: URL?
    @Environment(\.colorScheme) private var colorScheme
    /// The text currently displayed. Starts as the document's content and is
    /// refreshed from disk by FileWatcher whenever the file changes (the
    /// auto-reload half of the edit-in-your-editor roundtrip).
    @State private var currentText: String
    /// Per-document file watcher (created in onAppear, torn down in onDisappear).
    @State private var fileWatcher: FileWatcher?
    /// The watched file disappeared from its path (moved/deleted).
    @State private var fileMissing = false
    @State private var cachedBlocks: [MarkdownBlock] = []
    /// Incremented on every successful parse. Text blocks use it to invalidate
    /// their NSAttributedString caches — a font-size-only change leaves the
    /// characters identical, so nothing cheaper detects it reliably.
    @State private var contentVersion: Int = 0
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
    /// Transient bottom toast ("Copied!", "Opened in …"). Nil = hidden.
    @State private var toastText: String?
    /// Pre-computed focused block ID — updated only in navigateMatch/updateMatchResults
    @State private var focusedBlockId: String? = nil
    /// Pre-computed focused occurrence within the block — updated only in navigateMatch/updateMatchResults
    @State private var focusedOccInBlock: Int? = nil
    /// Last measured height per block id — lets lazily re-created NSTextView
    /// blocks start at their real height instead of a placeholder (no scroll jumps)
    @State private var heightCache = BlockHeightCache()
    /// Debounce so that rapid typing in the search bar coalesces into a single recompute
    @State private var searchDebounce: DispatchWorkItem?
    /// Monotonic token so stale background search results are dropped (the user
    /// may have typed again while a previous computation was still running).
    @State private var searchGeneration: Int = 0
    @AppStorage("selectedTheme") private var selectedThemeName: String = "Auto"
    /// Settings → Fonts. "" = system. Merged into the theme below (a custom
    /// theme's own families win) and part of `DocumentIdentity`, because font
    /// families are baked into the AttributedStrings at parse time.
    @AppStorage(DocumentFonts.bodyDefaultsKey) private var bodyFontFamily: String = ""
    @AppStorage(DocumentFonts.codeDefaultsKey) private var codeFontFamily: String = ""
    /// ⌘+ / ⌘- / ⌘0 zoom. Deliberately @State, not @AppStorage: zoom belongs to
    /// this window only and every document starts back at 100%.
    /// This is the *requested* scale — it drives the re-parse.
    @State private var fontScale: Double = 1.0
    /// The scale `cachedBlocks` was actually parsed with. Views render from
    /// this, never from `fontScale`, so headings (rendered synchronously in
    /// body) can't resize a frame ahead of body text (which waits for the
    /// background parse). Updated in the same transaction as `cachedBlocks`,
    /// so the whole document changes size in one step.
    @State private var renderedFontScale: Double = 1.0

    init(document: MarkdownDocument, documentURL: URL?) {
        self.document = document
        self.documentURL = documentURL
        _currentText = State(initialValue: document.text)
    }

    /// Documents up to this size render in an eager `VStack`; larger ones in
    /// `LazyVStack`.
    ///
    /// Why not always lazy: LazyVStack sizes the rows it has not placed by
    /// extrapolating from the ones it has. Markdown rows range from a 17-pt
    /// paragraph to a 500-pt code block, so as rows are placed and unplaced
    /// during scrolling the estimate for the rest swings by hundreds of points,
    /// every visible row shifts, the visible set changes, the estimate swings
    /// again — and on macOS 15 that settles into a permanent 100 % main-thread
    /// layout loop (wheel-scroll up and down on demo.md: 4 of 5 attempts;
    /// eager VStack: 0 of 5). With every row placed there is nothing to
    /// estimate. See constraints.md.
    ///
    /// Why not always eager: creating every NSTextView up front costs main-
    /// thread time proportional to the text — no measurable stall up to this
    /// limit (190 KB / 2 000 dense link lines) and ~1 s for the 11 700-line
    /// #10 repro, which therefore stays on the lazy path exactly as it shipped
    /// in 1.7.0.
    static let eagerLayoutByteLimit = 256 * 1024

    /// Set with each parse from the document size (see `eagerLayoutByteLimit`).
    @State private var useEagerLayout = true

    /// Resolved theme from user selection + system color scheme + Settings fonts
    private var theme: MarkdownTheme {
        MarkdownTheme.theme(named: selectedThemeName, colorScheme: colorScheme)
            .resolvingFonts(defaults: DocumentFonts(body: bodyFontFamily, code: codeFontFamily))
    }

    private struct DocumentIdentity: Equatable {
        let text: String
        let colorScheme: ColorScheme
        let themeName: String
        let fonts: DocumentFonts
        let fontScale: Double
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
                    if let section = SectionExtractor.extractSection(from: currentText, entry: entry, headings: headings) {
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
                        // Eager VStack for documents up to `eagerLayoutByteLimit`,
                        // LazyVStack above it — see `useEagerLayout`. Both stacks
                        // host the same block views: text, headings, blockquotes
                        // and code render through NSTextView, so neither stack
                        // has the SwiftUI text-selection overlay that froze the
                        // Sprint 4.2 attempt (constraints.md, bug B).
                        Group {
                            if useEagerLayout {
                                VStack(alignment: .leading, spacing: 8) { blockList }
                            } else {
                                LazyVStack(alignment: .leading, spacing: 8) { blockList }
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
                HStack(spacing: 8) {
                    if documentURL != nil {
                        EditInEditorButton(theme: theme) {
                            openInExternalEditor()
                        }
                    }
                    CopySourceButton(theme: theme) {
                        copyToClipboard(currentText)
                    }
                }
                .chromeHoverCluster()
                .padding(.top, isSearchVisible ? 44 : 8)
                .padding(.trailing, 24)
            }
            .overlay(alignment: .top) {
                if fileMissing {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text("File no longer exists at \(documentURL?.path ?? "this location")")
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Close Tab") {
                            NSApp.keyWindow?.close()
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                    .padding(.top, isSearchVisible ? 44 : 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
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
                if let toastText {
                    Text(toastText)
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
        .focusedSceneValue(\.documentText, currentText)
        .focusedSceneValue(\.searchAction, { toggleSearch() })
        .focusedSceneValue(\.toggleToCAction, { withAnimation(.easeInOut(duration: 0.2)) { isToCVisible.toggle() } })
        .focusedSceneValue(\.copyDocumentAction, { copyToClipboard(currentText) })
        .focusedSceneValue(\.openInExternalEditorAction, { openInExternalEditor() })
        .focusedSceneValue(\.toggleDocumentListAction, { withAnimation(.easeInOut(duration: 0.2)) { isDocumentListVisible.toggle() } })
        .focusedSceneValue(\.zoomAction, { zoom in fontScale = zoom.applied(to: fontScale) })
        .environment(\.openURL, OpenURLAction { url in
            handleLinkActivation(url)
            return .handled
        })
        .frame(minWidth: 400, minHeight: 300)
        .task(id: DocumentIdentity(text: currentText, colorScheme: colorScheme, themeName: selectedThemeName,
                                   fonts: DocumentFonts(body: bodyFontFamily, code: codeFontFamily),
                                   fontScale: fontScale)) {
            let text = currentText
            let currentTheme = theme
            isParsing = true
            let scale = CGFloat(fontScale)
            let parsed: ParsedDocument = await Task.detached(priority: .userInitiated) {
                let blocks = MarkdownBlockParser(theme: currentTheme, fontScale: scale).parse(text)
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
            // SwiftUI cancels this task when the id changes (new text, theme or
            // zoom) but the detached parse above keeps running to completion —
            // without this guard a superseded parse can land last and win, which
            // is what made repeated ⌘+/⌘- jump to arbitrary sizes.
            guard !Task.isCancelled else { return }
            heightCache.removeAll()  // new content/theme — stale heights would mis-seed diagrams
            useEagerLayout = text.utf8.count <= Self.eagerLayoutByteLimit
            cachedBlocks = parsed.blocks
            renderedFontScale = Double(scale)
            contentVersion += 1
            textBlockMeta = parsed.textMeta
            headings = parsed.blocks.compactMap { block in
                if case .heading(let level, let title, let sourceLine) = block.content {
                    return ToCEntry(id: block.id, level: level, title: title, sourceLine: sourceLine)
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
                // Auto-reload: watch this document's file and refresh on save.
                // Silent by default — pro users expect the viewer to be current.
                let watcher = FileWatcher()
                watcher.onChange = { reloadFromDisk() }
                watcher.onFileMissing = {
                    withAnimation(.easeInOut(duration: 0.2)) { fileMissing = true }
                }
                watcher.start(watching: url)
                fileWatcher = watcher
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
            fileWatcher?.stop()
            fileWatcher = nil
        }
    }

    // MARK: - Auto-Reload & External Editor

    /// Re-reads the watched file and swaps the displayed text if it changed.
    /// Same decode + line-ending normalization as the initial document load.
    private func reloadFromDisk() {
        guard let url = documentURL else { return }
        guard let data = try? Data(contentsOf: url),
              let decoded = MarkdownDocument.decode(data) else { return }
        let text = MarkdownDocument.normalizeLineEndings(decoded)
        if text != currentText {
            currentText = text
        }
        if fileMissing {
            withAnimation(.easeInOut(duration: 0.2)) { fileMissing = false }
        }
    }

    /// ⌘E — hand the document off to the user's configured editor.
    private func openInExternalEditor() {
        guard let url = documentURL else { return }
        if let appName = ExternalEditorManager.openInEditor(url) {
            showToast("Opened in \(appName)")
        }
    }

    // MARK: - Block Rendering

    /// The document's blocks, shared by the eager and lazy stacks.
    private var blockList: some View {
        ForEach(cachedBlocks) { block in
            blockView(for: block)
        }
    }

    @ViewBuilder
    private func blockView(for block: MarkdownBlock) -> some View {
        #if DEBUG
        let _ = viewSignpost.emitEvent("blockView", "id=\(block.id, privacy: .public)")
        #endif
        let focusedOcc = (block.id == focusedBlockId) ? focusedOccInBlock : nil
        let scale = CGFloat(renderedFontScale)
        let view = Group {
            switch block.content {
            case .text(let attributedString):
                // hasInlineMath is precomputed at parse time (see textBlockMeta).
                // TextBlockView handles search highlighting (temporaryAttributes)
                // and inline math (NSTextAttachment) natively.
                TextBlockView(
                    blockId: block.id,
                    attributed: attributedString,
                    hasInlineMath: textBlockMeta[block.id]?.hasInlineMath ?? false,
                    theme: theme,
                    fontScale: scale,
                    contentVersion: contentVersion,
                    searchTerm: searchText,
                    focusedOccurrence: focusedOcc,
                    onLink: { handleLinkActivation($0) }
                )

            case .table(let headers, let rows, let alignments):
                TableBlockView(headers: headers, rows: rows, alignments: alignments, theme: theme,
                               fontScale: scale, searchText: searchText, focusedOccurrence: focusedOcc)
                    .padding(.vertical, 8)

            case .codeBlock(let code, let language):
                CodeBlockView(code: code, language: language, theme: theme,
                              fontScale: scale, searchText: searchText, focusedOccurrence: focusedOcc)
                    .padding(.vertical, 4)

            case .image(let url, let alt):
                ImageBlockView(url: url, alt: alt, theme: theme, documentURL: documentURL)
                    .padding(.vertical, 8)

            case .blockquote(let content, let level):
                BlockquoteView(blockId: block.id, content: content, level: level, theme: theme,
                               fontScale: scale, contentVersion: contentVersion,
                               searchText: searchText, focusedOccurrence: focusedOcc,
                               onLink: { handleLinkActivation($0) })

            case .alert(let kind, let content):
                AlertBlockView(blockId: block.id, kind: kind, content: content, theme: theme,
                               fontScale: scale, contentVersion: contentVersion,
                               searchText: searchText, focusedOccurrence: focusedOcc,
                               onLink: { handleLinkActivation($0) })
                    .padding(.vertical, 4)
                    .padding(.vertical, 4)

            case .heading(let level, let title, _):
                HeadingBlockView(
                    id: block.id,
                    level: level,
                    title: title,
                    theme: theme,
                    fontScale: scale,
                    searchText: searchText,
                    focusedOccurrence: focusedOcc,
                    onCopySection: {
                        if let entry = headings.first(where: { $0.id == block.id }),
                           let section = SectionExtractor.extractSection(from: currentText, entry: entry, headings: headings) {
                            copyToClipboard(section)
                        }
                    }
                )

            case .mathBlock(let latex):
                MathBlockView(latex: latex, theme: theme, fontScale: scale)
                    .padding(.vertical, 4)

            case .mermaidDiagram(let source):
                MermaidBlockView(blockId: block.id, source: source, theme: theme,
                                 heightCache: heightCache)
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
        showToast("Copied!")
    }

    private func showToast(_ message: String) {
        withAnimation(.easeIn(duration: 0.15)) { toastText = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.3)) {
                if toastText == message { toastText = nil }
            }
        }
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
        searchGeneration += 1
        guard !term.isEmpty else {
            matchBlockIds = []
            currentMatchIndex = 0
            focusedBlockId = nil
            focusedOccInBlock = nil
            return
        }

        // Match computation walks every block — too heavy for the main thread
        // on 10K-line docs. Run it detached and drop the result if the term
        // changed meanwhile. (Per-block highlight painting happens in the
        // NSTextView wrappers via temporary attributes.)
        let generation = searchGeneration
        let blocks = cachedBlocks
        Task.detached(priority: .userInitiated) {
            let results = DocumentSearch.computeMatches(in: blocks, term: term)
            await MainActor.run {
                guard generation == searchGeneration else { return }
                matchBlockIds = results.matchBlockIds
                currentMatchIndex = 0
                updateFocusState()
                if !results.matchBlockIds.isEmpty {
                    scrollTrigger += 1
                }
            }
        }
    }

    private func handleLinkActivation(_ url: URL) {
        // Web and mail links open normally
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            NSWorkspace.shared.open(url)
            return
        case nil, "file":
            break  // resolved against the document directory below
        case .some(let scheme):
            // Any other scheme (shortcuts:, ssh:, vnc:, …) launches whatever app
            // registered it. Documents are untrusted input — confirm before
            // handing control to another application.
            let alert = NSAlert()
            alert.messageText = "Open \u{201C}\(scheme):\u{201D} link?"
            alert.informativeText = "This link opens another application:\n\(url.absoluteString)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(url)
            }
            return
        }

        // If it's a relative path or lacks a scheme, resolve it against the current document's directory
        var finalURL = url
        if let documentURL = documentURL {
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
