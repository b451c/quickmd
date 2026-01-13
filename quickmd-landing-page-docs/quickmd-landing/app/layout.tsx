import type { Metadata, Viewport } from "next";
import { Outfit, JetBrains_Mono } from "next/font/google";
import "./globals.css";

// Display font - Modern geometric sans-serif
const outfit = Outfit({
  variable: "--font-outfit",
  subsets: ["latin"],
  display: "swap",
});

// Monospace font - Developer-centric
const jetbrainsMono = JetBrains_Mono({
  variable: "--font-jetbrains-mono",
  subsets: ["latin"],
  display: "swap",
});

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#fafbfc" },
    { media: "(prefers-color-scheme: dark)", color: "#0c0f14" },
  ],
  width: "device-width",
  initialScale: 1,
};

export const metadata: Metadata = {
  title: "QuickMD - Free Markdown Viewer for Mac | Instant Preview",
  description:
    "QuickMD is a free, native macOS app for viewing Markdown files instantly. Syntax highlighting, dark mode, tables support. Download from the Mac App Store.",
  keywords: [
    "markdown viewer mac",
    "markdown preview mac",
    "md file viewer mac",
    "markdown reader macos",
    "free markdown viewer",
    "markdown app mac",
    "quick look markdown",
  ],
  authors: [{ name: "Falami Studio" }],
  creator: "Falami Studio",
  publisher: "Falami Studio",
  metadataBase: new URL("https://quickmd.app"),
  alternates: {
    canonical: "/",
  },
  openGraph: {
    type: "website",
    locale: "en_US",
    url: "https://quickmd.app",
    siteName: "QuickMD",
    title: "QuickMD - Free Markdown Viewer for Mac",
    description:
      "Preview Markdown files instantly with syntax highlighting, tables, and dark mode. Free native macOS app.",
    images: [
      {
        url: "/og-image.png",
        width: 1200,
        height: 630,
        alt: "QuickMD - Free Markdown Viewer for Mac",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "QuickMD - Free Markdown Viewer for Mac",
    description:
      "Preview Markdown files instantly. Syntax highlighting, dark mode, tables. Free on Mac App Store.",
    images: ["/twitter-card.png"],
  },
  robots: {
    index: true,
    follow: true,
    googleBot: {
      index: true,
      follow: true,
      "max-video-preview": -1,
      "max-image-preview": "large",
      "max-snippet": -1,
    },
  },
  icons: {
    icon: [
      { url: "/favicon.ico", sizes: "48x48" },
      { url: "/icon-64.png", type: "image/png", sizes: "64x64" },
      { url: "/icon-128.png", type: "image/png", sizes: "128x128" },
      { url: "/icon-256.png", type: "image/png", sizes: "256x256" },
    ],
    apple: "/apple-touch-icon.png",
  },
  manifest: "/site.webmanifest",
  category: "Developer Tools",
};

// JSON-LD Schema for SoftwareApplication
const jsonLd = {
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  name: "QuickMD",
  description:
    "A lightweight native macOS application for viewing Markdown files with syntax highlighting, tables, and dark mode support.",
  applicationCategory: "DeveloperApplication",
  operatingSystem: "macOS 13.0+",
  offers: {
    "@type": "Offer",
    price: "0",
    priceCurrency: "USD",
  },
  author: {
    "@type": "Organization",
    name: "Falami Studio",
  },
  downloadUrl: "https://apps.apple.com/app/quickmd/id6738038802",
  softwareVersion: "1.0",
  fileSize: "2MB",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className="scroll-smooth">
      <head>
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
        />
      </head>
      <body
        className={`${outfit.variable} ${jetbrainsMono.variable} antialiased bg-background text-foreground`}
      >
        {children}
      </body>
    </html>
  );
}
