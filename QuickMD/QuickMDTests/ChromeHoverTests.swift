import XCTest

/// Hover-cluster state machine for the top-right chrome pills.
/// The views own the collapse timer; these tests own the generation rules
/// that stop a late collapse from fighting a re-entry.
final class ChromeHoverTests: XCTestCase {

    func testStartsCollapsed() {
        XCTAssertFalse(ChromeHoverState().isExpanded)
    }

    func testPointerEnteredExpands() {
        var hover = ChromeHoverState()
        hover.pointerEntered()
        XCTAssertTrue(hover.isExpanded)
    }

    func testPointerExitedDoesNotCollapseImmediately() {
        var hover = ChromeHoverState()
        hover.pointerEntered()
        hover.pointerExited()
        XCTAssertTrue(hover.isExpanded)
    }

    func testScheduledCollapseHonoursMatchingGeneration() {
        var hover = ChromeHoverState()
        hover.pointerEntered()
        let generation = hover.pointerExited()
        hover.applyScheduledCollapse(generation: generation)
        XCTAssertFalse(hover.isExpanded)
    }

    func testStaleCollapseAfterReentryIsIgnored() {
        var hover = ChromeHoverState()
        hover.pointerEntered()
        let stale = hover.pointerExited()
        hover.pointerEntered()
        hover.applyScheduledCollapse(generation: stale)
        XCTAssertTrue(hover.isExpanded)
    }

    func testOnlyLatestExitGenerationCollapses() {
        var hover = ChromeHoverState()
        hover.pointerEntered()
        let firstExit = hover.pointerExited()
        hover.pointerEntered()
        let secondExit = hover.pointerExited()
        hover.applyScheduledCollapse(generation: firstExit)
        XCTAssertTrue(hover.isExpanded)
        hover.applyScheduledCollapse(generation: secondExit)
        XCTAssertFalse(hover.isExpanded)
    }

    func testUnknownGenerationIsANoOp() {
        var hover = ChromeHoverState()
        hover.pointerEntered()
        hover.applyScheduledCollapse(generation: .min)
        XCTAssertTrue(hover.isExpanded)
    }

    func testCollapseDelayMatchesHeadingCopyBallpark() {
        // Snappier than the heading copy button (0.4s) — this is toolbar chrome.
        XCTAssertEqual(ChromeHoverState.collapseDelay, 0.25)
        XCTAssertGreaterThan(ChromeHoverState.collapseDelay, 0)
        XCTAssertLessThan(ChromeHoverState.collapseDelay, 0.4)
    }
}
