import AppKit
import WebKit

/// Export from the same cached SVG as the document, not a screen-sized bitmap.
@MainActor
final class DiagramPDFRenderer {
    static func renderAll(sources: [DiagramSource], width: CGFloat,
                          totalBudget: TimeInterval = 30, renderer: DiagramRenderer? = nil) async -> [DiagramSource: NSImage] {
        let renderer = renderer ?? DiagramRenderer.shared
        var result: [DiagramSource: NSImage] = [:]
        let deadline = Date().addingTimeInterval(totalBudget)
        for source in sources where result[source] == nil {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 1 else { break }
            do {
                let svg = try await renderer.render(source, timeout: min(10, remaining))
                if let image = await pdfImage(svg, width: width, timeout: max(1, deadline.timeIntervalSinceNow)) {
                    result[source] = image
                }
            } catch { /* Export retains the styled-source fallback. */ }
        }
        return result
    }

    private static var active: Set<SVGDocumentExport> = []
    private static func pdfImage(_ diagram: RenderedDiagram, width: CGFloat, timeout: TimeInterval) async -> NSImage? {
        await withCheckedContinuation { continuation in
            var job: SVGDocumentExport!
            job = SVGDocumentExport(diagram: diagram, width: width, timeout: timeout) { image in
                active.remove(job)
                continuation.resume(returning: image)
            }
            active.insert(job)
            job.start()
        }
    }
}

private final class SVGDocumentExport: NSObject, WKNavigationDelegate {
    let diagram: RenderedDiagram
    let width: CGFloat
    let timeout: TimeInterval
    let completion: (NSImage?) -> Void
    var window: NSWindow?
    var webView: WKWebView?
    var finished = false

    init(diagram: RenderedDiagram, width: CGFloat, timeout: TimeInterval, completion: @escaping (NSImage?) -> Void) {
        self.diagram = diagram; self.width = width; self.timeout = timeout; self.completion = completion
    }
    func start() {
        let size = DiagramLayout.size(natural: diagram.size, contentWidth: width, fontScale: 1)
        let config = SVGDocument.configuration()
        let view = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
        view.navigationDelegate = self
        webView = view
        let host = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = view
        host.orderBack(nil)
        window = host
        view.loadHTMLString(SVGDocument.html(for: diagram), baseURL: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(nil) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let config = WKPDFConfiguration()
        config.rect = webView.bounds
        webView.createPDF(configuration: config) { [weak self] result in
            self?.finish((try? result.get()).flatMap(NSImage.init(data:)))
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(nil) }
    private func finish(_ image: NSImage?) {
        guard !finished else { return }
        finished = true
        webView?.navigationDelegate = nil
        window?.orderOut(nil)
        webView = nil; window = nil
        completion(image)
    }
}
