# QuickMD - Visual Assets Requirements

## Quick Summary

Complete list of all visual assets needed for the landing page, with specifications and creation guidelines.

---

## Asset Checklist

### Required Assets

| Asset | Format | Dimensions | Priority |
|-------|--------|------------|----------|
| App Icon | PNG/SVG | 512x512, 256x256, 128x128 | Critical |
| Hero Screenshot | PNG | 2560x1600 (retina) | Critical |
| Dark Mode Screenshot | PNG | 2560x1600 (retina) | High |
| Code Highlight Screenshot | PNG | 1200x800 | High |
| Table Screenshot | PNG | 1200x600 | Medium |
| App Store Badge | SVG | Standard Apple size | Critical |
| OG Image | PNG | 1200x630 | High |
| Favicon | ICO/PNG | 32x32, 16x16 | Critical |

### Optional Assets

| Asset | Format | Dimensions | Priority |
|-------|--------|------------|----------|
| File Opening GIF | GIF | 800x500 | Nice-to-have |
| Feature Icons (x6) | SVG | 48x48 | Recommended |
| Background Pattern | SVG | Tileable | Optional |
| Video Demo | MP4 | 1920x1080 | Optional |

---

## Detailed Asset Specifications

### 1. App Icon

**Source:** Already exists in Xcode project
**Location:** `QuickMD/Assets.xcassets/AppIcon.appiconset/`

**Needed sizes for web:**
- 512x512 (high-res display)
- 256x256 (regular display)
- 128x128 (smaller uses)
- 64x64 (favicon/small icons)
- 32x32 (favicon)
- 16x16 (favicon)

**Format:** PNG with transparency OR SVG
**Notes:**
- Use existing app icon design
- Ensure it looks good at small sizes
- Consider adding subtle shadow for web use

---

### 2. Hero Screenshot

**Purpose:** Main visual in hero section
**Dimensions:** 2560x1600px (MacBook Pro retina resolution)
**Alternative:** 1920x1200px for faster loading

**Content requirements:**
- Full QuickMD window
- macOS window chrome (title bar, traffic lights)
- Rich markdown content showing:
  - H1 header
  - Regular paragraph
  - Code block with syntax highlighting
  - Table (optional)
  - At least one other element (list, blockquote)

**Styling:**
- Clean macOS desktop background (or transparent)
- Optional: Subtle shadow/float effect
- Consider: Mockup frame (MacBook frame)

**Mode:** Choose ONE for hero (recommend Light for broader appeal)

**Demo content suggestion:**
```markdown
# Welcome to QuickMD

The fastest way to preview Markdown on your Mac.

## Features

- **Instant preview** - No waiting, no loading
- **Syntax highlighting** - Code that pops

```python
def hello(name):
    return f"Hello, {name}!"
```

| Feature | Status |
|---------|--------|
| Tables  | ✅     |
| Code    | ✅     |
```

---

### 3. Dark Mode Screenshot

**Purpose:** Show dark mode support
**Dimensions:** Same as Hero (2560x1600 or 1920x1200)

**Requirements:**
- SAME content as hero screenshot
- Dark mode enabled
- Side-by-side comparison optimal

**Usage:**
- Feature section
- OR toggle comparison component
- OR below hero as secondary image

---

### 4. Code Highlight Screenshot

**Purpose:** Showcase syntax highlighting feature
**Dimensions:** 1200x800px (cropped to code block area)

**Content:**
- Fenced code block with language tag
- Multiple syntax elements:
  - Keywords (purple/pink)
  - Strings (orange/brown)
  - Comments (gray)
  - Numbers (green)
  - Types (blue/cyan)

**Recommended languages for demo:**
1. Swift (Apple ecosystem relevance)
2. Python (universal appeal)
3. JavaScript (web developers)

**Example content:**
```swift
struct User {
    let name: String
    var age: Int = 25

    // Returns a greeting message
    func greet() -> String {
        return "Hello, \(name)!"
    }
}
```

---

### 5. Table Screenshot

**Purpose:** Show table rendering capability
**Dimensions:** 1200x600px

