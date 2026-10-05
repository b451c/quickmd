import Foundation

// MARK: - Landing after Source Edit (v1.12 S-D10)
//
// Where the rendered list scrolls when the editor goes away. Pure, so the one
// timing rule that matters is tested without a window: the target block must
// be looked up in the blocks parsed from the CURRENT text. Block ids are
// positional (`text-3` exists in every parse) — a save followed at once by
// leaving would otherwise resolve against the previous parse's blocks and send
// the list to whatever `text-3` used to be.

struct SourceEditLanding: Equatable {

    /// A 0-based source line still waiting for the parse of the current text.
    private(set) var pendingLine: Int?

    /// The session left. Returns the block id to scroll to NOW, or nil — then
    /// either nothing needs to move (`shouldLand` false) or the line waits for
    /// `blocksInstalled` because the installed blocks are not the current
    /// text's yet. Every leave replaces what an earlier one left pending.
    mutating func leave(_ info: SourceEditSession.LeaveInfo, installedBlocksAreCurrent: Bool,
                        blocks: [MarkdownBlock]) -> String? {
        pendingLine = nil
        guard info.shouldLand else { return nil }
        guard installedBlocksAreCurrent else {
            pendingLine = info.caretLine
            return nil
        }
        return Self.target(line: info.caretLine, in: blocks)
    }

    /// A parse of the current text is being installed: the pending line, if
    /// any, resolved against those blocks — to be requested in the SAME
    /// transaction, where it wins over the list's own anchor restore.
    mutating func blocksInstalled(_ blocks: [MarkdownBlock]) -> String? {
        guard let line = pendingLine else { return nil }
        pendingLine = nil
        return Self.target(line: line, in: blocks)
    }

    /// Editing again before the parse arrived: that landing is stale.
    mutating func cancel() {
        pendingLine = nil
    }

    private static func target(line: Int, in blocks: [MarkdownBlock]) -> String? {
        SourceEditSupport.blockIndex(containingLine: line, in: blocks).map { blocks[$0].id }
    }
}
