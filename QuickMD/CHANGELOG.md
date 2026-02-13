# Changelog

All notable changes to QuickMD will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
