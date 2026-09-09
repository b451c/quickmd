import SwiftUI
import WebKit

// MARK: - Mermaid Block View

/// Renders Mermaid diagrams using WKWebView with bundled mermaid.min.js.
///
/// Security: diagram source reaches the page as JSON via `evaluateJavaScript`
/// (see MermaidWebView) — NEVER concatenated into the template HTML.
///
/// LazyVStack support: rendered diagrams are snapshotted into a static cache;
/// when the lazy container recreates this view during scroll, the snapshot is
/// shown instantly instead of re-running the WebView render (no flicker), and
/// the height is seeded from BlockHeightCache (no scroll jump).
///
/// Clicking the diagram opens a window-filling preview with pinch/button zoom.
/// Shared store of rendered-diagram snapshots, keyed by (isDark, source).
/// Written by the inline MermaidBlockView after each successful render; read
/// back by MermaidBlockView on LazyVStack re-creation AND by the PDF exporter
/// (MermaidPDFRenderer) as a fast path before spinning up an offscreen
/// WebView. NSCache evicts under memory pressure.
enum MermaidSnapshotStore {
    private static let cache = NSCache<NSString, NSImage>()

    private static func key(source: String, isDark: Bool) -> NSString {
        "\(isDark)|\(source)" as NSString
    }

    static func image(source: String, isDark: Bool) -> NSImage? {
        cache.object(forKey: key(source: source, isDark: isDark))
    }

    static func set(_ image: NSImage, source: String, isDark: Bool) {
        cache.setObject(image, forKey: key(source: source, isDark: isDark))
    }
}

struct MermaidBlockView: View {
    let blockId: String
    let source: String
    let theme: MarkdownTheme
    let heightCache: BlockHeightCache

    @State private var diagramHeight: CGFloat
    @State private var snapshot: NSImage?
    let fontScale: CGFloat
    let contentWidth: CGFloat
    let onEnlarge: (GraphicPreview) -> Void

    private var snapshotKey: String { "\(fontScale)|\(contentWidth)|\(source)" }
    @State private var isHovered = false

    /// Padding, corner radius and the un-measured default height — see
    /// `BlockLayout.Mermaid` (shared with `BlockHeightMeasurer`).
    typealias Metrics = BlockLayout.Mermaid

    init(blockId: String, source: String, theme: MarkdownTheme, heightCache: BlockHeightCache,
         fontScale: CGFloat, contentWidth: CGFloat, onEnlarge: @escaping (GraphicPreview) -> Void) {
        self.blockId = blockId
        self.source = source
        self.theme = theme
        self.heightCache = heightCache
        self.fontScale = fontScale
        self.contentWidth = contentWidth
        self.onEnlarge = onEnlarge
        _diagramHeight = State(initialValue: heightCache.height(for: blockId) ?? Metrics.defaultHeight)
        let cached = MermaidSnapshotStore.image(source: "\(fontScale)|\(contentWidth)|\(source)", isDark: theme.isDark)
        _snapshot = State(initialValue: cached)
        if let cached { _diagramHeight = State(initialValue: cached.size.height) }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let snapshot {
                    // Re-created by LazyVStack after a previous successful render —
                    // show the cached bitmap, skip the WebView round-trip entirely.
                    Image(nsImage: snapshot)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: diagramHeight)
                        .frame(maxWidth: .infinity)
                } else {
                    MermaidWebView(
                        source: source,
                        isDark: theme.isDark,
                        fontScale: fontScale,
                        diagramHeight: $diagramHeight,
                        onHeight: { height in
                            heightCache.set(height, for: blockId)
                        },
                        onSnapshot: { image in
                            MermaidSnapshotStore.set(image, source: snapshotKey, isDark: theme.isDark)
                            if fontScale == 1 {
                                MermaidSnapshotStore.set(image, source: source, isDark: theme.isDark)
                            }
                        }
                    )
                    .frame(height: diagramHeight)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius))

            // A transparent button also catches clicks over the embedded WKWebView.
            Button { onEnlarge(.diagram(source, isDark: theme.isDark)) } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Enlarge diagram")
            .help("Click to enlarge diagram")

            Button {
                onEnlarge(.diagram(source, isDark: theme.isDark))
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
            .help("Zoom diagram")
            .opacity(isHovered ? 1 : 0)
            .padding(6)
        }
        .padding(.vertical, Metrics.verticalPadding)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Window-filling preview

