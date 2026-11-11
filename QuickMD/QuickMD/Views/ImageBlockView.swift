import SwiftUI
import AppKit

// MARK: - Image Block View

/// Renders a markdown image from any source `ImageSource` understands:
/// - Remote URLs (http://, https://)
/// - Local absolute paths (/path/to/image.png) and file:// URLs
/// - Relative paths (./images/photo.png) - resolved relative to document location
/// - Inline `data:image/...` URLs (#32)
///
/// Every source goes through `ImageLoader`: decoded off the main thread,
/// downsampled to max 1200 px, and cached, so a row re-created by cell reuse
/// starts from the cached bitmap at its real height.
///
/// The picture itself is a `PictureView` (shared with the pictures of an
/// image row, `ImageRowView`); this view adds the alt-text caption under it.
struct ImageBlockView: View {
    let url: String
    let alt: String
    /// HTML `<img width>` (nil for Markdown images) — see `ImageWidth`.
    let width: ImageWidth?
    /// The picture is a link (`[![alt](img)](url)`): a click follows it.
    let link: URL?
    let theme: MarkdownTheme
    let documentURL: URL?
    let fontScale: CGFloat
    let contentWidth: CGFloat
    /// Where the image's size goes once it is known, so every later measure
    /// computes this row instead of starting it at the loading view.
    let heightCache: BlockHeightCache?
    var onEnlarge: (GraphicPreview) -> Void = { _ in }
    /// `MarkdownView.handleLinkActivation` — the text links' handler.
    var onLink: (URL) -> Void = { _ in }

    init(url: String, alt: String, width: ImageWidth? = nil, link: URL? = nil, theme: MarkdownTheme,
         documentURL: URL?, fontScale: CGFloat, contentWidth: CGFloat, heightCache: BlockHeightCache? = nil,
         onEnlarge: @escaping (GraphicPreview) -> Void = { _ in }, onLink: @escaping (URL) -> Void = { _ in }) {
        self.url = url
        self.alt = alt
        self.width = width
        self.link = link
        self.theme = theme
        self.documentURL = documentURL
        self.fontScale = fontScale
        self.contentWidth = contentWidth
        self.heightCache = heightCache
        self.onEnlarge = onEnlarge
        self.onLink = onLink
    }

    // A two-view TUPLE on purpose (picture, caption): the row's stack puts
    // `ImageBlock.captionSpacing` between them and pads each — the geometry
    // `ImageBlock.rowHeight` measures.
    var body: some View {
        PictureView(url: url, alt: alt, width: width, link: link, theme: theme, documentURL: documentURL,
                    fontScale: fontScale, contentWidth: contentWidth, heightCache: heightCache,
                    style: .block, onEnlarge: onEnlarge, onLink: onLink)

        if !alt.isEmpty {
            ImageCaption(alt: alt, color: theme.secondaryTextColor, fontScale: fontScale,
                         contentWidth: contentWidth)
        }
    }
}

// MARK: - Image Row View (v1.15)

/// A paragraph made only of images (`MarkdownBlock.BlockContent.imageRow`):
/// its pictures side by side, wrapping like words (`ImageFlowLayout`), each
/// at the single image's size rule, without captions (GitHub draws none;
/// the alt is the accessibility label, the copy text and what search finds).
/// Each picture loads, fails and is clicked on its own.
struct ImageRowView: View {
    let images: [RowImage]
    let theme: MarkdownTheme
    let documentURL: URL?
    let fontScale: CGFloat
    let contentWidth: CGFloat
    let heightCache: BlockHeightCache?
    var onEnlarge: (GraphicPreview) -> Void = { _ in }
    var onLink: (URL) -> Void = { _ in }

    var body: some View {
        ImageFlowLayout(separators: images.map(\.separator), fontScale: fontScale) {
            ForEach(images.indices, id: \.self) { index in
                let image = images[index]
                PictureView(url: image.url, alt: image.alt, width: nil, link: image.link, theme: theme,
                            documentURL: documentURL, fontScale: fontScale, contentWidth: contentWidth,
                            heightCache: heightCache, style: .inline, onEnlarge: onEnlarge, onLink: onLink)
            }
        }
    }
}

// MARK: - Picture

