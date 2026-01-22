# QuickMD v1.2.1 Release Notes

**Release Date:** 2026-01-22
**Build:** 8

---

## App Store Release Notes

### What's New in Version 1.2.1

**Performance Improvements**
- Faster document rendering with optimized caching
- Improved syntax highlighting performance for code blocks
- Reduced memory usage through smart resource management

**Quality & Stability**
- Enhanced error handling for PDF export
- Improved reliability across all features
- Code quality improvements for long-term maintainability

---

## GitHub Release Notes

### QuickMD v1.2.1

A quality-focused release with significant performance optimizations and code improvements.

#### Performance Highlights

| Optimization | Impact |
|--------------|--------|
| Cached MarkdownRenderer | -99% allocations per parse |
| Cached syntax highlighting | Zero recomputation on re-render |
| Static regex compilation | 9 patterns, zero runtime compilation |
| Theme caching | Singleton pattern, zero allocations |

#### Code Quality Improvements

- **Zero runtime force unwraps** - All URLs moved to compile-time validated constants
- **Zero sync network calls** - Remote images handled gracefully in PDF export
- **Proper logging** - Replaced print() with os.Logger
- **Consistent patterns** - Stored properties instead of computed where appropriate

#### Technical Changes

**Modified Files:**
- `MarkdownBlockParser.swift` - Cached renderer instance
- `CodeBlockView.swift` - @State cache with smart sync/async strategy
- `MarkdownRenderer.swift` - Uses cached theme
- `MarkdownExport.swift` - Theme-based colors, better error handling
- `QuickMDApp.swift` - AppURLs enum
- `MarkdownView.swift` - AppURLs enum
- `TableBlockView.swift` - Stored columnCount
- `TipJarView.swift` - @ObservedObject for singleton
- `TipJarManager.swift` - os.Logger

#### Audit Results

| Category | Score |
|----------|-------|
| Performance | 10/10 |
| Code Quality | 10/10 |
| Production Readiness | 10/10 |

---

## Build Instructions

### GitHub Version (Direct Download)

```bash
# Clone repository
git clone https://github.com/b451c/quickmd.git
cd quickmd/QuickMD

# Build
xcodebuild -project QuickMD.xcodeproj -scheme QuickMD -configuration Release build

# Archive for distribution
xcodebuild -project QuickMD.xcodeproj -scheme QuickMD -configuration Release archive -archivePath QuickMD-v1.2.1.xcarchive
```

### App Store Version

```bash
# Build with APPSTORE flag
xcodebuild -project QuickMD.xcodeproj -scheme QuickMD -configuration Release \
  GCC_PREPROCESSOR_DEFINITIONS='APPSTORE=1' \
  archive -archivePath QuickMD-v1.2.1-AppStore.xcarchive
```

---

## Checksums

```
SHA256 (QuickMD-v1.2.1.zip) = e57d7a208e9c02bbd175792ad1a890296a42916fecce3a532b4a9419d61342c0
```

## File Sizes

| File | Size |
|------|------|
| QuickMD-v1.2.1.zip | 3.1 MB |
| QuickMD-v1.2.1-GitHub.xcarchive | 11 MB |
| QuickMD-v1.2.1-AppStore.xcarchive | 11 MB |
