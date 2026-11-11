import Foundation

// MARK: - Emphasis and strikethrough: CommonMark's delimiter stack
//
// `*`, `_` and `~` runs are not matched by looking for "the next marker"
// (the pre-1.15 renderer did, and `**foo*bar*baz**`, `*foo**bar**baz*`,
// `__foo, __bar__, baz__`, `*(*foo*)*`, `5__6__78`, `*foo [bar*](u)` all came
// out wrong). Each run is classified by its neighbours (left/right-flanking),
// pushed here as it is met, and matched by CommonMark's "process emphasis"
// procedure — with GFM's strikethrough (`~`/`~~`, equal lengths) in the same
// stack, as cmark-gfm does. The renderer runs it at every link's `]` for the
// runs inside the link text (so emphasis never crosses a link boundary) and
// once at the end of the line.
//
// The result is a list of spans over the renderer's NODE indices (a node is a
// piece of text, an atom such as a code span, or a delimiter run whose
// leftover characters are literal text). Spans nest properly — a match
// removes every run between its opener and closer — and a run's consumed
// characters are always the ones next to the content, so a span is exactly
// "the nodes strictly between opener and closer".
//
// Linear: runs live in a doubly linked list (removal O(1)), and the openers
// a closer has already searched past are skipped through `openersBottom`
// (keyed by everything that decides a match: character, the closer's
// can-open, its length mod 3). No recursion anywhere, so 10 000 `*` or deeply
// nested emphasis cannot overflow the parse task's 512 KB stack.

struct InlineDelimiterStack {

    enum Style { case emphasis, strong, strikethrough }

    /// Nodes `start..<end` carry `style`.
    struct Span: Equatable {
        let start: Int
        let end: Int
        let style: Style
    }

    struct Run {
        /// `*`, `_` or `~`.
        let character: UInt8
        /// The node that holds this run's characters.
        let node: Int
        let originalCount: Int
        /// Characters not (yet) used by a match — drawn as literal text.
        var count: Int
        let canOpen: Bool
        let canClose: Bool
    }

    private(set) var runs: [Run] = []
    private var previous: [Int] = []
    private var next: [Int] = []
    private var removed: [Bool] = []
    /// The newest run still on the stack, -1 when empty.
    private var top = -1
    private(set) var spans: [Span] = []

    /// Index the next pushed run will get — a link opener remembers it as
    /// its stack bottom.
    var count: Int { runs.count }

    // MARK: Pushing

    /// Classifies a run of `length` × `character` by the scalars around it
    /// (nil = start / end of the line, which counts as white space) and
    /// pushes it. Nil when the run is no delimiter at all (`~~~`, a `~` run
    /// longer than two, is literal text in GFM) — the caller keeps it as text.
    mutating func push(character: UInt8, length: Int, node: Int,
                       before: Unicode.Scalar?, after: Unicode.Scalar?) -> Int? {
        if character == UInt8(ascii: "~"), length > 2 { return nil }
        let beforeSpace = before.map(Self.isWhitespace) ?? true
        let afterSpace = after.map(Self.isWhitespace) ?? true
        let beforePunct = before.map(Self.isPunctuation) ?? false
        let afterPunct = after.map(Self.isPunctuation) ?? false
        let leftFlanking = !afterSpace && (!afterPunct || beforeSpace || beforePunct)
        let rightFlanking = !beforeSpace && (!beforePunct || afterSpace || afterPunct)
        let canOpen: Bool
        let canClose: Bool
        if character == UInt8(ascii: "_") {
            // `_` inside a word neither opens nor closes (`snake_case_name`).
            canOpen = leftFlanking && (!rightFlanking || beforePunct)
            canClose = rightFlanking && (!leftFlanking || afterPunct)
        } else {
            canOpen = leftFlanking
            canClose = rightFlanking
        }
        let index = runs.count
        runs.append(Run(character: character, node: node, originalCount: length, count: length,
                        canOpen: canOpen, canClose: canClose))
        previous.append(top)
        next.append(-1)
        removed.append(false)
        if top >= 0 { next[top] = index }
        top = index
        return index
    }