/// One picture — loading, failed, access denied or shown — of an image
/// block or of an image row. A plain picture is a button that opens the
/// window-filling preview (PR #29). A LINKED picture is a link: a click
/// follows it through the text links' handler, the pointer is a pointing
/// hand, the help tag is the destination, and the preview stays one hover
/// away — the zoom button the diagrams have, shown while the pointer is on
/// a picture big enough to carry it (`ImageBlock.enlargeButtonMinimumSide`;
/// a badge is not worth previewing).
struct PictureView: View {
    /// `.block`: an image block (the 100 pt loading view while the size is
    /// unknown). `.inline`: a picture of an image row (a loading square,
    /// `ImageRow.placeholderSide`).
    enum Style { case block, inline }

    let url: String
    let alt: String
    let width: ImageWidth?
    let link: URL?
    let theme: MarkdownTheme
    let documentURL: URL?
    let fontScale: CGFloat
    let contentWidth: CGFloat
    let heightCache: BlockHeightCache?
    let style: Style
    let onEnlarge: (GraphicPreview) -> Void
    let onLink: (URL) -> Void

    /// Display width cap and the pre-load placeholder height — see
    /// `BlockLayout.ImageBlock` (shared with `BlockHeightMeasurer`, which starts
    /// an image row at the placeholder height).
    typealias Metrics = BlockLayout.ImageBlock

    /// `url` resolved once per init. Pure (no I/O): for a `data:` URL it only
    /// reads the header up to the first comma.
    private let source: ImageSource?

    @State private var image: NSImage?
    @State private var failure: ImageLoadFailure?
    /// The existing file the user declined folder access for (sandbox prompt).
    @State private var accessDeniedURL: URL?
    /// The pointer is on a linked picture (`.documentHover`): shows its
    /// enlarge button.
    @State private var isHovered = false

    init(url: String, alt: String, width: ImageWidth?, link: URL?, theme: MarkdownTheme, documentURL: URL?,
         fontScale: CGFloat, contentWidth: CGFloat, heightCache: BlockHeightCache?, style: Style,
         onEnlarge: @escaping (GraphicPreview) -> Void, onLink: @escaping (URL) -> Void) {
        self.url = url
        self.alt = alt
        self.width = width
        self.link = link
        self.theme = theme
        self.documentURL = documentURL
        self.fontScale = fontScale
        self.contentWidth = contentWidth
        self.heightCache = heightCache
        self.style = style
        self.onEnlarge = onEnlarge
        self.onLink = onLink
        let source = ImageSource.resolve(url, documentURL: documentURL)
        self.source = source
        // Seed from the cache (precedent: `MermaidBlockView` seeding from
        // `MermaidSnapshotStore`). NSTableView cell reuse re-creates this view
        // and resets `@State`; without the seed every scroll-back would show
        // the 100 pt placeholder, report it, then jump to the real height.
        let cached = source.flatMap {
            ImageLoader.cachedImage(for: url, source: $0, maxPixel: ImageLoader.displayMaxPixel)
        }
        _image = State(initialValue: cached)
        if let cached { heightCache?.setImageSize(cached.size, for: url) }
        // Same reasoning for failures known without I/O (a non-image or
        // oversized `data:` URL, a recorded data:/remote failure): the row
        // starts at the error view instead of the 100 pt spinner, so it reports
        // one height, once.
        _failure = State(initialValue: cached == nil
                         ? source.flatMap { ImageLoader.knownFailure(for: url, source: $0) }
                         : nil)
    }

    var body: some View {
        Group {
            if let image {
                if let link {
                    linkButton(image, link: link)
                } else {
                    graphicButton(image)
                }
            } else if let accessDeniedURL {
                accessDeniedView(for: accessDeniedURL)
            } else if source == nil || failure != nil {
                imageErrorView
            } else if let known = heightCache?.imageSize(for: url) {
                // Loading an image whose size this document already knows
                // (the bitmap was evicted from `ImageLoader`'s cache): hold
                // the picture's place, which is the row the measurer computed.
                let size = pictureSize(for: known)
                ProgressView()
                    .frame(width: size.width, height: size.height)
            } else if style == .inline {
                let side = BlockLayout.ImageRow.placeholderSide * fontScale
                ProgressView()
                    .controlSize(.small)
                    .frame(width: side, height: side)
            } else {
                ProgressView()
                    .frame(height: Metrics.placeholderHeight)
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }

    private func picture(_ image: NSImage) -> some View {
        let size = pictureSize(for: image.size)
        return Image(nsImage: image).resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: style == .inline ? 0 : 8))
    }

