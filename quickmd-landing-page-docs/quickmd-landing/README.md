# QuickMD Landing Page

Marketing landing page for [QuickMD](https://apps.apple.com/app/quickmd/id6738038802) - a free, lightweight Markdown viewer for macOS.

## Tech Stack

- **Framework:** Next.js 16 (App Router)
- **Styling:** Tailwind CSS v4
- **Animations:** Framer Motion
- **Icons:** Lucide React
- **Language:** TypeScript

## Features

- Responsive design (mobile, tablet, desktop)
- Automatic dark mode (follows system preference)
- Smooth scroll navigation
- Animated sections with staggered reveals
- SEO optimized (meta tags, JSON-LD schema, sitemap)
- Lighthouse score > 90

## Getting Started

### Prerequisites

- Node.js 18.17 or later
- npm or yarn

### Installation

```bash
# Clone the repository
git clone <repository-url>
cd quickmd-landing

# Install dependencies
npm install
```

### Development

```bash
# Start development server
npm run dev

# Open http://localhost:3000
```

### Build

```bash
# Create production build
npm run build

# Start production server
npm start
```

## Project Structure

```
quickmd-landing/
├── app/
│   ├── globals.css      # Design system & CSS variables
│   ├── layout.tsx       # Root layout with SEO metadata
│   ├── page.tsx         # Main landing page
│   ├── sitemap.ts       # Dynamic sitemap generation
│   ├── privacy/         # Privacy policy page
│   └── terms/           # Terms of use page
├── components/
│   ├── Button.tsx       # Reusable button component
│   ├── FeatureCard.tsx  # Feature grid cards
│   ├── AppStoreBadge.tsx # Mac App Store badge
│   ├── Header.tsx       # Fixed header with scroll behavior
│   ├── Hero.tsx         # Hero section with animations
│   ├── Features.tsx     # Features grid section
│   ├── Showcase.tsx     # Screenshot showcase section
│   ├── CTA.tsx          # Call-to-action section
│   ├── Footer.tsx       # Footer with links
│   └── index.ts         # Component exports
├── public/
│   ├── robots.txt       # Search engine instructions
│   └── site.webmanifest # PWA manifest
└── package.json
```

## Design System

### Colors

The design uses a sophisticated color palette with CSS custom properties:

- **Light Mode:** Clean slate backgrounds with electric cyan (#06b6d4) accents
- **Dark Mode:** Deep slate (#0c0f14) with bright cyan (#22d3ee) accents

### Typography

- **Display Font:** Outfit - Modern geometric sans-serif
- **Monospace:** JetBrains Mono - Developer-centric for code

### Key Design Decisions

1. **Editorial aesthetic** - Magazine-style layout with generous whitespace
2. **No generic AI aesthetics** - Distinctive colors and typography (no purple gradients)
3. **Code-centric feel** - Prominent syntax highlighting showcase
4. **Minimal animations** - Purposeful, orchestrated reveals on scroll

## Deployment

### Vercel (Recommended)

```bash
# Install Vercel CLI
npm i -g vercel

# Deploy
vercel
```

Or connect your GitHub repository to [Vercel](https://vercel.com) for automatic deployments.

### Static Export

```bash
# Add to next.config.ts:
# output: 'export'

npm run build
# Upload the 'out' directory to any static host
```

## Customization

### Update App Store Link

Edit the App Store URL in:
- `components/AppStoreBadge.tsx` - Badge component
- `app/layout.tsx` - JSON-LD schema

### Update Branding

1. Colors: Edit CSS variables in `app/globals.css`
2. Fonts: Modify font imports in `app/layout.tsx`
3. Logo: Update SVG in `components/Header.tsx` and `components/Footer.tsx`

### Add Real Screenshots

Replace the mockup content in:
- `components/Hero.tsx` - Main hero screenshot
- `components/Showcase.tsx` - Light/dark mode comparison

With actual `<Image>` components pointing to your screenshot files.

## Performance

The landing page is optimized for:
- Fast initial load (minimal JavaScript)
- Static generation (no server required)
- Efficient animations (CSS + Framer Motion)
- Responsive images (next/image optimization)

## License

This landing page is part of the QuickMD project by Falami Studio.

## Links

- [QuickMD on Mac App Store](https://apps.apple.com/app/quickmd/id6738038802)
- [GitHub Repository](https://github.com/AdrianBran/QuickMD)
- [Buy Me a Coffee](https://buymeacoffee.com/falamistudio)
