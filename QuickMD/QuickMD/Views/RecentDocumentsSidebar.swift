import SwiftUI
import AppKit

// MARK: - Recent Documents Sidebar

/// Left sidebar listing documents opened in this session — and, after
/// File ▸ Open Folder (#62), the Markdown files of that folder above them.
/// Clicking a row opens the file in QuickMD (`DocumentOpener`).
///
/// With no folder open the sidebar is exactly the 1.15 one: that branch of
/// `body` is kept as it was. Rows are plain `Text` inside the `LazyVStack`,
/// never `.textSelection` (constraints, first section); `.onHover` is right
/// here — window chrome, not a document row.
///
/// Originally contributed by COSMAX-JYP (https://github.com/COSMAX-JYP/quickmd).
struct RecentDocumentsSidebar: View {
    /// The `@AppStorage` key of "the Documents sidebar is shown" (all
    /// windows): Open Folder sets it from outside any window.
    static let visibilityDefaultsKey = "isDocumentListVisible"

    @ObservedObject var store: RecentDocumentsStore = .shared
    @ObservedObject var folders: FolderBrowserStore = .shared
    let theme: MarkdownTheme
    let currentURL: URL?
    let onCollapse: () -> Void
    /// A row's file could not be opened: the message, for this window's toast.
    let onOpenFailed: (String) -> Void
    /// The current document's path as the disk spells it (symlinks, case),
    /// computed once per document off the main thread — the folder's
    /// listing is built on the canonical root, so a document opened as
    /// `/tmp/x.md` still finds its `/private/tmp/x.md` row. No I/O in rows.
    @State private var canonicalCurrentPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text("Documents")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    // Two header buttons now share the row; at the 160 pt minimum
                    // width the title must keep its single line, not wrap.
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                // Same symbol as the overlay capsule; inverse verb. Not xmark — that's row-remove.
                Button {
                    onCollapse()
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide recent documents (⇧⌘D)")
                .accessibilityLabel("Hide recent documents")
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

            if let folder = folders.folder {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        folderSection(folder)
                        if !store.documents.isEmpty {
                            Text("Recent")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.top, 10)
                                .padding(.bottom, 2)
                            recentRows
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else if store.documents.isEmpty {
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
        // The remembered folder comes back on the first appearance (once per
        // process; the store does the I/O off the main thread).
        .task { await folders.restore() }
        .task(id: currentURL) {
            let url = currentURL
            let canonical = await Task.detached(priority: .utility) {
                url.map { FolderAccessBroker.canonicalPath($0) }
            }.value
            // A newer document's task replaced this one: its answer stands.
            guard !Task.isCancelled else { return }
            canonicalCurrentPath = canonical
        }
    }

    /// The recent rows, as in the no-folder branch.
    private var recentRows: some View {
        ForEach(store.documents, id: \.absoluteString) { url in
            DocumentRow(
                url: url,
                isCurrent: isCurrent(url),
                theme: theme,
                onOpen: { openDocument(url) },
                onRemove: { store.remove(url) }
            )
        }
    }

    /// The open folder: its header, then every folder that holds Markdown
    /// files (the root's without a header of its own).
    @ViewBuilder
    private func folderSection(_ folder: URL) -> some View {
        FolderHeaderRow(folder: folder, onClose: { folders.close() })
        if folders.isUnreadable {
            // Kept (restored, or listed before): the last listing, if any,
            // stays below.
            folderNote("Can\u{2019}t read this folder")
        }
        if folders.groups.isEmpty {
            // Only a COMPLETE scan may say there are none.
            if !folders.isLoading && !folders.isUnreadable {
                folderNote(folders.isTruncated ? "This folder is too large to list" : "No Markdown files")
            }
        } else {
            ForEach(folders.groups) { group in
                if !group.relativePath.isEmpty {
                    Text(group.relativePath)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                }
                ForEach(group.files, id: \.absoluteString) { url in
                    FolderFileRow(url: url, isCurrent: isCurrentInFolder(url), theme: theme,
                                  onOpen: { openDocument(url) })
                }
            }
            if folders.isTruncated {
                folderNote("Showing the first \(folders.fileCount.formatted()) files")
            }
        }
    }

    private func folderNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    private func isCurrent(_ url: URL) -> Bool {
        currentURL?.standardizedFileURL == url.standardizedFileURL
    }

    /// Listing URLs are canonical (see `canonicalCurrentPath`).
    private func isCurrentInFolder(_ url: URL) -> Bool {
        (canonicalCurrentPath != nil && canonicalCurrentPath == url.path) || isCurrent(url)
    }

    private func openDocument(_ url: URL) {
        DocumentOpener.open(url, onFailure: onOpenFailed)
    }
}

// MARK: - Opening

/// The ONE way a sidebar row (folder file or recent document) or Open Folder
/// opens a file: in QuickMD itself, as Finder would — a tab, or a window with
/// "Open documents in separate windows" on; an already open document gets
/// its tab selected. A failure is reported (`onFailure`, on the main queue,
/// with the Local links wording) instead of the pre-1.16 debug-only
/// assertion: the sandbox may have dropped a recent file's access, a listed
/// file may have been removed a moment ago.
enum DocumentOpener {
    static func open(_ url: URL, onFailure: @escaping (String) -> Void) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: Bundle.main.bundleURL,
            configuration: config,
            completionHandler: { _, error in
                guard error != nil else { return }
                let message = LocalLinkOpening.message(for: .openFailed, name: url.lastPathComponent)
                DispatchQueue.main.async { onFailure(message) }
            }
        )
    }
}

// MARK: - Folder rows

/// The open folder's name, its path as help, and Close Folder on hover.
private struct FolderHeaderRow: View {
    let folder: URL
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text(folder.lastPathComponent)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isHovered {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close Folder")
                .accessibilityLabel("Close Folder")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .help(folder.path)
    }
}

/// A file of the open folder: the recent row's look on one line (name only),
/// no remove button — the folder decides what is listed.
private struct FolderFileRow: View {
    let url: URL
    let isCurrent: Bool
    let theme: MarkdownTheme
    let onOpen: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.plaintext")
                .font(.system(size: 11))
                .foregroundColor(isCurrent ? .accentColor : .secondary)
            Text(url.lastPathComponent)
                .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                .foregroundColor(theme.textColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
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
