import { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "Privacy Policy | QuickMD",
  description: "Privacy Policy for QuickMD - Free Markdown Viewer for Mac",
};

export default function PrivacyPolicy() {
  return (
    <div className="min-h-screen bg-background py-24 px-6">
      <div className="max-w-3xl mx-auto">
        <Link
          href="/"
          className="text-accent hover:text-accent-hover transition-colors text-sm mb-8 inline-block"
        >
          ← Back to Home
        </Link>

        <h1 className="text-4xl font-bold text-foreground mb-8">
          Privacy Policy
        </h1>

        <div className="prose prose-slate dark:prose-invert max-w-none">
          <p className="text-muted text-lg mb-6">
            Last updated: January 2024
          </p>

          <h2 className="text-2xl font-semibold text-foreground mt-8 mb-4">
            Overview
          </h2>
          <p className="text-muted leading-relaxed mb-4">
            QuickMD is designed with privacy in mind. We believe that a Markdown
            viewer should be simple, fast, and respectful of your privacy.
          </p>

          <h2 className="text-2xl font-semibold text-foreground mt-8 mb-4">
            Data Collection
          </h2>
          <p className="text-muted leading-relaxed mb-4">
            <strong className="text-foreground">QuickMD does not collect any personal data.</strong>
          </p>
          <ul className="list-disc list-inside text-muted space-y-2 mb-4">
            <li>No analytics or tracking</li>
            <li>No user accounts required</li>
            <li>No network requests (except for loading remote images in Markdown files)</li>
            <li>All file processing happens locally on your device</li>
          </ul>

          <h2 className="text-2xl font-semibold text-foreground mt-8 mb-4">
            File Access
          </h2>
          <p className="text-muted leading-relaxed mb-4">
            QuickMD only accesses files that you explicitly open with the
            application. The app runs in a sandboxed environment and cannot
            access other files on your system without your permission.
          </p>

          <h2 className="text-2xl font-semibold text-foreground mt-8 mb-4">
            Third-Party Services
          </h2>
          <p className="text-muted leading-relaxed mb-4">
            QuickMD does not integrate with any third-party services or APIs.
            The application works entirely offline once installed.
          </p>

          <h2 className="text-2xl font-semibold text-foreground mt-8 mb-4">
            Contact
          </h2>
          <p className="text-muted leading-relaxed mb-4">
            If you have any questions about this privacy policy, please contact
            us at{" "}
            <a
              href="mailto:support@quickmd.app"
              className="text-accent hover:text-accent-hover"
            >
              support@quickmd.app
            </a>
            .
          </p>
        </div>
      </div>
    </div>
  );
}
