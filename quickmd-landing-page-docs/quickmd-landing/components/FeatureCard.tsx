"use client";

import { motion } from "framer-motion";
import { ReactNode } from "react";

interface FeatureCardProps {
  icon: ReactNode;
  title: string;
  description: string;
  index?: number;
}

export function FeatureCard({ icon, title, description, index = 0 }: FeatureCardProps) {
  return (
    <motion.div
      className="feature-card group relative bg-surface rounded-[var(--radius-lg)] border border-border p-8 hover:border-accent/30"
      initial={{ opacity: 0, y: 24 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, margin: "-50px" }}
      transition={{
        duration: 0.5,
        delay: index * 0.1,
        ease: [0.4, 0, 0.2, 1],
      }}
    >
      {/* Subtle accent glow on hover */}
      <div className="absolute inset-0 rounded-[var(--radius-lg)] bg-gradient-to-br from-accent/5 to-transparent opacity-0 group-hover:opacity-100 transition-opacity duration-300" />

      {/* Icon container */}
      <div className="relative mb-5">
        <div className="inline-flex items-center justify-center w-12 h-12 rounded-[var(--radius-md)] bg-accent-subtle text-accent">
          {icon}
        </div>
      </div>

      {/* Content */}
      <h3 className="relative text-lg font-semibold text-foreground mb-2">
        {title}
      </h3>
      <p className="relative text-muted leading-relaxed text-[15px]">
        {description}
      </p>
    </motion.div>
  );
}
