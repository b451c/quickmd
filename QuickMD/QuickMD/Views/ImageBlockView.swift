import SwiftUI

// MARK: - Image Block View

/// Renders a markdown image with support for:
/// - Remote URLs (http://, https://)
/// - Local absolute paths (/path/to/image.png)
/// - Relative paths (./images/photo.png) - resolved relative to document location
struct ImageBlockView: View {
    let url: String
    let alt: String
    let theme: MarkdownTheme
    let documentURL: URL?

    var body: some View {
        Group {
            if let imageURL = resolvedURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(height: 100)
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 600)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    case .failure:
                        imageErrorView
                    @unknown default:
                        imageErrorView
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
