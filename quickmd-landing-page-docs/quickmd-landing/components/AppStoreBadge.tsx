"use client";

import { motion } from "framer-motion";

interface AppStoreBadgeProps {
  href?: string;
  className?: string;
}

export function AppStoreBadge({
  href = "https://apps.apple.com/app/quickmd/id6738038802",
  className = "",
}: AppStoreBadgeProps) {
  return (
    <motion.a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      className={`inline-block ${className}`}
      whileHover={{ scale: 1.02 }}
      whileTap={{ scale: 0.98 }}
      transition={{ duration: 0.15 }}
      aria-label="Download on the Mac App Store"
    >
      {/* Official Apple Mac App Store badge - black background per Apple guidelines */}
      {/* Minimum height: 40px, includes required gray border as part of artwork */}
      <svg
        viewBox="0 0 165 40"
        xmlns="http://www.w3.org/2000/svg"
        className="h-11 w-auto"
        role="img"
        aria-hidden="true"
      >
        {/* Black background with subtle rounded corners */}
        <rect width="165" height="40" rx="6" fill="#000000" />
        {/* Gray border as per Apple guidelines */}
        <rect x="0.5" y="0.5" width="164" height="39" rx="5.5" fill="none" stroke="#A6A6A6" strokeWidth="1" />

        {/* Apple logo */}
        <g fill="#FFFFFF">
          <path d="M24.769 20.3c-.029-3.223 2.639-4.791 2.761-4.864-1.511-2.203-3.853-2.504-4.676-2.528-1.967-.207-3.875 1.177-4.877 1.177-1.022 0-2.565-1.157-4.228-1.123-2.14.033-4.142 1.272-5.24 3.196-2.266 3.923-.576 9.688 1.595 12.859 1.086 1.553 2.355 3.287 4.016 3.226 1.625-.067 2.232-1.036 4.193-1.036 1.943 0 2.513 1.036 4.207 1.002 1.74-.028 2.842-1.56 3.89-3.127 1.255-1.78 1.759-3.533 1.779-3.623-.04-.014-3.386-1.292-3.42-5.159z" />
          <path d="M21.75 10.6c.874-1.093 1.472-2.58 1.306-4.089-1.265.056-2.847.875-3.758 1.944-.806.942-1.526 2.486-1.34 3.938 1.421.106 2.88-.717 3.792-1.793z" />
        </g>

        {/* "Download on the" text */}
        <text x="42" y="12.5" fill="#FFFFFF" fontFamily="system-ui, -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif" fontSize="8" fontWeight="400">
          Download on the
        </text>

        {/* "Mac App Store" text */}
        <text x="42" y="28" fill="#FFFFFF" fontFamily="system-ui, -apple-system, BlinkMacSystemFont, 'SF Pro Display', sans-serif" fontSize="16" fontWeight="500">
          Mac App Store
        </text>
      </svg>
    </motion.a>
  );
}
