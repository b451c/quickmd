"use client";

import { motion } from "framer-motion";
import { Sun, Moon } from "lucide-react";

export function Showcase() {
  return (
    <section id="showcase" className="relative py-24 px-6 overflow-hidden">
      {/* Background accent */}
      <div className="absolute inset-0 bg-gradient-mesh pointer-events-none" />

      <div className="relative z-10 max-w-6xl mx-auto">
        {/* Section header */}
        <motion.div
          className="text-center mb-16"
          initial={{ opacity: 0, y: 20 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-100px" }}
          transition={{ duration: 0.5 }}
        >
          <h2 className="text-3xl sm:text-4xl font-bold text-foreground mb-4">
            See It In Action
          </h2>
          <p className="text-muted text-lg max-w-2xl mx-auto">
            Beautiful rendering in both light and dark mode, following your system preference.
          </p>
        </motion.div>

        {/* Light/Dark mode showcase */}
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
          {/* Light Mode Screenshot */}
          <motion.div
            initial={{ opacity: 0, x: -30 }}
            whileInView={{ opacity: 1, x: 0 }}
            viewport={{ once: true, margin: "-50px" }}
            transition={{ duration: 0.6 }}
          >
            <div className="flex items-center gap-2 mb-4">
              <Sun size={18} className="text-amber-500" />
              <span className="text-sm font-medium text-muted">Light Mode</span>
            </div>
            {/* Matching real QuickMD app - MarkdownTheme.swift light mode */}
            <div className="screenshot-frame bg-[#fafafa] overflow-hidden">
              {/* Window chrome */}
              <div className="flex items-center gap-2 px-4 py-3 border-b border-[#d4d4d4] bg-[#fafafa]">
                <div className="w-3 h-3 rounded-full bg-[#FF5F56]" />
                <div className="w-3 h-3 rounded-full bg-[#FFBD2E]" />
                <div className="w-3 h-3 rounded-full bg-[#27C93F]" />
                <span className="ml-4 text-xs text-[#666666] font-mono">CHANGELOG.md</span>
              </div>

              {/* Content - Light theme matching app */}
              <div className="p-6 min-h-[320px] text-left font-sans">
                <h1 className="text-xl font-bold text-[#000000] mb-3">
                  Changelog
                </h1>

                <h2 className="text-base font-semibold text-[#000000] mb-2">
                  v1.0.0{" "}
                  <span className="text-[#666666] font-normal text-sm">
                    — January 2024
                  </span>
                </h2>

                {/* Bullet points - app uses black • */}
                <ul className="space-y-1.5 mb-4 text-[#666666] text-sm">
                  <li className="flex items-start gap-2">
                    <span className="text-[#000000]">•</span>
                    Initial release on Mac App Store
                  </li>
                  <li className="flex items-start gap-2">
                    <span className="text-[#000000]">•</span>
                    Syntax highlighting for 20+ languages
                  </li>
                  <li className="flex items-start gap-2">
                    <span className="text-[#000000]">•</span>
                    Full GFM support (tables, task lists)
                  </li>
                </ul>

                {/* Table - matching app: headerBackgroundColor = 90% white */}
                <div className="rounded border border-[#c0c0c0]/30 overflow-hidden text-sm">
                  <table className="w-full">
                    <thead className="bg-[#e6e6e6]">
                      <tr>
                        <th className="px-3 py-2 text-left font-semibold text-[#000000]">
                          Feature
                        </th>
                        <th className="px-3 py-2 text-left font-semibold text-[#000000]">
                          Status
                        </th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-[#c0c0c0]/30 bg-[#fafafa]">
                      <tr>
                        <td className="px-3 py-2 text-[#000000]">Tables</td>
                        <td className="px-3 py-2 text-[#000000]">Done</td>
                      </tr>
                      <tr>
                        <td className="px-3 py-2 text-[#000000]">Code Blocks</td>
                        <td className="px-3 py-2 text-[#000000]">Done</td>
                      </tr>
                      <tr>
                        <td className="px-3 py-2 text-[#000000]">Images</td>
                        <td className="px-3 py-2 text-[#000000]">Done</td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>
          </motion.div>

          {/* Dark Mode Screenshot */}
          <motion.div
            initial={{ opacity: 0, x: 30 }}
            whileInView={{ opacity: 1, x: 0 }}
            viewport={{ once: true, margin: "-50px" }}
            transition={{ duration: 0.6, delay: 0.1 }}
          >
            <div className="flex items-center gap-2 mb-4">
              <Moon size={18} className="text-indigo-400" />
              <span className="text-sm font-medium text-muted">Dark Mode</span>
            </div>
            {/* Matching real QuickMD app - MarkdownTheme.swift dark mode */}
            <div className="screenshot-frame bg-[#1f1f1f] overflow-hidden">
              {/* Window chrome */}
              <div className="flex items-center gap-2 px-4 py-3 border-b border-[#808080]/50 bg-[#1f1f1f]">
                <div className="w-3 h-3 rounded-full bg-[#FF5F56]" />
                <div className="w-3 h-3 rounded-full bg-[#FFBD2E]" />
                <div className="w-3 h-3 rounded-full bg-[#27C93F]" />
                <span className="ml-4 text-xs text-[#808080] font-mono">CHANGELOG.md</span>
              </div>

              {/* Content - Dark theme matching app */}
              <div className="p-6 min-h-[320px] text-left font-sans">
                <h1 className="text-xl font-bold text-[#ffffff] mb-3">
                  Changelog
                </h1>

                <h2 className="text-base font-semibold text-[#ffffff] mb-2">
                  v1.0.0{" "}
                  <span className="text-[#808080] font-normal text-sm">
                    — January 2024
                  </span>
                </h2>

                {/* Bullet points - app uses white • */}
                <ul className="space-y-1.5 mb-4 text-[#808080] text-sm">
                  <li className="flex items-start gap-2">
                    <span className="text-[#ffffff]">•</span>
                    Initial release on Mac App Store
                  </li>
                  <li className="flex items-start gap-2">
                    <span className="text-[#ffffff]">•</span>
                    Syntax highlighting for 20+ languages
                  </li>
                  <li className="flex items-start gap-2">
                    <span className="text-[#ffffff]">•</span>
                    Full GFM support (tables, task lists)
                  </li>
                </ul>

                {/* Table - matching app: headerBackgroundColor = 20% white */}
                <div className="rounded border border-[#808080]/50 overflow-hidden text-sm">
                  <table className="w-full">
                    <thead className="bg-[#333333]">
                      <tr>
                        <th className="px-3 py-2 text-left font-semibold text-[#ffffff]">
                          Feature
                        </th>
                        <th className="px-3 py-2 text-left font-semibold text-[#ffffff]">
                          Status
                        </th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-[#808080]/50 bg-[#1f1f1f]">
                      <tr>
                        <td className="px-3 py-2 text-[#ffffff]">Tables</td>
                        <td className="px-3 py-2 text-[#ffffff]">Done</td>
                      </tr>
                      <tr>
                        <td className="px-3 py-2 text-[#ffffff]">Code Blocks</td>
                        <td className="px-3 py-2 text-[#ffffff]">Done</td>
                      </tr>
                      <tr>
                        <td className="px-3 py-2 text-[#ffffff]">Images</td>
                        <td className="px-3 py-2 text-[#ffffff]">Done</td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            </div>
          </motion.div>
        </div>

        {/* Code highlighting showcase */}
        <motion.div
          className="mt-16"
          initial={{ opacity: 0, y: 30 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-50px" }}
          transition={{ duration: 0.6 }}
        >
          <div className="text-center mb-8">
            <h3 className="text-xl font-semibold text-foreground mb-2">
              Syntax Highlighting That Shines
            </h3>
            <p className="text-muted">
              Support for Swift, Python, JavaScript, Go, Rust, and 15+ more languages.
            </p>
          </div>

          {/* Code samples grid */}
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            {/* Swift */}
            <div className="rounded-[var(--radius-lg)] bg-code-bg border border-code-border overflow-hidden">
              <div className="px-4 py-2 border-b border-code-border flex items-center justify-between">
                <span className="text-[11px] text-muted uppercase tracking-wider">
                  swift
                </span>
                <div className="w-2 h-2 rounded-full bg-orange-500" />
              </div>
              <pre className="p-4 text-xs font-mono overflow-x-auto">
                <code>
                  <span style={{ color: "var(--syntax-keyword)" }}>struct</span>{" "}
                  <span style={{ color: "var(--syntax-type)" }}>User</span>
                  <span className="text-foreground">{" {"}</span>
                  {"\n"}
                  {"    "}
                  <span style={{ color: "var(--syntax-keyword)" }}>let</span>{" "}
                  <span className="text-foreground">name</span>
                  <span className="text-foreground">:</span>{" "}
                  <span style={{ color: "var(--syntax-type)" }}>String</span>
                  {"\n"}
                  {"    "}
                  <span style={{ color: "var(--syntax-keyword)" }}>var</span>{" "}
                  <span className="text-foreground">age</span>
                  <span className="text-foreground">:</span>{" "}
                  <span style={{ color: "var(--syntax-type)" }}>Int</span>
                  <span className="text-foreground">{" = "}</span>
                  <span style={{ color: "var(--syntax-number)" }}>25</span>
                  {"\n"}
                  <span className="text-foreground">{"}"}</span>
                </code>
              </pre>
            </div>

            {/* JavaScript */}
            <div className="rounded-[var(--radius-lg)] bg-code-bg border border-code-border overflow-hidden">
              <div className="px-4 py-2 border-b border-code-border flex items-center justify-between">
                <span className="text-[11px] text-muted uppercase tracking-wider">
                  javascript
                </span>
                <div className="w-2 h-2 rounded-full bg-yellow-400" />
              </div>
              <pre className="p-4 text-xs font-mono overflow-x-auto">
                <code>
                  <span style={{ color: "var(--syntax-keyword)" }}>const</span>{" "}
                  <span style={{ color: "var(--syntax-function)" }}>greet</span>
                  <span className="text-foreground">{" = ("}</span>
                  <span style={{ color: "var(--syntax-type)" }}>name</span>
                  <span className="text-foreground">{") => {"}</span>
                  {"\n"}
                  {"  "}
                  <span style={{ color: "var(--syntax-keyword)" }}>return</span>{" "}
                  <span style={{ color: "var(--syntax-string)" }}>`Hello, ${"{"}</span>
                  <span style={{ color: "var(--syntax-type)" }}>name</span>
                  <span style={{ color: "var(--syntax-string)" }}>{"}!`"}</span>
                  <span className="text-foreground">;</span>
                  {"\n"}
                  <span className="text-foreground">{"};"}</span>
                </code>
              </pre>
            </div>

            {/* Go */}
            <div className="rounded-[var(--radius-lg)] bg-code-bg border border-code-border overflow-hidden">
              <div className="px-4 py-2 border-b border-code-border flex items-center justify-between">
                <span className="text-[11px] text-muted uppercase tracking-wider">
                  go
                </span>
                <div className="w-2 h-2 rounded-full bg-cyan-500" />
              </div>
              <pre className="p-4 text-xs font-mono overflow-x-auto">
                <code>
                  <span style={{ color: "var(--syntax-keyword)" }}>func</span>{" "}
                  <span style={{ color: "var(--syntax-function)" }}>main</span>
                  <span className="text-foreground">() {"{"}</span>
                  {"\n"}
                  {"  "}
                  <span className="text-foreground">fmt.</span>
                  <span style={{ color: "var(--syntax-function)" }}>Println</span>
                  <span className="text-foreground">(</span>
                  <span style={{ color: "var(--syntax-string)" }}>&quot;QuickMD&quot;</span>
                  <span className="text-foreground">)</span>
                  {"\n"}
                  <span className="text-foreground">{"}"}</span>
                </code>
              </pre>
            </div>
          </div>
        </motion.div>
      </div>
    </section>
  );
}
