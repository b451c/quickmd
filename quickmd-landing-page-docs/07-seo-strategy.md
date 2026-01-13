# QuickMD - SEO Strategy

## Quick Summary

Comprehensive SEO plan targeting developers searching for Markdown preview tools on Mac. Focus on long-tail keywords with purchase intent.

---

## Target Keywords

### Primary Keywords (High Priority)

| Keyword | Search Volume | Difficulty | Intent |
|---------|--------------|------------|--------|
| markdown viewer mac | Medium | Medium | Transactional |
| markdown preview mac | Medium | Medium | Transactional |
| md file viewer mac | Low-Medium | Low | Transactional |
| markdown reader macos | Low | Low | Transactional |

### Secondary Keywords

| Keyword | Search Volume | Difficulty | Intent |
|---------|--------------|------------|--------|
| view markdown files | Medium | Medium | Informational |
| open md file mac | Low | Low | Transactional |
| markdown app mac free | Low | Medium | Transactional |
| best markdown viewer | Medium | High | Commercial |
| markdown preview tool | Low | Low | Commercial |

### Long-tail Keywords (Low Competition)

- "how to open md file on mac"
- "free markdown viewer for macos"
- "markdown file preview without editor"
- "lightweight markdown app mac"
- "read readme files on mac"
- "quick look markdown mac"
- "syntax highlighted markdown preview"

---

## Meta Tags

### Title Tag (60 chars max)

**Primary:**
```
QuickMD - Free Markdown Viewer for Mac | Instant Preview
```

**Alternatives:**
```
QuickMD: Lightweight Markdown Viewer for macOS - Free Download
```
```
Free Markdown Preview App for Mac | QuickMD
```

### Meta Description (155 chars max)

**Primary:**
```
QuickMD is a free, native macOS app for viewing Markdown files instantly. Syntax highlighting, dark mode, tables support. Download from the Mac App Store.
```

**Alternative:**
```
Preview Markdown files beautifully on Mac. QuickMD offers instant rendering, code syntax highlighting, and dark mode. Free download from the App Store.
```

---

## Open Graph Tags

```html
<meta property="og:title" content="QuickMD - Free Markdown Viewer for Mac">
<meta property="og:description" content="Preview Markdown files instantly with syntax highlighting, tables, and dark mode. Free native macOS app.">
<meta property="og:image" content="https://quickmd.app/og-image.png">
<meta property="og:url" content="https://quickmd.app">
<meta property="og:type" content="website">
<meta property="og:site_name" content="QuickMD">
```

### Twitter Card Tags

```html
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="QuickMD - Free Markdown Viewer for Mac">
<meta name="twitter:description" content="Preview Markdown files instantly. Syntax highlighting, dark mode, tables. Free on Mac App Store.">
<meta name="twitter:image" content="https://quickmd.app/twitter-card.png">
```

---

## Structured Data (JSON-LD)

### SoftwareApplication Schema

```json
{
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  "name": "QuickMD",
  "description": "A lightweight native macOS application for viewing Markdown files with syntax highlighting, tables, and dark mode support.",
  "applicationCategory": "DeveloperApplication",
  "operatingSystem": "macOS 13.0+",
  "offers": {
    "@type": "Offer",
    "price": "0",
    "priceCurrency": "USD"
  },
  "aggregateRating": {
    "@type": "AggregateRating",
    "ratingValue": "5",
    "ratingCount": "1"
  },
  "author": {
    "@type": "Organization",
    "name": "Falami Studio"
  },
  "downloadUrl": "https://apps.apple.com/app/quickmd/id[APP_ID]",
  "screenshot": "https://quickmd.app/images/screenshot-hero.png",
  "softwareVersion": "1.0",
  "fileSize": "2MB"
}
```

### BreadcrumbList (if subpages exist)

```json
{
  "@context": "https://schema.org",
  "@type": "BreadcrumbList",
  "itemListElement": [
    {
      "@type": "ListItem",
      "position": 1,
      "name": "Home",
      "item": "https://quickmd.app"
    }
  ]
}
```

---

## On-Page SEO

### Content Hierarchy

```html
<h1>Read Markdown. Instantly.</h1>  <!-- Only ONE h1 -->

<h2>Everything You Need. Nothing You Don't.</h2>
  <h3>Instant Preview</h3>
  <h3>Syntax Highlighting</h3>
  <h3>Tables Support</h3>
  <h3>Dark Mode</h3>
  <h3>Lightweight</h3>
  <h3>Free Forever</h3>

<h2>See It In Action</h2>

<h2>Why QuickMD?</h2>

<h2>Download QuickMD</h2>
```

### Semantic HTML

```html
<header>...</header>
<main>
  <section id="hero" aria-label="Hero">...</section>
  <section id="features" aria-labelledby="features-heading">
    <h2 id="features-heading">Features</h2>
    ...
  </section>
  <section id="showcase" aria-labelledby="showcase-heading">...</section>
  <section id="download" aria-labelledby="download-heading">...</section>
</main>
<footer>...</footer>
```

### Image Alt Text Guidelines

