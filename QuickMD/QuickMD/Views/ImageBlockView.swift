import SwiftUI
import AppKit

// MARK: - Image Block View

/// Renders a markdown image with support for:
/// - Remote URLs (http://, https://)
/// - Local absolute paths (/path/to/image.png)
/// - Relative paths (./images/photo.png) - resolved relative to document location
///
/// Local images are downsampled to max 1200px to reduce memory usage
struct ImageBlockView: View {
    let url: String
    let alt: String
    let theme: MarkdownTheme
    let documentURL: URL?
    let fontScale: CGFloat
    let contentWidth: CGFloat
    var onEnlarge: (GraphicPreview) -> Void = { _ in }

    /// Display width cap and the pre-load placeholder height — see
    /// `BlockLayout.ImageBlock` (shared with `BlockHeightMeasurer`, which starts
    /// an image row at the placeholder height).
    typealias Metrics = BlockLayout.ImageBlock

    /// Maximum pixel dimension for downsampling (2x for Retina)
    private static let maxPixelDimension: Int = 1200

    /// Cached downsampled image for local files
    @State private var localImage: NSImage?
    @State private var isLoadingLocal = false
    @State private var accessDenied = false
    @State private var fileNotFound = false

    var body: some View {
        Group {
            if let imageURL = resolvedURL {
                if imageURL.isFileURL {
                    // Local file: use downsampled image
                    localImageView(for: imageURL)
                } else {
                    // Remote URL: use AsyncImage
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .frame(height: Metrics.placeholderHeight)
                        case .success(let image):
                            graphicButton(image, fileURL: nil)
                        case .failure:
                            imageErrorView
                        @unknown default:
                            imageErrorView
                        }
                    }
                }
            } else {
                imageErrorView
            }
        }

        if !alt.isEmpty {
            Text(alt)
                .font(.system(size: 12 * fontScale))
                .foregroundColor(theme.secondaryTextColor)
                .italic()
        }
    }

    private func graphicButton(_ image: Image, fileURL: URL?) -> some View {
        Button {
            onEnlarge(.image(image, title: alt, fileURL: fileURL))
        } label: {
            image.resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: Metrics.displayWidth(fontScale: fontScale, contentWidth: contentWidth))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Click to enlarge image")
        .accessibilityLabel(alt.isEmpty ? "Enlarge image" : "Enlarge image: \(alt)")
    }

    // MARK: - Local Image View

    @ViewBuilder
    private func localImageView(for fileURL: URL) -> some View {
        if let image = localImage {
            graphicButton(Image(nsImage: image), fileURL: fileURL)
        } else if isLoadingLocal {
            ProgressView()
                .frame(height: Metrics.placeholderHeight)
        } else if accessDenied {
            accessDeniedView(for: fileURL)
        } else if fileNotFound {
            imageErrorView
        } else {
            Color.clear
                .frame(height: Metrics.placeholderHeight)
                .task {
                    await loadLocalImage(from: fileURL)
                }
        }
    }

    /// Placeholder shown when the user denied folder access for a local image.
    private func accessDeniedView(for fileURL: URL) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            Text("Can\u{2019}t load \u{201C}\(fileURL.lastPathComponent)\u{201D}")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            Button("Grant Folder Access") {
                Task { await retryWithAccess(for: fileURL) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: Metrics.displayWidth(fontScale: fontScale, contentWidth: contentWidth))
        .padding(.vertical, 12)
    }

    /// Load and downsample local image off the main thread.
    /// If loading fails (e.g. sandbox denies access), prompts the user
    /// to grant folder access and retries once.
    private func loadLocalImage(from url: URL) async {
        isLoadingLocal = true
        defer { isLoadingLocal = false }

        // First attempt — try loading directly
        let firstAttempt = await Task.detached(priority: .userInitiated) {
            Self.loadDownsampledImage(from: url, maxPixelSize: Self.maxPixelDimension)
        }.value

        if let image = firstAttempt {
            await MainActor.run { self.localImage = image }
            return
        }

        // Check if the file actually exists before assuming sandbox denial.
        // If it simply doesn't exist, there's nothing the user can do.
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        guard fileExists else {
            fileNotFound = true
            return
        }

        // File exists but couldn't load — likely sandbox. Request access and retry.
        let granted = await SandboxAccessManager.shared.ensureAccess(forParentOf: url)
        guard granted else {
            accessDenied = true
            return
        }

        let retryAttempt = await Task.detached(priority: .userInitiated) {
            Self.loadDownsampledImage(from: url, maxPixelSize: Self.maxPixelDimension)
        }.value

        await MainActor.run {
            self.localImage = retryAttempt
        }
    }

    /// Retry loading after the user clicks "Grant Folder Access".
    private func retryWithAccess(for url: URL) async {
        accessDenied = false
        await loadLocalImage(from: url)
    }

    /// Efficiently load and downsample image using ImageIO
    /// This prevents loading huge images (e.g., 4K) at full resolution
    private nonisolated static func loadDownsampledImage(from url: URL, maxPixelSize: Int) -> NSImage? {
        guard let cgImage = loadThumbnail(from: url, maxPixelSize: maxPixelSize) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    fileprivate nonisolated static func loadThumbnail(from url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - URL Resolution

    /// Resolve image URL based on type:
    /// - http/https: Use as-is
    /// - file://: Use as-is
    /// - Absolute path (/...): Convert to file URL
    /// - Relative path: Resolve relative to document directory
    private var resolvedURL: URL? {
        if url.hasPrefix("http://") || url.hasPrefix("https://") {
            return URL(string: url)
        } else if url.hasPrefix("file://") {
            return URL(string: url)
        } else if url.hasPrefix("/") {
            return URL(fileURLWithPath: url)
        } else if let docURL = documentURL {
            // Relative path - resolve relative to document directory
            return docURL.deletingLastPathComponent().appendingPathComponent(url)
        } else {
            return URL(string: url)
        }
    }

    // MARK: - Error View

    private var imageErrorView: some View {
        HStack {
            Image(systemName: "photo")
            Text("Image: \(alt.isEmpty ? url : alt)")
        }
        .font(.system(size: 13))
        .foregroundColor(theme.secondaryTextColor)
        .padding(12)
        .background(theme.codeBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// The document owns presentation so the preview covers the whole window,
// including sidebars, and survives virtualization of the originating row.
enum GraphicPreview {
    case image(Image, title: String, fileURL: URL?)
    case diagram(String, theme: MarkdownTheme)
}

struct GraphicPreviewOverlay: View {
    let preview: GraphicPreview
    let theme: MarkdownTheme
    let onClose: () -> Void
    @State private var detailedImage: NSImage?

    var body: some View {
        Group {
            switch preview {
            case .image(let image, let title, let fileURL):
                VStack(spacing: 0) {
                    HStack {
                        Text(title.isEmpty ? "Image" : title)
                            .lineLimit(1)
                            .foregroundColor(theme.textColor)
                        Spacer()
                        Button("Done", action: onClose)
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding()
                    GeometryReader { geometry in
                        (detailedImage.map { Image(nsImage: $0) } ?? image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    .padding(16)
                }
                .task(id: fileURL) {
                    detailedImage = nil
                    guard let fileURL else { return }
                    let loaded = await Task.detached(priority: .userInitiated) {
                        ImageBlockView.loadThumbnail(from: fileURL, maxPixelSize: 4096)
                    }.value
                    guard !Task.isCancelled else { return }
                    if let loaded {
                        detailedImage = NSImage(cgImage: loaded, size: NSSize(width: loaded.width, height: loaded.height))
                    }
                }
            case .diagram(let source, let diagramTheme):
                MermaidZoomView(source: source, theme: diagramTheme, onClose: onClose)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The document's theme, not the system background: a dark custom
        // theme under a light appearance must not flash a white panel.
        .background(theme.backgroundColor)
    }
}
