# Changelog

All notable changes to QuickMD will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3] - 2026-02-13

### Added
- **Reference-style links (D3):** Full support for `[text][id]`, `[text][]` (collapsed), and `[text]` (shortcut) reference link formats per CommonMark spec
  - Pre-pass parser collects `[id]: url` definitions from anywhere in document
  - Reference definitions are hidden from rendered output
  - Case-insensitive ID matching
- **Custom color themes (D6):** 7 selectable themes via Settings (Cmd+,)
  - Auto (follows system light/dark)
  - Solarized Light, Solarized Dark
  - Dracula
  - GitHub
  - Gruvbox Dark
  - Nord
  - Theme selection persists across app restarts (`@AppStorage`)
  - Color bar preview for each theme in Settings picker
  - PDF/Print always renders in light theme (independent of selection)

### Changed
- `MarkdownTheme` refactored from computed properties to stored `let` properties with static theme instances
- `MarkdownRenderer` and `MarkdownBlockParser` accept `MarkdownTheme` directly (convenience `colorScheme:` init kept for export code)
- `ThemeName` enum (`CaseIterable`, `Sendable`) drives theme selection
- Removed unused `renderSetextHeader()` dead code from parser

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
