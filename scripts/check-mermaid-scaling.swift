// Run from the repository root: swift scripts/check-mermaid-scaling.swift
import AppKit
import WebKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("QuickMD/QuickMD/Resources")
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1400, height: 800))
let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = web
window.orderBack(nil)

func js(_ code: String) async throws -> Any? {
    try await web.evaluateJavaScript(code)
}
func pause() async throws { try await Task.sleep(nanoseconds: 100_000_000) }
func width(scale: Double) async throws -> Double {
    _ = try await js("renderDiagram('flowchart LR; A[Read text] --> B[Inspect image]', false, \(scale));")
    for _ in 0..<100 {
        if let value = try await js("document.querySelector('#output svg')?.getBoundingClientRect().width ?? 0") as? Double, value > 0 {
            return value
        }
        try await pause()
    }
    throw NSError(domain: "Diagram did not render", code: 1)
}
Task { @MainActor in
    do {
        web.loadFileURL(resources.appendingPathComponent("mermaid-template.html"), allowingReadAccessTo: resources)
        for _ in 0..<100 {
            if (try? await js("typeof renderDiagram")) as? String == "function" { break }
            try await pause()
        }
        let baseline = try await width(scale: 1)
        let enlarged = try await width(scale: 1.5)
        let reduced = try await width(scale: 0.75)
        print("Mermaid widths: baseline=\(baseline), 150%=\(enlarged), 75%=\(reduced)")
        guard abs(enlarged / baseline - 1.5) < 0.02,
              abs(reduced / baseline - 0.75) < 0.02 else {
            print("FAIL: diagram does not scale with text")
            exit(1)
        }
        web.setFrameSize(NSSize(width: 200, height: 800))
        try await pause()
        let narrow = try await js("document.querySelector('#output svg').getBoundingClientRect().width") as! Double
        guard narrow <= 201 else { print("FAIL: diagram exceeds column width"); exit(1) }
        let narrowBaseline = try await width(scale: 1)
        let narrowReduced = try await width(scale: 0.75)
        guard abs(narrowReduced / narrowBaseline - 0.75) < 0.02 else {
            print("FAIL: fitted diagram does not shrink in a narrow column"); exit(1)
        }
        _ = try await js("renderDiagram('flowchart TD; A[Read] --> B[Inspect]', false, 1, true);")
        for _ in 0..<100 {
            if (try await js("document.querySelector('#output svg') != null")) as? Bool == true { break }
            try await pause()
        }
        let fitted = try await js("(() => { const r = document.querySelector('#output svg').getBoundingClientRect(); return [r.width, r.height]; })()") as! [Double]
        guard fitted[0] <= 201, fitted[1] <= 801,
              abs(fitted[0] - 200) < 1 || abs(fitted[1] - 800) < 1 else {
            print("FAIL: preview does not fit the window"); exit(1)
        }
        print("PASS: proportional scaling, narrow-column shrinking, and preview fit")
        exit(0)
    } catch { print("FAIL: \(error)"); exit(1) }
}
app.run()