/// Full-size diagram viewer: pinch-to-zoom (native WKWebView magnification)
/// plus explicit zoom buttons. Scrolling stays INSIDE this web view (it is a
/// plain WKWebView, not the scroll-passthrough subclass used inline).
struct MermaidZoomView: View {
    let source: String
    let isDark: Bool
    let onClose: () -> Void
    @State private var controller = ZoomWebViewController()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Mermaid Diagram")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { controller.zoom(by: 1 / 1.25) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Zoom out")
                Button { controller.resetZoom() } label: {
                    Image(systemName: "1.magnifyingglass")
                }
                .help("Fit diagram to window")
                Button { controller.zoom(by: 1.25) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("Zoom in")
                Divider().frame(height: 16)
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ZoomableMermaidWebView(source: source, isDark: isDark, controller: controller)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Holds a weak reference to the preview's web view so toolbar buttons can
/// drive `magnification` directly (pinch gestures work natively alongside).
/// Main-thread by convention (button actions); not @MainActor for older-SDK
/// compatibility — see BlockHeightCache note in TextBlockView.swift.
final class ZoomWebViewController {
    weak var webView: WKWebView?

    func zoom(by factor: CGFloat) {
        guard let webView else { return }
        webView.magnification = min(8, max(0.25, webView.magnification * factor))
    }

    func resetZoom() {
        webView?.magnification = 1
    }
}

private struct ZoomableMermaidWebView: NSViewRepresentable {
    let source: String
    let isDark: Bool
    let controller: ZoomWebViewController

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        controller.webView = webView

        if let templateURL = Bundle.main.url(forResource: "mermaid-template", withExtension: "html"),
           let templateHTML = try? String(contentsOf: templateURL, encoding: .utf8) {
            webView.loadHTMLString(templateHTML, baseURL: Bundle.main.resourceURL)
        }
        context.coordinator.pendingSource = source
        context.coordinator.pendingIsDark = isDark
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        var pendingSource: String?
        var pendingIsDark: Bool?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let source = pendingSource, let isDark = pendingIsDark else { return }
            // The inline template clips overflow and caps the SVG at container
            // width; the zoom view needs free panning of magnified content.
            webView.evaluateJavaScript("""
                var s = document.createElement('style');
                s.textContent = 'body{overflow:auto !important;} #output svg{max-width:none !important;}';
                document.head.appendChild(s);
                """, completionHandler: nil)
            guard let data = try? JSONSerialization.data(withJSONObject: source, options: [.fragmentsAllowed]),
                  let jsLiteral = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("renderDiagram(\(jsLiteral), \(isDark ? "true" : "false"), 1, true);",
                                       completionHandler: nil)
        }
    }
}

// MARK: - Scroll Passthrough WebView

/// WKWebView subclass that passes scroll events to the parent ScrollView
/// while keeping click/selection interactions working.
private class ScrollPassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        // Pass scroll events to the next responder (parent ScrollView)
        nextResponder?.scrollWheel(with: event)
    }
}

// MARK: - WKWebView Wrapper (inline rendering)

private struct MermaidWebView: NSViewRepresentable {
    let source: String
    let isDark: Bool
    let fontScale: CGFloat
    @Binding var diagramHeight: CGFloat
    let onHeight: (CGFloat) -> Void
    let onSnapshot: (NSImage) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "mermaidHeight")

        let webView = ScrollPassthroughWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator

        // Load the static template exactly once. The diagram source is delivered
        // separately via evaluateJavaScript — NEVER concatenated into the HTML.
        // Concatenation let a crafted code block break out of the JS string with
        // "</script>" and inject arbitrary markup; it also missed "\r" escaping,
        // which is a JS line terminator and silently killed rendering.
        if let templateURL = Bundle.main.url(forResource: "mermaid-template", withExtension: "html"),
           let templateHTML = try? String(contentsOf: templateURL, encoding: .utf8) {
            webView.loadHTMLString(templateHTML, baseURL: Bundle.main.resourceURL)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Avoid re-rendering if content hasn't changed
        if context.coordinator.lastSource == source,
           context.coordinator.lastIsDark == isDark,
           context.coordinator.parent.fontScale == fontScale {
            return
        }
        context.coordinator.parent = self
        context.coordinator.lastSource = source
        context.coordinator.lastIsDark = isDark
        context.coordinator.renderIfReady(in: webView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MermaidWebView
        var lastSource: String?
        var lastIsDark: Bool?
        private var templateLoaded = false

        init(_ parent: MermaidWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            templateLoaded = true
            renderIfReady(in: webView)
        }

        /// Renders the pending diagram once both the template page and a source
        /// are available. The source travels as a JSON string literal, so quotes,
        /// backslashes, control characters and "</script>" all arrive in the
        /// page as inert data.
        func renderIfReady(in webView: WKWebView) {
            guard templateLoaded, let source = lastSource, let isDark = lastIsDark else { return }
            guard let data = try? JSONSerialization.data(withJSONObject: source, options: [.fragmentsAllowed]),
                  let jsLiteral = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("renderDiagram(\(jsLiteral), \(isDark ? "true" : "false"), \(parent.fontScale));",
                                       completionHandler: nil)
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let height = message.body as? Double else { return }
            let newHeight = max(CGFloat(height), 50)
            if abs(newHeight - parent.diagramHeight) > 1 {
                DispatchQueue.main.async {
                    self.parent.diagramHeight = newHeight
                    self.parent.onHeight(newHeight)
                }
            }
            // Snapshot the rendered diagram for instant re-display when the
            // lazy container recreates this block. Small delay lets WebKit
            // finish painting the freshly inserted SVG.
            guard let webView = message.webView else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak webView] in
                guard let self, let webView else { return }
                webView.takeSnapshot(with: WKSnapshotConfiguration()) { image, _ in
                    if let image {
                        self.parent.onSnapshot(image)
                    }
                }
            }
        }
    }
}
