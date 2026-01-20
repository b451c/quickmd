# QuickMD v1.1 Release Notes

## Release Overview

**Version:** 1.1
**Build:** 5
**Release Date:** January 2025
**Type:** Feature Update

---

## Summary

QuickMD v1.1 brings significant improvements to Markdown rendering with enhanced table support, new formatting features, and better CommonMark compatibility. This update focuses on rendering accuracy and expanded Markdown syntax support.

---

## New Features

### 1. Escape Characters
Backslash escaping now works correctly for special Markdown characters.
- `\*not bold\*` renders as literal `*not bold*`
- `\|` renders as literal pipe character in tables
- Supports all standard escapable characters: `\ ` ` * _ { } [ ] ( ) # + - . ! |`

### 2. Markdown Formatting in Tables
Table cells now support inline Markdown formatting:
- **Bold text** in cells
- *Italic text* in cells
- `inline code` in cells
- [Links](url) in cells
- Combined formatting

### 3. Table Column Alignment
Full support for GFM table alignment syntax:
- `:---` for left alignment
- `:---:` for center alignment
- `---:` for right alignment

### 4. Relative Image Paths
Images with relative paths now resolve correctly relative to the document location:
- `![](./images/photo.png)` - same directory
- `![](../assets/logo.png)` - parent directory
- Absolute and URL paths continue to work as before

### 5. URL Autolinking
Bare URLs are now automatically converted to clickable links:
- `https://example.com` becomes a clickable link
- No need for `[text](url)` syntax for simple URLs

### 6. Setext-Style Headers
Support for underlined header syntax (CommonMark compatible):
```
Main Title
==========

Subtitle
--------
```

### 7. Smart Table Normalization
Tables with inconsistent column counts are automatically corrected:
- Rows with missing columns are padded with empty cells
- Rows with extra columns are trimmed to match header
- Prevents rendering errors from malformed tables

---

## Improvements

### Enhanced Table Rendering
- Continuous vertical borders between columns
- Proper alignment across all rows
- Better handling of wide content

### Print & PDF Export
- Fixed black page issue in print preview
- Tables render correctly in PDF export
- Improved layout consistency

### UI Polish
- Fixed Tip Jar button focus ring issue
- Smoother hover animations

---

## Technical Changes

### Files Modified
- `MarkdownTheme.swift` - Added patterns for escape chars, autolinks, setext headers
- `MarkdownRenderer.swift` - New parsing methods for escape, autolink; public renderInline API
- `MarkdownView.swift` - Table alignment support, GeometryReader borders, normalization
- `MarkdownExport.swift` - Updated PrintableTableView with alignment support
- `QuickMDApp.swift` - Pass document URL for relative path resolution

### Compatibility
- macOS 14.0 (Sonoma) or later
- Universal binary (Apple Silicon + Intel)

---

## GitHub Release

### Tag
`v1.1`

### Title
`QuickMD v1.1 - Enhanced Markdown Rendering`

### Release Notes (Markdown)
```markdown
## What's New in v1.1

### New Features
- **Escape Characters** - Use `\*` to show literal asterisks
- **Markdown in Tables** - Bold, italic, code, and links now work inside table cells
- **Table Alignment** - Support for `:---`, `:---:`, `---:` column alignment
- **Relative Images** - `![](./path/image.png)` resolves relative to document
- **URL Autolinking** - Bare `https://` URLs become clickable automatically
- **Setext Headers** - Underlined `===` and `---` style headers

### Improvements
- Smart table normalization (auto-fix malformed tables)
- Better table border rendering
- Fixed print/PDF export
- UI polish improvements

### Download
- **QuickMD.app.zip** - Universal binary for macOS 14.0+

---

**Full Changelog**: https://github.com/b451c/quickmd/compare/v1.0...v1.1
```

---

## App Store Connect

### What's New (Version 1.1)

**English:**
```
Enhanced Markdown Rendering

