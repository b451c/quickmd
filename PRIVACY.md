# Privacy Policy for QuickMD

**Last updated: October 1, 2026**

## Overview

QuickMD is committed to protecting your privacy. This privacy policy explains how QuickMD handles your data and what information (if any) we collect.

## The Short Version

**QuickMD collects ZERO personal data. None. Nada. Nothing.**

We believe your files and data are yours and yours alone. QuickMD is a simple Markdown viewer that runs entirely on your device, offline, with no internet connection required for core functionality.

---

## Detailed Privacy Information

### Data Collection

**QuickMD does not collect, store, or transmit any personal information.**

Specifically, QuickMD does NOT collect:
- Your name, email, or contact information
- File names or file contents
- Usage statistics or analytics
- Device information
- Location data
- Cookies or tracking data

### File Access

QuickMD only accesses files that **you explicitly open**.

- Files are read locally from your device
- File contents are never transmitted over the internet
- Files are never uploaded to any server
- No files are cached or stored by QuickMD outside of macOS's standard document handling

### Network Access

QuickMD requests **Outgoing Network Connections** permission for the following limited purposes:

1. **Remote Images:** If your Markdown file contains images hosted on the internet (e.g., `![Image](https://example.com/image.png)`), QuickMD will fetch those images to display them, using Apple's native `URLSession` API. Images embedded in the file itself (`data:` URLs) are decoded locally and need no network.

2. **Check for Updates (GitHub / Homebrew version only):** When you choose "Check for Updates...", QuickMD asks GitHub's public API (api.github.com) for the latest release number. Nothing about you or your files is sent. The Mac App Store version gets updates through the App Store instead.

3. **Support Links:** The app contains support buttons that open your browser to Buy Me a Coffee (buymeacoffee.com/bsroczynskh) or Ko-fi (ko-fi.com/quickmd). No data is transmitted - this simply opens a web page.

4. **Help Links:** The Help menu contains links to the QuickMD GitHub repository and qmd.app. Clicking these opens your browser; no data is transmitted by QuickMD.

**QuickMD does NOT:**
- Track which images you view
- Log network requests
- Send any data to our servers (we don't have servers!)
- Use analytics services
- Use advertising networks

### Third-Party Services

QuickMD does not use any third-party services, analytics frameworks, or tracking code.

The only external interactions are:
- **Buy Me a Coffee / Ko-fi** (optional support links) - if you click a support button, you'll be taken to buymeacoffee.com or ko-fi.com in your browser. Their privacy policies apply once you leave QuickMD.
- **Tip Jar** (Mac App Store version only, optional) - tips are processed by Apple's in-app purchase system.
- **Donation goal on qmd.app** - the website (not the app) shows a donation total. When Buy Me a Coffee or Ko-fi notify qmd.app about a donation, only the amount, currency, date and the platform's transaction ID are stored - never names, email addresses or messages.

### App Sandbox

QuickMD runs in **macOS App Sandbox** with the following permissions:

| Permission | Purpose |
|------------|---------|
| **User Selected File (Read Only)** | To read Markdown files you explicitly open |
| **Outgoing Network Connections** | To fetch remote images from URLs in your Markdown files, and (GitHub version) Check for Updates |

QuickMD has **NO** access to:
- Your contacts, calendar, or location
- Your camera, microphone, or photos
- Your Downloads, Desktop, or Documents folders (unless you explicitly open a file from there)
- Any system files or settings

### Open Source

QuickMD is **fully open source**. You can review the entire codebase at:

**https://github.com/b451c/quickmd**

See for yourself—there's no analytics, no tracking, no sneaky code. Just a simple Markdown viewer.

### Changes to This Policy

If we ever change this privacy policy (e.g., if we add optional features that require data collection), we will:

1. Update the "Last updated" date at the top
2. Notify users via the GitHub repository
3. Require explicit opt-in for any new data collection

### Data Security

Since QuickMD doesn't collect data, there's no data to secure. Your Markdown files remain on your device and are processed entirely locally.

### Children's Privacy

QuickMD does not knowingly collect any information from anyone, including children under 13. Since we collect zero data, the app is safe for all ages.

### International Users

QuickMD works the same everywhere. We don't collect data from users in any country.

### Contact

If you have questions about this privacy policy, please:

- **Open an issue:** https://github.com/b451c/quickmd/issues
- **Email:** [Contact information will be added when available]

### Your Rights

You have the right to:
- Use QuickMD without providing any personal information (which is exactly how it works)
- Know what data we collect (zero)
- Request deletion of your data (there is no data to delete)

---

## Summary

| Question | Answer |
|----------|--------|
| Does QuickMD collect my data? | **No** |
| Does QuickMD use analytics? | **No** |
| Does QuickMD track me? | **No** |
| Are my files sent to a server? | **No** |
| Can QuickMD work offline? | **Yes** (except for remote images in your Markdown and Check for Updates) |
| Is the code open source? | **Yes** - https://github.com/b451c/quickmd |

---

**QuickMD respects your privacy because we believe software should serve you, not spy on you.**

If you appreciate privacy-focused software, consider [supporting QuickMD](https://buymeacoffee.com/bsroczynskh) ☕
