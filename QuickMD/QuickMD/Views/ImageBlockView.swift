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

    /// Maximum display width for images
    private static let maxDisplayWidth: CGFloat = 600

    /// Maximum pixel dimension for downsampling (2x for Retina)
    private static let maxPixelDimension: Int = 1200

    /// Cached downsampled image for local files
    @State private var localImage: NSImage?
    @State private var isLoadingLocal = false

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
                                .frame(height: 100)
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: Self.maxDisplayWidth)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
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
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryTextColor)
                .italic()
        }
    }

    // MARK: - Local Image View

    @ViewBuilder
    private func localImageView(for fileURL: URL) -> some View {
        if let image = localImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: Self.maxDisplayWidth)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if isLoadingLocal {
            ProgressView()
                .frame(height: 100)
        } else {
            Color.clear
                .frame(height: 100)
                .task {
                    await loadLocalImage(from: fileURL)
                }
        }
    }

    /// Load and downsample local image off the main thread
    private func loadLocalImage(from url: URL) async {
        isLoadingLocal = true
        defer { isLoadingLocal = false }

        // Load on background thread
        let image = await Task.detached(priority: .userInitiated) {
            Self.loadDownsampledImage(from: url, maxPixelSize: Self.maxPixelDimension)
        }.value

        await MainActor.run {
            self.localImage = image
        }
    }

    /// Efficiently load and downsample image using ImageIO
    /// This prevents loading huge images (e.g., 4K) at full resolution
    private static func loadDownsampledImage(from url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            // Fallback to NSImage if CGImageSource fails
            return NSImage(contentsOf: url)
        }

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            // Fallback to NSImage if thumbnail creation fails
            return NSImage(contentsOf: url)
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
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