NEW FEATURES
• Escape characters - use \* for literal asterisks
• Markdown in tables - bold, italic, code, links in cells
• Table alignment - left, center, right column alignment
• Relative image paths - ./images/photo.png works
• URL autolinking - bare https:// URLs become clickable
• Setext headers - underlined === and --- style

IMPROVEMENTS
• Smarter table parsing with auto-correction
• Better table border rendering
• Fixed print and PDF export
• UI polish and bug fixes
```

**Polish:**
```
Ulepszone Renderowanie Markdown

NOWE FUNKCJE
• Znaki escape - użyj \* dla dosłownych gwiazdek
• Markdown w tabelach - pogrubienie, kursywa, kod, linki w komórkach
• Wyrównanie tabel - wyrównanie kolumn do lewej, środka, prawej
• Względne ścieżki obrazów - ./images/foto.png działa
• Auto-linkowanie URL - https:// automatycznie staje się linkiem
• Nagłówki Setext - styl podkreślony === i ---

ULEPSZENIA
• Inteligentniejsze parsowanie tabel z auto-korektą
• Lepsze renderowanie obramowań tabel
• Naprawiony druk i eksport PDF
• Poprawki UI i błędów
```

### Updated Keywords (if needed)
```
markdown,viewer,md,reader,developer,code,documentation,readme,preview,tables,syntax
```

### Review Notes for Apple
```
QuickMD v1.1 adds enhanced Markdown rendering features.

New in this version:
- Escape character support (\* shows literal *)
- Markdown formatting inside table cells
- Table column alignment (GFM syntax)
- Relative image path resolution
- Automatic URL linking
- Setext-style headers

To test new features:
1. Open the included test file or any .md with tables
2. Verify table alignment and formatting in cells
3. Test print (Cmd+P) - should show proper layout
4. Test relative images if document has local images

No new permissions required. No network access changes.
Tip Jar (In-App Purchase) unchanged from v1.0.
```

---

## Pre-Release Checklist

### Version Numbers
- [ ] Update MARKETING_VERSION to 1.1
- [ ] Update CURRENT_PROJECT_VERSION to 5

### Build & Test
- [ ] Clean build (Cmd+Shift+K)
- [ ] Build Release with APPSTORE flag
- [ ] Test all new features manually
- [ ] Test print/PDF export
- [ ] Test Tip Jar functionality
- [ ] Test on both light and dark mode

### Archive & Upload
- [ ] Product → Archive
- [ ] Validate archive
- [ ] Upload to App Store Connect
- [ ] Wait for processing

### App Store Connect
- [ ] Create new version 1.1
- [ ] Add "What's New" text
- [ ] Update screenshots if needed
- [ ] Submit for review

### GitHub
- [ ] Commit all changes
- [ ] Create tag v1.1
- [ ] Create GitHub release
- [ ] Upload .app.zip binary
- [ ] Update README if needed

---

## Commands Reference

### Update Version Numbers
```bash
# In Xcode: Target → General → Version = 1.1, Build = 5
# Or edit project.pbxproj
```

### Build for App Store
```bash
xcodebuild -project QuickMD.xcodeproj -scheme QuickMD \
  -configuration Release \
  OTHER_SWIFT_FLAGS="-D APPSTORE" \
  archive -archivePath QuickMD-v1.1.xcarchive
```

### Build for GitHub
```bash
xcodebuild -project QuickMD.xcodeproj -scheme QuickMD \
  -configuration Release \
  build

# Then zip the .app
cd ~/Library/Developer/Xcode/DerivedData/QuickMD-*/Build/Products/Release
zip -r QuickMD-v1.1.zip QuickMD.app
```

### Git Commands
```bash
git add -A
git commit -m "v1.1: Enhanced Markdown rendering"
git tag -a v1.1 -m "QuickMD v1.1 - Enhanced Markdown Rendering"
git push origin main --tags
```
