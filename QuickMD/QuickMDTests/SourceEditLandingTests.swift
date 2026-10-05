import XCTest
@testable import QuickMD

/// The landing scroll after leaving Source Edit (S-D10): resolved against the
/// blocks of the CURRENT text, never against a previous parse.
final class SourceEditLandingTests: XCTestCase {

    private func parse(_ text: String) -> [MarkdownBlock] {
        MarkdownBlockParser(theme: MarkdownTheme.cached(for: .light), fontScale: 1).parse(text)
    }

    private func leave(line: Int, land: Bool = true) -> SourceEditSession.LeaveInfo {
        SourceEditSession.LeaveInfo(caretLine: line, shouldLand: land, sequence: 1)
    }

    func testLandsAtOnceWhenTheInstalledBlocksAreCurrent() {
        let blocks = parse("# One\n\npara one\n\n# Two\n\npara two\n")
        var landing = SourceEditLanding()
        let target = landing.leave(leave(line: 6), installedBlocksAreCurrent: true, blocks: blocks)
        XCTAssertEqual(target, blocks[SourceEditSupport.blockIndex(containingLine: 6, in: blocks)!].id)
        XCTAssertNil(landing.pendingLine)
    }

    func testNoLandingLeavesTheListAlone() {
        var landing = SourceEditLanding()
        XCTAssertNil(landing.leave(leave(line: 3, land: false), installedBlocksAreCurrent: true,
                                   blocks: parse("a\n\nb\n\nc\n\nd\n")))
        XCTAssertNil(landing.leave(leave(line: 3, land: false), installedBlocksAreCurrent: false,
                                   blocks: parse("a\n")))
        XCTAssertNil(landing.pendingLine)
        XCTAssertNil(landing.blocksInstalled(parse("a\n")))
    }

    /// Save, then leave at once: the list still shows the OLD parse, where the
    /// same positional id names a different block.
    func testWaitsForTheParseOfTheSavedText() {
        let old = parse("# Title\n\nintro\n")
        let saved = parse("# Title\n\nnew first\n\nnew second\n\n# Next\n\nend\n")
        var landing = SourceEditLanding()
        XCTAssertNil(landing.leave(leave(line: 6), installedBlocksAreCurrent: false, blocks: old))
        XCTAssertEqual(landing.pendingLine, 6)
        let target = landing.blocksInstalled(saved)
        XCTAssertEqual(target, saved[SourceEditSupport.blockIndex(containingLine: 6, in: saved)!].id)
        guard case .heading(_, let title, _) = saved.first(where: { $0.id == target })?.content else {
            return XCTFail("the target is the heading on line 6 of the saved text")
        }
        XCTAssertEqual(title, "Next")
        XCTAssertNil(landing.pendingLine, "landed once")
        XCTAssertNil(landing.blocksInstalled(saved), "a later parse (zoom, theme) does not land again")
    }

    func testEnteringAgainDropsThePendingLanding() {
        var landing = SourceEditLanding()
        _ = landing.leave(leave(line: 4), installedBlocksAreCurrent: false, blocks: [])
        landing.cancel()
        XCTAssertNil(landing.blocksInstalled(parse("a\n\nb\n\nc\n")))
    }

    func testANewLeaveReplacesThePendingOne() {
        let blocks = parse("a\n\nb\n\nc\n\nd\n")
        var landing = SourceEditLanding()
        _ = landing.leave(leave(line: 6), installedBlocksAreCurrent: false, blocks: blocks)
        XCTAssertNil(landing.leave(leave(line: 2, land: false), installedBlocksAreCurrent: false, blocks: blocks))
        XCTAssertNil(landing.blocksInstalled(blocks))
    }

    func testEmptyDocumentHasNoTarget() {
        var landing = SourceEditLanding()
        XCTAssertNil(landing.leave(leave(line: 0), installedBlocksAreCurrent: true, blocks: []))
        _ = landing.leave(leave(line: 0), installedBlocksAreCurrent: false, blocks: [])
        XCTAssertNil(landing.blocksInstalled([]))
    }
}