    private func graphicButton(_ image: NSImage) -> some View {
        Button {
            onEnlarge(preview(for: image))
        } label: {
            picture(image)
        }
        .buttonStyle(.plain)
        .help("Click to enlarge image")
        .accessibilityLabel(alt.isEmpty ? "Enlarge image" : "Enlarge image: \(alt)")
    }

    /// A linked picture: click = the link, as a text link (in-document
    /// anchors, other documents, the web, the scheme confirmation — all in
    /// `onLink`). The enlarge button sits in the corner while hovered.
    private func linkButton(_ image: NSImage, link: URL) -> some View {
        let size = pictureSize(for: image.size)
        let canEnlarge = size.width >= Metrics.enlargeButtonMinimumSide
            && size.height >= Metrics.enlargeButtonMinimumSide
        return Button {
            onLink(link)
        } label: {
            picture(image)
        }
        .buttonStyle(.plain)
        // Never a megabyte `data:` destination in a help tag (#32).
        .help(DisplayString.middleTruncated(link.absoluteString, maxLength: 200))
        .accessibilityLabel(alt.isEmpty ? "Link" : "Link: \(alt)")
        .overlay(PointingHandCursorArea().allowsHitTesting(false))
        .overlay(alignment: .topTrailing) {
            if canEnlarge && isHovered {
                Button {
                    onEnlarge(preview(for: image))
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(5)
                        .background(theme.codeBackgroundColor.opacity(0.85))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Enlarge image")
                .accessibilityLabel(alt.isEmpty ? "Enlarge image" : "Enlarge image: \(alt)")
                .padding(6)
            }
        }
        .documentHover { hovering in
            isHovered = hovering
        }
    }

    /// GitHub parity (D4): the column cap from `ImageBlock.displayWidth`, but
    /// never wider than the image's own width × zoom — the rule `SVGBlockView`
    /// already used. A 90 px icon stays icon-sized instead of being blown up
    /// (blurry) to 600 pt; large images are unchanged (the cap wins). An HTML
    /// `<img width>` takes the place of the image's own width (T-C). The one
    /// rule the measurer sizes the row with (`ImageBlock.pictureSize`).
    private func pictureSize(for imageSize: CGSize) -> CGSize {
        Metrics.pictureSize(imageSize: imageSize, htmlWidth: width, fontScale: fontScale,
                            contentWidth: contentWidth)
    }

    /// The window-filling preview re-decodes at 4096 px. Local files keep the
    /// pre-existing path (`fileURL`, decoded by the overlay); `data:` and
    /// remote images hand over a loader closure — the preview tier is not
    /// cached, so it decodes (or re-fetches) on demand.
    private func preview(for image: NSImage) -> GraphicPreview {
        let shown = Image(nsImage: image)
        switch source {
        case .file(let fileURL):
            // The undecoded `%` fallback, if that is the file that exists.
            let existing = ImageLoader.fileCandidates(for: fileURL, raw: url)
                .first { FileManager.default.fileExists(atPath: $0.path) } ?? fileURL
            return .image(shown, title: alt, fileURL: existing)
        case .some(let source):
            let raw = url
            return .image(shown, title: alt, fileURL: nil, loadDetail: {
                try? await ImageLoader.load(raw: raw, source: source,
                                            maxPixel: ImageLoader.previewMaxPixel).get()
            })
        case nil:
            return .image(shown, title: alt, fileURL: nil)
        }
    }

    // MARK: - Loading

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
                Task { await retryWithAccess() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: Metrics.displayWidth(fontScale: fontScale, contentWidth: contentWidth))
        .padding(.vertical, 12)
    }

