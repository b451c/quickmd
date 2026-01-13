# QuickMD - Design Guidelines

## Quick Summary

Brand identity and design system for the QuickMD landing page, derived from the native app's design language.

---

## Brand Identity

### Brand Personality

| Trait | Expression |
|-------|------------|
| **Professional** | Clean layouts, mature typography |
| **Minimal** | White space, no clutter |
| **Technical** | Developer-friendly aesthetic |
| **Approachable** | Warm accents, friendly copy |
| **Fast** | Sharp edges, no heavy shadows |

### Brand Promise
"Simple tools that respect your time."

---

## Color Palette

### Primary Colors (from app analysis)

#### Light Mode

| Token | Hex | RGB | Usage |
|-------|-----|-----|-------|
| `--background` | `#FAFAFA` | rgb(250, 250, 250) | Page background |
| `--foreground` | `#000000` | rgb(0, 0, 0) | Primary text |
| `--muted` | `#666666` | rgb(102, 102, 102) | Secondary text |
| `--code-bg` | `#F2F2F2` | rgb(242, 242, 242) | Code backgrounds |
| `--border` | `#D1D1D1` | rgb(209, 209, 209) at 0.3 opacity | Borders, dividers |

#### Dark Mode

| Token | Hex | RGB | Usage |
|-------|-----|-----|-------|
| `--background` | `#1E1E1E` | rgb(30, 30, 30) | Page background |
| `--foreground` | `#FFFFFF` | rgb(255, 255, 255) | Primary text |
| `--muted` | `#808080` | rgb(128, 128, 128) | Secondary text |
| `--code-bg` | `#2E2E2E` | rgb(46, 46, 46) | Code backgrounds |
| `--border` | `#808080` | rgb(128, 128, 128) at 0.5 opacity | Borders, dividers |

### Accent Colors

| Token | Light | Dark | Usage |
|-------|-------|------|-------|
| `--link` | `#0066CC` | `#4DA6FF` | Links, CTAs |
| `--success` | `#28A745` | `#5DD879` | Checkmarks, success |
| `--keyword` | `#9B2D9B` | `#CC66CC` | Code keywords |
| `--string` | `#994D1A` | `#CC9966` | Code strings |
| `--comment` | `#666666` | `#808080` | Code comments |
| `--number` | `#336633` | `#99CC99` | Code numbers |
| `--type` | `#1A6699` | `#80CCEE` | Code types |

### CSS Variables (Ready to Use)

```css
:root {
  /* Light mode defaults */
  --background: #FAFAFA;
  --foreground: #000000;
  --muted: #666666;
  --code-bg: #F2F2F2;
  --border: rgba(128, 128, 128, 0.3);
  --link: #0066CC;
  --success: #28A745;

  /* Syntax highlighting */
  --syntax-keyword: #9B2D9B;
  --syntax-string: #994D1A;
  --syntax-comment: #666666;
  --syntax-number: #336633;
  --syntax-type: #1A6699;
}

@media (prefers-color-scheme: dark) {
  :root {
    --background: #1E1E1E;
    --foreground: #FFFFFF;
    --muted: #808080;
    --code-bg: #2E2E2E;
    --border: rgba(128, 128, 128, 0.5);
    --link: #4DA6FF;
    --success: #5DD879;

    --syntax-keyword: #CC66CC;
    --syntax-string: #CC9966;
    --syntax-comment: #808080;
    --syntax-number: #99CC99;
    --syntax-type: #80CCEE;
  }
}
```

---

## Typography

### Font Stack

```css
--font-sans: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto,
             'Helvetica Neue', Arial, sans-serif;
--font-mono: ui-monospace, SFMono-Regular, 'SF Mono', Menlo,
             Consolas, 'Liberation Mono', monospace;
```

**Rationale:** System fonts for:
- Fastest loading (no font files)
- Native feel on each platform
- Matches macOS app experience

### Type Scale

| Element | Size | Weight | Line Height | Usage |
|---------|------|--------|-------------|-------|
| Hero H1 | 48px / 3rem | 700 | 1.1 | Main headline |
| H2 | 32px / 2rem | 700 | 1.2 | Section headlines |
| H3 | 24px / 1.5rem | 600 | 1.3 | Feature headlines |
| Body | 16px / 1rem | 400 | 1.6 | Paragraphs |
| Small | 14px / 0.875rem | 400 | 1.5 | Captions, meta |
| Code | 14px / 0.875rem | 400 | 1.5 | Inline code |
| Code Block | 13px / 0.8125rem | 400 | 1.6 | Code blocks |

### Typography CSS

```css
h1 {
  font-size: 3rem;
  font-weight: 700;
  line-height: 1.1;
  letter-spacing: -0.02em;
}

h2 {
  font-size: 2rem;
  font-weight: 700;
  line-height: 1.2;
  letter-spacing: -0.01em;
}

h3 {
  font-size: 1.5rem;
  font-weight: 600;
  line-height: 1.3;
}

p {
  font-size: 1rem;
  font-weight: 400;
  line-height: 1.6;
}

code {
  font-family: var(--font-mono);
  font-size: 0.875rem;
  background: var(--code-bg);
  padding: 0.125rem 0.375rem;
  border-radius: 4px;
}
```

---

## Spacing System

