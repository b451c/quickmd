# QuickMD - Page Structure

## Quick Summary

Complete wireframe and sitemap for the QuickMD landing page - a single-page application with smooth scroll navigation.

---

## Page Architecture

### Type: Single Page Application (SPA)
### Sections: 6 main sections
### Navigation: Smooth scroll to anchors
### Estimated scroll depth: ~4-5 viewport heights

---

## Visual Wireframe

```
┌─────────────────────────────────────────────────────────────────┐
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │  HEADER (Fixed)                                             │ │
│ │  [Logo]                    [Features] [Download]            │ │
│ └─────────────────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│                        HERO SECTION                             │
│                                                                 │
│              "Read Markdown. Instantly."                        │
│                                                                 │
│         Lightweight viewer for Mac. Free forever.               │
│                                                                 │
│              [Download for Free]  [GitHub →]                    │
│                                                                 │
│                   ┌─────────────────┐                           │
│                   │                 │                           │
│                   │   SCREENSHOT    │                           │
│                   │    (Hero)       │                           │
│                   │                 │                           │
│                   └─────────────────┘                           │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│                     FEATURES SECTION                            │
│                                                                 │
│          "Everything You Need. Nothing You Don't."              │
│                                                                 │
│    ┌──────────┐    ┌──────────┐    ┌──────────┐                │
│    │    ⚡    │    │    🎨    │    │    📊    │                │
│    │ Instant  │    │   Code   │    │  Tables  │                │
│    │ Preview  │    │ Highlight│    │ Support  │                │
│    │          │    │          │    │          │                │
│    └──────────┘    └──────────┘    └──────────┘                │
│                                                                 │
│    ┌──────────┐    ┌──────────┐    ┌──────────┐                │
│    │    🌗    │    │    🪶    │    │    💝    │                │
│    │  Dark    │    │  Light-  │    │   Free   │                │
│    │  Mode    │    │  weight  │    │ Forever  │                │
│    └──────────┘    └──────────┘    └──────────┘                │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│                    SHOWCASE SECTION                             │
│                                                                 │
│               "See It In Action"                                │
│                                                                 │
│  ┌────────────────────────────────────────────────────────┐    │
│  │                                                        │    │
│  │              LARGE SCREENSHOT                          │    │
│  │              (Code highlighting demo)                  │    │
│  │                                                        │    │
│  └────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ┌─────────────────────┐    ┌─────────────────────┐            │
│  │   Light Mode        │    │   Dark Mode         │            │
│  │   Screenshot        │    │   Screenshot        │            │
│  └─────────────────────┘    └─────────────────────┘            │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│                   COMPARISON SECTION (Optional)                 │
│                                                                 │
│                    "Why QuickMD?"                               │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ Feature      │ QuickMD │ VS Code │ Typora │ Marked 2     │  │
│  ├──────────────┼─────────┼─────────┼────────┼──────────────│  │
│  │ Price        │  Free   │  Free   │  $15   │    $14       │  │
│  │ Native macOS │   ✅    │   ❌    │   ❌   │     ✅       │  │
│  │ Instant      │   ✅    │   ❌    │   ⚠️   │     ⚠️       │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│                      CTA SECTION                                │
│                                                                 │
│        "Ready to Read Markdown the Right Way?"                  │
│                                                                 │
│          Download QuickMD free from the App Store.              │
│                                                                 │
│                  [Download for Free]                            │
│                                                                 │
│               ┌─────────────────────┐                           │
│               │ Download on the     │                           │
│               │ Mac App Store       │                           │
│               └─────────────────────┘                           │
│                                                                 │
│            Requires macOS 13.0+ · ~2MB download                 │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│                        FOOTER                                   │
│                                                                 │
│  QuickMD                           Links                        │
│  Read Markdown. Instantly.         Privacy Policy               │
│                                    Terms of Use                 │
│  [GitHub] [☕ Support]              Contact                      │
│                                                                 │
│              © 2024 Falami Studio. Made with ❤️                 │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Section Details

### 1. Header (Fixed/Sticky)

**Height:** 64px
**Position:** Fixed top, transparent → solid on scroll
**Z-index:** 50

**Contents:**
| Left | Right |
|------|-------|
| Logo (icon + "QuickMD") | Nav: Features, Download (CTA button) |

**Behavior:**
- Transparent background initially
- Solid background + shadow after scrolling ~100px
- Smooth transition between states

```jsx
// Pseudo-structure
<header className="fixed top-0 w-full z-50">
  <div className="container flex justify-between items-center h-16">
    <Logo />
    <nav>
      <a href="#features">Features</a>
      <Button href="#download">Download</Button>
    </nav>
  </div>
</header>
```

---

### 2. Hero Section

**Height:** ~100vh (full viewport)
**ID:** `#hero`
**Background:** Solid (--background)

