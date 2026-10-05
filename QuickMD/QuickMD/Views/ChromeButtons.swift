import SwiftUI
import AppKit

// MARK: - Heading Block View (hover-to-copy section)

/// Heading with hover-to-reveal copy button that copies the section.
///
/// Since v1.11 (S-D7) the title renders through `TextBlockView` — an NSTextView
/// — so it is part of the document selection (drag, ⌘A, ⌘C), search hits are
/// painted by `applyNSSearchHighlight`, and links go through the text view's
/// delegate → `onLink`. Never `Text(...).textSelection(.enabled)`: its
/// SelectionOverlay is constraints.md bug B.
///
/// The copy button is an OVERLAY in the trailing strip the title gives up
/// (`Metrics.copyButtonReservedWidth`, the same width `BlockHeightMeasurer`
/// wraps the title at), not an HStack sibling: an HStack re-negotiates an
/// NSViewRepresentable child's width every pass (scroll-freeze rule 4). An
/// overlay takes no space, so the old HStack's first-baseline union is
/// reproduced with explicit insets — see `BlockLayout.Heading.titleGeometry`.
struct HeadingBlockView: View {
    let id: String
    let level: Int
    let title: String
    let theme: MarkdownTheme
    var fontScale: CGFloat = 1.0
    /// `TextBlockView`'s cache invalidation signal (bumped per parse).
    var contentVersion: Int = 0
    let searchText: String
    let focusedOccurrence: Int?
    let onLink: (URL) -> Void
    let onCopySection: () -> Void
    @State private var isHovered = false
    @State private var hideWorkItem: DispatchWorkItem?

    /// Copy-button spacing, icon metrics and the title/button geometry — see
    /// `BlockLayout.Heading` (shared with `BlockHeightMeasurer`, which
    /// subtracts the button from the width the title wraps at).
    typealias Metrics = BlockLayout.Heading