### Base Unit: 8px

| Token | Value | Usage |
|-------|-------|-------|
| `--space-1` | 4px | Tight spacing |
| `--space-2` | 8px | Default small |
| `--space-3` | 12px | - |
| `--space-4` | 16px | Default medium |
| `--space-6` | 24px | - |
| `--space-8` | 32px | Section padding |
| `--space-12` | 48px | - |
| `--space-16` | 64px | Large sections |
| `--space-24` | 96px | Hero padding |
| `--space-32` | 128px | Section gaps |

### Section Spacing

```css
/* Hero section */
.hero { padding: 96px 0 64px; }

/* Content sections */
.section { padding: 64px 0; }

/* Between section elements */
.section-content { gap: 48px; }

/* Feature cards */
.feature-card { padding: 24px; gap: 16px; }
```

---

## Component Styles

### Buttons

#### Primary Button (CTA)

```css
.btn-primary {
  background: var(--link);
  color: white;
  font-size: 1rem;
  font-weight: 600;
  padding: 12px 24px;
  border-radius: 8px;
  border: none;
  cursor: pointer;
  transition: all 0.2s ease;
}

.btn-primary:hover {
  background: #0052A3; /* Darker shade */
  transform: translateY(-1px);
}
```

#### Secondary Button

```css
.btn-secondary {
  background: transparent;
  color: var(--foreground);
  font-size: 1rem;
  font-weight: 500;
  padding: 12px 24px;
  border-radius: 8px;
  border: 1px solid var(--border);
  cursor: pointer;
  transition: all 0.2s ease;
}

.btn-secondary:hover {
  background: var(--code-bg);
}
```

### Cards

```css
.card {
  background: var(--background);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 24px;
  transition: all 0.2s ease;
}

.card:hover {
  border-color: var(--muted);
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.05);
}

/* Dark mode shadow */
@media (prefers-color-scheme: dark) {
  .card:hover {
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
  }
}
```

### Code Blocks

```css
.code-block {
  background: var(--code-bg);
  border-radius: 8px;
  padding: 16px;
  overflow-x: auto;
  font-family: var(--font-mono);
  font-size: 0.8125rem;
  line-height: 1.6;
}

.code-block .language-label {
  font-size: 0.6875rem;
  color: var(--muted);
  margin-bottom: 8px;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}
```

---

## Border Radius

| Token | Value | Usage |
|-------|-------|-------|
| `--radius-sm` | 4px | Small elements, badges |
| `--radius-md` | 8px | Buttons, inputs |
| `--radius-lg` | 12px | Cards, containers |
| `--radius-xl` | 16px | Large cards, modals |
| `--radius-full` | 9999px | Pills, avatars |

---

## Shadows

```css
/* Subtle shadow for cards */
--shadow-sm: 0 1px 2px rgba(0, 0, 0, 0.05);

/* Default shadow */
--shadow-md: 0 4px 6px rgba(0, 0, 0, 0.07);

/* Elevated shadow for hover states */
--shadow-lg: 0 10px 15px rgba(0, 0, 0, 0.1);

/* Screenshot/image shadow */
--shadow-screenshot: 0 25px 50px rgba(0, 0, 0, 0.15);
```

**Note:** Keep shadows subtle. The app is minimal, the landing page should match.

---

## Animations

### Principles
- **Subtle** - Don't distract from content
- **Fast** - 200-300ms max
- **Purposeful** - Guide attention, not entertain

### Transitions

```css
/* Default transition */
--transition: all 0.2s ease;

/* Slower for larger elements */
--transition-slow: all 0.3s ease;
```

### Scroll Animations (Framer Motion)

```jsx
// Fade in from bottom
const fadeInUp = {
  initial: { opacity: 0, y: 20 },
  animate: { opacity: 1, y: 0 },
  transition: { duration: 0.5 }
};

// Stagger children
const staggerContainer = {
  animate: {
    transition: {
      staggerChildren: 0.1
    }
  }
};
```

---

## Responsive Breakpoints

```css
/* Mobile first approach */
--breakpoint-sm: 640px;   /* Small tablets */
--breakpoint-md: 768px;   /* Tablets */
--breakpoint-lg: 1024px;  /* Laptops */
--breakpoint-xl: 1280px;  /* Desktops */
--breakpoint-2xl: 1536px; /* Large screens */
```

### Container Widths

```css
.container {
  max-width: 1200px;
  margin: 0 auto;
  padding: 0 24px;
}

@media (min-width: 768px) {
  .container {
    padding: 0 48px;
  }
}
```

---

## Do's and Don'ts

### Do ✅
- Use plenty of white space
- Keep the color palette limited
- Use system fonts
- Match the app's minimal aesthetic
- Let screenshots speak
- Use subtle shadows

### Don't ❌
- Add gradients (app doesn't have them)
- Use loud colors
- Over-animate
- Add decorative elements
- Use custom fonts (performance hit)
- Make it look "trendy" over functional

---

## Implementation Notes

1. **Match the app** - Landing page should feel like an extension of QuickMD
2. **Dark mode is essential** - Implement with CSS media query
3. **Performance first** - No heavy fonts, optimize images
4. **Accessibility** - Maintain contrast ratios (4.5:1 minimum)
5. **Test both modes** - Equal attention to light and dark
