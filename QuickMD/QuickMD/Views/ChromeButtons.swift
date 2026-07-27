import SwiftUI
import AppKit

// MARK: - Heading Block View (hover-to-copy section)

/// Heading with hover-to-reveal copy button that copies the section.
/// NOTE: deliberately NO `.textSelection(.enabled)` — that modifier's internal
/// SelectionOverlay is what makes LazyVStack freeze (constraints.md, bug B).
/// Keeping plain Text preserves the inline copy-button layout; copying a
/// heading is covered by the copy-section button itself.
struct HeadingBlockView: View {
    let id: String
    let level: Int
    let title: String
    let theme: MarkdownTheme
    var fontScale: CGFloat = 1.0
    let searchText: String
    let focusedOccurrence: Int?
    let onCopySection: () -> Void
    @State private var isHovered = false
    @State private var hideWorkItem: DispatchWorkItem?

    var body: some View {
        let headingAttr = MarkdownRenderer(theme: theme, fontScale: fontScale).renderHeader(title, level: level)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if searchText.isEmpty {
                Text(headingAttr)
            } else {
                Text(searchHighlight(headingAttr, term: searchText, focusedOccurrence: focusedOccurrence))
            }

            Button {
                onCopySection()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy section")
            .opacity(isHovered ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            hideWorkItem?.cancel()
            if hovering {
                isHovered = true
            } else {
                let work = DispatchWorkItem { isHovered = false }
                hideWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
            }
        }
    }
}

// MARK: - Copy Source Button

/// Subtle top-right button to copy the entire raw markdown
struct CopySourceButton: View {
    let theme: MarkdownTheme
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                if isHovered {
                    Text("Copy source")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, isHovered ? 10 : 6)
            .padding(.vertical, 4)
            .background(theme.codeBackgroundColor.opacity(isHovered ? 0.9 : 0.6))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .foregroundColor(.secondary)
        .opacity(isHovered ? 1.0 : 0.5)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Copy source")
    }
}

// MARK: - Edit In External Editor Button

/// Top-right pencil button — one-click handoff to the user's editor (⌘E).
struct EditInEditorButton: View {
    let theme: MarkdownTheme
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                if isHovered {
                    Text("Edit")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, isHovered ? 10 : 6)
            .padding(.vertical, 4)
            .background(theme.codeBackgroundColor.opacity(isHovered ? 0.9 : 0.6))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .foregroundColor(.secondary)
        .opacity(isHovered ? 1.0 : 0.5)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Open in external editor (⌘E)")
    }
}

// MARK: - Tip Jar Button (App Store version)

#if APPSTORE
struct TipJarButton: View {
    let theme: MarkdownTheme
    @Environment(\.openWindow) private var openWindow
    @State private var isHovered = false

    var body: some View {
        Button {
            openWindow(id: "tip-jar")
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11))
                if isHovered {
                    Text("Tip Jar")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, isHovered ? 10 : 6)
            .padding(.vertical, 4)
            .background(theme.codeBackgroundColor.opacity(isHovered ? 0.9 : 0.6))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .foregroundColor(.pink)
        .opacity(isHovered ? 1.0 : 0.5)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Support QuickMD")
    }
}
#endif

// MARK: - Support Button (GitHub version)

#if !APPSTORE
struct SupportButton: View {
    let theme: MarkdownTheme
    @State private var isHovered = false

    var body: some View {
        Menu {
            Button {
                NSWorkspace.shared.open(AppURLs.website)
            } label: {
                Label("Visit qmd.app", systemImage: "globe")
            }
            Divider()
            Button {
                NSWorkspace.shared.open(AppURLs.buyMeCoffee)
            } label: {
                Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
            }
            Button {
                NSWorkspace.shared.open(AppURLs.kofi)
            } label: {
                Label("Ko-fi", systemImage: "heart.fill")
            }
        } label: {
            HStack(spacing: 4) {
                Text("☕")
                    .font(.system(size: 12))
                if isHovered {
                    Text("Support")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, isHovered ? 10 : 6)
            .padding(.vertical, 4)
            .background(theme.codeBackgroundColor.opacity(isHovered ? 0.9 : 0.6))
            .clipShape(Capsule())
        }
        .menuStyle(.button)
        .opacity(isHovered ? 1.0 : 0.5)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Support QuickMD development")
    }
}
#endif
