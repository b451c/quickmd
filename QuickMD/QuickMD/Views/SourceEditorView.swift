import SwiftUI

// MARK: - Source editor view (v1.12 S-D4)

/// SwiftUI host for the source editor. Wiring only: the controller builds the
/// hierarchy once and owns all behaviour (`SourceEditorController.swift`), so
/// the session keeps talking to the same text view — and the same undo stack —
/// however often SwiftUI re-creates this struct.
struct SourceEditorView: NSViewRepresentable {
    let controller: SourceEditorController
    let style: SourceEditorController.Style

    func makeNSView(context: Context) -> NSScrollView {
        controller.makeScrollView(style: style)
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        controller.apply(style: style)
    }
}
