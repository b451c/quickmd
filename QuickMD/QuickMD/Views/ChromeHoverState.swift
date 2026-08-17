import Foundation

/// Generation-counted hover expansion. Views own the timer; this owns whether
/// the chrome pills should show their labels.
///
/// A delayed collapse must not clobber a later re-entry: `pointerExited()`
/// returns a generation that `applyScheduledCollapse(generation:)` honours
/// only if nothing has happened since.
struct ChromeHoverState: Equatable {
    static let collapseDelay: TimeInterval = 0.25

    private(set) var isExpanded = false
    private var collapseGeneration = 0

    mutating func pointerEntered() {
        collapseGeneration += 1
        isExpanded = true
    }

    /// Does not collapse immediately — schedule `applyScheduledCollapse`
    /// after `collapseDelay` with the returned generation.
    @discardableResult
    mutating func pointerExited() -> Int {
        collapseGeneration += 1
        return collapseGeneration
    }

    mutating func applyScheduledCollapse(generation: Int) {
        guard generation == collapseGeneration else { return }
        isExpanded = false
    }
}
