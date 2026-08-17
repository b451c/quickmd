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

// MARK: - Shared hover-expand capsule

/// How a chrome pill decides whether to show its label.
///
/// `.local` — the pill tracks the pointer itself (Support, Tip Jar).
/// `.cluster` — a parent `chromeHoverCluster()` owns hover so siblings
/// expand and collapse together and do not shove each other sideways.
private enum ChromeExpansionSource: Equatable {
    case local
    case cluster(expanded: Bool)
}

private struct ChromeExpansionSourceKey: EnvironmentKey {
    static let defaultValue: ChromeExpansionSource = .local
}

private extension EnvironmentValues {
    var chromeExpansionSource: ChromeExpansionSource {
        get { self[ChromeExpansionSourceKey.self] }
        set { self[ChromeExpansionSourceKey.self] = newValue }
    }
}

/// Pointer tracking for one hover region. Cancels an in-flight collapse on
/// re-entry and on disappear so a late timer cannot mutate a gone view.
private struct ChromeHoverTracking: ViewModifier {
    @Binding var hover: ChromeHoverState
    @State private var collapseWork: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                collapseWork?.cancel()
                collapseWork = nil
                var next = hover
                if hovering {
                    next.pointerEntered()
                    hover = next
                } else {
                    let generation = next.pointerExited()
                    hover = next
                    let work = DispatchWorkItem {
                        var collapsed = hover
                        collapsed.applyScheduledCollapse(generation: generation)
                        hover = collapsed
                    }
                    collapseWork = work
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + ChromeHoverState.collapseDelay,
                        execute: work
                    )
                }
            }
            .onDisappear {
                collapseWork?.cancel()
                collapseWork = nil
            }
    }
}

/// Shared hover for a group of pills. Independent per-button expansion
/// shifts siblings and makes the pointer miss the other control.
struct ChromeHoverCluster: ViewModifier {
    @State private var hover = ChromeHoverState()

    func body(content: Content) -> some View {
        content
            // Grow the hover bounds (gap + 4pt slop) without shifting layout.
            // onHover tracks layout bounds, not contentShape, so padding is
            // what actually keeps the pointer "inside" while crossing pills.
            .padding(4)
            .contentShape(Rectangle())
            .environment(\.chromeExpansionSource, .cluster(expanded: hover.isExpanded))
            .modifier(ChromeHoverTracking(hover: $hover))
            .padding(-4)
    }
}

extension View {
    func chromeHoverCluster() -> some View {
        modifier(ChromeHoverCluster())
    }
}

/// Visual capsule used by every document-chrome pill. Expansion comes from
/// a parent cluster when present, otherwise from local hover.
struct ChromePillLabel<Icon: View>: View {
    let theme: MarkdownTheme
    let title: String
    var tint: Color = .secondary
    @ViewBuilder var icon: () -> Icon

    @Environment(\.chromeExpansionSource) private var expansionSource
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var localHover = ChromeHoverState()

    private var expanded: Bool {
        switch expansionSource {
        case .cluster(let expanded): return expanded
        case .local: return localHover.isExpanded
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            icon()
            if expanded {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .padding(.horizontal, expanded ? 10 : 6)
        .padding(.vertical, 4)
        .background(theme.codeBackgroundColor.opacity(expanded ? 0.9 : 0.6))
        .clipShape(Capsule())
        .contentShape(Capsule())
        .foregroundColor(tint)
        .opacity(expanded ? 1.0 : 0.5)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: expanded)
        .modifier(LocalHoverIfNeeded(enabled: isLocal, hover: $localHover))
    }

    private var isLocal: Bool {
        if case .local = expansionSource { return true }
        return false
    }
}

private struct LocalHoverIfNeeded: ViewModifier {
    let enabled: Bool
    @Binding var hover: ChromeHoverState

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.modifier(ChromeHoverTracking(hover: $hover))
        } else {
            content
        }
    }
}

/// Button-wrapped chrome pill. Keeps a stable accessibility name even
/// when the visible label is collapsed.
struct ChromePill<Icon: View>: View {
    let theme: MarkdownTheme
    let title: String
    let help: String
    var tint: Color = .secondary
    let action: () -> Void
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        Button(action: action) {
            ChromePillLabel(theme: theme, title: title, tint: tint, icon: icon)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
        .accessibilityLabel(title)
    }
}

// MARK: - Copy Source Button

/// Subtle top-right button to copy the entire raw markdown
struct CopySourceButton: View {
    let theme: MarkdownTheme
    let action: () -> Void

    var body: some View {
        ChromePill(theme: theme, title: "Copy source", help: "Copy source", action: action) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11))
        }
    }
}

// MARK: - Edit In External Editor Button

/// Top-right pencil button — one-click handoff to the user's editor (⌘E).
struct EditInEditorButton: View {
    let theme: MarkdownTheme
    let action: () -> Void

    var body: some View {
        ChromePill(
            theme: theme,
            title: "Edit",
            help: "Open in external editor (⌘E)",
            action: action
        ) {
            Image(systemName: "pencil")
                .font(.system(size: 11))
        }
    }
}

// MARK: - Tip Jar Button (App Store version)

#if APPSTORE
struct TipJarButton: View {
    let theme: MarkdownTheme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ChromePill(
            theme: theme,
            title: "Tip Jar",
            help: "Support QuickMD",
            tint: .pink,
            action: { openWindow(id: "tip-jar") }
        ) {
            Image(systemName: "heart.fill")
                .font(.system(size: 11))
        }
    }
}
#endif

// MARK: - Support Button (GitHub version)

#if !APPSTORE
struct SupportButton: View {
    let theme: MarkdownTheme

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
            ChromePillLabel(theme: theme, title: "Support") {
                Text("☕")
                    .font(.system(size: 12))
            }
        }
        .menuStyle(.button)
        .help("Support QuickMD development")
        .accessibilityLabel("Support")
    }
}
#endif
