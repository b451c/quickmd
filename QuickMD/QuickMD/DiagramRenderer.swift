import AppKit
import WebKit

struct RenderedDiagram {
    let svg: String
    let size: CGSize
}

private final class CachedDiagram: NSObject {
    let value: RenderedDiagram
    init(_ value: RenderedDiagram) { self.value = value }
}

enum DiagramRenderError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// One serial, offline rendering context. The SVG cache is independent of the
/// document width and text scale: resizing never re-runs a diagram engine.
@MainActor
final class DiagramRenderer: NSObject, WKNavigationDelegate {
    static let shared = DiagramRenderer()
    private let resourcesURL: URL?
    private let cache = NSCache<NSString, CachedDiagram>()
    private var tail: Task<Void, Never>?
    private var webView: WKWebView?
    private var window: NSWindow?
    private var ready = false
    private var completion: ((Result<RenderedDiagram, Error>) -> Void)?
    private var pendingSource: DiagramSource?
    private var timeoutWork: DispatchWorkItem?
    private var generation = 0

    init(resourcesURL: URL? = Bundle.main.resourceURL) {
        self.resourcesURL = resourcesURL
        super.init()
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 128
    }

    private func cacheKey(_ source: DiagramSource) -> NSString {
        "\(source.kind.rawValue)|\(source.isDark)|\(source.source)" as NSString
    }

    func render(_ source: DiagramSource, timeout: TimeInterval = 12) async throws -> RenderedDiagram {
        guard source.source.utf8.count <= 2 * 1024 * 1024 else {
            throw DiagramRenderError.failed("Diagram source exceeds the 2 MB rendering limit.")
        }
        if let cached = cache.object(forKey: cacheKey(source)) { return cached.value }
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            if let cached = self.cache.object(forKey: self.cacheKey(source)) { return cached.value }
            let result = try await self.perform(source, timeout: timeout)
            self.cache.setObject(CachedDiagram(result), forKey: self.cacheKey(source), cost: result.svg.utf8.count)
            return result
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    private func perform(_ source: DiagramSource, timeout: TimeInterval) async throws -> RenderedDiagram {
        try await withCheckedThrowingContinuation { continuation in
            completion = { continuation.resume(with: $0) }
            pendingSource = source
            generation += 1
            let token = generation
            let timer = DispatchWorkItem { [weak self] in
                guard let self, self.generation == token else { return }
                self.finish(.failure(DiagramRenderError.failed("Diagram rendering timed out.")), reset: true)
            }
            timeoutWork = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timer)
            if ready { run() } else if webView == nil { load() }
        }
    }

    private func load() {
        guard let resourcesURL else {
            finish(.failure(DiagramRenderError.failed("Bundled diagram resources are missing.")), reset: true)
            return
        }
        let page = resourcesURL.appendingPathComponent("Diagrams/render.html")
        guard FileManager.default.fileExists(atPath: page.path) else {
            finish(.failure(DiagramRenderError.failed("Bundled diagram renderer is missing.")), reset: true)
            return
        }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        view.navigationDelegate = self
        let host = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1200, height: 800),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = view
        host.orderBack(nil)
        window = host
        webView = view
        view.loadFileURL(page, allowingReadAccessTo: resourcesURL)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        ready = true
        run()
    }

    private func run() {
        guard let webView, let source = pendingSource, completion != nil else { return }
        let token = generation
        webView.callAsyncJavaScript("return await quickmdRender(kind, source, isDark);",
                                   arguments: ["kind": source.kind.rawValue, "source": source.source,
                                               "isDark": source.isDark], in: nil, in: .page) { [weak self] result in
            guard let self, self.generation == token, self.completion != nil else { return }
            switch result {
            case .success(let value):
                guard let fields = value as? [String: Any], let svg = fields["svg"] as? String,
                      let width = fields["width"] as? Double, let height = fields["height"] as? Double,
                      width.isFinite, height.isFinite, width > 0, height > 0 else {
                    self.finish(.failure(DiagramRenderError.failed("Renderer returned invalid SVG dimensions.")), reset: true)
                    return
                }
                self.finish(.success(RenderedDiagram(svg: svg, size: CGSize(width: width, height: height))))
            case .failure(let error):
                let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                self.finish(.failure(DiagramRenderError.failed(detail ?? error.localizedDescription)), reset: true)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error), reset: true)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error), reset: true)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(DiagramRenderError.failed("The diagram renderer stopped unexpectedly.")), reset: true)
    }

    private func finish(_ result: Result<RenderedDiagram, Error>, reset: Bool = false) {
        timeoutWork?.cancel()
        timeoutWork = nil
        let callback = completion
        completion = nil
        pendingSource = nil
        if reset {
            ready = false
            webView?.navigationDelegate = nil
            webView?.stopLoading()
            window?.orderOut(nil)
            window = nil
            webView = nil
        }
        callback?(result)
    }
}

/// SVG-as-image mode disables active SVG content and external subresources.
enum SVGDocument {
    static func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        return config
    }
    static func html(for diagram: RenderedDiagram) -> String {
        let data = Data(diagram.svg.utf8).base64EncodedString()
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'">
        <style>html,body{margin:0;width:100%;height:100%;background:transparent;overflow:auto}
        img{display:block;width:100%;height:100%;object-fit:contain}</style></head>
        <body><img alt="Diagram" src="data:image/svg+xml;base64,\(data)"></body></html>
        """
    }

}
