import XCTest
import SwiftUI
import AppKit

/// ⌘E at the reading position (v1.11 E-D1…E-D5): the per-editor line links,
/// the "which row is the reader at" rule and the toast copy.
///
/// The URL tests check two things per editor: the exact string for an ASCII
/// path (so a format change is a visible diff), and a ROUND TRIP through the
/// receiver's decoding for hostile paths — spaces, `#`, `?`, `%`, `&`,
/// non-ASCII — because that is what the editor actually sees.
final class ExternalEditorLineTests: XCTestCase {

    private let vscode = "com.microsoft.VSCode"
    private let insiders = "com.microsoft.VSCodeInsiders"
    private let bbedit = "com.barebones.bbedit"
    private let textmate = "com.macromates.TextMate"
    private let nova = "com.panic.Nova"

    /// Every awkward character the spec names, plus `&` (query separator) and
    /// a non-ASCII letter without a canonical decomposition (stable under NFC/NFD).
    private let hostilePaths = [
        "/Users/me/My Notes/read me.md",
        "/Users/me/Zażółć gęślą/łódź.md",
        "/Users/me/issue #31/notes.md",
        "/Users/me/what?/q.md",
        "/Users/me/100% done/a%20b.md",
        "/Users/me/R&D/a=b+c.md",
    ]

    private func link(_ bundleID: String, _ path: String, _ line: Int) -> URL? {
        ExternalEditorManager.lineLinkURL(bundleID: bundleID,
                                          fileURL: URL(fileURLWithPath: path), line: line)
    }

