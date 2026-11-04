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
    @State private var graphicPreview: GraphicPreview?
    /// Bumped when the graphic preview or the search bar closes: the document
    /// list takes keyboard focus back (⌘C/⌘A/arrows) if nothing else has it.
    @State private var documentFocusRequest = 0
    @State private var keyMonitor: Any?
    /// The NSWindow hosting this view (set by `WindowConfigurator`); the key
    /// monitor uses it to ignore events addressed to other tabs' windows.
    @State private var hostWindow: NSWindow?
    @AppStorage("isToCVisible") private var isToCVisible: Bool = false
    @AppStorage("isDocumentListVisible") private var isDocumentListVisible: Bool = false
    @AppStorage("documentListWidth") private var documentListWidth: Double = 220
    @State private var headings: [ToCEntry] = []
    /// Transient bottom toast ("Copied 12 characters", "Opened in …"). Nil = hidden.
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
    /// What the background run that `searchGeneration` currently names was
    /// started for; nil when none is in flight. A re-parse that supersedes a
    /// typing run must keep that run's "focus the first match and scroll"
    /// landing — the reader's last action was typing, not the reload.
    @State private var searchInFlight: DocumentSearch.Trigger?
    @AppStorage("selectedTheme") private var selectedThemeName: String = "Auto"
    /// The system's light/dark choice, read by `SystemColorSchemeReader`
    /// (nil until the first report). Only used to hand a window that once had
    /// a light or dark theme back to the system — see `windowColorScheme`.
    @State private var systemColorScheme: ColorScheme?
    /// Set once this window has shown a light or dark (non-Auto) theme.
    @State private var windowSchemeWasForced = false
    /// Settings → Fonts. "" = system. Merged into the theme below (a custom
    /// theme's own families win) and part of `DocumentIdentity`, because font
    /// families are baked into the AttributedStrings at parse time.
    @AppStorage(DocumentFonts.bodyDefaultsKey) private var bodyFontFamily: String = ""
    @AppStorage(DocumentFonts.codeDefaultsKey) private var codeFontFamily: String = ""
    /// Settings ▸ Fonts ▸ Default zoom (#48), raw as stored; read it through
    /// `defaultZoom`, which normalizes whatever `defaults write` left there.
    @AppStorage(DefaultZoom.defaultsKey) private var defaultZoomSetting: Double = 1.0
    /// ⌘+ / ⌘- / ⌘0 zoom. Deliberately @State, not @AppStorage: zoom belongs to
    /// this window only. Every window starts at the Settings default; starting
    /// BOTH this and `renderedFontScale` there means a new window parses once,
    /// at the default — no 100% frame first, no second parse.
    /// This is the *requested* scale — it drives the re-parse.
    @State private var fontScale: Double
    /// The scale `cachedBlocks` was actually parsed with. Views render from
    /// this, never from `fontScale`, so headings (rendered synchronously in
    /// body) can't resize a frame ahead of body text (which waits for the
    /// background parse). Updated in the same transaction as `cachedBlocks`,
    /// so the whole document changes size in one step.
    @State private var renderedFontScale: Double
    /// The default this window last followed. A window still AT it follows a
    /// change in Settings; one the user zoomed away from keeps its size.
    /// The zoom pill compares against THIS, not the live `defaultZoom`: in the
    /// update pass that delivers a Settings change `defaultZoom` is already new
    /// while `fontScale` is still old (onChange runs after), so the live
    /// comparison would flash the pill in a window that is about to follow.
    /// Both @State values change together in onChange, after which this equals
    /// `defaultZoom` in every case.
    @State private var appliedDefaultZoom: Double
    /// ⌘⇧R — distraction-free reading: both sidebars, the top-right chrome pills
    /// and the Support/Tip Jar button step out of the way, and the text column
    /// stops at `Metrics.readingMaxContentWidth` and centres itself.
    ///
    /// @State, not @AppStorage, for the same reason as `fontScale`: it belongs to
    /// this window and this reading session. A viewer that reopens with its
    /// sidebars and buttons missing reads as broken, not as focused. The sidebar
    /// flags themselves are never touched — reading mode only overrides where
    /// they are USED, so leaving it restores exactly what the reader had.
    @State private var isReadingMode = false
    /// The virtualized list's height table + pre-converted strings for
    /// `cachedBlocks`, produced by `BlockHeightMeasurer` (v1.9 D3/D4). Replaced
    /// wholesale, never merged — except for the single-row patches height
    /// reports apply (`applyHeightReport`). `.empty` until the first width.
    @State private var measured: MeasuredBlocks = .empty
    /// Width a block view actually gets, reported by `VirtualBlockList`'s
    /// coordinator (column width − 2 × horizontal padding). 0 until the list has
    /// had its first layout — the heights can't be measured before that.
    @State private var contentWidth: CGFloat = 0
    /// Current programmatic scroll target for the virtualized list (ToC, search).
    @State private var scrollRequest: VirtualBlockList.ScrollRequest?
    @State private var scrollRequestToken: Int = 0
    /// ⌘E's "where is the reader" question, answered by the list's coordinator
    /// on demand. A reference in @State on purpose: the coordinator fills it,
    /// nothing observes it, so scrolling never re-evaluates this body (E-D1).
    @State private var readingPosition = DocumentReadingPosition()
    /// Source Edit (v1.12): the raw-Markdown editor over the rendered list, its
    /// buffer, saving and the close guard's answers. One per window, lives with
    /// the tab. Publishes only rare events (enter / leave, dirty, banner) — the
    /// body never reads anything per keystroke from it.
    @StateObject private var editSession = SourceEditSession()
    /// The editor's find bar height (0 = hidden): the bar sits where the pills
    /// and banners float, so they move below it (`topChromeInset`).
    @State private var editorFindBarHeight: CGFloat = 0
    /// The text `cachedBlocks` were parsed from. Block ids are positional, so a
    /// scroll by id is only meaningful against the blocks of the text it was
    /// computed for — the landing after Source Edit checks this (S-D10).
    @State private var installedText: String?
    /// A landing waiting for the parse of the just-saved text.
    @State private var landing = SourceEditLanding()

    /// File name suggested by the PDF export save panel (`ExportPDFCommand`).
    private var exportName: String {
        documentURL?.deletingPathExtension().lastPathComponent ?? "document"
    }

    init(document: MarkdownDocument, documentURL: URL?) {
        self.document = document
        self.documentURL = documentURL
        _currentText = State(initialValue: document.text)
        // One read of the Settings default for all three zoom states (SwiftUI
        // keeps only the first view init's values, like any @State initial).
        let startZoom = DefaultZoom.current
        _fontScale = State(initialValue: startZoom)
        _renderedFontScale = State(initialValue: startZoom)
        _appliedDefaultZoom = State(initialValue: startZoom)
    }

    /// Content insets, inter-block spacing and the per-kind `.padding(.vertical:)`
    /// applied in `blockView(for:)` — see `BlockLayout.Document`. Shared with
    /// `BlockHeightMeasurer`: those outer paddings are part of a block's row
    /// height, so both sides have to read the same numbers.
    typealias Metrics = BlockLayout.Document

    /// The window's light/dark scheme: the theme's own for a light or dark
    /// theme (the title bar and controls must match the background under them),
    /// nil — the system's — for Auto. Once a window was light or dark, Auto is
    /// passed as the system's EXPLICIT scheme: `preferredColorScheme(nil)` does
    /// not give the window back (GitHub → Auto left an Auto document light on a
    /// dark Mac, macOS 27). A window that was always Auto keeps plain nil.
    private var windowColorScheme: ColorScheme? {
        if let themed = MarkdownTheme.windowColorScheme(forThemeNamed: selectedThemeName) { return themed }
        return windowSchemeWasForced ? systemColorScheme : nil
    }

    /// Resolved theme from user selection + system color scheme + Settings fonts
    private var theme: MarkdownTheme {
        MarkdownTheme.theme(named: selectedThemeName, colorScheme: colorScheme)
            .resolvingFonts(defaults: DocumentFonts(body: bodyFontFamily, code: codeFontFamily))
    }

    private struct DocumentIdentity: Equatable {
        let text: String
        /// Only for a theme that follows the system (Auto, or a name that no
        /// longer resolves); nil for a light or dark theme, whose palette does
        /// not depend on it. Otherwise a window whose theme differs from the
        /// system would parse twice on open: once with the system's scheme,
        /// again after `preferredColorScheme` flips the window.
        let colorScheme: ColorScheme?
        let themeName: String
        let fonts: DocumentFonts
        let fontScale: Double
    }

    /// Re-measure trigger for the virtualized list: a new parse (`contentVersion`)
    /// or a new column width. Everything else that changes a height — theme,
    /// fonts, zoom — goes through a re-parse and therefore bumps `contentVersion`.
    private struct HeightsIdentity: Equatable {
        let contentVersion: Int
        let contentWidth: CGFloat
    }

    /// The parse task's payload: parser output plus the height table measured at
    /// the same width, so both land in ONE main-thread transaction (D4).
    private struct ParsedAndMeasured: @unchecked Sendable {
        let parsed: ParsedDocument
        let measured: MeasuredBlocks
    }

    /// Nothing to show yet: no blocks at all, or blocks whose height table is
    /// still being measured (the virtualized list keeps its previous content
    /// until the pair is consistent, so the spinner covers the gap).
    private var isRenderPending: Bool {
        return (isParsing && cachedBlocks.isEmpty)
            || (!cachedBlocks.isEmpty && measured.table.count != cachedBlocks.count)
    }

    /// The window content (sidebars + document + overlays). Kept out of `body`
    /// so the modifier chain below stays inside the type-checker's budget.
    private var documentStack: some View {
        HStack(spacing: 0) {
            // Recent documents sidebar (leftmost). Reading mode hides both
            // sidebars at the USE SITE — their @AppStorage flags keep whatever the
            // reader chose, so leaving reading mode brings back exactly that.
            if isDocumentListVisible && !isReadingMode {
                RecentDocumentsSidebar(theme: theme, currentURL: documentURL) {
                    withAnimation(.easeInOut(duration: 0.2)) { isDocumentListVisible = false }
                }
                .frame(width: documentListWidth)
                .transition(.move(edge: .leading).combined(with: .opacity))
                SidebarResizeHandle(width: $documentListWidth, minWidth: 160, maxWidth: 500)
            }

            // Table of Contents sidebar
            if isToCVisible && !headings.isEmpty && !isReadingMode {
                TableOfContentsView(headings: headings, onSelect: { targetId in
                    selectHeading(targetId)
                }, onCopy: { entry in
                    if let section = SectionExtractor.extractSection(from: currentText, entry: entry, headings: headings) {
                        copyToClipboard(section)
                    }
                }, onCollapse: {
                    withAnimation(.easeInOut(duration: 0.2)) { isToCVisible = false }
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

                // Our own virtualized list (v1.9): exact row heights from
                // `measured.table`, one layout path for every document size,
                // nothing estimated — see VirtualBlockList.swift.
                VirtualBlockList(
                    blocks: cachedBlocks,
                    table: measured.table,
                    contentVersion: contentVersion,
                    searchText: searchText,
                    focusedBlockId: focusedBlockId,
                    focusedOccInBlock: focusedOccInBlock,
                    scrollRequest: scrollRequest,
                    layoutStyle: isReadingMode ? .reading : .standard,
                    contentWidth: $contentWidth,
                    onHeightReport: { blockId, row, height in
                        applyHeightReport(blockId: blockId, row: row, height: height)
                    },
                    content: { block in AnyView(hostedBlockView(for: block)) },
                    selectableText: { block, version in
                        selectableText(for: block, installedVersion: version)
                    },
                    selectableTable: { block, version in
                        selectableTable(for: block, installedVersion: version)
                    },
                    onCopySelection: { output in copySelectionToClipboard(output) },
                    focusRequest: documentFocusRequest,
                    // Stays mounted under the editor (its anchor and offset
                    // survive; a remount would park at the top) but never takes
                    // the focus back while covered, and leaves the
                    // accessibility tree meanwhile (set on the AppKit view).
                    isCovered: graphicPreview != nil || editSession.isActive,
                    readingPosition: readingPosition
                )
                .onChange(of: scrollTrigger) { _ in
                    scrollFocusedMatchIntoView()
                }
            }
            .overlay {
                // Source Edit (S-D4). The FIRST overlay, so the pills, banners
                // and toast below stay above the editor. No transition and no
                // changing identity: one live `SourceEditorView` per controller
                // (an outgoing copy would take the scroll view from the new
                // one). Theme, zoom and Reading Mode reach it through `style`.
                Group {
                    if editSession.isActive {
                        SourceEditorView(controller: editSession.editor,
                                         style: .init(theme: theme, fontScale: fontScale,
                                                      isReadingLayout: isReadingMode))
                    }
                }
                // An animated transaction from elsewhere (a toast, a sidebar)
                // must not turn the mount or unmount into a fade.
                .transaction { $0.animation = nil }
            }
            .overlay(alignment: .topLeading) {
                // Reveal sidebar when hidden (sits at top-leading; out of the way
                // of content). Reading mode is the one state where "hidden" was
                // not the reader asking for a way back.
                if !isDocumentListVisible && !isReadingMode {
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
                    .padding(.top, topChromeInset)
                    .padding(.leading, 8)
                }
            }
            .overlay(alignment: .topTrailing) {
                chromeCluster
            }
            .overlay(alignment: .top) {
                // The missing-file and changed-on-disk banners can be up at
                // once (a change the buffer has not acknowledged, then the file
                // goes): stacked, never on top of each other.
                VStack(spacing: 8) {
                    if fileMissing {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.yellow)
                            Text("File no longer exists at \(documentURL?.path ?? "this location")")
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Close Tab") {
                                EditCloseGuard.requestClose(NSApp.keyWindow)
                            }
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial)
                        .clipShape(Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if editSession.externalChange {
                        changedOnDiskBanner
                    }
                }
                .padding(.top, topChromeInset)
            }
            .overlay(alignment: .bottomTrailing) {
                // The Support / Tip Jar button is hidden while editing as well
                // as in Reading Mode: it would float over the text being
                // edited (bottom-right is where a long line ends), and a
                // misclick there opens a menu or a window mid-edit.
                if !isReadingMode && !editSession.isActive {
                    Group {
                        #if APPSTORE
                        TipJarButton(theme: theme)
                        #else
                        SupportButton(theme: theme)
                        #endif
                    }
                    .padding(16)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .center) {
                // The hidden list re-parses after every save; the editor is
                // what is on screen, and it is not waiting for anything.
                if isRenderPending && !editSession.isActive {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        // Two different waits, and on a big document they are
                        // long enough to tell apart: the parser turning text into
                        // blocks, then the measurer turning blocks into row
                        // heights.
                        Text(isParsing ? "Parsing…" : "Rendering…")
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
    }

    /// Where the top chrome (pills, banners, the sidebar button) floats: below
    /// the search bar, or below the editor's find bar while that is showing —
    /// the find bar's own buttons sit exactly under the Save / Done pills.
    private var topChromeInset: CGFloat {
        if isSearchVisible { return 44 }
        if editSession.isActive && editorFindBarHeight > 0 { return editorFindBarHeight + 8 }
        return 8
    }

    /// The top-right pill cluster.
    ///
    /// Reading: zoom reset (while zoomed), Reload (⌘R), Edit (Source Edit,
    /// ⌥⌘E), Copy source — gone in Reading Mode, whose shortcuts (⌘0, ⌘R,
    /// ⌥⌘E, ⌘⇧C) all still work, so nothing is lost except the thing
    /// hovering over the text.
    ///
    /// Editing: ONLY Save and Done, also in Reading Mode — a mode you can only
    /// leave by shortcut is not acceptable (S-D12).
    @ViewBuilder
    private var chromeCluster: some View {
        if editSession.isActive {
            HStack(spacing: 8) {
                SourceSaveButton(theme: theme, isEnabled: editSession.isDirty) {
                    editSession.save()
                }
                SourceDoneButton(theme: theme) {
                    editSession.requestLeave()
                }
            }
            .chromeHoverCluster()
            .padding(.top, topChromeInset)
            .padding(.trailing, 24)
        } else if !isReadingMode {
            HStack(spacing: 8) {
                // `appliedDefaultZoom`, not `defaultZoom`: no pill flash in a
                // window that follows a Settings change (see its doc comment).
                if fontScale != appliedDefaultZoom {
                    ZoomResetButton(theme: theme, fontScale: fontScale, defaultScale: appliedDefaultZoom) {
                        applyZoom(.actualSize)
                    }
                    .transition(.opacity)
                }
                if documentURL != nil {
                    ReloadDocumentButton(theme: theme) {
                        reloadManually()
                    }
                    EditSourceButton(theme: theme) {
                        toggleSourceEdit()
                    }
                }
                CopySourceButton(theme: theme) {
                    copyToClipboard(currentText)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: fontScale != appliedDefaultZoom)
            .chromeHoverCluster()
            .padding(.top, topChromeInset)
            .padding(.trailing, 24)
            .transition(.opacity)
        }
    }

    /// S-D9: the file changed on disk while the buffer holds unsaved text. The
    /// rendered view (hidden) already shows the disk; the user decides about
    /// the buffer. Same look and place as the missing-file banner.
    private var changedOnDiskBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
            Text("This file changed on disk while you were editing.")
                .font(.system(size: 12))
                .lineLimit(1)
            Button("Keep My Version") {
                editSession.keepMyVersion()
            }
            .controlSize(.small)
            .accessibilityIdentifier("source-keep-mine")
            Button("Load Disk Version") {
                editSession.loadDiskVersion()
            }
            .controlSize(.small)
            .accessibilityIdentifier("source-load-disk")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// `documentStack` plus the window configuration and every value the app's
    /// menu commands read from the focused document.
    ///
    /// Split out of `body` for the same reason as `documentStack` itself: with ten
    /// chained `focusedSceneValue` calls in front of the `.task`s, the whole
    /// modifier chain no longer type-checks inside the compiler's budget.
    private var configuredDocumentStack: some View {
        documentStack
        .disabled(graphicPreview != nil)
        .onChange(of: graphicPreview == nil) { closed in
            if closed { documentFocusRequest += 1 }
        }
        .onChange(of: isSearchVisible) { visible in
            // Esc or the close button: the search field goes away with focus,
            // and ⌘A/⌘C should reach the document without a click.
            if !visible { documentFocusRequest += 1 }
        }
        .accessibilityHidden(graphicPreview != nil)
        .overlay {
            if let graphicPreview {
                GraphicPreviewOverlay(preview: graphicPreview, theme: theme) { self.graphicPreview = nil }
            }
        }
        .background(theme.backgroundColor)
        .background(WindowConfigurator { window in
            // Tabbing is set up app-wide (WindowTabbing.preferTabsAlways); the
            // window keeps SwiftUI's shared tabbingIdentifier.
            // Remembered so the process-global key monitor below can ignore
            // key events addressed to OTHER windows (tabs are separate windows).
            hostWindow = window
        })
        .preferredColorScheme(windowColorScheme)
        .background(SystemColorSchemeReader { systemColorScheme = $0 })
        // Keyed on the scheme actually forced, not on the theme name: a custom
        // theme whose file comes back resolves without the name changing.
        .onChange(of: MarkdownTheme.windowColorScheme(forThemeNamed: selectedThemeName)) { forced in
            if forced != nil { windowSchemeWasForced = true }
        }
        .focusedSceneValue(\.documentText, currentText)
        .focusedSceneValue(\.exportName, exportName)
        // Print / PDF resolve relative image paths against the document folder.
        .focusedSceneValue(\.exportDocumentLocation, ExportDocumentLocation(url: documentURL))
        .focusedSceneValue(\.searchAction, { findCommand() })
        .focusedSceneValue(\.toggleToCAction, {
            // No-op in reading mode: the sidebars are hidden and must come back
            // exactly as they were, so their flags are not touched meanwhile.
            guard !isReadingMode else { return }
            withAnimation(.easeInOut(duration: 0.2)) { isToCVisible.toggle() }
        })
        .focusedSceneValue(\.copyDocumentAction, { copyToClipboard(currentText) })
        .focusedSceneValue(\.openInExternalEditorAction, { openInExternalEditor() })
        .focusedSceneValue(\.reloadDocumentAction, { reloadManually() })
        .focusedSceneValue(\.toggleDocumentListAction, {
            guard !isReadingMode else { return }
            withAnimation(.easeInOut(duration: 0.2)) { isDocumentListVisible.toggle() }
        })
        .focusedSceneValue(\.zoomAction, { zoom in applyZoom(zoom) })
        // Settings ▸ Fonts ▸ Default zoom changed: a window still at the old
        // default follows (no toast — the user is looking at Settings), a
        // window zoomed elsewhere keeps its size. Single-parameter onChange:
        // the two-parameter variant is macOS 14+.
        .onChange(of: defaultZoom) { newDefault in
            if fontScale == appliedDefaultZoom {
                fontScale = newDefault
            }
            appliedDefaultZoom = newDefault
        }
        .focusedSceneValue(\.toggleReadingModeAction, { toggleReadingMode() })
        // The menu item's title flips with the state, so the View menu needs the
        // flag as well as the action (⌘⇧R routes to the focused tab only).
        .focusedSceneValue(\.isReadingMode, isReadingMode)
    }

    /// `configuredDocumentStack` plus Source Edit's menu values and its leave
    /// handling — one more split for the type-checker's budget.
    private var sourceEditStack: some View {
        configuredDocumentStack
        .focusedSceneValue(\.sourceEditState,
                           SourceEditMenuState(isEditing: editSession.isActive, isDirty: editSession.isDirty))
        .focusedSceneValue(\.toggleSourceEditAction, { toggleSourceEdit() })
        .focusedSceneValue(\.saveSourceAction, { editSession.save() })
        .focusedSceneValue(\.discardSourceChangesAction, { editSession.discardChanges() })
        // A document can be moved or renamed while open: the session's URL
        // and the watcher follow the view's (both set on appear too). A
        // "file missing" from the old path no longer applies.
        .onChange(of: documentURL) { url in
            editSession.environment.documentURL = url
            startWatching(url)
            if fileMissing {
                withAnimation(.easeInOut(duration: 0.2)) { fileMissing = false }
            }
        }
        .onChange(of: editSession.lastLeave) { leave in
            if let leave { didLeaveSourceEdit(leave) }
        }
    }

    var body: some View {
        sourceEditStack
        .environment(\.openURL, OpenURLAction { url in
            handleLinkActivation(url)
            return .handled
        })
        .frame(minWidth: 400, minHeight: 300)
        .task(id: DocumentIdentity(text: currentText,
                                   colorScheme: MarkdownTheme.windowColorScheme(forThemeNamed: selectedThemeName) == nil
                                       ? colorScheme : nil,
                                   themeName: selectedThemeName,
                                   fonts: DocumentFonts(body: bodyFontFamily, code: codeFontFamily),
                                   fontScale: fontScale)) {
            let text = currentText
            let currentTheme = theme
            isParsing = true
            let scale = CGFloat(fontScale)
            // The width the list will lay the blocks out at. 0 before the host's
            // first layout — then the heights task below picks it up as soon as
            // the coordinator reports one.
            let width = contentWidth
            // Keyed by the link, so valid across this re-parse.
            let imageSizes = heightCache.imageSizesSnapshot
            let out: ParsedAndMeasured = await Task.detached(priority: .userInitiated) {
                let blocks = MarkdownBlockParser(theme: currentTheme, fontScale: scale).parse(text)
                // Pre-compute per-text-block metadata on the background thread so the
                // main thread never has to do it later.
                var meta: [String: TextBlockMeta] = [:]
                for block in blocks {
                    if case .text(let attr) = block.content {
                        let plain = String(attr.characters)
                        // Same test BlockHeightMeasurer applies when meta is
                        // missing — one rule, or a measured row and the view it
                        // hosts disagree about inline math.
                        meta[block.id] = TextBlockMeta(
                            plain: plain,
                            hasInlineMath: BlockTextConverter.containsInlineMath(plain))
                    }
                }
                // Measure in the SAME task, so blocks and their heights reach the
                // main actor together and the list never has to guess (D4).
                // `math: nil` is mandatory here: the SwiftMath engine is
                // main-thread-only (thread rule in BlockHeightMeasurer.swift);
                // the rows it defers are finished on main just below.
                // No `heightSeeds`: `heightCache` is cleared for this parse, and
                // block ids are positional, so the previous document's diagram
                // heights would seed the wrong diagrams. Pictures and diagrams
                // that were shown before are computed (`imageSizes`, the SVG
                // decoder, `MermaidGeometryStore`).
                let measured = width > 0
                    ? BlockHeightMeasurer.measure(blocks: blocks, theme: currentTheme,
                                                  fontScale: scale, contentWidth: width,
                                                  imageSizes: imageSizes, math: nil)
                    : MeasuredBlocks.empty
                return ParsedAndMeasured(parsed: ParsedDocument(blocks: blocks, textMeta: meta),
                                         measured: measured)
            }.value
            // SwiftUI cancels this task when the id changes (new text, theme or
            // zoom) but the detached parse above keeps running to completion —
            // without this guard a superseded parse can land last and win, which
            // is what made repeated ⌘+/⌘- jump to arbitrary sizes.
            guard !Task.isCancelled else { return }
            let parsed = out.parsed
            // A display formula SwiftMath cannot typeset would draw an empty
            // row: show its source as a ```latex code block instead. Decided
            // here, once per parse and before anything is laid out (the engine
            // is main-thread only), so every consumer of `cachedBlocks` — view,
            // measurer, search, selection, landing — sees the same block. Its
            // row is still in `mathPendingRows`; `measureMathRows` measures it
            // as code below.
            let blocks = MathRendering.swiftMath.substitutingUntypesettableMath(in: parsed.blocks)
            heightCache.removeAll()  // new content/theme — stale heights would mis-seed diagrams
            cachedBlocks = blocks
            renderedFontScale = Double(scale)
            contentVersion += 1
            textBlockMeta = parsed.textMeta
            installedText = text
            // Inline `$…$` paragraphs and display-math rows were deferred by the
            // off-main pass; finish them here, on the main actor, before the
            // table is used for layout.
            measured = width > 0
                ? BlockHeightMeasurer.measureMathRows(out.measured.mathPendingRows,
                                                      in: out.measured, blocks: blocks,
                                                      theme: currentTheme, fontScale: scale,
                                                      contentWidth: width, math: .swiftMath)
                : .empty
            headings = blocks.compactMap { block in
                if case .heading(let level, let title, let sourceLine) = block.content {
                    return ToCEntry(id: block.id, level: level, title: title, sourceLine: sourceLine)
                }
                return nil
            }
            // A landing that waited for THIS parse (Source Edit saved, then
            // left before the re-parse arrived): requested in the transaction
            // that installs the blocks, so it wins over the list's own anchor
            // restore and resolves against the new ids.
            if let target = landing.blocksInstalled(blocks) {
                requestScroll(to: target, anchor: .top, animated: false)
            }
            // The find bar's matches index the PREVIOUS parse's blocks: count
            // again over these (and the measured strings just installed).
            rerunSearchAfterReparse()
            isParsing = false
        }
        .task(id: HeightsIdentity(contentVersion: contentVersion, contentWidth: contentWidth)) {
            // Covers the two cases the parse transaction can't: the first layout
            // (no width yet when the document was parsed) and every later width
            // change (window resize, sidebar toggle or drag). Zoom, theme and
            // font changes go through a re-parse, which measures inline.
            guard contentWidth > 0, !cachedBlocks.isEmpty else { return }
            guard measured.table.count != cachedBlocks.count
                    || measured.table.contentWidth != contentWidth else { return }
            let blocks = cachedBlocks
            let currentTheme = theme
            let scale = CGFloat(renderedFontScale)
            let width = contentWidth
            let version = contentVersion
            // The first table for this parse (it was parsed before the list had
            // a width): the search ran on fallback strings, re-count it on the
            // measured ones. A width-only re-measure changes no character.
            let firstTableForParse = measured.table.count != cachedBlocks.count
            // Mermaid rows: seed from the heights the WebViews actually reported,
            // so a re-measure doesn't send every diagram back to the 200 pt default.
            let seeds = heightCache.snapshot
            // Images shown before: their rows are computed at the new width.
            let imageSizes = heightCache.imageSizesSnapshot
            // Inline-math paragraphs: hand the previous pass's strings back so the
            // main-actor step re-wraps them instead of re-rendering every `$…$`
            // segment through SwiftMath. Safe only because this task never runs
            // across a content change — the guard below drops the result if a
            // parse landed meanwhile, and everything that alters the characters
            // (text, theme, fonts, zoom) goes through a re-parse.
            let reusableStrings = measured.converted
            let raw: MeasuredBlocks = await Task.detached(priority: .userInitiated) {
                BlockHeightMeasurer.measure(blocks: blocks, theme: currentTheme, fontScale: scale,
                                            contentWidth: width, heightSeeds: seeds,
                                            imageSizes: imageSizes, math: nil)
            }.value
            // A parse that landed while we were measuring owns the state now —
            // its own transaction published a matching table.
            guard !Task.isCancelled, version == contentVersion else { return }
            measured = BlockHeightMeasurer.measureMathRows(raw.mathPendingRows, in: raw,
                                                          blocks: blocks, theme: currentTheme,
                                                          fontScale: scale, contentWidth: width,
                                                          math: .swiftMath,
                                                          reusing: reusableStrings)
            if firstTableForParse { rerunSearchAfterReparse() }
        }
        .onChange(of: searchText) { newValue in
            searchDebounce?.cancel()
            // Empty search is cheap and the user expects instant clear
            if newValue.isEmpty {
                searchDebounce = nil
                updateMatchResults(for: newValue, trigger: .termChanged)
                return
            }
            let work = DispatchWorkItem {
                // Nil = no keystroke waiting (`rerunSearchAfterReparse` reads it).
                searchDebounce = nil
                updateMatchResults(for: newValue, trigger: .termChanged)
            }
            searchDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        .onAppear {
            if MarkdownTheme.windowColorScheme(forThemeNamed: selectedThemeName) != nil { windowSchemeWasForced = true }
            configureEditSession()
            if let url = documentURL {
                RecentDocumentsStore.shared.register(url)
            }
            startWatching(documentURL)
            // NSEvent.addLocalMonitorForEvents is GLOBAL for the app process —
            // every visible MarkdownView (one per open tab) registers its own
            // monitor, and ALL of them fire on every keypress. So we can't
            // toggle per-view state here for shortcuts that have menu equivalents
            // (⌘F, ⌘⇧T, ⌘⇧D, ⌘⇧C) — those are routed through `@FocusedValue`
            // in QuickMDApp.swift, which correctly targets the active tab.
            //
            // Only handle the search-bar-specific keys here (⌘G next match,
            // ⇧⌘G previous, Escape close), Escape for reading mode and ⌘G / ⇧⌘G
            // for the Source Edit find bar. These already gate on per-view state
            // (`isSearchVisible`, `isReadingMode`, `editSession.isActive`), so
            // inactive tabs return the event unchanged and the active tab
            // consumes it. ⌘⇧R itself is a menu shortcut, routed through
            // `@FocusedValue` like ⌘F/⌘⇧T/⌘⇧D — a monitor would toggle every
            // open tab at once.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Every tab installs one of these monitors and ALL of them see
                // every keypress. Per-view state alone is not enough to make
                // that safe for a MODE (a reader can leave reading mode on in
                // a background tab), so gate on the event's window: only the
                // tab that owns the key window handles it.
                if let hostWindow, let eventWindow = event.window, eventWindow !== hostWindow {
                    return event
                }
                if graphicPreview != nil {
                    if event.keyCode == 53 {
                        graphicPreview = nil
                        return nil
                    }
                    return event
                }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

                if editSession.isActive {
                    // ⌘G / ⇧⌘G — exactly those, not ⌥⌘G / ⌃⌘G — go to the
                    // editor's text finder (S-D6).
                    let finderFlags = flags.intersection([.command, .shift, .option, .control])
                    if finderFlags == .command || finderFlags == [.command, .shift],
                       event.charactersIgnoringModifiers?.lowercased() == "g" {
                        if finderFlags.contains(.shift) {
                            editSession.editor.findPrevious()
                        } else {
                            editSession.editor.findNext()
                        }
                        return nil
                    }
                    // Escape: in a text view (the editor, or the find bar's
                    // field editor) it is theirs — the editor reports it to the
                    // session, the field closes the bar. With the focus
                    // anywhere else (a banner or sidebar button, nothing) the
                    // session gets it here, so Esc works wherever focus is —
                    // and never reaches Reading Mode or the search first.
                    if event.keyCode == 53 {
                        let responder = event.window?.firstResponder ?? hostWindow?.firstResponder
                        if !(responder is NSText) {
                            editSession.escape()
                            return nil
                        }
                    }
                    return event
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
                if event.keyCode == 53 {  // Escape
                    // Search first: with both open, Escape is the reader asking
                    // to dismiss the thing they opened last, and the search bar
                    // is the only one of the two they can open from inside
                    // reading mode.
                    if isSearchVisible {
                        isSearchVisible = false
                        searchText = ""
                        return nil
                    }
                    if isReadingMode {
                        setReadingMode(false)
                        return nil
                    }
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
            releaseEditSession()
        }
        #if APPSTORE
        // Rating prompt (App Store build only): counts this window's open once
        // its first parse landed (`contentVersion` only grows — reloads, zoom
        // and theme changes don't count again) and may ask after 60 s of
        // display. Not while Source Edit is up.
        .modifier(ReviewPromptTrigger(isRendered: contentVersion > 0,
                                      isEditing: editSession.isActive,
                                      window: hostWindow))
        #endif
    }

    // MARK: - Auto-Reload & External Editor

    /// Auto-reload: watch this document's file and refresh on save. Silent by
    /// default — pro users expect the viewer to be current. Replaces any
    /// watcher bound to a previous path (the document was moved or renamed).
    private func startWatching(_ url: URL?) {
        fileWatcher?.stop()
        fileWatcher = nil
        guard let url else { return }
        let watcher = FileWatcher()
        watcher.onChange = { reloadFromDisk() }
        watcher.onFileMissing = {
            withAnimation(.easeInOut(duration: 0.2)) { fileMissing = true }
        }
        watcher.start(watching: url)
        fileWatcher = watcher
    }

    /// What `reloadFromDisk` found — the ⌘R toast reports it.
    private enum DiskReload { case changed, unchanged, unreadable, ownedBySession }

    /// Re-reads the watched file and swaps the displayed text if it changed.
    /// Same decode + line-ending normalization as the initial document load.
    @discardableResult
    private func reloadFromDisk() -> DiskReload {
        guard let url = documentURL else { return .unreadable }
        if editSession.isActive {
            // The session reads the disk itself and keeps the rendered text
            // equal to it through `commitText` (S-D9) — or shows the banner
            // when the buffer holds unsaved text. Touching `currentText` here
            // would race it.
            editSession.diskDidChange()
            if fileMissing && FileManager.default.fileExists(atPath: url.path) {
                withAnimation(.easeInOut(duration: 0.2)) { fileMissing = false }
            }
            return .ownedBySession
        }
        // Only the read can fail: decoding falls back to Latin-1.
        guard let data = try? Data(contentsOf: url),
              let decoded = MarkdownDocument.decode(data) else { return .unreadable }
        let text = MarkdownDocument.normalizeLineEndings(decoded)
        let changed = text != currentText
        if changed {
            currentText = text
        }
        if fileMissing {
            withAnimation(.easeInOut(duration: 0.2)) { fileMissing = false }
        }
        return changed ? .changed : .unchanged
    }

    /// ⌘R / the reload pill: re-read the file now, and restart the watcher in
    /// case it lost track of the file (some volumes and save strategies never
    /// deliver an event). Not while Source Edit shows — the session owns the
    /// disk then.
    private func reloadManually() {
        guard !editSession.isActive, let url = documentURL else { return }
        // Watch first, then read: a write landing in between is caught by the
        // new watcher (at worst one more reload that finds nothing new). For a
        // missing file the watcher shows the banner and polls for its return.
        startWatching(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        switch reloadFromDisk() {
        case .changed: showToast("Reloaded")
        case .unchanged: showToast("Reloaded \u{00B7} no changes")
        case .unreadable: showToast("Couldn't read the file")
        case .ownedBySession: break
        }
    }

    /// ⌘E — hand the document off to the user's configured editor, at the line
    /// the reader is at when that editor documents a line link (v1.11 E-D1).
    private func openInExternalEditor() {
        // Two editors on one file: not while Source Edit is showing.
        guard !editSession.isActive, let url = documentURL else { return }
        let line = readingPosition.editorLine()
        if let result = ExternalEditorManager.openInEditor(url, line: line) {
            showToast(ExternalEditorManager.toastText(for: result))
        }
    }

    // MARK: - Source Edit (v1.12)

    /// Hands the session what it needs from this view. The closures capture
    /// the view — and with it the @StateObject's storage, a cycle — so they
    /// are dropped in `onDisappear` (`releaseEditSession`) and set again here.
    /// Nothing that saves depends on them: a save uses `documentURL` and the
    /// window the close guard hands in (or the text view's own window).
    private func configureEditSession() {
        editSession.environment = SourceEditSession.Environment(
            documentURL: documentURL,
            window: { hostWindow },
            renderedText: { currentText },
            commitText: { text in
                if !SourceEditSession.isSameText(text, currentText) { currentText = text }
            },
            toast: { showToast($0) }
        )
        editSession.editor.onFindBarHeightChange = { height in
            // Reported from the scroll view's `tile()`, i.e. inside an AppKit
            // layout pass: published on the next turn, not during it.
            DispatchQueue.main.async { editorFindBarHeight = height }
        }
    }

    private func releaseEditSession() {
        editSession.environment = SourceEditSession.Environment(documentURL: documentURL)
        editSession.editor.onFindBarHeightChange = nil
    }

    /// ⌥⌘E, File ▸ Edit Source / Done Editing, the Edit pill. Entering starts
    /// at the source line being read — the selection's first row, else the
    /// top visible row (`editorLine()` is 1-based, the session 0-based).
    private func toggleSourceEdit() {
        if editSession.isActive {
            editSession.requestLeave()
            return
        }
        guard graphicPreview == nil else { return }
        // A rendered selection whose text is literally in its source lines is
        // selected in the editor (S-D14b); otherwise the caret goes to the line.
        if let refusal = editSession.enter(atLine: readingPosition.editorLine().map { $0 - 1 },
                                           selection: { readingPosition.selectionHint() }) {
            showToast(refusal.message)
            return
        }
        // A landing still waiting for a parse belongs to the previous session.
        landing.cancel()
        isSearchVisible = false
        searchText = ""
        editSession.focusEditor()
    }

    /// The session left (Done, Esc, the command; after Save or Don't Save).
    /// The list gets the keyboard back; if the session saved or the caret
    /// moved off the entry line, the list lands on the block holding the
    /// caret's line — against the blocks of the CURRENT text (S-D10).
    private func didLeaveSourceEdit(_ leave: SourceEditSession.LeaveInfo) {
        documentFocusRequest += 1
        // `==`, as `DocumentIdentity` compares: text it calls equal is never
        // re-parsed, so waiting for a parse of it would wait forever.
        let current = installedText.map { $0 == currentText } ?? false
        if let target = landing.leave(leave, installedBlocksAreCurrent: current, blocks: cachedBlocks) {
            requestScroll(to: target, anchor: .top, animated: false)
        }
    }

    /// ⌘F: the editor's find bar while editing (S-D6), the search bar otherwise.
    private func findCommand() {
        if editSession.isActive {
            editSession.editor.showFind()
        } else {
            toggleSearch()
        }
    }

    /// A ToC click. While editing, the EDITOR scrolls to the heading's source
    /// line (S-D13) — best effort until the next save, since the headings come
    /// from the last saved parse; the hidden list stays where the reader was.
    private func selectHeading(_ targetId: String) {
        if editSession.isActive {
            if let entry = headings.first(where: { $0.id == targetId }) {
                editSession.editor.scroll(toLine: entry.sourceLine)
            }
            return
        }
        requestScroll(to: targetId, anchor: .top, animated: true)
    }

    // MARK: - Block Rendering

    /// `blockView(for:)` plus the environment the block views would otherwise
    /// lose by being hosted in an `NSHostingView` inside a table cell.
    ///
    /// `NSViewRepresentable` is an environment boundary: nothing applied to the
    /// SwiftUI tree AROUND `VirtualBlockList` reaches the views inside its cells.
    /// The link action matters — any SwiftUI `Text` with a Foundation `.link`
    /// attribute inside a cell is opened by SwiftUI through `openURL`; without
    /// this it would bypass `handleLinkActivation` (relative paths unresolved,
    /// `.md` files opened by whatever app claims them, no confirmation for
    /// exotic schemes). The NSTextView-backed rows (text, headings, tables
    /// since v1.13) open links through their delegate's `onLink` instead.
    private func hostedBlockView(for block: MarkdownBlock) -> some View {
        blockView(for: block)
            .environment(\.openURL, OpenURLAction { url in
                handleLinkActivation(url)
                return .handled
            })
    }

    /// Opens the window-filling image / diagram preview. Focus rings are drawn
    /// by AppKit above every view, so a focused control under the overlay (the
    /// sidebar collapse button is the first responder after launch with
    /// keyboard navigation on) would keep its ring visible through the
    /// preview — drop first responder before covering the document.
    private func presentGraphicPreview(_ preview: GraphicPreview) {
        hostWindow?.makeFirstResponder(nil)
        graphicPreview = preview
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
                    // D12 — the measurer already built this string to size the
                    // row; nil until the document has been measured.
                    preconverted: measured.converted[block.id],
                    onLink: { handleLinkActivation($0) }
                )

            case .table(let headers, let rows, let alignments, let style):
                // One NSTextView over the measurer's own `TableText` (v1.13
                // TS-D1/TS-D3) — an `.exact` row like the text kinds.
                TableTextBlockView(headers: headers, rows: rows, alignments: alignments, style: style, theme: theme,
                                   fontScale: scale, searchText: searchText, focusedOccurrence: focusedOcc,
                                   preconverted: measured.tables[block.id],
                                   onLink: { handleLinkActivation($0) })
                    .padding(.vertical, Metrics.tableOuterVerticalPadding)

            case .codeBlock(let code, let language):
                // The copy button's toast belongs to THIS tab: a closure, not a
                // notification every open document would observe.
                CodeBlockView(code: code, language: language, theme: theme,
                              fontScale: scale, searchText: searchText, focusedOccurrence: focusedOcc,
                              onCopy: { copyToClipboard($0) })
                    .padding(.vertical, Metrics.codeOuterVerticalPadding)

            case .image(let url, let alt, let width):
                ImageBlockView(url: url, alt: alt, width: width, theme: theme, documentURL: documentURL,
                               fontScale: scale, contentWidth: contentWidth, heightCache: heightCache,
                               onEnlarge: presentGraphicPreview)
                    .padding(.vertical, Metrics.imageOuterVerticalPadding)

            case .blockquote(let content, let level):
                BlockquoteView(blockId: block.id, content: content, level: level, theme: theme,
                               fontScale: scale, contentVersion: contentVersion,
                               searchText: searchText, focusedOccurrence: focusedOcc,
                               preconverted: measured.converted[block.id],
                               onLink: { handleLinkActivation($0) })

            case .alert(let kind, let content):
                AlertBlockView(blockId: block.id, kind: kind, content: content, theme: theme,
                               fontScale: scale, contentVersion: contentVersion,
                               searchText: searchText, focusedOccurrence: focusedOcc,
                               preconverted: measured.converted[block.id],
                               onLink: { handleLinkActivation($0) })
                    .padding(.vertical, Metrics.alertOuterVerticalPadding)

            case .heading(let level, let title, _):
                HeadingBlockView(
                    id: block.id,
                    level: level,
                    title: title,
                    theme: theme,
                    fontScale: scale,
                    contentVersion: contentVersion,
                    searchText: searchText,
                    focusedOccurrence: focusedOcc,
                    onLink: { handleLinkActivation($0) },
                    onCopySection: {
                        if let entry = headings.first(where: { $0.id == block.id }),
                           let section = SectionExtractor.extractSection(from: currentText, entry: entry, headings: headings) {
                            copyToClipboard(section)
                        }
                    }
                )

            case .mathBlock(let latex):
                MathBlockView(latex: latex, theme: theme, fontScale: scale)
                    .padding(.vertical, Metrics.mathOuterVerticalPadding)

            case .svgImage(let source):
                SVGBlockView(source: source, theme: theme, fontScale: scale,
                             contentWidth: contentWidth, onEnlarge: presentGraphicPreview)
                    .padding(.vertical, Metrics.imageOuterVerticalPadding)

            case .mermaidDiagram(let source):
                MermaidBlockView(blockId: block.id, source: source, theme: theme,
                                 heightCache: heightCache, fontScale: scale,
                                 contentWidth: contentWidth,
                                 onEnlarge: presentGraphicPreview)
                    .id("\(block.id)|\(scale)|\(contentWidth)|\(theme.isDark)")
                    .padding(.vertical, Metrics.mermaidOuterVerticalPadding)
            }
        }

        view
            .id(block.id)
    }

    // MARK: - Search Helpers

    private func toggleSearch() {
        // The document search cannot open over the editor (S-D6).
        guard !editSession.isActive else { return }
        isSearchVisible.toggle()
        if !isSearchVisible { searchText = "" }
    }

    // MARK: - Clipboard Helpers

    /// Copy Markdown (⌘⇧C, the Copy pill), Copy section (heading button, ToC)
    /// and the code block's copy button: plain text through the one clipboard
    /// path, with the same "Copied N characters · M words" toast as a
    /// selection copy (S-D9) — the count tells the reader WHAT was copied,
    /// which "Copied!" never did (a section can be one line or fifty).
    private func copyToClipboard(_ text: String) {
        showToast(DocumentClipboard.write(plain: text, rtf: nil))
    }

    /// ⌘C / context-menu Copy / auto-copy of the document selection (v1.11 S-D8/S-D9):
    /// plain text + RTF through `DocumentClipboard.write`, and the toast says
    /// what was copied ("Copied 1,234 characters · 210 words").
    private func copySelectionToClipboard(_ output: DocumentCopyOutput) {
        showToast(DocumentClipboard.write(plain: output.plain, rtf: output.rtf))
    }

    // MARK: - Selectable strings (v1.11 S-D2)

    /// The string `block`'s text view displays — the string the document
    /// selection's offsets index into — or nil for rows without one (images,
    /// math, diagrams), which are selected whole. A table's is its
    /// `TableTextBuilder` string (v1.13 TS-D4): cells in reading order, one
    /// paragraph each.
    ///
    /// Built WITHOUT the view, so ⌘A + ⌘C works for rows that were never
    /// materialized. Each case is the same construction the block's view uses
    /// (same converter, same renderer, same theme and scale), so offsets and
    /// characters agree with what is drawn.
    ///
    /// `installedVersion` is the content version of the blocks the list is
    /// SHOWING. `measured.converted` and `textBlockMeta` are keyed by block id,
    /// and ids are positional (`text-3` exists in every parse), so the cache is
    /// only used when it belongs to the same parse; otherwise the string is
    /// converted from the block itself.
    private func selectableText(for block: MarkdownBlock, installedVersion: Int) -> NSAttributedString? {
        let scale = CGFloat(renderedFontScale)
        let cached = installedVersion == contentVersion ? measured.converted[block.id] : nil
        switch block.content {
        case .text(let attributed):
            if let cached { return cached }
            return TextBlockView.makeNSAttributedString(
                from: attributed,
                hasInlineMath: BlockTextConverter.containsInlineMath(String(attributed.characters)),
                theme: theme, fontScale: scale)
        case .blockquote(let content, _):
            if let cached { return cached }
            return TextBlockView.makeNSAttributedString(
                from: MarkdownRenderer(theme: theme, fontScale: scale).renderQuotedBody(content),
                hasInlineMath: false, theme: theme, fontScale: scale)
        case .alert(_, let content):
            // The alert's TITLE is chrome, not text: only the body is selectable.
            guard !content.isEmpty else { return nil }
            if let cached { return cached }
            return TextBlockView.makeNSAttributedString(
                from: MarkdownRenderer(theme: theme, fontScale: scale).renderQuotedBody(content),
                hasInlineMath: false, theme: theme, fontScale: scale)
        case .codeBlock(let code, _):
            // The plain string the view shows until the highlight lands; the
            // highlight changes colours only, never characters.
            return BlockTextConverter.plainCode(code, theme: theme, fontScale: scale)
        case .heading(let level, let title, _):
            // Exactly what `HeadingBlockView` hands its `TextBlockView`: the
            // same `renderHeader` output through the same converter (no
            // inline math — a heading shows `$…$` literally, as before). The
            // measurer kept it (`MeasuredBlocks.converted`): a ⌘C of a
            // heading-heavy document no longer converts every heading again.
            if let cached { return cached }
            return TextBlockView.makeNSAttributedString(
                from: MarkdownRenderer(theme: theme, fontScale: scale).renderHeader(title, level: level),
                hasInlineMath: false, theme: theme, fontScale: scale)
        case .table:
            return selectableTable(for: block, installedVersion: installedVersion)?.string
        case .image, .svgImage, .mathBlock, .mermaidDiagram:
            return nil
        }
    }

    /// A `.table` block's selectable string with its cell layout (TS-D4 /
    /// TS-D8): the measurer's instance when it belongs to this parse and was
    /// built with the theme the view renders with (the strict `matches`, as
    /// `TableTextBlockView` checks it); otherwise the same builder the view
    /// falls back to. Nil for any other block.
    private func selectableTable(for block: MarkdownBlock, installedVersion: Int) -> TableText? {
        guard case .table(let headers, let rows, let alignments, let style) = block.content else { return nil }
        let scale = CGFloat(renderedFontScale)
        if installedVersion == contentVersion, let table = measured.tables[block.id],
           table.matches(headers: headers, rows: rows, alignments: alignments, style: style,
                         theme: theme, fontScale: scale) {
            return table
        }
        return TableTextBuilder.build(headers: headers, rows: rows, alignments: alignments, style: style,
                                      theme: theme, fontScale: scale)
    }

    /// The Settings default, normalized (never blank, never 0).
    private var defaultZoom: Double { DefaultZoom.normalized(defaultZoomSetting) }

    /// ⌘+ / ⌘− / ⌘0 (menu, shortcuts, the zoom pill). Announces the resulting
    /// level in the toast so the user always knows where the ladder stands;
    /// the top-right zoom pill keeps showing it while != the default.
    /// ⌘0 returns to the LIVE Settings default (`defaultZoom`), not to a fixed
    /// 100%; only the pill's visibility uses `appliedDefaultZoom`.
    private func applyZoom(_ zoom: MarkdownZoom) {
        let next = zoom.applied(to: fontScale, defaultScale: defaultZoom)
        fontScale = next
        showToast("Zoom \(Int((next * 100).rounded()))%")
    }

    // MARK: - Reading Mode

    /// ⌘⇧R (View ▸ Reading Mode) and the menu item's Exit counterpart.
    private func toggleReadingMode() {
        setReadingMode(!isReadingMode)
    }

    /// Enter or leave reading mode.
    ///
    /// The toast is shown on the way IN only, and it says how to get out: ⌘⇧R is
    /// discoverable from the menu, but a reader who has just watched every control
    /// disappear needs the answer before they start looking for it. On the way out
    /// nothing needs saying — the sidebars and pills coming back are the message.
    private func setReadingMode(_ on: Bool) {
        guard on != isReadingMode else { return }
        // Animate what is cheap to animate: the sidebars' move/opacity transitions
        // and the pills' fade. The document column re-lays out through the
        // measurer (AppKit, virtual path), which is deliberately outside this.
        // Plain assignment on purpose: an animated transaction here would also
        // reach `updateNSView` → the hosted cells' `rootView` re-assignment and
        // could animate the AppKit column's re-wrap. The sidebars and pills
        // animate through their own `.animation(value: isReadingMode)`.
        isReadingMode = on
        // While editing the first Esc leaves the editor, not Reading Mode —
        // the hint would be wrong there.
        if on { showToast(editSession.isActive ? "Reading Mode" : "Reading Mode (Esc to exit)") }
    }

    private func showToast(_ message: String) {
        withAnimation(.easeIn(duration: 0.15)) { toastText = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.3)) {
                if toastText == message { toastText = nil }
            }
        }
    }

    // MARK: - Virtualized List Plumbing

    /// Ask the virtualized list to scroll. The token — not the target — is what
    /// the coordinator acts on, so asking twice for the same block scrolls twice
    /// and an unrelated body re-evaluation scrolls not at all.
    private func requestScroll(to blockId: String, anchor: VirtualBlockList.Anchor, animated: Bool) {
        scrollRequestToken += 1
        scrollRequest = VirtualBlockList.ScrollRequest(blockId: blockId, anchor: anchor,
                                                      animated: animated, token: scrollRequestToken)
    }

    /// ⌘F next/previous: centre the block holding the focused match.
    ///
    /// Animated, like 1.8.0 (`withAnimation(.easeInOut(duration: 0.25))` around
    /// `proxy.scrollTo(_:anchor:.center)`): the 0.25 s glide is what tells the
    /// reader the document moved and roughly how far, where a jump-cut between
    /// two similar-looking passages does not. No delay before the request: the
    /// list resolves a row index directly (1.8.0 needed 50 ms for
    /// `ScrollViewProxy` to see ids already in the tree).
    private func scrollFocusedMatchIntoView() {
        guard let targetId = focusedBlockId else { return }
        requestScroll(to: targetId, anchor: .center, animated: true)
    }

    /// A placed `.reported` row told the list its real height (D3). The list has
    /// already applied it to its own copy and compensated the scroll offset; this
    /// keeps the parent's authoritative table in step, so the next wholesale
    /// replace doesn't hand back the estimate.
    private func applyHeightReport(blockId: String, row: Int, height: CGFloat) {
        // Reports can outlive the model they were measured in (a re-parse landed
        // in between) — the id at that row is the proof that they didn't.
        guard row >= 0, row < cachedBlocks.count, cachedBlocks[row].id == blockId else { return }
        let table = measured.table
        // A row the measurer sized exactly is not up for correction (the list
        // ignores such reports too — this is the same rule on the parent's side,
        // so a stale report can never overwrite an exact height).
        guard row < table.kinds.count, table.kinds[row] == .reported else { return }
        guard row < table.heights.count, abs(table.heights[row] - height) >= 0.5 else { return }
        // The block's height only: its space above stays as measured.
        measured = measured.replacingHeight(height, at: row)
    }

    /// Recompute focusedBlockId and focusedOccInBlock from currentMatchIndex
    private func updateFocusState() {
        let focus = DocumentSearch.focus(in: matchBlockIds, at: currentMatchIndex)
        focusedBlockId = focus?.blockId
        focusedOccInBlock = focus?.occurrence
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

    /// A new parse landed (or its first height table): re-count the current
    /// term over the new blocks without moving the document. Nothing to do
    /// when the find bar is empty, or when a keystroke is still debounced —
    /// that run reads `cachedBlocks` when it fires, so it already searches
    /// this parse, and it keeps its own "first match + scroll" landing. A
    /// typing run already in flight is superseded here (its blocks are
    /// stale), so this run inherits its landing.
    private func rerunSearchAfterReparse() {
        guard !searchText.isEmpty, searchDebounce == nil else { return }
        updateMatchResults(for: searchText,
                           trigger: searchInFlight == .termChanged ? .termChanged : .reparsed)
    }

    private func updateMatchResults(for term: String, trigger: DocumentSearch.Trigger) {
        searchGeneration += 1
        guard !term.isEmpty else {
            searchInFlight = nil
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
        searchInFlight = trigger
        let blocks = cachedBlocks
        // Every block is counted on the string its view shows; the measurer's
        // strings are reused (nothing rebuilt per keystroke) when they belong
        // to these blocks. `measured` is replaced in the same transaction as
        // `cachedBlocks` (or by the version-checked heights task), so a table
        // of the same length is this parse's; `computeMatches` additionally
        // checks each table string against its block.
        let measuredBlocks = measured
        let converted = measuredBlocks.table.count == blocks.count ? measuredBlocks.converted : [:]
        let currentTheme = theme
        let scale = CGFloat(renderedFontScale)
        Task.detached(priority: .userInitiated) {
            let results = DocumentSearch.computeMatches(in: blocks, term: term, converted: converted,
                                                        tables: measuredBlocks.tables,
                                                        theme: currentTheme, fontScale: scale)
            await MainActor.run {
                guard generation == searchGeneration else { return }
                searchInFlight = nil
                let count = results.matchBlockIds.count
                matchBlockIds = results.matchBlockIds
                // Read at landing, not at dispatch: ⌘G may have moved it.
                currentMatchIndex = DocumentSearch.focusedIndex(after: trigger, previous: currentMatchIndex,
                                                                matchCount: count)
                updateFocusState()
                if DocumentSearch.scrollsToFocus(after: trigger, matchCount: count) {
                    scrollTrigger += 1
                }
            }
        }
    }

    private func handleLinkActivation(_ url: URL) {
        // In-document link (`#install`, #43). Never a file: it used to resolve
        // to the document's folder and open it in Finder.
        if let fragment = HeadingAnchors.inDocumentFragment(of: url) {
            followAnchor(fragment)
            return
        }

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
            // Middle-truncated: a document can carry a multi-megabyte URL
            // (a `data:` link, #32) and an alert does not scroll.
            alert.informativeText = "This link opens another application:\n"
                + DisplayString.middleTruncated(url.absoluteString, maxLength: 200)
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
            // This very document with a fragment (`README.md#install` inside
            // README.md) is the same jump as `#install`
            if let fragment = url.fragment(percentEncoded: false),
               finalURL.standardizedFileURL.path == documentURL.standardizedFileURL.path {
                followAnchor(fragment)
                return
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

    /// Scrolls to the heading an in-document link names, as a ToC click does
    /// (`HeadingAnchors.target`: `#` and an unclaimed `#top` are the top); an
    /// id no heading has beeps.
    private func followAnchor(_ fragment: String) {
        let renderer = MarkdownRenderer(theme: theme, fontScale: CGFloat(renderedFontScale))
        let headings = HeadingAnchors.headings(of: cachedBlocks, renderer: renderer)
        switch HeadingAnchors.target(forFragment: fragment, in: headings) {
        case .heading(let id):
            selectHeading(id)
        case .top where !cachedBlocks.isEmpty:
            requestScroll(to: cachedBlocks[0].id, anchor: .top, animated: true)
        case .top, .none:
            NSSound.beep()
        }
    }

}

// MARK: - System appearance

/// Reports the SYSTEM's light/dark choice (`NSApp.effectiveAppearance`, which a
/// window's own `preferredColorScheme` does not change) now and whenever it
/// changes — Auto at sunset, a switch in System Settings. An NSView subclass,
/// like `WindowConfigurator`'s, so the observation starts on the main thread
/// on every SDK (CI builds with an older one, where a View's methods are
/// nonisolated).
struct SystemColorSchemeReader: NSViewRepresentable {
    let onChange: (ColorScheme) -> Void

    func makeNSView(context: Context) -> NSView { ObserverView(onChange: onChange) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ObserverView: NSView {
        private let onChange: (ColorScheme) -> Void
        private var observation: NSKeyValueObservation?

        init(onChange: @escaping (ColorScheme) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, observation == nil else { return }
            observation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, change in
                guard let appearance = change.newValue else { return }
                let scheme: ColorScheme = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
                Task { @MainActor in self?.onChange(scheme) }
            }
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
