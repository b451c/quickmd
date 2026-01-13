"use client";

import { motion } from "framer-motion";
import {
  Zap,
  Code2,
  Table,
  Moon,
  Feather,
  Heart,
} from "lucide-react";
import { FeatureCard } from "./FeatureCard";

const features = [
  {
    icon: <Zap size={24} />,
    title: "Instant Preview",
    description:
      "Double-click any .md file and see it rendered immediately. No loading screens, no configuration. Just beautiful Markdown.",
  },
  {
    icon: <Code2 size={24} />,
    title: "Code That Pops",
    description:
      "Fenced code blocks with proper syntax highlighting. Keywords, strings, comments — all color-coded across 20+ languages.",
  },
  {
    icon: <Table size={24} />,
    title: "Tables, Tasks & More",
    description:
      "GitHub Flavored Markdown rendered correctly. Tables with headers, task lists with checkboxes, images, blockquotes — it's all there.",
  },
  {
    icon: <Moon size={24} />,
    title: "Easy on the Eyes",
    description:
      "Automatic light and dark mode support. QuickMD follows your system preference with optimized color schemes for both.",
  },
  {
    icon: <Feather size={24} />,
    title: "2MB of Pure Focus",
    description:
      "No Electron bloat. Native macOS app that launches instantly and uses minimal resources. Your MacBook will thank you.",
  },
  {
    icon: <Heart size={24} />,
    title: "Free. No Catch.",
    description:
      "No trials, no subscriptions, no in-app purchases. QuickMD is free because good tools should be accessible to everyone.",
  },
];

export function Features() {
  return (
    <section id="features" className="relative py-24 px-6">
      {/* Subtle background variation */}
      <div className="absolute inset-0 bg-code-bg/30 pointer-events-none" />

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
            Everything You Need.{" "}
            <span className="text-muted">Nothing You Don&apos;t.</span>
          </h2>
          <p className="text-muted text-lg max-w-2xl mx-auto">
            Built for developers who just want to read Markdown without the bloat.
          </p>
        </motion.div>

        {/* Features grid */}
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
          {features.map((feature, index) => (
            <FeatureCard
              key={feature.title}
              icon={feature.icon}
              title={feature.title}
              description={feature.description}
              index={index}
            />
          ))}
        </div>
      </div>
    </section>
  );
}
