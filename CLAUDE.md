# CLAUDE.md - QuickMD Agent Handoff Document

> **Last Updated:** January 22, 2026
> **Current Version:** 1.2 (Build 1)
> **Status:** Ready for Release

---

## Quick Reference

| Item | Value |
|------|-------|
| Bundle ID | `pl.falami.studio.QuickMD` |
| Min macOS | 14.0 (Sonoma) |
| Swift | 5.9+ |
| Architecture | Universal (arm64 + x86_64) |
| App Size | ~2MB |
| UTType | `net.daringfireball.markdown` |

---

## Project Overview

QuickMD is a native macOS Markdown viewer - the "Preview.app equivalent for Markdown files". Built with SwiftUI, it prioritizes:
- **Speed**: Instant launch, no Electron
- **Privacy**: Zero analytics, fully offline
- **Simplicity**: Read-only viewer, not an editor

**Distribution:**
- **App Store**: With Tip Jar (IAP) - uses `APPSTORE` flag
- **GitHub**: With donation links (Buy Me a Coffee, Ko-fi)

---

## Directory Structure

```
markdown-reader-MacOS/
├── CLAUDE.md                    # This file
├── QuickMD/                     # Main Xcode project
│   ├── QuickMD.xcodeproj/
│   ├── QuickMD/                 # Source files
│   │   ├── QuickMDApp.swift           # App entry point
│   │   ├── MarkdownDocument.swift     # FileDocument conformance
│   │   ├── MarkdownView.swift         # Main content view (196 lines)
│   │   ├── MarkdownRenderer.swift     # Inline formatting parser
│   │   ├── MarkdownTheme.swift        # Colors + regex patterns
│   │   ├── MarkdownBlock.swift        # Block type enum
│   │   ├── MarkdownBlockParser.swift  # Block-level parser
│   │   ├── MarkdownExport.swift       # PDF/Print export
│   │   ├── TipJarManager.swift        # StoreKit 2 IAP
│   │   ├── TipJarView.swift           # Tip Jar UI
│   │   └── Views/                     # Extracted components
│   │       ├── TableBlockView.swift   # Table rendering
│   │       ├── CodeBlockView.swift    # Syntax highlighting
│   │       └── ImageBlockView.swift   # Image loading
│   ├── RELEASE-v1.1.md          # Release notes & checklist
│   └── TODO.md                  # Feature backlog
└── quickmd-landing-page-docs/   # Next.js landing page
    └── quickmd-landing/
```

---

## Build Commands

### Development Build (GitHub version)
```bash
cd /Volumes/@Basic/Projekty/markdown-reader-MacOS/QuickMD
xcodebuild -project QuickMD.xcodeproj -scheme QuickMD -configuration Release build

# Run the built app
open ~/Library/Developer/Xcode/DerivedData/QuickMD-*/Build/Products/Release/QuickMD.app
```

### App Store Build (with Tip Jar)
```bash
xcodebuild -project QuickMD.xcodeproj -scheme QuickMD \
  -configuration Release \
  OTHER_SWIFT_FLAGS="-D APPSTORE" \
  archive -archivePath QuickMD-v1.2.xcarchive
```

### Archive for Distribution
```bash
# Archive
xcodebuild -project QuickMD.xcodeproj -scheme QuickMD \
  -archivePath QuickMD.xcarchive archive

# Then use Xcode Organizer: Window → Organizer → Distribute App
```

### Landing Page
```bash
cd quickmd-landing-page-docs/quickmd-landing
npm install && npm run dev    # Dev server at localhost:3000
npm run build                 # Production build
```

---

## Compiler Flags

### `APPSTORE`
Controls App Store vs GitHub distribution features:

```swift
#if APPSTORE
// Tip Jar (StoreKit 2 IAP)
TipJarView()
#else
// External donation links
Link("Buy Me a Coffee", destination: coffeeURL)
Link("Ko-fi", destination: kofiURL)
#endif
```

**Usage:** Add `-D APPSTORE` to `OTHER_SWIFT_FLAGS` for App Store builds.