    /// CommonMark's Unicode white space: Zs, tab, line feed, form feed,
    /// carriage return (a no-break space counts: `*\u{A0}a\u{A0}*` is text).
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case " ", "\t", "\n", "\u{0C}", "\r": return true
        default: return scalar.properties.generalCategory == .spaceSeparator
        }
    }

    /// cmark-gfm's punctuation: every ASCII punctuation character (`$`, `+`,
    /// `<`, `|`, `~` … included) and Unicode P* — not other symbols:
    /// on GitHub `x*€a€*y` is emphasis, `€` (Sc) being no punctuation, while
    /// `«*a*»` and `„*a*”` are too because the quotes are.
    static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII {
            let value = scalar.value
            return (0x21...0x2F).contains(value) || (0x3A...0x40).contains(value)
                || (0x5B...0x60).contains(value) || (0x7B...0x7E).contains(value)
        }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    // MARK: Processing

    private func key(_ run: Run) -> Int {
        let character: Int
        switch run.character {
        case UInt8(ascii: "*"): character = 0
        case UInt8(ascii: "_"): character = 1
        default: character = 2
        }
        return character * 6 + (run.canOpen ? 3 : 0) + run.originalCount % 3
    }

    private mutating func remove(_ index: Int) {
        guard !removed[index] else { return }
        removed[index] = true
        let before = previous[index]
        let after = next[index]
        if before >= 0 { next[before] = after }
        if after >= 0 { previous[after] = before } else { top = before }
    }

    /// Matches the runs pushed at index `bottom` or later (CommonMark
    /// "process emphasis" with that stack bottom), appends the spans, and
    /// removes all of those runs from the stack — their leftover characters
    /// are text from now on.
    mutating func process(above bottom: Int) {
        // First run at or above the bottom.
        var closer = top
        while closer >= 0, previous[closer] >= bottom { closer = previous[closer] }
        guard closer >= bottom else { return }
        var openersBottom = [Int](repeating: bottom - 1, count: 18)

        while closer >= 0 {
            let closing = runs[closer]
            guard closing.canClose else { closer = next[closer]; continue }
            let bucket = key(closing)
            var opener = previous[closer]
            var found = false
            while opener >= bottom, opener > openersBottom[bucket] {
                let opening = runs[opener]
                if opening.canOpen, opening.character == closing.character {
                    if closing.character == UInt8(ascii: "~") {
                        if opening.count == closing.count { found = true; break }
                    } else {
                        // The "multiple of 3" rule: a run that can both open
                        // and close matches only if the lengths don't sum to
                        // a multiple of 3 (unless both are).
                        let oddMatch = (closing.canOpen || opening.canClose)
                            && closing.originalCount % 3 != 0
                            && (opening.originalCount + closing.originalCount) % 3 == 0
                        if !oddMatch { found = true; break }
                    }
                }
                opener = previous[opener]
            }

            guard found else {
                // Nothing at or below here matches a closer of this kind.
                openersBottom[bucket] = previous[closer]
                let following = next[closer]
                if !closing.canOpen { remove(closer) }
                closer = following
                continue
            }

            let style: Style
            let used: Int
            if closing.character == UInt8(ascii: "~") {
                style = .strikethrough
                used = closing.count
            } else {
                used = closing.count >= 2 && runs[opener].count >= 2 ? 2 : 1
                style = used == 2 ? .strong : .emphasis
            }
            runs[opener].count -= used
            runs[closer].count -= used
            spans.append(Span(start: runs[opener].node + 1, end: closing.node, style: style))
            // Runs between the two can no longer match anything.
            var between = next[opener]
            while between != closer {
                let following = next[between]
                remove(between)
                between = following
            }
            if runs[opener].count == 0 { remove(opener) }
            if runs[closer].count == 0 {
                let following = next[closer]
                remove(closer)
                closer = following
            }
        }

        // Everything above the bottom is text now.
        while top >= bottom { remove(top) }
    }
}
