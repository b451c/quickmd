import AppKit
import WebKit

// MARK: - Mermaid PDF Renderer

/// Renders Mermaid diagrams to bitmaps for PDF export, independent of the
/// document view. Fast path: reuse the light-mode snapshot already cached by
/// the inline MermaidBlockView. Slow path: offscreen WKWebView loading the
/// bundled template — the diagram source travels as JSON via
/// `evaluateJavaScript`, NEVER concatenated into the HTML (constraints.md).
/// Any failure (timeout, mermaid parse error) yields no image and the caller
/// keeps the styled-code fallback, so export can never get stuck or embed an
/// error screenshot.
@MainActor
final class MermaidPDFRenderer {

    /// Renders every distinct source, returning [source: image]. Sequential —
    /// documents rarely hold more than a handful of diagrams, and one WebView
    /// at a time keeps memory flat. `totalBudget` caps the whole document so a
    /// file full of broken diagrams cannot stall the export.
    static func renderAll(sources: [String], width: CGFloat,
                          totalBudget: TimeInterval = 20) async -> [String: NSImage] {
        var result: [String: NSImage] = [:]
        guard !sources.isEmpty else { return result }
        let deadline = Date().addingTimeInterval(totalBudget)

        for source in sources where result[source] == nil {
            if let cached = MermaidSnapshotStore.image(source: source, isDark: false) {
                result[source] = cached
                continue
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 1 else { continue }
            if let image = await renderOffscreen(source: source, width: width,
                                                 timeout: min(8, remaining)) {
                result[source] = image
                MermaidSnapshotStore.set(image, source: source, isDark: false)
            }
        }
        return result
    }

    /// Keeps in-flight renders alive until their completion fires.
    private static var active: Set<OffscreenMermaidRender> = []

    private static func renderOffscreen(source: String, width: CGFloat,
                                        timeout: TimeInterval) async -> NSImage? {
        await withCheckedContinuation { continuation in
            var render: OffscreenMermaidRender!
            render = OffscreenMermaidRender(source: source, width: width, timeout: timeout) { image in
                Self.active.remove(render)
                continuation.resume(returning: image)
            }
            Self.active.insert(render)
            render.start()
        }
    }
}

// MARK: - Offscreen Render (one diagram)

/// One offscreen render pass: borderless window far outside the visible area
/// hosts the WebView (WebKit won't paint — and takeSnapshot returns blank —
/// for a view that isn't in any window). Flow: load template → didFinish →
/// renderDiagram(JSON) → template posts height → verify an SVG actually
/// rendered (the template shows error text and STILL posts height on failure)
/// → resize → snapshot. A single timeout covers the whole flow.
private final class OffscreenMermaidRender: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let source: String
    private let width: CGFloat
    private let timeout: TimeInterval
    private let completion: (NSImage?) -> Void

    private var window: NSWindow?
    private var webView: WKWebView?
    private var finished = false

    init(source: String, width: CGFloat, timeout: TimeInterval,
         completion: @escaping (NSImage?) -> Void) {
        self.source = source
        self.width = width
        self.timeout = timeout
        self.completion = completion
    }

    func start() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "mermaidHeight")

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 600),
                                configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        self.webView = webView

        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderBack(nil)
        self.window = window

        guard let templateURL = Bundle.main.url(forResource: "mermaid-template", withExtension: "html"),
              let templateHTML = try? String(contentsOf: templateURL, encoding: .utf8) else {
            finish(nil)
            return
        }
        webView.loadHTMLString(templateHTML, baseURL: Bundle.main.resourceURL)

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let data = try? JSONSerialization.data(withJSONObject: source, options: [.fragmentsAllowed]),
              let jsLiteral = String(data: data, encoding: .utf8) else {
            finish(nil)
            return
        }
        webView.evaluateJavaScript("renderDiagram(\(jsLiteral), false);", completionHandler: nil)
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard !finished, let webView, let height = message.body as? Double, height > 10 else { return }

        // The template posts height for failed renders too (it shows the error
        // text inline). Only snapshot when an actual SVG landed — otherwise
        // fall back to the styled-code block instead of a screenshot of an error.
        webView.evaluateJavaScript("document.querySelector('#output svg') !== null") { [weak self] value, _ in
            guard let self, !self.finished else { return }
            guard let hasSVG = value as? Bool, hasSVG else {
                self.finish(nil)
                return
            }
            let size = NSSize(width: self.width, height: CGFloat(height))
            webView.setFrameSize(size)
            self.window?.setContentSize(size)
            // Small delay lets WebKit finish painting the freshly inserted SVG
            // (same 0.4s the inline snapshot path uses).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, !self.finished, let webView = self.webView else { return }
                webView.takeSnapshot(with: WKSnapshotConfiguration()) { [weak self] image, _ in
                    self?.finish(image)
                }
            }
        }
    }

    private func finish(_ image: NSImage?) {
        guard !finished else { return }
        finished = true
        // The message-handler registration retains self — break the cycle.
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "mermaidHeight")
        window?.orderOut(nil)
        window = nil
        webView = nil
        completion(image)
    }
}