**Layout:**
```
[Centered content]
├── Badge (optional): "Free on Mac App Store"
├── H1: Main headline
├── Subheadline paragraph
├── CTA buttons row
│   ├── Primary: "Download for Free"
│   └── Secondary: "View on GitHub →"
└── Hero image (screenshot)
```

**Screenshot placement:**
- Below CTAs
- Max-width: 900px
- Subtle shadow
- Optional: MacBook mockup frame

**Animation:**
- Fade in + slide up on load
- Stagger: headline → subheadline → CTAs → image

---

### 3. Features Section

**Height:** Auto (content-based)
**ID:** `#features`
**Background:** Subtle alternate (--code-bg or same)

**Layout:**
```
[Section header centered]
├── H2: "Everything You Need. Nothing You Don't."
└── Subtitle (optional)

[Features grid]
├── Row 1: 3 features
└── Row 2: 3 features
```

**Grid:**
- Desktop: 3 columns
- Tablet: 2 columns
- Mobile: 1 column

**Feature card structure:**
```
┌─────────────────┐
│      [Icon]     │
│     Headline    │
│   Description   │
│    (2-3 lines)  │
└─────────────────┘
```

**Animation:**
- Stagger reveal on scroll
- Cards fade in from bottom

---

### 4. Showcase Section

**Height:** Auto
**ID:** `#showcase`
**Background:** Same as hero

**Layout:**
```
[Section header centered]
├── H2: "See It In Action"

[Large screenshot]
└── Full-width code highlighting demo

[Comparison row]
├── Light mode screenshot
└── Dark mode screenshot
```

**Notes:**
- This section is very visual
- Let screenshots do the talking
- Minimal text

---

### 5. Comparison Section (Optional)

**Height:** Auto
**ID:** `#compare`
**Background:** Subtle alternate

**Layout:**
```
[Section header centered]
├── H2: "Why QuickMD?"

[Comparison table]
└── Feature matrix (see 02-messaging-copy.md)
```

**Table styling:**
- Horizontal scroll on mobile
- Sticky first column (feature names)
- QuickMD column highlighted

**Decision:** This section is optional - can be removed if page feels too long.

---

### 6. Final CTA Section

**Height:** ~50vh
**ID:** `#download`
**Background:** Solid (--background)

**Layout:**
```
[Centered content]
├── H2: "Ready to Read Markdown the Right Way?"
├── Subheadline
├── Primary CTA button
├── App Store badge
└── System requirements text (small, muted)
```

**Notes:**
- High contrast section
- Clear, singular focus on download action
- App Store badge should be official Apple asset

---

### 7. Footer

**Height:** Auto
**Background:** Darker than main (--code-bg)

**Layout:**
```
[Container]
├── Left column
│   ├── Logo + tagline
│   └── Social links (GitHub, Buy Me a Coffee)
│
└── Right column
    └── Links (Privacy, Terms, Contact)

[Bottom bar]
└── Copyright
```

---

## Navigation Flow

### Smooth Scroll Anchors

| Link | Target |
|------|--------|
| Features | `#features` |
| Download | `#download` |

### Scroll Behavior

```css
html {
  scroll-behavior: smooth;
}

/* Offset for fixed header */
:target {
  scroll-margin-top: 80px;
}
```

---

## Responsive Behavior

### Mobile (< 768px)

- Header: Hamburger menu OR simplified (just Download button)
- Hero: Stack vertically, smaller headline
- Features: Single column
- Screenshots: Full width, scaled down
- Comparison table: Horizontal scroll

### Tablet (768px - 1024px)

- Header: Full nav visible
- Features: 2-column grid
- Screenshots: Side by side or stacked

### Desktop (> 1024px)

- Full layout as wireframed
- Features: 3-column grid
- Screenshots: Side by side with breathing room

---

## Component Inventory

| Component | Count | Notes |
|-----------|-------|-------|
| Header | 1 | Fixed, with scroll behavior |
| Hero | 1 | Full viewport |
| FeatureCard | 6 | Reusable component |
| Screenshot | 3-4 | With shadow/frame |
| ComparisonTable | 1 | Optional section |
| CTASection | 1 | With App Store badge |
| Footer | 1 | Links + copyright |
| Button | 2 types | Primary + Secondary |
| AppStoreBadge | 1-2 | Official Apple asset |

---

## Implementation Notes

1. **Single page** - All content on one page, no routing needed
2. **Anchor links** - Use smooth scroll for in-page navigation
3. **Lazy load images** - Screenshots below fold should lazy load
4. **Mobile-first CSS** - Build mobile layout first, enhance for desktop
5. **Performance budget** - Keep total page weight under 1MB
6. **Above the fold** - Hero + headline + CTA should be instantly visible