---

## Architecture Deep Dive

### Markdown Parsing Pipeline

```
┌─────────────────┐     ┌──────────────────────┐     ┌─────────────────┐
│  Raw .md text   │ ──▶ │ MarkdownBlockParser  │ ──▶ │ [MarkdownBlock] │
└─────────────────┘     └──────────────────────┘     └─────────────────┘
                                                              │
                        ┌─────────────────────────────────────┼─────────────────┐
                        ▼                   ▼                 ▼                 ▼
                   .text(...)         .table(...)      .codeBlock(...)    .image(...)
                        │                   │                 │                 │
                        ▼                   ▼                 ▼                 ▼
              MarkdownRenderer      TableBlockView    CodeBlockView    ImageBlockView
              (inline formatting)   (alignment,       (syntax          (relative
               bold, italic, etc.)   cell markdown)    highlighting)    paths)
```

### MarkdownBlock Enum
```swift
enum MarkdownBlock: Identifiable {
    case text(index: Int, AttributedString)
    case table(index: Int, headers: [String], rows: [[String]], alignments: [TextAlignment])
    case codeBlock(index: Int, code: String, language: String)
    case image(index: Int, url: String, alt: String)
}
```

### Key Protocols

**TableAlignmentProvider** - Shared alignment logic for screen and print:
```swift
protocol TableAlignmentProvider {
    var alignments: [TextAlignment] { get }
}
extension TableAlignmentProvider {
    func alignmentFor(_ index: Int) -> Alignment { ... }
    func textAlignmentFor(_ index: Int) -> TextAlignment { ... }
}
```

### Regex Patterns (MarkdownTheme.swift)
All patterns centralized as static constants:
- `tableSeparatorPattern` - `|---|---|`
- `headerPattern` - `# H1` through `###### H6`
- `horizontalRulePattern` - `***`, `---`, `___`
- `imagePattern` - `![alt](url)`
- `taskListPattern` - `- [ ]` and `- [x]`
- `autolinkPattern` - bare `https://` URLs
- `setextH1Pattern` / `setextH2Pattern` - underlined headers
- `escapableChars` - characters escapable with `\`

---

## Version History

### v1.2 (Build 1) - January 2026
**Status:** Ready for Release

**Performance Optimizations:**
- Stable block identifiers (index-based instead of hash-based)
- Cached `MarkdownTheme` instances (light/dark singletons)
- Optimized `MarkdownRenderer` initialization (stored property vs computed)
- Removed `GeometryReader` from `TableBlockView` (inline dividers)
- Image downsampling for local files (max 1200px via ImageIO)

**Technical Changes:**
- `MarkdownBlock` enum now includes `index` parameter for stable identity
- `MarkdownTheme.cached(for:)` static method for cached instances
- `ImageBlockView` uses async loading with `CGImageSourceCreateThumbnailAtIndex`

### v1.1 (Build 6) - January 2026
**Status:** Released on App Store

**New Features:**
- Escape characters (`\*` → literal `*`)
- Markdown formatting in table cells (bold, italic, code, links)
- Table column alignment (`:---`, `:---:`, `---:`)
- Relative image paths (`./images/pic.png`)
- URL autolinking (bare `https://` becomes clickable)
- Setext-style headers (`===` and `---` underlines)

**Code Refactoring:**
- Extracted components from MarkdownView.swift (641 → 196 lines)
- Created Views/ folder with TableBlockView, CodeBlockView, ImageBlockView
- Created MarkdownBlock.swift and MarkdownBlockParser.swift
- Added TableAlignmentProvider protocol (DRY)
- Added documentation to all regex patterns

**Bug Fixes:**
- Fixed table column alignment parsing (was checking colons AFTER removing dashes)
- Fixed print/PDF export black page issue

### v1.0 (Build 4) - January 2026
- Initial App Store release
- Tip Jar IAP
- Basic markdown rendering

---

## Known Issues & Gotchas

