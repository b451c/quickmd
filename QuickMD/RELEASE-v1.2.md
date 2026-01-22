# QuickMD v1.2 Release Notes

## Release Overview

**Version:** 1.2
**Build:** 1
**Release Date:** January 2026
**Type:** Performance Update

---

## Summary

QuickMD v1.2 is a performance-focused release that optimizes memory usage, reduces CPU overhead, and improves rendering efficiency. This update is especially beneficial for large Markdown documents with many tables and images.

---

## Performance Improvements

### 1. Stable Block Identifiers
Replaced hash-based block IDs with index-based stable identifiers.
- **Before:** IDs could change between renders, causing unnecessary view rebuilds
- **After:** IDs remain constant, SwiftUI efficiently diffs only changed content
- **Impact:** Smoother theme switching, reduced CPU usage

### 2. Cached Theme Instances
Added static cached instances for light and dark themes.
- **Before:** New `MarkdownTheme` allocated on every body evaluation
- **After:** Singleton instances reused via `MarkdownTheme.cached(for:)`
- **Impact:** Zero allocations per render cycle

### 3. Optimized Renderer Initialization
`MarkdownRenderer` is now created once per view init, not per body evaluation.
- **Before:** Computed property recreated renderer on each access
- **After:** Stored property initialized in `init()`
- **Impact:** Significant reduction in object allocations for tables

### 4. Simplified Table Layout
Replaced `GeometryReader` overlay with inline dividers in `HStack`.
- **Before:** GeometryReader caused additional layout pass
- **After:** Single-pass layout with inline `Rectangle` dividers
- **Impact:** Faster table rendering, especially with many tables

### 5. Image Downsampling
Local images are now downsampled to max 1200px before display.
- **Before:** Large images (e.g., 4K) loaded at full resolution
- **After:** ImageIO-based downsampling on background thread
- **Impact:** Up to 90% memory reduction for large local images

---

## Technical Changes

### Files Modified

| File | Changes |
|------|---------|
| `MarkdownBlock.swift` | Added `index` parameter to all cases for stable identity |
| `MarkdownBlockParser.swift` | Tracks block index during parsing |
| `MarkdownTheme.swift` | Added `cached(for:)` static method with singleton instances |
| `MarkdownView.swift` | Uses `MarkdownTheme.cached(for:)` |
| `TableBlockView.swift` | Cached renderer in init; inline dividers replace GeometryReader |
| `ImageBlockView.swift` | Added `loadDownsampledImage()` with ImageIO; async loading |
| `MarkdownExport.swift` | Updated for new block enum; cached renderer in PrintableTableView |

### API Changes

```swift
// MarkdownBlock - now includes index
enum MarkdownBlock: Identifiable {
    case text(index: Int, AttributedString)
    case table(index: Int, headers: [String], rows: [[String]], alignments: [TextAlignment])
    case codeBlock(index: Int, code: String, language: String)
    case image(index: Int, url: String, alt: String)
}

// MarkdownTheme - new cached accessor
extension MarkdownTheme {
    static func cached(for colorScheme: ColorScheme) -> MarkdownTheme
}
```

### Compatibility
- macOS 14.0 (Sonoma) or later
- Universal binary (Apple Silicon + Intel)

---

## GitHub Release

### Tag
`v1.2`

### Title
`QuickMD v1.2 - Performance Optimizations`

### Release Notes (Markdown)
```markdown
## What's New in v1.2

### Performance Improvements
- **Stable Block IDs** - Smoother re-renders when switching themes
- **Cached Themes** - Zero allocations per render cycle
- **Optimized Renderer** - Reduced object creation in tables
- **Faster Table Layout** - Single-pass rendering without GeometryReader
- **Image Downsampling** - Up to 90% memory savings for large local images

### Technical Details
This release focuses on internal optimizations with no user-facing feature changes. The app should feel snappier, especially with:
- Large Markdown documents
- Documents with many tables
- Documents with high-resolution local images
- Frequent theme switching (light/dark mode)

### Download
- **QuickMD.app.zip** - Universal binary for macOS 14.0+

---

**Full Changelog**: https://github.com/b451c/quickmd/compare/v1.1...v1.2
```

---

## App Store Connect

### What's New (Version 1.2)

**English:**
```
Performance Optimizations

This update focuses on speed and efficiency improvements:

• Faster rendering - optimized view updates and layout
• Lower memory usage - images are now downsampled for display
• Smoother theme switching - stable identifiers prevent flicker
• Better table performance - simplified layout calculations

No new features - just a faster, leaner QuickMD.
```

**Polish:**
```
Optymalizacje Wydajności

Ta aktualizacja skupia się na poprawie szybkości i efektywności:

• Szybsze renderowanie - zoptymalizowane aktualizacje widoków i układ
• Mniejsze zużycie pamięci - obrazy są teraz skalowane do wyświetlania
• Płynniejsze przełączanie motywu - stabilne identyfikatory zapobiegają migotaniu
• Lepsza wydajność tabel - uproszczone obliczenia układu

Brak nowych funkcji - tylko szybszy i lżejszy QuickMD.
```

### Review Notes for Apple
```
QuickMD v1.2 is a performance-focused update with no new features.

Changes in this version:
- Optimized view rendering with stable block identifiers
- Cached theme instances to reduce allocations
- Improved table layout without GeometryReader
- Added image downsampling for local files (max 1200px)

To test:
1. Open a large Markdown file with tables
2. Switch between light and dark mode
3. Verify smooth scrolling and theme transitions
4. Open a document with large local images

No new permissions required. No network access changes.
Tip Jar (In-App Purchase) unchanged.
```

---

## Pre-Release Checklist

### Version Numbers
- [x] Update MARKETING_VERSION to 1.2
- [x] Update CURRENT_PROJECT_VERSION to 1

### Build & Test
- [ ] Clean build (Cmd+Shift+K)
- [ ] Build Release with APPSTORE flag
- [ ] Test with large Markdown files
- [ ] Test theme switching performance
- [ ] Test documents with local images
- [ ] Verify memory usage in Activity Monitor

### Archive & Upload
- [ ] Product → Archive
- [ ] Validate archive
- [ ] Upload to App Store Connect
- [ ] Wait for processing

### App Store Connect
- [ ] Create new version 1.2
- [ ] Add "What's New" text
- [ ] Submit for review

### GitHub
- [ ] Commit all changes
- [ ] Create tag v1.2
- [ ] Create GitHub release
- [ ] Upload .app.zip binary

---

## Commands Reference

### Build for App Store
```bash
cd /Volumes/@Basic/Projekty/markdown-reader-MacOS/QuickMD
xcodebuild -project QuickMD.xcodeproj -scheme QuickMD \
  -configuration Release \
  OTHER_SWIFT_FLAGS="-D APPSTORE" \
  archive -archivePath QuickMD-v1.2.xcarchive
```

### Build for GitHub
```bash
xcodebuild -project QuickMD.xcodeproj -scheme QuickMD \
  -configuration Release \
  build

# Then zip the .app
cd ~/Library/Developer/Xcode/DerivedData/QuickMD-*/Build/Products/Release
zip -r QuickMD-v1.2.zip QuickMD.app
```

### Git Commands
```bash
git add -A
git commit -m "v1.2: Performance optimizations"
git tag -a v1.2 -m "QuickMD v1.2 - Performance Optimizations"
git push origin main --tags
```
