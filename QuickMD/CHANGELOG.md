# Changelog

All notable changes to QuickMD will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Document layout rebuilt on a native virtualized list:** The document body is now an AppKit table of blocks with exact, pre-measured heights (text, quotes, alerts and code are measured off the main thread with the same TextKit layout the views use; headings, tables, math, images and diagrams settle once when they appear). Every document size takes the same path — no more lazy-stack size estimation for large files — so wheel scrolling can no longer live-lock, Table of Contents and search jumps land exactly, and the reading position is preserved across zoom, theme changes, window/sidebar resizes and auto-reload. The 1.8.0 layout remains available for one release via `defaults write pl.falami.studio.QuickMD QMDLegacyBlockLayout -bool YES`.
- **Edit / Copy pills:** hovering the top-right pills no longer shoves the neighbouring pill out from under the pointer — a pill expands when the pointer touches it and every touched pill stays open until the pointer leaves the group. Contributed by [@Coriou](https://github.com/Coriou) (#20).

### Added
- **Zoom indicator:** ⌘+ / ⌘− / ⌘0 announce the new level ("Zoom 120%"), and while a document is zoomed a small "120%" pill sits next to Edit / Copy — hover shows "Reset zoom", click returns to 100%.
- Table of Contents entries highlight on hover, matching the Recent Documents sidebar.
- The Export as PDF panel suggests the document's file name instead of "document.pdf".

### Fixed
- **Math in PDF and print:** display math (`$$…$$`) exported as a yellow placeholder and inline `$…$` as raw source since the vector PDF export (1.7.0). Both now render as typeset math — display math centred, inline math sitting on the text baseline.
- Blank lines between two blockquotes (or any two non-text blocks) no longer render as an empty ~42 pt text block.
- Support pill (GitHub build) keeps its dimmed idle state after the pill refactor.

## [1.8.0] - 2026-08-15

### Added
- **Custom Fonts:** Settings (⌘,) gains a **Fonts** tab — pick any installed font family for body text and another for code (JetBrains Mono, Fira Code, a serif for long reads…). The choice applies to every open document, print and PDF export; font size and ⌘+/⌘− zoom are unaffected, and the app's own controls keep the system font. Custom themes can carry their own typography with two new optional keys, `bodyFontFamily` and `codeFontFamily`, which take precedence over the Settings choice; a family that isn't installed is reported in the theme picker and falls back to the system font, so the theme still loads. Requested by [@cloud-on-prem](https://github.com/cloud-on-prem) (#18).

### Fixed
- **Freeze while scrolling:** Scrolling a document up and down with the mouse wheel could lock the window at 100 % CPU (an endless SwiftUI layout loop in the lazy block list, present since 1.6.0 but rare). Documents up to 256 KB now lay out eagerly, block heights are measured synchronously instead of being fed back through view state, and blockquote bars no longer sit in a stack that re-negotiates the text width — verified with an automated wheel-scroll harness across every test document.

### Changed
- **Soft Line Breaks (behavior change):** A single newline inside a paragraph now renders as a space, as CommonMark and GitHub do, instead of a visible line break — documents written one sentence per line read as flowing paragraphs, and wrapped list-item text stays inside the item with its hanging indent. Hard breaks still work: end the line with two spaces or a backslash. Headings, rules and blank lines never join. Applies to paragraphs, blockquotes and alerts, on screen and in PDF/print alike. Contributed by [@shmuelzon](https://github.com/shmuelzon) (#19).

## [1.7.0] - 2026-07-27

A community release: two features and two fixes in this version arrived as pull requests from [@shmuelzon](https://github.com/shmuelzon), and the vector PDF upgrade plus the window-size suggestion came from [@weiykong](https://github.com/weiykong). Thank you both!

### Added
- **Zoom (⌘+ / ⌘- / ⌘0):** Scale the rendered document per window from the View menu — headings, body text, tables, code blocks, math and footnotes all follow, search highlighting included. Every document opens at 100%; zooming one tab leaves the others alone. Contributed by @shmuelzon (#15).
- **GitHub-Flavored Alerts:** `> [!NOTE]`, `> [!TIP]`, `> [!IMPORTANT]`, `> [!WARNING]` and `> [!CAUTION]` render as native callouts — icon, accent title, colored bar and tinted background in GitHub's palette — with full text selection, search, zoom and PDF support. Regular blockquotes, unknown markers and nested quotes are untouched.
- **Mermaid Diagrams in PDF Export:** Exported PDFs now embed rendered diagrams as images instead of falling back to code blocks. Diagrams already shown in the window export instantly; the rest render in the background during export. A diagram that fails to render keeps the readable code-block fallback.
- **Remember Window Size:** New document windows open at the size you last used instead of a fixed 800×600 (clamped to the screen; tabs keep adopting their host window's frame). Suggested by @weiykong (#13).

### Changed
- **Vector PDF Export:** PDF export draws real vector text instead of rasterized images — sharp at any zoom, fully selectable and searchable, with embedded font subsets, and smaller files. Pagination and the slicing of blocks taller than one page are preserved. Contributed by @weiykong (#14).

### Fixed
- **Headerless Tables:** Tables with an all-empty header row (`| | |` — the definition-list idiom) vanished entirely; the separator row now defines the column count and the empty header band is skipped. Contributed by @shmuelzon (#16).
- **List Indentation:** List items now sit in a proper gutter and wrapped lines hang under the item text instead of falling back to the bullet's margin. Wider markers ("10.") hang correspondingly further, nesting works for both 2-space and 4-space documents, and the indents follow the zoom level. Contributed by @shmuelzon (#17).

## [1.6.0] - 2026-06-12

### Added
- **File Auto-Reload:** QuickMD now watches every open document and reloads it automatically when the file changes on disk — edit in your editor, save, and the preview is instantly current. Handles atomic saves (VS Code, Zed, Sublime, vim) and debounces rapid writes. If the file is moved or deleted, a banner appears instead of a stale view. **Tip:** enable auto-save in your editor (e.g. VS Code `Files: Auto Save → afterDelay`) and QuickMD becomes a practical live preview.
- **Open in External Editor (⌘E):** One-click handoff of the current document to your editor — toolbar pencil button or File → Open in External Editor. Settings (⌘,) gains an Editor tab that auto-detects installed editors (VS Code, Cursor, Sublime Text, Zed, Typora, Obsidian, Nova, BBEdit, MacDown, iA Writer), with System Default and any-app fallback. Never bounces back into QuickMD.
- **Copy Button on Code Blocks:** Hover any code block and click the copy button — the single most common action on documentation code.
- **Mermaid Diagram Zoom:** Hover a diagram and click the zoom button to open it in a resizable viewer with pinch-to-zoom and zoom buttons (requested in #12).

### Performance
- **Large Documents Open Instantly (Issues #10, #11):** Text, blockquote and footnote blocks now render through native `NSTextView` (like code blocks since 1.5.0), which removes the last SwiftUI text-selection overlay from the document layout — the main view is lazily rendered again. Verified on an 11,700-line document: no main-thread freeze on open, 0 SelectionOverlay frames during fast scroll, ~92 MB memory after open (the v1.3.3-era pathology peaked at 890 MB). Inline `$...$` math renders via native text attachments; text selection inside paragraphs, quotes and code is native AppKit selection.
- **No Diagram Flicker While Scrolling:** Rendered Mermaid diagrams are snapshotted; scrolling back to one shows it instantly instead of re-running the web renderer.

### Security
- **Mermaid Diagram Hardening:** Diagram source now reaches the rendering WebView as JSON-encoded data via `evaluateJavaScript` instead of being concatenated into the page HTML. A crafted code block containing `</script>` could previously inject arbitrary markup into the diagram view; it is now inert data.
- **Custom URL Scheme Confirmation:** Links using non-web schemes (`shortcuts:`, `ssh:`, `vnc:`, …) now show a confirmation dialog before handing control to another application. Web (`http`/`https`/`mailto`) and file links open as before.

### Fixed
- **Windows Line Endings (CRLF):** Files saved with CRLF or classic-Mac CR line endings now parse identically to LF files. Previously a stray `\r` broke single-line `$$math$$` detection (swallowing the rest of the document) and silently killed Mermaid rendering.
- **Setext H2 Headings:** Text underlined with `---` now renders as a level-2 heading per CommonMark. The branch existed but was unreachable due to a redundant table-separator guard.
- **Section Copy Accuracy:** "Copy section" boundaries now come from parser-assigned source lines. Previously a re-scan of the raw text counted `#` comment lines inside fenced code blocks as headings and could copy the wrong section (or nothing).
- **PDF Export Clipping:** Blocks taller than one page (long code blocks) are sliced across pages instead of being silently cut off.
- **Check for Updates Feedback:** The menu item now shows a transient "You're up to date" / "check failed" state instead of appearing to do nothing.
- **Custom Theme Validation:** Theme JSON with an invalid hex color (or a name colliding with a built-in theme) is rejected with a clear error in Settings instead of silently rendering black.

### Added
- **YAML Frontmatter:** Documents starting with a `---` fence (Jekyll/Hugo/Obsidian convention) render the frontmatter as a neutral `yaml` code block.
- **Encoding Fallbacks:** Non-UTF-8 files now fall back to UTF-16 (BOM-detected), then Latin-1, instead of failing to open.
- **Unit Test Suite & CI:** 65 automated tests covering the parser, renderer, search, section copy, document decoding, and theme validation; GitHub Actions builds (incl. the App Store flavor) and runs tests on every push/PR.

### Changed
- **Faster Search on Large Documents:** Match computation moved off the main thread (with stale-result dropping), so typing in the find bar no longer hitches on 10K-line documents.
- **Faster Open for Code-Heavy Documents:** Syntax highlighting is computed in the background per code block; blocks show plain monospaced text for a moment instead of blocking the first paint.

## [1.5.0] - 2026-05-05

### Added
- **Custom Themes from Disk:** Drop your own theme JSON into `~/Library/Application Support/QuickMD/Themes/` and it appears under a **Custom** section in the picker. Live reload — no app restart. Settings panel adds **Import Theme…** (sandbox-safe NSOpenPanel), **Open Themes Folder**, and **Reload** buttons. See `docs/themes/` for the schema and starter palettes (Issue #9, requested by @cameronsjo).
- **Recent Documents Sidebar:** Optional left sidebar listing every document opened in this session. Click a row to re-open. Drag the right edge to resize (160–500pt, persisted). Hover a row to remove it; **trash** icon clears the list. Toggle via menu **Edit → Recent Documents (⇧⌘D)** or the floating sidebar button. Originally contributed by [@COSMAX-JYP](https://github.com/COSMAX-JYP/quickmd) and refined for QuickMD.

### Changed
- **Code Block Rendering — NSTextView:** Code blocks now render through `NSTextView` (via `NSViewRepresentable`) instead of SwiftUI `Text(AttributedString)`. Native macOS line layout, native selection with auto-scroll-during-drag, and zero risk of the box-drawing-Unicode SwiftUI bug that previously required eager `VStack` rendering.
- **Large Document Optimizations:** Long bullet/link lists are chunked at blank-line boundaries (≤30 lines per block) and per-text-block metadata is precomputed during background parsing, reducing open and resize cost on large documents (Issue #10, reported by @cameronsjo). *Correction (2026-06-12): this entry previously claimed the layout "switched back to `LazyVStack`" and that 10K-line files "open instantly" — that change was attempted, hit a second SwiftUI issue, and was reverted before release. The layout remains eager pending a full NSTextView migration; Issue #10 stays open.*
- **Search Debounce:** A 150 ms debounce on search input avoids redundant per-keystroke recomputes when typing fast in the find bar; the empty-string clear remains instant.

### Fixed
- **Theme Switch Cost on Code-Heavy Documents:** Code block highlighting is cached per (theme, code) pair with identity short-circuiting in `updateNSView`, so switching themes no longer recomputes every code block from scratch.

## [1.4.1] - 2026-04-03

### Added
- **Inline Math:** Single-dollar `$...$` expressions now render as TeX-quality graphics inline with paragraph text — fractions, integrals, superscripts all render within a sentence.
- **Footnotes:** `[^id]` references render as superscript numbers with definitions listed at the end of the document.
- **Homebrew Cask:** Added `quickmd.rb` formula for `brew install --cask quickmd`.

## [1.4.0] - 2026-04-03

### Added
- **LaTeX Math Rendering:** Display math blocks (`$$...$$`) are now rendered with TeX-quality typography via vendored SwiftMath library. Supports fractions, integrals, matrices, sums, and all standard LaTeX math notation.
- **Mermaid Diagram Rendering:** Fenced code blocks with `mermaid` language tag are now rendered as interactive diagrams — flowcharts, sequence diagrams, pie charts, class diagrams, and more. Powered by bundled Mermaid.js.

### Fixed
- **Dead App Store Link:** Updated the Mac App Store link in README to the correct app ID.

## [1.3.3] - 2026-03-25

### Added
- **Folder Access for Local Images:** QuickMD now prompts for folder access when a local image can't be loaded due to sandbox restrictions. Access is persisted via Security-Scoped Bookmarks — the prompt only appears once per folder.
- **Persistent Table of Contents:** The ToC sidebar state now persists across app launches and new documents.
- **Check for Updates:** GitHub version now shows "Check for Updates" in the Help menu, with a subtle notification when a new version is available.

### Fixed
- **Scroll Freeze on Complex Code Blocks:** Fixed a UI freeze caused by SwiftUI's `LazyVStack` repeatedly creating/destroying views containing box-drawing Unicode characters during fast scrolling.
- **Cmd+W to Close:** Restored the standard macOS Close Window shortcut that was accidentally removed by a CommandGroup override.

## [1.3.2] - 2026-02-24

### Added
- **Local Markdown Navigation:** Clicking a link to another local `.md`, `.markdown`, `.mdown`, or `.mkd` file from within a document now automatically opens the target file inside a new QuickMD window, bypassing default system editors.
- **Space Character URL Parsing:** Proper percent-encoding is now explicitly layered into the MarkdownRenderer, fixing a bug where links with spaces in their paths/titles would fail to parse or activate.

### Fixed
- **Missing File -> Open Menu:** Restored the native `File -> Open` and `File -> Open Recent` macOS menu items that were previously hidden/replaced by an empty CommandGroup.
- **Local Document Routing:** Fixed the routing layer for relative document links (`./other.md`); these are now resolved dynamically against the originating document's directory.

## [1.3.1] - 2026-02-13

### Added
- **Copy to Clipboard:** Copy entire raw markdown with `⌘⇧C` or the "Copy source" button (top-right)
- **Copy sections:** Hover-to-reveal copy icon next to each heading in the main content and ToC sidebar
- **Search highlighting in all block types:** Word-level highlighting now works inside code blocks, tables, and blockquotes (not just text and headings)
- **Per-occurrence search navigation:** Arrow keys navigate between individual word occurrences, not just blocks. Counter shows exact match count (e.g., "5/19" for 19 individual words)
- **Focused match distinction:** Current match highlighted in orange, all others in yellow

### Fixed
- **Critical performance fix:** `MarkdownBlock` converted from enum to struct with stored `let id`. SwiftUI's `LazyVStack` called the computed `id` getter thousands of times during layout — each call copied the entire enum (including `AttributedString`) and allocated a new String, causing 100% CPU hangs during scrolling
- **Search navigation performance:** Pre-computed yellow highlight cache for text blocks + dedicated `@State` for focus tracking. Arrow key clicks now recompute highlighting for only 1 block instead of all visible blocks
- **Optimized `searchHighlight`:** Replaced dictionary-based index mapping with single-pass parallel iteration — eliminates thousands of hash insertions per call

### Changed
- `MarkdownBlock` is now a struct wrapping `BlockContent` enum (stored `id` instead of computed)
- `MarkdownExport` updated for new `block.content` pattern matching
- Toast "Copied!" feedback for all copy operations (1.5s fade)

## [1.3] - 2026-02-13

### Added
- **Find & Search (D5):** `⌘F` search with match highlighting and navigation
  - SearchBar with match counter ("1/5"), `⌘G` / `⇧⌘G` next/previous, Escape to close
  - Yellow highlight on matches via AttributedString index mapping
  - `ScrollViewReader` scrolls to matched blocks
  - `NSEvent.addLocalMonitorForEvents` for macOS 13 keyboard shortcut compatibility
- **Nested blockquotes (D2):** Full blockquote support with nesting levels
  - New `.blockquote(index, content, level)` block type
  - `BlockquoteView` with left border indicator per nesting level
  - `PrintableBlockquoteView` for PDF/print export
- **Double-backtick inline code (D1):** `` ``code with ` backtick`` `` per CommonMark spec
  - Backtick count matching, leading/trailing space stripping
- **Per-block PDF export (C4):** Redesigned multi-page PDF rendering
  - Each block rendered individually via `ImageRenderer`
  - Page breaks only between blocks (no mid-block splits)
  - `MarkdownPrintableBlockView` for single-block rendering
- **Table of Contents (D4):** Sidebar with document headings (`⌘⇧T`)
  - Auto-generated from H1-H6 headings
  - Click-to-navigate with `ScrollViewReader`
  - Font size/weight scaled by heading level
  - `TableOfContentsView` with `ToCEntry` model
- **Reference-style links (D3):** Full CommonMark reference link support
  - `[text][id]`, `[text][]` (collapsed), `[text]` (shortcut) formats
  - Pre-pass parser collects `[id]: url` definitions, hides them from output
  - Case-insensitive ID matching
- **Custom color themes (D6):** 7 selectable themes via Settings (`⌘,`)
  - Auto (follows system light/dark), Solarized Light, Solarized Dark, Dracula, GitHub, Gruvbox Dark, Nord
  - `ThemePickerView` with color bar previews in Settings scene
  - `@AppStorage` persistence across app restarts
  - PDF/Print always renders in light theme (independent of selection)

### Changed
- **Background parsing:** `MarkdownBlockParser.parse()` runs on `Task.detached` to avoid UI freezes
- **MarkdownTheme** refactored from computed properties to stored `let` properties with `ThemeName` enum and static theme instances
- **MarkdownRenderer** and **MarkdownBlockParser** accept `MarkdownTheme` directly (convenience `colorScheme:` init kept for export code)
- `Color(hex:)` extension for readable theme color definitions
- Comprehensive code audit: 35 fixes across 14 files (+222/-152 LOC)
  - Sendable conformance on all value types (Swift 6 readiness)
  - FocusedValue for multi-window document context
  - Recursive inline parsing for nested bold/italic
  - Link/image parser with bracket/parenthesis depth tracking
  - Static `AppURLs` enum replacing force-unwrapped URL literals

### Fixed
- Search highlighting correctly maps String indices to AttributedString indices
- Triple-backtick in inline context renders as literal characters (not code fence)
- `⌘F` shortcut works reliably with NSEvent monitor
- Blockquote nesting level detection handles mixed `>` spacing

### Removed
- Unused `renderSetextHeader()` dead code from parser

## [1.2.1] - 2026-01-22

### Changed
- **Performance:** Cached MarkdownRenderer instance in parser (single allocation per parse)
- **Performance:** Cached syntax highlighting in CodeBlockView with smart strategy
  - Small blocks (< 500 lines): synchronous computation, zero flicker
  - Large blocks (500+ lines): async computation with graceful fallback
- **Performance:** All regex patterns now statically precompiled (9 total patterns)
- **Code Quality:** Replaced force unwrap URLs with static `AppURLs` enum constants
- **Code Quality:** Changed `@StateObject` to `@ObservedObject` for singleton TipJarManager
- **Code Quality:** Replaced `print()` with `os.Logger` in TipJarManager
- **Code Quality:** Changed computed `columnCount` to stored property in table views
- **Code Quality:** PDF export now uses cached theme instead of hardcoded colors
- **Code Quality:** Added proper error handling when PDF generation fails

### Fixed
- Remote images no longer block main thread during PDF export (graceful placeholder shown)
- MarkdownPrintableView no longer re-parses document on every body evaluation

### Security
- Zero runtime force unwraps (all URL constants validated at compile time)
- Zero synchronous network calls on main thread

## [1.2] - 2026-01-20

### Added
- Multi-page PDF export with proper pagination
- Print functionality using PDFKit
- Syntax highlighting for code blocks (Swift, Python, JavaScript, Rust, Go, etc.)

### Changed
- Performance optimizations with static regex compilation
- Theme caching for reduced allocations
- Image downsampling to 1200px for memory efficiency

## [1.1] - 2026-01-18

### Added
- Table support with column alignment (left, center, right)
- Task list support with checkboxes
- Setext-style headers (underlined with === or ---)

### Changed
- Code refactoring for better maintainability
- Fixed text alignment in tables

## [1.0] - 2026-01-15

### Added
- Initial release
- Markdown rendering with headers, lists, blockquotes
- Inline formatting: bold, italic, strikethrough, inline code
- Link and image support
- Light and dark mode support
- Tip Jar for App Store version