    /// Load through `ImageLoader` (decode off the main thread). A local file
    /// that exists but can't be read is most likely the sandbox: prompt for
    /// folder access and retry once — the pre-existing (1.x) flow, unchanged.
    ///
    /// Explicitly `@MainActor`: `SandboxAccessManager` is main-actor isolated,
    /// and on older SDKs (the CI toolchain) a View's methods are nonisolated —
    /// only `body` is annotated — so the call would not compile there.
    @MainActor
    private func loadImage() async {
        guard let source else { return }
        if let known = ImageLoader.knownFailure(for: url, source: source) {
            // Already showing it when seeded in `init`; no spinner in between.
            image = nil
            accessDeniedURL = nil
            if failure != known { failure = known }
            return
        }
        failure = nil
        accessDeniedURL = nil
        // Re-seed for the CURRENT url: `.task(id:)` also re-runs when the url
        // of a live view changes, and the old bitmap must not linger.
        let seeded = ImageLoader.cachedImage(for: url, source: source, maxPixel: ImageLoader.displayMaxPixel)
        if image !== seeded { image = seeded }
        if let seeded { heightCache?.setImageSize(seeded.size, for: url) }

        let first = await ImageLoader.load(raw: url, source: source, maxPixel: ImageLoader.displayMaxPixel)
        if case .failure(.unreadable(let fileURL)) = first {
            // File exists but couldn't load — likely sandbox. Request access and retry.
            let granted = SandboxAccessManager.shared.ensureAccess(forParentOf: fileURL)
            guard granted else {
                guard !Task.isCancelled else { return }
                image = nil
                accessDeniedURL = fileURL
                return
            }
            let retry = await ImageLoader.load(raw: url, source: source, maxPixel: ImageLoader.displayMaxPixel)
            guard !Task.isCancelled else { return }
            apply(retry)
            return
        }
        guard !Task.isCancelled else { return }
        apply(first)
    }

    private func apply(_ result: Result<NSImage, ImageLoadFailure>) {
        switch result {
        case .success(let loaded):
            heightCache?.setImageSize(loaded.size, for: url)
            if loaded !== image { image = loaded }
        case .failure(let loadFailure):
            // Terminal: shows the error placeholder. (Before, a retry that still
            // failed fell back to the initial state and re-ran the load forever.)
            image = nil
            failure = loadFailure
        }
    }

    /// Retry loading after the user clicks "Grant Folder Access".
    private func retryWithAccess() async {
        accessDeniedURL = nil
        await loadImage()
    }

    // MARK: - Error View

    private var imageErrorView: some View {
        HStack {
            Image(systemName: "photo")
            // Never the raw url: a `data:` payload is megabytes (#32).
            Text(ImageLabel.errorText(alt: alt, raw: url, source: source, failure: failure))
        }
        .font(.system(size: 13))
        .foregroundColor(theme.secondaryTextColor)
        .padding(12)
        .background(theme.codeBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Pointing-hand cursor

/// The pointing hand over a linked picture, as over a text link
/// (`linkTextAttributes[.cursor]`). A CURSOR RECT, not a hover callback:
/// AppKit clips cursor rects to what is visible, so a row scrolled under a
/// resting pointer can never leave a stale hand behind (the hover trap
/// `.documentHover` exists for). Transparent to clicks: `hitTest` is nil and
/// the SwiftUI side has `allowsHitTesting(false)`.
struct PointingHandCursorArea: NSViewRepresentable {
    final class CursorView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            window?.invalidateCursorRects(for: self)
        }
    }

    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ nsView: CursorView, context: Context) {}
}

// The document owns presentation so the preview covers the whole window,
// including sidebars, and survives virtualization of the originating row.
enum GraphicPreview {
    /// `fileURL`: a local image the overlay re-decodes at 4096 px.
    /// `loadDetail`: the same for `data:` / remote images, through `ImageLoader`.
    case image(Image, title: String, fileURL: URL?, loadDetail: (() async -> NSImage?)? = nil)
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
            case .image(let image, let title, let fileURL, let loadDetail):
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
                    if let fileURL {
                        let loaded = await Task.detached(priority: .userInitiated) {
                            ImageLoader.loadThumbnail(from: fileURL, maxPixelSize: ImageLoader.previewMaxPixel)
                        }.value
                        guard !Task.isCancelled else { return }
                        if let loaded {
                            detailedImage = NSImage(cgImage: loaded, size: NSSize(width: loaded.width, height: loaded.height))
                        }
                    } else if let loadDetail {
                        let loaded = await loadDetail()
                        guard !Task.isCancelled else { return }
                        detailedImage = loaded
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
