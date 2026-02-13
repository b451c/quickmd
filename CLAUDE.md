# QuickMD - Agent Onboarding

## Project Overview

**QuickMD** is a native macOS Markdown viewer built with SwiftUI. It opens `.md` files instantly with no Electron overhead. Read-only by design - it renders Markdown, it does not edit it.

- **Bundle ID:** `pl.falami.studio.QuickMD`
- **Deployment target:** macOS 13.0 (Ventura)
- **Current version:** 1.3
- **Language:** Swift 5.9, SwiftUI
- **External dependencies:** None (zero third-party packages)

### Distribution Channels

| Channel | Monetization | Build flag |
|---------|-------------|------------|
| **App Store** | Free + Tip Jar (IAP) | `OTHER_SWIFT_FLAGS="-DAPPSTORE"` |
| **GitHub** | Free + donation links (BMC, Ko-fi) | Default (no flag) |

## Repository Structure

```
QuickMD/
├── QuickMD/
│   ├── QuickMDApp.swift            # @main entry, DocumentGroup, menu commands, #if APPSTORE scenes
│   ├── MarkdownDocument.swift      # FileDocument conformance, UTType.markdown
│   ├── MarkdownView.swift          # Main document view, search, support/tip buttons, #if APPSTORE UI
│   ├── MarkdownBlock.swift         # Block enum: .text, .table, .codeBlock, .image, .blockquote
│   ├── MarkdownBlockParser.swift   # Line-by-line parser → [MarkdownBlock]
│   ├── MarkdownRenderer.swift      # Inline markdown → AttributedString, search highlighting
│   ├── MarkdownTheme.swift         # ThemeName enum, stored color properties, 7 theme definitions, regex patterns
│   ├── MarkdownExport.swift        # Per-block PDF export, print, FocusedValue keys for multi-window
│   ├── TipJarManager.swift         # StoreKit 2 IAP manager (App Store only)
│   ├── TipJarView.swift            # Tip Jar window UI (App Store only)
│   ├── Views/
│   │   ├── CodeBlockView.swift     # Fenced code blocks with syntax highlighting
│   │   ├── TableBlockView.swift    # Table rendering with column alignment
│   │   ├── ImageBlockView.swift    # Local + remote image rendering
│   │   ├── BlockquoteView.swift    # Nested blockquotes with left border indicators
│   │   ├── SearchBar.swift         # Cmd+F search bar with match navigation
│   │   └── ThemePickerView.swift   # Settings UI for theme selection (Cmd+,)
│   ├── Assets.xcassets/            # App icon
│   └── QuickMD.entitlements        # App Sandbox + print/PDF entitlements
├── Screenshots/                    # App Store & README screenshots
├── CHANGELOG.md                    # Version history
├── AppStore-Metadata.md            # App Store descriptions (EN/PL)
├── demo-screenshot.md              # Demo file for taking screenshots
├── test-tables.md                  # Test file for table rendering
├── test-advanced.md                # Test file for advanced markdown features
├── test-reference-links.md         # Test file for reference-style links
└── QuickMD.xcodeproj/
```

### Root Files

```
CLAUDE.md                           # This file (project overview for agents)
DEVELOPMENT.md                      # Audit results, roadmap, agent workflow
README.md                           # GitHub README
PRIVACY.md                          # Privacy policy
LICENSE                             # MIT license
.gitignore                          # Ignores .app, .xcarchive, .zip, tool configs
```

## Build System

### GitHub Release (default)

```bash
xcodebuild -project QuickMD/QuickMD.xcodeproj \
  -scheme QuickMD \
  -configuration Release \
  -archivePath build/QuickMD-GitHub.xcarchive \
  archive
```

Opens Xcode: `open QuickMD/QuickMD.xcodeproj`, then Cmd+B.

### App Store Release

```bash
xcodebuild -project QuickMD/QuickMD.xcodeproj \
  -scheme QuickMD \
  -configuration Release \
  OTHER_SWIFT_FLAGS="-DAPPSTORE" \
  -archivePath build/QuickMD-AppStore.xcarchive \
  archive
```

The `APPSTORE` flag is **not** in the Xcode project file - it must be passed via CLI or Xcode build settings override for App Store builds.

## `#if APPSTORE` Flag Map

The flag controls which monetization UI is compiled:

| File | Lines | What it controls |
|------|-------|-----------------|
| `QuickMDApp.swift` | 32-47 | Menu: Tip Jar button (App Store) vs donation links (GitHub) |
| `QuickMDApp.swift` | 52-57 | Tip Jar window scene (App Store only) |
| `QuickMDApp.swift` | 61-71 | `TipJarMenuButton` struct (App Store only) |
| `MarkdownView.swift` | ~47-55 | Floating button: `TipJarButton` (App Store) vs `SupportButton` (GitHub) |
| `MarkdownView.swift` | ~68+ | `TipJarButton` struct (App Store only) |
| `MarkdownView.swift` | ~105+ | `SupportButton` struct (GitHub only) |

**Files only compiled for App Store:** `TipJarManager.swift`, `TipJarView.swift` (referenced only from `#if APPSTORE` blocks)

## Architecture

### Data Flow

```
.md file → MarkdownDocument (FileDocument)
         → MarkdownView (main view, @AppStorage theme selection)
         → MarkdownTheme.theme(named:colorScheme:) resolves active theme
         → MarkdownBlockParser.parse() → [MarkdownBlock]  (background thread)
             Pre-pass: collects [id]: url reference definitions
             Main pass: splits into blocks, renders text with reference-aware renderer
         → ForEach renders each block:
             .text → Text(AttributedString)  ← MarkdownRenderer
             .table → TableBlockView
             .codeBlock → CodeBlockView (with syntax highlighting)
             .image → ImageBlockView (local + remote)
             .blockquote → BlockquoteView (nested, with left border)
         → SearchBar (Cmd+F) highlights matches, ScrollViewReader navigates
         → FocusedValue publishes document text for PDF/Print commands
         → PDF export renders block-by-block (always Auto Light theme)
         → Settings (Cmd+,) → ThemePickerView for theme selection
```

### Key Patterns

- **Custom parser** (not Apple's AttributedString markdown) for full control over rendering
- **Block-level parsing** (`MarkdownBlockParser`) splits into discrete blocks, then inline rendering (`MarkdownRenderer`) handles formatting within text blocks
- **Recursive inline parsing** - bold/italic markers recursively parse inner content for nesting
- **Custom themes** via `ThemeName` enum + `MarkdownTheme.theme(named:colorScheme:)` - 7 themes with stored color properties, persisted via `@AppStorage("selectedTheme")`
- **Reference-style links** - parser pre-pass collects `[id]: url` definitions, renderer resolves `[text][id]`, `[text][]`, `[text]` formats
- **Static regex compilation** - all regex patterns compiled once at type level
- **Syntax highlighting** with range exclusion (strings > comments > keywords priority)
- **FocusedValue** for multi-window document context (export/print commands)
- **Sendable conformance** on all value types for Swift 6 readiness
- **LazyVStack** for efficient rendering of large documents
- **DocumentGroup** for standard macOS document lifecycle
- **ScrollViewReader** for search result navigation (scroll-to-match)
- **NSEvent local monitor** for keyboard shortcuts (macOS 13 compatible)
- **Per-block PDF rendering** - each block rendered individually, page breaks between blocks only
- **Search highlighting** via AttributedString background color with index mapping
- **Double-backtick inline code** - `` ``code with ` backtick`` `` per CommonMark spec

## Monetization

### App Store Version (IAP)

Product IDs:
- `pl.falami.studio.QuickMD.tip.small`
- `pl.falami.studio.QuickMD.tip.medium`
- `pl.falami.studio.QuickMD.tip.large`

### GitHub Version (donation links)

- Buy Me a Coffee: `https://buymeacoffee.com/bsroczynskh`
- Ko-fi: `https://ko-fi.com/quickmd`
- Website: `https://qmd.app/`

## Release Process

1. Update `MARKETING_VERSION` in `project.pbxproj`
2. Update `CURRENT_PROJECT_VERSION` (build number)
3. Update `CHANGELOG.md`
4. Commit: `v{X.Y}: Description`
5. Tag: `git tag v{X.Y}`
6. **GitHub:** Archive default Release build, create GitHub release with zip
7. **App Store:** Archive with `OTHER_SWIFT_FLAGS="-DAPPSTORE"`, upload via Xcode Organizer

## Important Notes

- **Deployment target is macOS 13.0** (Ventura), not 14.0 - supports older Macs
- **Zero external dependencies** - no SPM packages, no CocoaPods, no Carthage
- **Read-only by design** - `FileDocument` with `readableContentTypes` only, no write support
- **App Sandbox** enabled with network client (for remote images) and print entitlements
- **No tests** - the project has no unit/UI test targets
- **Regex patterns** are defined as static strings in `MarkdownTheme` and compiled in respective files
- **Background parsing** - `MarkdownBlockParser.parse()` runs on `Task.detached` to avoid UI freezes
- **Handoff:** Read `DEVELOPMENT.md` for audit history, roadmap, and agent team methodology