**Content:**
- Realistic data table
- 3-4 columns
- 4-6 rows
- Visible header styling
- Clear borders

**Example:**
```markdown
| Feature       | QuickMD | Others |
|---------------|:-------:|:------:|
| Free          | ✅      | ❌     |
| Native macOS  | ✅      | ❌     |
| Instant Start | ✅      | ❌     |
| Syntax HL     | ✅      | ✅     |
```

---

### 6. App Store Badge

**Source:** Official Apple Marketing Resources
**URL:** https://developer.apple.com/app-store/marketing/guidelines/

**Required badge:** "Download on the Mac App Store"

**Specifications:**
- Use official Apple SVG/PNG
- Do not modify the badge
- Minimum clear space required
- Link to actual App Store listing

**Sizes:**
- Standard: 156x40 (1x) / 312x80 (2x)
- Large: 195x50 (1x) / 390x100 (2x)

---

### 7. Open Graph Image

**Purpose:** Social media sharing preview
**Dimensions:** 1200x630px (standard OG size)

**Content:**
- App icon (left or center)
- App name "QuickMD"
- Tagline: "Read Markdown. Instantly."
- Optional: Small screenshot preview
- Background: Brand colors or gradient

**Platforms:**
- Twitter Cards
- Facebook/LinkedIn shares
- Slack/Discord previews
- iMessage link previews

---

### 8. Favicon

**Dimensions:**
- favicon.ico: 16x16, 32x32 (multi-size ICO)
- apple-touch-icon: 180x180
- android-chrome: 192x192, 512x512

**Design:**
- Simplified app icon
- Works at tiny sizes
- Recognizable silhouette

---

### 9. Feature Icons (Optional but Recommended)

**Purpose:** Visual anchors for feature cards
**Dimensions:** 48x48px (can scale to 24-64px)
**Format:** SVG preferred

**Icons needed:**
| Feature | Icon Suggestion | Alt |
|---------|-----------------|-----|
| Instant | Lightning bolt | Zap |
| Code | Code brackets `</>` | Terminal |
| Tables | Grid/Table | Columns |
| Dark Mode | Moon/Sun | Circle half |
| Lightweight | Feather | Leaf |
| Free | Heart/Gift | Star |

**Style:**
- Outline/line icons (match modern aesthetic)
- 2px stroke weight
- Single color (adapt to theme)
- Consider: Lucide, Heroicons, Feather icons

---

## Asset Creation Workflow

### Screenshots:

1. **Prepare demo content**
   - Create sample .md file with ideal content
   - Cover all features you want to show

2. **Set up environment**
   - Clean desktop background
   - Set screen to target resolution
   - Enable/disable dark mode as needed

3. **Capture**
   - Use macOS screenshot (⌘+Shift+4, Space, click window)
   - Or use full screen and crop
   - Consider: CleanShot X for better shadows

4. **Post-process**
   - Crop to exact dimensions
   - Optimize file size (TinyPNG)
   - Export @2x versions for retina

### Mockups:

**Optional but professional:**
- Place screenshots in MacBook mockup
- Tools: Figma, Sketch, or online mockup generators
- Adds "premium" feel

---

## File Naming Convention

```
/public/images/
├── icon/
│   ├── icon-512.png
│   ├── icon-256.png
│   ├── icon-128.png
│   └── favicon.ico
├── screenshots/
│   ├── hero-light.png
│   ├── hero-light@2x.png
│   ├── hero-dark.png
│   ├── hero-dark@2x.png
│   ├── feature-code.png
│   └── feature-table.png
├── social/
│   ├── og-image.png
│   └── twitter-card.png
└── badges/
    └── app-store-badge.svg
```

---

## Implementation Notes

1. **Optimize all images** - Use WebP format where supported
2. **Provide @2x versions** - Essential for retina displays
3. **Lazy load below-fold images** - Improve initial load time
4. **Use next/image** - Automatic optimization in Next.js
5. **Alt text required** - Accessibility and SEO
6. **Keep file sizes small** - Target <500KB per image
