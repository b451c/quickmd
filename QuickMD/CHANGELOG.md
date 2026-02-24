# Changelog

All notable changes to QuickMD will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.2] - 2026-02-24

### Added
- **Local Markdown Navigation:** Clicking a link to another local `.md`, `.markdown`, `.mdown`, or `.mkd` file from within a document now automatically opens the target file inside a new QuickMD window, bypassing default system editors.
- **Space Character URL Parsing:** Proper percent-encoding is now explicitly layered into the MarkdownRenderer, fixing a bug where links with spaces in their paths/titles would fail to parse or activate.

### Fixed
- **Missing File -> Open Menu:** Restored the native `File -> Open` and `File -> Open Recent` macOS menu items that were previously hidden/replaced by an empty CommandGroup.
- **App Sandbox Constraints (Error -50):** Added the `com.apple.security.temporary-exception.files.home-relative-path.read-only` entitlement (root `/`). This fixes the "Operation not permitted" bugs where the macOS sandbox previously blocked the renderer from accessing local images (`![alt](local.png)`) or adjacent local files.
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
