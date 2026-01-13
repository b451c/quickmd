"use client";

import { Github, Coffee, Mail } from "lucide-react";
import Image from "next/image";

export function Footer() {
  const currentYear = new Date().getFullYear();

  return (
    <footer className="relative py-12 px-6 border-t border-border bg-code-bg/50">
      <div className="max-w-6xl mx-auto">
        <div className="grid grid-cols-1 md:grid-cols-3 gap-8 md:gap-12">
          {/* Brand */}
          <div className="md:col-span-1">
            <div className="flex items-center gap-3 mb-4">
              <Image
                src="/icon-64.png"
                alt="QuickMD icon"
                width={32}
                height={32}
                className="rounded-lg"
              />
              <span className="font-semibold text-lg text-foreground">
                QuickMD
              </span>
            </div>
            <p className="text-muted text-sm leading-relaxed mb-4">
              Read Markdown. Instantly.
              <br />
              The lightweight viewer for macOS.
            </p>
            <div className="flex items-center gap-3">
              <a
                href="https://github.com/AdrianBran/QuickMD"
                target="_blank"
                rel="noopener noreferrer"
                className="p-2 rounded-lg bg-surface border border-border text-muted hover:text-foreground hover:border-border-hover transition-all"
                aria-label="GitHub"
              >
                <Github size={18} />
              </a>
              <a
                href="https://buymeacoffee.com/falamistudio"
                target="_blank"
                rel="noopener noreferrer"
                className="p-2 rounded-lg bg-surface border border-border text-muted hover:text-foreground hover:border-border-hover transition-all"
                aria-label="Buy Me a Coffee"
              >
                <Coffee size={18} />
              </a>
            </div>
          </div>

          {/* Links */}
          <div className="md:col-span-1">
            <h4 className="text-sm font-semibold text-foreground mb-4 uppercase tracking-wider">
              Links
            </h4>
            <nav className="flex flex-col gap-3">
              <a
                href="#features"
                className="text-muted hover:text-foreground transition-colors text-sm"
              >
                Features
              </a>
              <a
                href="#showcase"
                className="text-muted hover:text-foreground transition-colors text-sm"
              >
                Preview
              </a>
              <a
                href="#download"
                className="text-muted hover:text-foreground transition-colors text-sm"
              >
                Download
              </a>
              <a
                href="https://github.com/AdrianBran/QuickMD"
                target="_blank"
                rel="noopener noreferrer"
                className="text-muted hover:text-foreground transition-colors text-sm"
              >
                GitHub
              </a>
            </nav>
          </div>

          {/* Legal */}
          <div className="md:col-span-1">
            <h4 className="text-sm font-semibold text-foreground mb-4 uppercase tracking-wider">
              Legal
            </h4>
            <nav className="flex flex-col gap-3">
              <a
                href="/privacy"
                className="text-muted hover:text-foreground transition-colors text-sm"
              >
                Privacy Policy
              </a>
              <a
                href="/terms"
                className="text-muted hover:text-foreground transition-colors text-sm"
              >
                Terms of Use
              </a>
              <a
                href="mailto:support@quickmd.app"
                className="text-muted hover:text-foreground transition-colors text-sm flex items-center gap-2"
              >
                <Mail size={14} />
                Contact
              </a>
            </nav>
          </div>
        </div>

        {/* Bottom bar */}
        <div className="mt-12 pt-8 border-t border-border flex flex-col sm:flex-row items-center justify-between gap-4">
          <p className="text-sm text-muted">
            © {currentYear} Falami Studio. Made with care for the Mac community.
          </p>
          <p className="text-sm text-subtle">
            Built with Next.js · Deployed on Vercel
          </p>
        </div>
      </div>
    </footer>
  );
}
