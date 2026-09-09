import XCTest
import WebKit

@MainActor
final class DiagramRendererTests: XCTestCase {
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("QuickMD/Resources")
    }
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    func testLinkedDiagramFilesRenderWithTheirDetectedFormat() async throws {
        let renderer = DiagramRenderer(resourcesURL: resources)
        for name in ["process.bpmn", "architecture.puml", "sequence.plantuml", "vector-example.svg"] {
            let url = fixture.appendingPathComponent(name)
            let kind = try XCTUnwrap(DiagramKind.linkedKind(for: url))
            let source = try String(contentsOf: url, encoding: .utf8)
            let rendered = try await renderer.render(.init(kind: kind, source: source, isDark: true))
            XCTAssertTrue(rendered.svg.contains("<svg"), name)
            XCTAssertGreaterThan(rendered.size.width, 10, name)
            XCTAssertGreaterThan(rendered.size.height, 10, name)
        }
        XCTAssertEqual(DiagramKind.linkedKind(for: URL(string: "https://example.com/process.BPMN?version=2")!), .bpmn)
        XCTAssertEqual(DiagramKind.linkedKind(for: URL(fileURLWithPath: "/tmp/diagram.PLANTUML")), .plantuml)
        XCTAssertNil(DiagramKind.linkedKind(for: URL(fileURLWithPath: "/tmp/photo.png")))
        XCTAssertNil(DiagramKind.linkedKind(for: URL(fileURLWithPath: "/tmp/notes.txt")))
    }

    func testBundledRenderersProduceSVGOffline() async throws {
        let renderer = DiagramRenderer(resourcesURL: resources)
        let bpmn = try String(contentsOf: fixture.appendingPathComponent("process.bpmn"), encoding: .utf8)
        let svg = try String(contentsOf: fixture.appendingPathComponent("vector-example.svg"), encoding: .utf8)
        let inputs: [DiagramSource] = [
            .init(kind: .mermaid, source: "flowchart LR; A[Read] --> B[Show]"),
            .init(kind: .plantuml, source: "@startuml\nAlice -> Bob: Hello\n@enduml"),
            .init(kind: .plantuml, source: "@startuml\nclass A\nclass B\nA --> B\n@enduml", isDark: true),
            .init(kind: .bpmn, source: bpmn),
            .init(kind: .svg, source: svg)
        ]
        for input in inputs {
            let rendered = try await renderer.render(input)
            XCTAssertTrue(rendered.svg.contains("<svg"), input.kind.rawValue)
            XCTAssertGreaterThan(rendered.size.width, 10)
            XCTAssertGreaterThan(rendered.size.height, 10)
            if input.kind == .bpmn {
                XCTAssertTrue(rendered.svg.contains("https://bpmn.io"))
                XCTAssertTrue(rendered.svg.contains("Review request"))
            }
            let cached = try await renderer.render(input)
            XCTAssertEqual(cached.svg, rendered.svg)
            XCTAssertEqual(cached.size, rendered.size)
        }
    }

    func testRequestsAreSerializedAndInvalidInputDoesNotPoisonRenderer() async throws {
        let renderer = DiagramRenderer(resourcesURL: resources)
        do {
            _ = try await renderer.render(.init(kind: .svg, source: "<not-svg/>"))
            XCTFail("Invalid SVG must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Invalid SVG")) }
        async let first = renderer.render(.init(kind: .plantuml, source: "@startuml\nAlice -> Bob: First\n@enduml"))
        async let second = renderer.render(.init(kind: .plantuml, source: "@startuml\nCarol -> Dave: Second\n@enduml"))
        let (a, b) = try await (first, second)
        XCTAssertTrue(a.svg.contains("First"))
        XCTAssertTrue(b.svg.contains("Second"))
        XCTAssertFalse(a.svg.contains("Second"))
    }

    func testSVGImageIsInertAndStillPaints() async throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="80" onload="top.document.title='executed'">
        <script>top.document.title='executed'</script>
        <image href="probe://external/image.png" width="10" height="10"/>
        <rect width="120" height="80" fill="red"/>
        </svg>
        """
        let config = SVGDocument.configuration()
        let probe = ExternalResourceProbe()
        config.setURLSchemeHandler(probe, forURLScheme: "probe")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 240, height: 160), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        web.loadHTMLString(SVGDocument.html(for: RenderedDiagram(svg: svg, size: CGSize(width: 120, height: 80))), baseURL: nil)
        try await waitForImage(web)
        let title = try await web.evaluateJavaScript("document.title") as? String
        XCTAssertNotEqual(title, "executed")
        XCTAssertEqual(probe.requests, 0)
        let snapshot = try await web.takeSnapshot(configuration: nil)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(snapshot.tiffRepresentation)))
        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        // Color-managed WebKit snapshots can shift pure sRGB red on wide-gamut
        // displays. Assert a painted red region, rather than exact device RGB.
        XCTAssertGreaterThan(color.redComponent, 0.8)
        XCTAssertGreaterThan(color.redComponent - color.greenComponent, 0.5)
        XCTAssertGreaterThan(color.redComponent - color.blueComponent, 0.5)
    }

    func testSVGDisplayAndPDFOutputForEveryRenderer() async throws {
        let renderer = DiagramRenderer(resourcesURL: resources)
        let bpmn = try String(contentsOf: fixture.appendingPathComponent("process.bpmn"), encoding: .utf8)
        let sources: [DiagramSource] = [
            .init(kind: .bpmn, source: bpmn),
            .init(kind: .plantuml, source: "@startuml\nAlice -> Bob: Hello\n@enduml"),
            .init(kind: .mermaid, source: "flowchart LR; A[Read document] --> B[Render SVG]")
        ]
        for source in sources {
            let rendered = try await renderer.render(source)
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 400), configuration: SVGDocument.configuration())
            let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = web
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            web.loadHTMLString(SVGDocument.html(for: rendered), baseURL: nil)
            try await waitForImage(web)
            let snapshot = try await web.takeSnapshot(configuration: nil)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(snapshot.tiffRepresentation)))
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("quickmd-\(source.kind.rawValue)-qa.png"))
            }
        }
        let images = await DiagramPDFRenderer.renderAll(sources: sources, width: 532, renderer: renderer)
        XCTAssertEqual(images.count, sources.count)
        for image in images.values {
            XCTAssertTrue(image.representations.contains { $0 is NSPDFImageRep })
        }
    }

    private func waitForImage(_ web: WKWebView) async throws {
        for _ in 0..<50 {
            if (try? await web.evaluateJavaScript("Boolean(document.querySelector('img')?.complete && document.querySelector('img')?.naturalWidth > 0)")) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("SVG did not load as an image")
    }

    func testDiagramScaleUsesFittedBaseline() {
        let natural = CGSize(width: 1000, height: 500)
        XCTAssertEqual(DiagramLayout.size(natural: natural, contentWidth: 600, fontScale: 1), CGSize(width: 600, height: 300))
        XCTAssertEqual(DiagramLayout.size(natural: natural, contentWidth: 600, fontScale: 0.5), CGSize(width: 300, height: 150))
        XCTAssertEqual(DiagramLayout.size(natural: natural, contentWidth: 600, fontScale: 2), CGSize(width: 600, height: 300))
    }
}

private final class ExternalResourceProbe: NSObject, WKURLSchemeHandler {
    var requests = 0
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        requests += 1
        urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