    private func queryValue(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == name })?.value
    }

    // MARK: - Exact strings (ASCII path)

    func testVSCodeLinkFormat() {
        XCTAssertEqual(link(vscode, "/Users/me/doc.md", 42)?.absoluteString,
                       "vscode://file/Users/me/doc.md:42:1")
        XCTAssertEqual(link(insiders, "/Users/me/doc.md", 42)?.absoluteString,
                       "vscode-insiders://file/Users/me/doc.md:42:1")
    }

    func testBBEditLinkFormat() {
        XCTAssertEqual(link(bbedit, "/Users/me/doc.md", 7)?.absoluteString,
                       "x-bbedit://open?url=file:///Users/me/doc.md&line=7")
    }

    func testTextMateLinkFormat() {
        XCTAssertEqual(link(textmate, "/Users/me/doc.md", 7)?.absoluteString,
                       "txmt://open/?url=file:///Users/me/doc.md&line=7")
    }

    func testNovaLinkFormat() {
        XCTAssertEqual(link(nova, "/Users/me/doc.md", 7)?.absoluteString,
                       "nova://open?path=/Users/me/doc.md&line=7")
    }

    func testSpaceIsPercentEncodedPerForm() {
        // Path form: one level of encoding.
        XCTAssertEqual(link(vscode, "/a b.md", 1)?.absoluteString, "vscode://file/a%20b.md:1:1")
        XCTAssertEqual(link(nova, "/a b.md", 1)?.absoluteString, "nova://open?path=/a%20b.md&line=1")
        // File-URL-as-value form: the file URL's own %20, encoded once more.
        XCTAssertEqual(link(bbedit, "/a b.md", 1)?.absoluteString,
                       "x-bbedit://open?url=file:///a%2520b.md&line=1")
    }

    // MARK: - Round trips (what the editor decodes)

    func testVSCodeRoundTripsHostilePaths() {
        for bundleID in [vscode, insiders] {
            for path in hostilePaths {
                guard let url = link(bundleID, path, 12) else { return XCTFail("nil for \(path)") }
                // Nothing may leak into a query or fragment.
                XCTAssertNil(url.query, path)
                XCTAssertNil(url.fragment, path)
                XCTAssertEqual(url.host, "file")
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                XCTAssertEqual(components?.path, path + ":12:1", path)
            }
        }
    }

    func testFileURLEditorsRoundTripHostilePaths() {
        for bundleID in [bbedit, textmate] {
            for path in hostilePaths {
                guard let url = link(bundleID, path, 3) else { return XCTFail("nil for \(path)") }
                XCTAssertNil(url.fragment, path)
                XCTAssertEqual(queryValue(url, "line"), "3", path)
                guard let value = queryValue(url, "url"), let fileURL = URL(string: value) else {
                    return XCTFail("url value does not parse for \(path)")
                }
                XCTAssertTrue(fileURL.isFileURL, path)
                XCTAssertEqual(fileURL.path, path)
            }
        }
    }

    func testNovaRoundTripsHostilePaths() {
        for path in hostilePaths {
            guard let url = link(nova, path, 9) else { return XCTFail("nil for \(path)") }
            XCTAssertNil(url.fragment, path)
            XCTAssertEqual(queryValue(url, "path"), path)
            XCTAssertEqual(queryValue(url, "line"), "9", path)
        }
    }

    func testNonASCIIIsEncodedAsUTF8() {
        // "ł" is U+0142 → UTF-8 C5 82. CharacterSet.alphanumerics would have
        // left it raw.
        let url = link(vscode, "/ł.md", 1)
        XCTAssertEqual(url?.absoluteString, "vscode://file/%C5%82.md:1:1")
    }

    // MARK: - Lines

    func testLinesAreOneBasedAndClamped() {
        XCTAssertEqual(link(vscode, "/a.md", 1)?.absoluteString, "vscode://file/a.md:1:1")
        // Never line 0 or negative — editors count from 1.
        XCTAssertEqual(link(vscode, "/a.md", 0)?.absoluteString, "vscode://file/a.md:1:1")
        XCTAssertEqual(link(nova, "/a.md", -4).flatMap { queryValue($0, "line") }, "1")
    }

    // MARK: - Fallback

    func testEditorsWithoutDocumentedLineLinkGetNil() {
        // Plain file open for everything outside the table — including the
        // candidates dropped for lack of vendor documentation.
        for bundleID in ["abnerworks.Typora", "md.obsidian", "pro.writer.mac", "com.uranusjr.macdown",
                         "com.apple.TextEdit", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
                         "com.sublimetext.4", "", "com.example.unknown"] {
            XCTAssertNil(link(bundleID, "/a.md", 5), bundleID)
        }
    }

    func testTableHasUniqueBundleIDs() {
        let ids = ExternalEditorManager.lineLinkEditors.map(\.bundleID)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    // MARK: - UI copy (E-D4)

    func testToastText() {
        XCTAssertEqual(ExternalEditorManager.toastText(for: .init(appName: "Visual Studio Code", line: 42)),
                       "Opened in Visual Studio Code at line 42")
        XCTAssertEqual(ExternalEditorManager.toastText(for: .init(appName: "Typora", line: nil)),
                       "Opened in Typora")
    }

    func testSettingsExplanationListsEveryLineLinkEditor() {
        let text = ExternalEditorManager.lineLinkExplanation
        XCTAssertTrue(text.hasPrefix("\u{2318}E opens the document at the line you are reading ("))
        for editor in ExternalEditorManager.lineLinkEditors {
            XCTAssertTrue(text.contains(editor.name), editor.name)
        }
    }

    // MARK: - Reading position (E-D1)

    private func point(_ row: Int, _ offset: Int) -> SelectionPoint {
        SelectionPoint(row: row, offset: offset)
    }

    func testNoSelectionUsesTopRow() {
        XCTAssertEqual(DocumentReadingPosition.targetRow(selection: nil, topRow: 7), 7)
        XCTAssertNil(DocumentReadingPosition.targetRow(selection: nil, topRow: nil))
    }

    func testCollapsedSelectionDoesNotCount() {
        // A plain click leaves an empty selection behind — that is not "the
        // reader pointed at something".
        let caret = DocumentSelection(collapsedAt: point(30, 4))
        XCTAssertEqual(DocumentReadingPosition.targetRow(selection: caret, topRow: 7), 7)
    }

    func testSelectionWinsOverTopRowAndUsesItsFirstRow() {
        let downward = DocumentSelection(anchor: point(12, 3), focus: point(15, 0))
        XCTAssertEqual(DocumentReadingPosition.targetRow(selection: downward, topRow: 2), 12)
        // Drag upwards: the first row is the focus's.
        let upward = DocumentSelection(anchor: point(15, 2), focus: point(12, 8))
        XCTAssertEqual(DocumentReadingPosition.targetRow(selection: upward, topRow: 2), 12)
        // A selection off screen still wins (scrolled away after selecting).
        XCTAssertEqual(DocumentReadingPosition.targetRow(selection: upward, topRow: nil), 12)
    }

    func testEditorLineIsSourceLinePlusOne() {
        let blocks = [
            MarkdownBlock.heading(index: 0, level: 1, title: "Title", sourceLine: 0),
            MarkdownBlock.text(index: 1, AttributedString("para"), sourceLine: 2),
            MarkdownBlock.codeBlock(index: 2, code: "x", language: "", sourceLine: 9),
        ]
        XCTAssertEqual(DocumentReadingPosition.editorLine(selection: nil, topRow: 0, blocks: blocks), 1)
        XCTAssertEqual(DocumentReadingPosition.editorLine(selection: nil, topRow: 2, blocks: blocks), 10)
        let selection = DocumentSelection(anchor: point(1, 0), focus: point(2, 1))
        XCTAssertEqual(DocumentReadingPosition.editorLine(selection: selection, topRow: 0, blocks: blocks), 3)
        // Stale row (racing a re-install) → nil, never a wrong line.
        XCTAssertNil(DocumentReadingPosition.editorLine(selection: nil, topRow: 3, blocks: blocks))
        XCTAssertNil(DocumentReadingPosition.editorLine(selection: nil, topRow: nil, blocks: blocks))
    }

    func testParserSourceLineIsZeroBased() {
        // Pins the `+ 1`: the first line of a document is sourceLine 0.
        let blocks = MarkdownBlockParser(colorScheme: .light).parse("# One\n\nTwo\n")
        XCTAssertEqual(blocks.first?.sourceLine, 0)
        XCTAssertEqual(DocumentReadingPosition.editorLine(selection: nil, topRow: 0, blocks: blocks), 1)
        XCTAssertEqual(blocks.last?.sourceLine, 2)
    }

    func testHandleAsksItsProvider() {
        let handle = DocumentReadingPosition()
        XCTAssertNil(handle.editorLine())
        handle.provider = { 17 }
        XCTAssertEqual(handle.editorLine(), 17)
    }
}