| Image | Alt Text |
|-------|----------|
| Hero screenshot | "QuickMD app showing rendered Markdown with syntax highlighted code block" |
| Code highlight | "Python code with syntax highlighting in QuickMD" |
| Light mode | "QuickMD interface in light mode" |
| Dark mode | "QuickMD interface in dark mode" |
| App icon | "QuickMD app icon" |

### Internal Linking

Since it's a single page, use:
- Anchor links (`#features`, `#download`)
- These help search engines understand page structure
- Use descriptive anchor text

---

## Technical SEO

### Performance (Core Web Vitals)

| Metric | Target | How to Achieve |
|--------|--------|----------------|
| LCP (Largest Contentful Paint) | < 2.5s | Optimize hero image, preload fonts |
| FID (First Input Delay) | < 100ms | Minimal JS, no heavy frameworks |
| CLS (Cumulative Layout Shift) | < 0.1 | Set image dimensions, no dynamic content shifts |

### Performance Checklist

- [ ] Images in WebP format
- [ ] Images properly sized (@1x and @2x)
- [ ] Lazy loading for below-fold images
- [ ] Minified CSS/JS
- [ ] GZIP compression enabled
- [ ] Browser caching headers
- [ ] CDN for static assets
- [ ] No render-blocking resources

### Mobile-Friendliness

- Responsive design (required)
- Touch-friendly tap targets (min 44x44px)
- Readable text without zooming (16px minimum)
- No horizontal scrolling

### Indexing

**robots.txt:**
```
User-agent: *
Allow: /
Sitemap: https://quickmd.app/sitemap.xml
```

**sitemap.xml:**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>https://quickmd.app/</loc>
    <lastmod>2024-01-13</lastmod>
    <changefreq>monthly</changefreq>
    <priority>1.0</priority>
  </url>
</urlset>
```

### Canonical URL

```html
<link rel="canonical" href="https://quickmd.app/">
```

---

## Content Strategy

### Landing Page Content Priorities

1. **Clear value proposition** in H1
2. **Keywords naturally integrated** in:
   - Headline and subheadline
   - Feature descriptions
   - Alt text
   - Meta description

3. **Avoid keyword stuffing** - Natural language first

### Potential Blog Content (Future)

If adding a blog for SEO:
- "How to Open Markdown Files on Mac"
- "Best Free Markdown Viewers for macOS"
- "Markdown Syntax Cheat Sheet"
- "Why Developers Use Markdown"
- "QuickMD vs Typora: Which Markdown Viewer?"

---

## Link Building Opportunities

### Directories & Listings

- [ ] Product Hunt launch
- [ ] AlternativeTo.net listing
- [ ] Slant.co listing
- [ ] MacUpdate.com submission
- [ ] Softpedia submission

### Developer Communities

- [ ] Hacker News (Show HN post)
- [ ] Reddit r/macapps
- [ ] Reddit r/markdown
- [ ] Dev.to article
- [ ] Twitter/X developer community

### GitHub Presence

- [ ] Comprehensive README
- [ ] GitHub Pages (can host landing page)
- [ ] Star the repo campaigns
- [ ] Featured in awesome-macos lists

---

## Local SEO (Not Applicable)

QuickMD is a global digital product - local SEO not relevant.

---

## Tracking & Analytics

### Recommended Setup

1. **Google Search Console**
   - Monitor search performance
   - Submit sitemap
   - Track Core Web Vitals
   - Identify crawl issues

2. **Privacy-Friendly Analytics** (optional)
   - Plausible Analytics
   - Fathom Analytics
   - Simple Analytics
   - *Respect user privacy, match app philosophy*

### Key Metrics to Track

| Metric | Tool |
|--------|------|
| Organic traffic | Search Console |
| Keyword rankings | Search Console |
| Click-through rate | Search Console |
| Core Web Vitals | Search Console / Lighthouse |
| App Store clicks | UTM parameters |

---

## Implementation Checklist

### Pre-Launch

- [ ] All meta tags implemented
- [ ] Structured data added
- [ ] Images optimized with alt text
- [ ] robots.txt created
- [ ] sitemap.xml created
- [ ] Canonical URL set
- [ ] Mobile responsiveness verified
- [ ] Page speed optimized (Lighthouse > 90)

### Post-Launch

- [ ] Submit to Google Search Console
- [ ] Submit sitemap
- [ ] Request indexing
- [ ] Submit to directories
- [ ] Share on social/communities
- [ ] Monitor rankings weekly

---

## Expected Timeline

| Week | Action | Expected Result |
|------|--------|-----------------|
| 1 | Launch + submissions | Indexed by Google |
| 2-4 | Community sharing | Initial backlinks |
| 1-2 months | Content establishes | Rankings begin |
| 3-6 months | Steady traffic | Top 10 for long-tail |
| 6-12 months | Authority builds | Top 5 for primary keywords |

---

## Notes

1. **SEO is a long game** - Don't expect instant results
2. **Quality over quantity** - One great page beats many thin pages
3. **User experience first** - Good UX = good SEO
4. **Match app philosophy** - No dark patterns, no intrusive tracking
5. **Update content** - Keep meta tags current, add reviews when available
