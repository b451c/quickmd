"use client";

import { motion } from "framer-motion";
import { ArrowRight, Github } from "lucide-react";
import { Button } from "./Button";
import { AppStoreBadge } from "./AppStoreBadge";
import Image from "next/image";

export function Hero() {
  return (
    <section
      id="hero"
      className="relative min-h-screen flex flex-col items-center justify-center px-6 pt-24 pb-16 overflow-hidden"
    >
      {/* Background gradient mesh */}
      <div className="absolute inset-0 bg-gradient-mesh pointer-events-none" />

      {/* Subtle grid overlay */}
      <div className="absolute inset-0 bg-grid opacity-[0.02] pointer-events-none" />

      {/* Content container */}
      <div className="relative z-10 max-w-4xl mx-auto text-center">
        {/* Badge */}
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.1 }}
          className="mb-6"
        >
          <span className="inline-flex items-center gap-2 px-4 py-2 rounded-full bg-accent-subtle border border-accent/20 text-accent text-sm font-medium">
            <span className="w-2 h-2 rounded-full bg-accent animate-pulse" />
            Free on Mac App Store
          </span>
        </motion.div>

        {/* Main headline */}
        <motion.h1
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.2 }}
          className="text-5xl sm:text-6xl md:text-7xl font-bold tracking-tight text-foreground mb-6"
        >
          Read Markdown.
          <br />
          <span className="text-accent">Instantly.</span>
        </motion.h1>

        {/* Subheadline */}
        <motion.p
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.3 }}
          className="text-lg sm:text-xl text-muted max-w-2xl mx-auto mb-10 leading-relaxed"
        >
          A lightweight macOS app that renders your{" "}
          <code className="px-2 py-1 rounded bg-code-bg text-foreground text-[0.9em] font-mono">
            .md
          </code>{" "}
          files beautifully. Syntax highlighting, dark mode, tables — all for free.
        </motion.p>

        {/* CTA Buttons */}
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.4 }}
          className="flex flex-col sm:flex-row items-center justify-center gap-4 mb-16"
        >
          <AppStoreBadge />
          <Button
            href="https://github.com/AdrianBran/QuickMD"
            variant="secondary"
            external
          >
            <Github size={18} />
            View on GitHub
            <ArrowRight size={16} />
          </Button>
        </motion.div>

        {/* Hero Screenshot */}
        <motion.div
          initial={{ opacity: 0, y: 40, scale: 0.95 }}
          animate={{ opacity: 1, y: 0, scale: 1 }}
          transition={{ duration: 0.7, delay: 0.5, ease: [0.4, 0, 0.2, 1] }}
          className="relative"
        >
          {/* Screenshot frame with macOS window chrome */}
          <div className="relative max-w-4xl mx-auto">
            {/* Window shadow */}
            <div className="absolute -inset-4 bg-gradient-to-b from-accent/5 to-transparent rounded-3xl blur-2xl" />

            {/* Window container */}
            <div className="relative screenshot-frame bg-surface overflow-hidden">
              {/* macOS traffic lights */}
              <div className="flex items-center gap-2 px-4 py-3 border-b border-border bg-surface">
                <div className="w-3 h-3 rounded-full bg-[#FF5F56]" />
                <div className="w-3 h-3 rounded-full bg-[#FFBD2E]" />
                <div className="w-3 h-3 rounded-full bg-[#27C93F]" />
                <span className="ml-4 text-xs text-muted font-mono">README.md</span>
              </div>

              {/* Screenshot content - mockup of markdown rendering */}
              <div className="p-8 bg-surface min-h-[400px] font-mono text-left">
                {/* H1 */}
                <h1 className="text-2xl font-bold text-foreground mb-4">
                  Welcome to QuickMD
                </h1>

                {/* Paragraph */}
                <p className="text-muted mb-6 leading-relaxed font-sans">
                  The fastest way to preview Markdown on your Mac. Double-click any{" "}
                  <code className="px-1.5 py-0.5 rounded bg-code-bg text-foreground text-sm">
                    .md
                  </code>{" "}
                  file and see it rendered instantly.
                </p>

                {/* H2 */}
                <h2 className="text-lg font-semibold text-foreground mb-3">Features</h2>

                {/* List */}
                <ul className="space-y-2 mb-6 font-sans">
                  <li className="flex items-center gap-2 text-muted">
                    <span className="text-accent">•</span>
                    <strong className="text-foreground font-medium">Instant preview</strong> — No waiting, no loading
                  </li>
                  <li className="flex items-center gap-2 text-muted">
                    <span className="text-accent">•</span>
                    <strong className="text-foreground font-medium">Syntax highlighting</strong> — Code that pops
                  </li>
                  <li className="flex items-center gap-2 text-muted">
                    <span className="text-accent">•</span>
                    <strong className="text-foreground font-medium">Dark mode</strong> — Easy on the eyes
                  </li>
                </ul>

                {/* Code block */}
                <div className="rounded-lg bg-code-bg border border-code-border overflow-hidden">
                  <div className="px-4 py-2 border-b border-code-border">
                    <span className="text-[11px] text-muted uppercase tracking-wider">
                      python
                    </span>
                  </div>
                  <pre className="p-4 text-sm overflow-x-auto">
                    <code>
                      <span style={{ color: "var(--syntax-keyword)" }}>def</span>{" "}
                      <span style={{ color: "var(--syntax-function)" }}>hello</span>
                      <span className="text-foreground">(</span>
                      <span style={{ color: "var(--syntax-type)" }}>name</span>
                      <span className="text-foreground">):</span>
                      {"\n"}
                      {"    "}
                      <span style={{ color: "var(--syntax-keyword)" }}>return</span>{" "}
                      <span style={{ color: "var(--syntax-string)" }}>f&quot;Hello, </span>
                      <span className="text-foreground">{"{"}</span>
                      <span style={{ color: "var(--syntax-type)" }}>name</span>
                      <span className="text-foreground">{"}"}</span>
                      <span style={{ color: "var(--syntax-string)" }}>!&quot;</span>
                      {"\n\n"}
                      <span style={{ color: "var(--syntax-comment)" }}># Quick and easy</span>
                      {"\n"}
                      <span style={{ color: "var(--syntax-function)" }}>print</span>
                      <span className="text-foreground">(</span>
                      <span style={{ color: "var(--syntax-function)" }}>hello</span>
                      <span className="text-foreground">(</span>
                      <span style={{ color: "var(--syntax-string)" }}>&quot;World&quot;</span>
                      <span className="text-foreground">))</span>
                    </code>
                  </pre>
                </div>
              </div>
            </div>
          </div>
        </motion.div>
      </div>

      {/* Scroll indicator */}
      <motion.div
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ delay: 1.2, duration: 0.5 }}
        className="absolute bottom-8 left-1/2 -translate-x-1/2"
      >
        <motion.div
          animate={{ y: [0, 8, 0] }}
          transition={{ duration: 1.5, repeat: Infinity, ease: "easeInOut" }}
          className="w-6 h-10 rounded-full border-2 border-muted/30 flex items-start justify-center p-2"
        >
          <div className="w-1 h-2 rounded-full bg-muted/50" />
        </motion.div>
      </motion.div>
    </section>
  );
}
