import SwiftUI
import WebKit

// MARK: - Mermaid Block View

/// Renders Mermaid diagrams using WKWebView with bundled mermaid.min.js.
/// Uses a shared WKProcessPool to keep memory bounded across multiple diagrams.
struct MermaidBlockView: View {
    let source: String
    let theme: MarkdownTheme
    @Environment(\.colorScheme) private var colorScheme

    @State private var diagramHeight: CGFloat = 200

    var body: some View {
        MermaidWebView(
            source: source,
            isDark: isDarkTheme,
            diagramHeight: $diagramHeight
        )
        .frame(height: diagramHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.vertical, 8)
    }

    private var isDarkTheme: Bool {
        theme.isDark
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

// MARK: - WKWebView Wrapper

private struct MermaidWebView: NSViewRepresentable {
    let source: String
    let isDark: Bool
    @Binding var diagramHeight: CGFloat

    // Shared process pool — one WebKit process for all Mermaid diagrams
    private static let processPool = WKProcessPool()

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = Self.processPool
        config.userContentController.add(context.coordinator, name: "mermaidHeight")

        let webView = ScrollPassthroughWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Avoid reloading if content hasn't changed
        if context.coordinator.lastSource == source && context.coordinator.lastIsDark == isDark {
            return
        }
        context.coordinator.lastSource = source
        context.coordinator.lastIsDark = isDark

        guard let templateURL = Bundle.main.url(forResource: "mermaid-template", withExtension: "html"),
              let templateHTML = try? String(contentsOf: templateURL, encoding: .utf8) else { return }

        // Load template then call renderDiagram via JavaScript
        let escapedSource = source
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")

        let html = templateHTML + """
        <script>renderDiagram('\(escapedSource)', \(isDark));</script>
        """

        let baseURL = Bundle.main.resourceURL
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: MermaidWebView
        var lastSource: String?
        var lastIsDark: Bool?

        init(_ parent: MermaidWebView) { self.parent = parent }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if let height = message.body as? Double {
                let newHeight = max(CGFloat(height), 50)
                if abs(newHeight - parent.diagramHeight) > 1 {
                    DispatchQueue.main.async {
                        self.parent.diagramHeight = newHeight
                    }
                }
            }
        }
    }
}