### Table Alignment Parsing
**Critical:** Must check for colons BEFORE removing dashes:
```swift
// CORRECT:
let hasLeft = t.hasPrefix(":")
let hasRight = t.hasSuffix(":")

// WRONG (causes all columns to center):
let stripped = t.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
let hasLeft = stripped.hasPrefix(":")  // ":" matches both!
```

### Old Build Artifacts
DerivedData can have stale builds. If features aren't working:
```bash
# Check for old build folders
ls -la /Volumes/@Basic/Projekty/markdown-reader-MacOS/QuickMD/build/

# Delete if exists
rm -rf /Volumes/@Basic/Projekty/markdown-reader-MacOS/QuickMD/build/

# Clean DerivedData
rm -rf ~/Library/Developer/Xcode/DerivedData/QuickMD-*
```

### App Store Connect Upload
- Build numbers must be unique per version
- If upload fails with "already exists", increment `CURRENT_PROJECT_VERSION` in project.pbxproj
- Server errors ("Bad Gateway", "Failed to retrieve") are usually temporary - retry

---

## Testing Checklist

### Markdown Features
- [ ] Headers (ATX `#` and Setext `===`)
- [ ] Bold, italic, strikethrough
- [ ] Links and autolinks
- [ ] Images (absolute, relative, URL)
- [ ] Code blocks with syntax highlighting
- [ ] Tables with alignment
- [ ] Markdown in table cells
- [ ] Escape characters
- [ ] Task lists
- [ ] Blockquotes
- [ ] Horizontal rules

### App Features
- [ ] Dark mode / Light mode
- [ ] Print (Cmd+P)
- [ ] PDF Export
- [ ] Tip Jar (APPSTORE build only)

### Test File
Use `QuickMD/RELEASE-v1.1.md` - contains examples of all features.

---

## Git Workflow

### Release Process
```bash
# Commit changes
git add -A
git commit -m "v1.1: Enhanced Markdown rendering"

# Tag release
git tag -a v1.1 -m "QuickMD v1.1 - Enhanced Markdown Rendering"

# Push with tags
git push origin main --tags

# Update existing tag (if needed)
git tag -d v1.1
git push origin :refs/tags/v1.1
git tag -a v1.1 -m "QuickMD v1.1"
git push origin v1.1
```

### GitHub Release
Create release at: https://github.com/b451c/quickmd/releases

---

## App Store Connect

### Product IDs (Tip Jar)
- `pl.falami.studio.QuickMD.tip.small` - Small tip
- `pl.falami.studio.QuickMD.tip.medium` - Medium tip
- `pl.falami.studio.QuickMD.tip.large` - Large tip

### Supported File Types (Info.plist)
- `.md`
- `.markdown`
- `.mdown`
- `.mkd`

---

## Entitlements

**QuickMD.entitlements:**
- `com.apple.security.app-sandbox` - Required for App Store
- `com.apple.security.files.user-selected.read-only` - Open files
- `com.apple.security.files.user-selected.read-write` - Save PDF
- `com.apple.security.print` - Print functionality

---

## Landing Page

**Location:** `quickmd-landing-page-docs/quickmd-landing/`
**Framework:** Next.js with TypeScript
**Styling:** Tailwind CSS

Key components:
- `components/Hero.tsx` - Main hero section
- `components/Header.tsx` - Navigation
- `components/Footer.tsx` - Footer with links
- `components/CTA.tsx` - Call to action

---

## Contact & Resources

- **GitHub:** https://github.com/b451c/quickmd
- **App Store:** (search "QuickMD" on Mac App Store)
- **Developer:** Bartosz Sroczyński (pl.falami.studio)

---

## Quick Commands Reference

```bash
# Build and run
cd /Volumes/@Basic/Projekty/markdown-reader-MacOS/QuickMD
xcodebuild -project QuickMD.xcodeproj -scheme QuickMD -configuration Release build
open ~/Library/Developer/Xcode/DerivedData/QuickMD-*/Build/Products/Release/QuickMD.app

# Open project in Xcode
open QuickMD/QuickMD.xcodeproj

# Check git status
git status

# View recent commits
git log --oneline -10
```
