import SwiftUI
import AppKit

// MARK: - Recent Documents Sidebar

/// Left sidebar listing documents opened in this session.
/// Clicking a row re-opens the file in QuickMD.
///
/// Originally contributed by COSMAX-JYP (https://github.com/COSMAX-JYP/quickmd).
struct RecentDocumentsSidebar: View {
    @ObservedObject var store: RecentDocumentsStore = .shared
    let theme: MarkdownTheme
    let currentURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text("Documents")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if !store.documents.isEmpty {
                    Button {
                        store.clear()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Clear list")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if store.documents.isEmpty {
                Spacer(minLength: 0)
                Text("No documents opened yet")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.documents, id: \.absoluteString) { url in
                            DocumentRow(
                                url: url,
                                isCurrent: currentURL?.standardizedFileURL == url.standardizedFileURL,
                                theme: theme,
                                onOpen: { openDocument(url) },
                                onRemove: { store.remove(url) }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(theme.backgroundColor.opacity(0.5))
    }

    private func openDocument(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: Bundle.main.bundleURL,
            configuration: config,
            completionHandler: { _, error in
                if let error = error {
                    // Sandbox may deny access if the system has dropped its bookmark
                    // for this URL (rare). Surface via assertion in debug only.
                    assertionFailure("Recent document open failed: \(error.localizedDescription)")
                }
            }
        )
    }
}

// MARK: - Row

private struct DocumentRow: View {
    let url: URL
    let isCurrent: Bool
    let theme: MarkdownTheme
    let onOpen: () -> Void
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.plaintext")
                .font(.system(size: 11))
                .foregroundColor(isCurrent ? .accentColor : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundColor(theme.textColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(url.deletingLastPathComponent().path)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isHovered {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove from list")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isCurrent
                      ? Color.accentColor.opacity(0.18)
                      : (isHovered ? Color.gray.opacity(0.12) : Color.clear))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen()
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .help(url.path)
    }
}

// MARK: - Resize Handle

/// Thin vertical handle for resizing the documents sidebar by drag.
struct SidebarResizeHandle: View {
    @Binding var width: Double
    let minWidth: Double
    let maxWidth: Double
    @State private var startWidth: Double?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.gray.opacity(0.18))
                .frame(width: 1)

            Rectangle()
                .fill(Color.clear)
                .frame(width: 6)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if startWidth == nil {
                                startWidth = width
                            }
                            let new = (startWidth ?? width) + Double(value.translation.width)
                            width = max(minWidth, min(maxWidth, new))
                        }
                        .onEnded { _ in
                            startWidth = nil
                        }
                )
        }
        .frame(width: 6)
    }
}
