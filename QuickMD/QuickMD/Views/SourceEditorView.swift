import SwiftUI

// MARK: - Source editor view (v1.12 S-D4)

/// SwiftUI host for the source editor. Wiring only: the controller builds the
/// hierarchy once and owns all behaviour (`SourceEditorController.swift`), so
/// the session keeps talking to the same text view — and the same undo stack —
/// however often SwiftUI re-creates this struct.
///
/// Exactly ONE live `SourceEditorView` per controller: the controller has one
/// scroll view, and a second host takes it from the first, which stays empty.
/// The integrator must not put a `.transition` on the editor overlay (the
/// outgoing copy would briefly be a second host), and must keep the view's
/// identity stable across Reading Mode / zoom / theme changes — those reach
/// the editor through `style` (`apply(style:)`), never through a new identity.
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
