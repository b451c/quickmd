"use client";

import { useEffect, useState } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { Menu, X, Coffee } from "lucide-react";
import Image from "next/image";
import { Button } from "./Button";

export function Header() {
  const [scrolled, setScrolled] = useState(false);
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);

  useEffect(() => {
    const handleScroll = () => {
      setScrolled(window.scrollY > 50);
    };

    window.addEventListener("scroll", handleScroll, { passive: true });
    return () => window.removeEventListener("scroll", handleScroll);
  }, []);

  return (
    <motion.header
      className={`fixed top-0 left-0 right-0 z-50 transition-all duration-300 ${
        scrolled
          ? "glass border-b border-border shadow-sm"
          : "bg-transparent"
      }`}
      initial={{ y: -100 }}
      animate={{ y: 0 }}
      transition={{ duration: 0.5, ease: [0.4, 0, 0.2, 1] }}
    >
      <div className="max-w-6xl mx-auto px-6 h-16 flex items-center justify-between">
        {/* Logo */}
        <a href="#" className="flex items-center gap-3 group">
          <Image
            src="/icon-64.png"
            alt="QuickMD icon"
            width={32}
            height={32}
            className="group-hover:scale-105 transition-transform"
          />
          <span className="font-semibold text-lg text-foreground">
            QuickMD
          </span>
        </a>

        {/* Desktop Navigation */}
        <nav className="hidden md:flex items-center gap-8">
          <a
            href="#features"
            className="text-muted hover:text-foreground transition-colors text-[15px] font-medium"
          >
            Features
          </a>
          <a
            href="#showcase"
            className="text-muted hover:text-foreground transition-colors text-[15px] font-medium"
          >
            Preview
          </a>
          <a
            href="https://buymeacoffee.com/bsroczynskh"
            target="_blank"
            rel="noopener noreferrer"
            className="text-muted hover:text-foreground transition-colors text-[15px] font-medium flex items-center gap-1.5"
          >
            <Coffee size={16} />
            Support
          </a>
          <Button href="#download" size="sm">
            Download Free
          </Button>
        </nav>

        {/* Mobile Menu Button */}
        <button
          className="md:hidden p-2 text-muted hover:text-foreground transition-colors"
          onClick={() => setMobileMenuOpen(!mobileMenuOpen)}
          aria-label="Toggle menu"
        >
          {mobileMenuOpen ? <X size={24} /> : <Menu size={24} />}
        </button>
      </div>

      {/* Mobile Menu */}
      <AnimatePresence>
        {mobileMenuOpen && (
          <motion.div
            className="md:hidden glass border-t border-border"
            initial={{ opacity: 0, height: 0 }}
            animate={{ opacity: 1, height: "auto" }}
            exit={{ opacity: 0, height: 0 }}
            transition={{ duration: 0.2 }}
          >
            <nav className="flex flex-col px-6 py-4 gap-4">
              <a
                href="#features"
                className="text-muted hover:text-foreground transition-colors text-[15px] font-medium py-2"
                onClick={() => setMobileMenuOpen(false)}
              >
                Features
              </a>
              <a
                href="#showcase"
                className="text-muted hover:text-foreground transition-colors text-[15px] font-medium py-2"
                onClick={() => setMobileMenuOpen(false)}
              >
                Preview
              </a>
              <a
                href="https://buymeacoffee.com/bsroczynskh"
                target="_blank"
                rel="noopener noreferrer"
                className="text-muted hover:text-foreground transition-colors text-[15px] font-medium py-2 flex items-center gap-2"
                onClick={() => setMobileMenuOpen(false)}
              >
                <Coffee size={16} />
                Support
              </a>
              <Button
                href="#download"
                className="w-full mt-2"
                onClick={() => setMobileMenuOpen(false)}
              >
                Download Free
              </Button>
            </nav>
          </motion.div>
        )}
      </AnimatePresence>
    </motion.header>
  );
}
