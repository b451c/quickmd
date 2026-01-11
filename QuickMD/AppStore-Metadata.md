# QuickMD - App Store Submission Guide

## App Information

**App Name:** QuickMD
**Subtitle:** Lightning-fast Markdown Viewer
**Bundle ID:** pl.falami.studio.QuickMD
**SKU:** quickmd-macos-2025
**Primary Language:** English
**Category:** Developer Tools
**Secondary Category:** Productivity

---

## App Store Description (English)

```
QuickMD is the fastest, most elegant Markdown viewer for macOS. Double-click any .md file and instantly see beautifully rendered content.

INSTANT LAUNCH
• Opens in milliseconds - no loading screens
• Native macOS app - no Electron bloat
• Lightweight (~2MB) - respects your disk space

COMPLETE MARKDOWN SUPPORT
• Headers, bold, italic, strikethrough
• Tables with proper column alignment
• Code blocks with syntax highlighting
• Task lists with checkboxes
• Nested lists (ordered and unordered)
• Images (local and remote URLs)
• Links, blockquotes, horizontal rules

DEVELOPER-FRIENDLY
• Syntax highlighting for 10+ languages
• Perfect for README files and documentation
• Handles AI-generated markdown perfectly
• Dark mode that follows system settings

PRIVACY FOCUSED
• No analytics, no tracking
• Works completely offline
• Your files stay on your device

Perfect for developers, writers, students, and anyone who works with Markdown daily. QuickMD is the Preview.app equivalent for Markdown files.
```

---

## App Store Description (Polish)

```
QuickMD to najszybsza i najelegancka przeglądarka Markdown dla macOS. Kliknij dwukrotnie dowolny plik .md i natychmiast zobacz pięknie sformatowaną zawartość.

BŁYSKAWICZNE URUCHAMIANIE
• Otwiera się w milisekundach - bez ekranów ładowania
• Natywna aplikacja macOS - bez ciężkiego Electron
• Lekka (~2MB) - szanuje Twoją przestrzeń dyskową

PEŁNA OBSŁUGA MARKDOWN
• Nagłówki, pogrubienie, kursywa, przekreślenie
• Tabele z wyrównaniem kolumn
• Bloki kodu z podświetlaniem składni
• Listy zadań z checkboxami
• Zagnieżdżone listy (numerowane i punktowane)
• Obrazy (lokalne i zdalne URL)
• Linki, cytaty, linie poziome

PRZYJAZNA DLA DEWELOPERÓW
• Podświetlanie składni dla 10+ języków
• Idealna do plików README i dokumentacji
• Świetnie obsługuje markdown generowany przez AI
• Tryb ciemny synchronizowany z systemem

PRYWATNOŚĆ
• Bez analityki, bez śledzenia
• Działa całkowicie offline
• Twoje pliki pozostają na Twoim urządzeniu

Idealna dla deweloperów, pisarzy, studentów i wszystkich, którzy codziennie pracują z Markdown.
```

---

## Keywords (100 characters max)

```
markdown,viewer,md,reader,developer,code,documentation,readme,preview,syntax,highlighting
```

---

## What's New (Version 1.0)

```
Initial release of QuickMD - the lightning-fast Markdown viewer for macOS.

• Beautiful Markdown rendering
• Syntax highlighting for code blocks
• Table support with proper formatting
• Task lists and nested lists
• Image rendering (local + remote)
• Native dark mode support
```

---

## Support & Privacy

**Support URL:** https://github.com/b451c/quickmd
**Privacy Policy URL:** https://github.com/b451c/quickmd/blob/main/PRIVACY.md

### Privacy Policy (create PRIVACY.md):

```
# Privacy Policy for QuickMD

Last updated: January 2025

## Data Collection
QuickMD does not collect any personal data. The app runs entirely on your device.

## File Access
QuickMD only accesses files that you explicitly open. Files are read locally and never transmitted.

## Analytics
QuickMD contains no analytics or tracking code.

## Contact
For questions about this privacy policy, contact: [your-email]
```

---

## Screenshots Required

**Sizes needed for Mac App Store:**
- 1280 x 800 pixels (minimum)
- 1440 x 900 pixels (recommended)
- 2560 x 1600 pixels (Retina, optional but recommended)
- 2880 x 1800 pixels (Retina, optional)

**Suggested screenshots:**
1. Main view with sample Markdown (light mode)
2. Main view with sample Markdown (dark mode)
3. Code block with syntax highlighting
4. Table rendering example
5. Task list / checkbox example

---

## Pricing

**Price Tier:** Free

*Optional donations via Buy Me a Coffee (link in app)*

---

## Age Rating

- No objectionable content
- Select "None" for all categories
- Rating: 4+

---

## Next Steps

1. **Open Xcode:**
   ```
   open "/Volumes/@Basic/Projekty/markdown-reader-MacOS/QuickMD/QuickMD.xcodeproj"
   ```

2. **Configure Signing:**
   - Go to: QuickMD target → Signing & Capabilities
   - Select your Team
   - Ensure "Automatically manage signing" is checked

3. **Archive:**
   - Product → Archive
   - Wait for build to complete

4. **Upload:**
   - Window → Organizer
   - Select archive → Distribute App
   - Choose "App Store Connect"
   - Upload

5. **App Store Connect:**
   - Go to: https://appstoreconnect.apple.com
   - Create new app with Bundle ID: pl.falami.studio.QuickMD
   - Fill in metadata from this document
   - Add screenshots
   - Submit for review

---

## Review Notes (optional, for Apple reviewer)

```
QuickMD is a simple Markdown file viewer. To test:
1. Open any .md file from Finder
2. The app will display rendered Markdown content
3. Test dark mode by switching system appearance

No login required. No network access needed for core functionality.
```
