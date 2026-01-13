import { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "Terms of Use | QuickMD",
  description: "Terms of Use for QuickMD - Free Markdown Viewer for Mac",
};

export default function TermsOfUse() {
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
          Terms of Use
        </h1>

        <div className="prose prose-slate dark:prose-invert max-w-none">
          <p className="text-muted text-lg mb-6">
            Last updated: January 2024
          </p>

          <h2 className="text-2xl font-semibold text-foreground mt-8 mb-4">
            Agreement
          </h2>
          <p className="text-muted leading-relaxed mb-4">
            By downloading and using QuickMD, you agree to these terms of use.
          </p>

          <h2 className="text-2xl font-semibold text-foreground mt-8 mb-4">
            License
          </h2>
          <p className="text-muted leading-relaxed mb-4">
            QuickMD is provided free of charge for personal and commercial use.
            You may use the application on any Mac computers you own.
          </p>

          <h2 className="text-2xl font-semibold text-foreground mt-8 mb-4">
            Disclaimer
          </h2>
          <p className="text-muted leading-relaxed mb-4">
            QuickMD is provided &quot;as is&quot; without warranty of any kind, express
            or implied. The developer is not liable for any damages arising from
            the use of this application.
          </p>

          <h2 className="text-2xl font-semibold text-foreground mt-8 mb-4">
            Limitations
          </h2>
          <p className="text-muted leading-relaxed mb-4">
            QuickMD is a viewer only. It does not modify, edit, or save changes
            to your Markdown files. Any changes to files must be made using
            external editors.
          </p>

          <h2 className="text-2xl font-semibold text-foreground mt-8 mb-4">
            Updates
          </h2>
          <p className="text-muted leading-relaxed mb-4">
            We may update these terms from time to time. Continued use of
            QuickMD after changes constitutes acceptance of the new terms.
          </p>

          <h2 className="text-2xl font-semibold text-foreground mt-8 mb-4">
            Contact
          </h2>
          <p className="text-muted leading-relaxed mb-4">
            For questions about these terms, please contact us at{" "}
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
