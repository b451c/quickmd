import SwiftUI
import WebKit

struct DiagramBlockView: View {
    let source: DiagramSource
    let fontScale: CGFloat
    let contentWidth: CGFloat
    let onEnlarge: (GraphicPreview) -> Void
    @State private var diagram: RenderedDiagram?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let diagram {
                let size = DiagramLayout.size(natural: diagram.size, contentWidth: contentWidth, fontScale: fontScale)
                SVGImageView(diagram: diagram)
                    .frame(width: size.width, height: size.height)
                    .overlay {
                        Button { onEnlarge(.svg(diagram, title: source.kind.title, isBPMN: source.kind == .bpmn, isDark: source.isDark)) } label: {
                            Color.clear.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Enlarge \(source.kind.title)")
                        .help("Click to enlarge")
                    }
                if source.kind == .bpmn { BPMNAttribution() }
            } else if let error {
                Text("\(source.kind.title): \(error)")
                    .font(.system(size: 12 * fontScale))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                DisclosureGroup("Show diagram source") {
                    Text(source.source).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            } else {
                ProgressView().frame(height: BlockLayout.Mermaid.defaultHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, BlockLayout.Mermaid.verticalPadding)
        .task(id: source) {
            diagram = nil
            error = nil
            do {
                let rendered = try await DiagramRenderer.shared.render(source)
                guard !Task.isCancelled else { return }
                diagram = rendered
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

struct BPMNAttribution: View {
    var body: some View {
        Link("Powered by bpmn.io", destination: URL(string: "https://bpmn.io")!)
            .font(.system(size: 11))
    }
}

/// The SVG is an image resource, not executable page markup. JavaScript is
/// disabled, and CSP forbids all network/file subresources in this viewer.
struct SVGImageView: NSViewRepresentable {
    let diagram: RenderedDiagram
    var controller: ZoomWebViewController? = nil


    func makeNSView(context: Context) -> WKWebView {
        let config = SVGDocument.configuration()
        let view = DiagramDisplayWebView(frame: .zero, configuration: config)
        view.passesScrolling = controller == nil
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = controller != nil
        controller?.webView = view
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.svg != diagram.svg else { return }
        context.coordinator.svg = diagram.svg
        view.loadHTMLString(SVGDocument.html(for: diagram), baseURL: nil)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator { var svg: String? }
}

private final class DiagramDisplayWebView: WKWebView {
    var passesScrolling = true
    override func scrollWheel(with event: NSEvent) {
        if passesScrolling { nextResponder?.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }
}

final class ZoomWebViewController {
    weak var webView: WKWebView?
    func zoom(by factor: CGFloat) {
        guard let webView else { return }
        webView.magnification = min(8, max(0.25, webView.magnification * factor))
    }
    func resetZoom() { webView?.magnification = 1 }
}

struct SVGPreviewView: View {
    let diagram: RenderedDiagram
    let title: String
    let isBPMN: Bool
    let isDark: Bool
    let onClose: () -> Void
    @State private var controller = ZoomWebViewController()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { controller.zoom(by: 1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out")
                Button { controller.resetZoom() } label: { Image(systemName: "1.magnifyingglass") }
                    .help("Fit to window")
                Button { controller.zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in")
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
            }.padding()
            SVGImageView(diagram: diagram, controller: controller)
            if isBPMN { BPMNAttribution().padding(8) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDark ? Color(red: 0.12, green: 0.12, blue: 0.14) : Color.white)
        .environment(\.colorScheme, isDark ? .dark : .light)
    }
}