    var body: some View {
        // The same string the selection copies: `MarkdownView.selectableText`
        // converts this exact `renderHeader` output through the same converter.
        let renderer = MarkdownRenderer(theme: theme, fontScale: fontScale)
        let headingAttr = renderer.renderHeader(title, level: level)
        // Every character carries the heading font (`renderHeader` sets it over
        // the whole string), so it is the font TextKit sets the first line in.
        let geometry = Metrics.titleGeometry(
            titleFirstBaseline: Metrics.titleFirstBaseline(font: renderer.headerAppKitFont(level: level)))

        TextBlockView(
            blockId: id,
            attributed: headingAttr,
            hasInlineMath: false,
            theme: theme,
            fontScale: fontScale,
            contentVersion: contentVersion,
            searchTerm: searchText,
            focusedOccurrence: focusedOccurrence,
            cacheScope: "\(level)|\(title)",
            onLink: onLink
        )
        .padding(.trailing, Metrics.copyButtonReservedWidth)
        .padding(.top, geometry.titleTopInset)
        .frame(minHeight: geometry.minimumHeight, alignment: .top)
        .overlay(alignment: .topTrailing) {
            // `buttonTopInset` puts the icon's baseline on the title's first
            // baseline, as the old `.firstTextBaseline` HStack did.
            Button {
                onCopySection()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: Metrics.copyButtonIconFontSize))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(Metrics.copyButtonIconPadding)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy section")
            .opacity(isHovered ? 1 : 0)
            .padding(.top, geometry.buttonTopInset)
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
/// `.local` — the pill tracks the pointer itself (Tip Jar).
/// `.cluster` — a parent `chromeHoverCluster()` reports whether the pointer
/// is inside the group. A pill expands only once the pointer has actually
/// touched it, and every touched pill stays expanded until the pointer
/// leaves the whole group. Growing only the pill under the pointer keeps
/// that pill under the pointer (capsules grow leftward from a trailing
/// anchor); holding siblings open means nothing jumps back while the
/// pointer travels between them.
/// `.fixed` — never expands and applies no hover feedback of its own. Menu
/// labels on macOS render once and ignore later state changes (opacity,
/// conditional text), so the host applies hover feedback outside the label
/// (see `SupportButton`).
private enum ChromeExpansionSource: Equatable {
    case local
    case cluster(active: Bool)
    case fixed
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
/// shifts siblings and makes the pointer miss the other control; the
/// cluster keeps every touched pill open while the pointer is inside the
/// group (see `ChromeExpansionSource.cluster`).
struct ChromeHoverCluster: ViewModifier {
    @State private var hover = ChromeHoverState()

    func body(content: Content) -> some View {
        content
            // Grow the hover bounds (gap + 4pt slop) without shifting layout.
            // onHover tracks layout bounds, not contentShape, so padding is
            // what actually keeps the pointer "inside" while crossing pills.
            .padding(4)
            .contentShape(Rectangle())
            .environment(\.chromeExpansionSource, .cluster(active: hover.isExpanded))
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
    /// Cluster mode: the pointer has been over THIS pill since the cluster
    /// became active. Reset when the cluster deactivates.
    @State private var touched = false

    private var expanded: Bool {
        switch expansionSource {
        case .local: return localHover.isExpanded
        case .cluster(let active): return active && touched
        case .fixed: return false
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
        .opacity(ownsHoverFeedback && !expanded ? 0.5 : 1.0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: expanded)
        .modifier(ChromePillTracking(source: expansionSource, localHover: $localHover, touched: $touched))
    }

    /// `.fixed` pills leave dimming/brightening to their host.
    private var ownsHoverFeedback: Bool { expansionSource != .fixed }
}

/// Per-mode pointer tracking for `ChromePillLabel`.
private struct ChromePillTracking: ViewModifier {
    let source: ChromeExpansionSource
    @Binding var localHover: ChromeHoverState
    @Binding var touched: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        switch source {
        case .local:
            content.modifier(ChromeHoverTracking(hover: $localHover))
        case .cluster(let active):
            content
                .onHover { hovering in
                    if hovering { touched = true }
                }
                .onChange(of: active) { isActive in
                    if !isActive { touched = false }
                }
        case .fixed:
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

// MARK: - Zoom Indicator / Reset Pill

/// Shown in the top-right cluster only while the document is zoomed
/// (`fontScale != 1`): the collapsed pill reads the current level ("120%"),
/// hovering reveals "Reset zoom", clicking resets — the same thing ⌘0 does.
/// The pill answers "how far did I zoom, and how do I get back?" without a
/// permanent HUD.
struct ZoomResetButton: View {
    let theme: MarkdownTheme
    let fontScale: Double
    let action: () -> Void

    private var percentText: String { "\(Int((fontScale * 100).rounded()))%" }

    var body: some View {
        ChromePill(theme: theme, title: "Reset zoom", help: "Reset zoom to 100% (⌘0)", action: action) {
            Text(percentText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .accessibilityValue(percentText)
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

// MARK: - Edit Source Button

/// Top-right pencil button — fixes the source in place (Source Edit, ⌥⌘E).
/// Since v1.12 (U2) the pencil means "edit HERE"; the handoff to another
/// application has its own pill (`OpenInEditorButton`). One of the three ways
/// into Source Edit, with File ▸ Edit Source and the shortcut.
struct EditSourceButton: View {
    let theme: MarkdownTheme
    let action: () -> Void

    var body: some View {
        ChromePill(
            theme: theme,
            title: "Edit",
            help: "Edit source (⌥⌘E)",
            action: action
        ) {
            Image(systemName: "pencil")
                .font(.system(size: 11))
        }
        .accessibilityIdentifier("source-edit")
    }
}

// MARK: - Open In External Editor Button

/// Top-right handoff to the user's configured editor (⌘E), at the line being
/// read when that editor supports line links. Was the pencil until v1.12.
struct OpenInEditorButton: View {
    let theme: MarkdownTheme
    let action: () -> Void

    var body: some View {
        ChromePill(
            theme: theme,
            title: "Open in editor",
            help: "Open in external editor (⌘E)",
            action: action
        ) {
            Image(systemName: "arrow.up.forward.square")
                .font(.system(size: 11))
        }
    }
}

// MARK: - Source Edit Pills (Save / Done)

/// The whole cluster while Source Edit shows (S-D12) — also in Reading Mode,
/// where the cluster is otherwise hidden: a mode you could only leave by
/// shortcut is not acceptable. Save is dimmed and inert while there is
/// nothing to save, but stays in place so Done never shifts under the pointer.
struct SourceSaveButton: View {
    let theme: MarkdownTheme
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        ChromePill(theme: theme, title: "Save", help: "Save (⌘S)", action: action) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 11))
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityIdentifier("source-save")
    }
}

struct SourceDoneButton: View {
    let theme: MarkdownTheme
    let action: () -> Void

    var body: some View {
        ChromePill(theme: theme, title: "Done", help: "Done editing (Esc)", action: action) {
            Image(systemName: "checkmark")
                .font(.system(size: 11))
        }
        .accessibilityIdentifier("source-done")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = ChromeHoverState()

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
            // Menu labels render once on macOS and ignore later state changes,
            // so the label is `.fixed` and hover feedback lives on the Menu.
            ChromePillLabel(theme: theme, title: "Support") {
                Text("☕")
                    .font(.system(size: 12))
            }
            .environment(\.chromeExpansionSource, .fixed)
        }
        .menuStyle(.button)
        .opacity(hover.isExpanded ? 1.0 : 0.5)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: hover.isExpanded)
        .modifier(ChromeHoverTracking(hover: $hover))
        .help("Support QuickMD development")
        .accessibilityLabel("Support")
    }
}
#endif
