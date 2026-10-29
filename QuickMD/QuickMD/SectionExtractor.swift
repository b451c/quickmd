import Foundation

// MARK: - Table of Contents Entry

/// A heading entry as seen by the ToC sidebar and section copy.
/// `sourceLine` is the 0-based line index of the heading in the raw document
/// text (assigned by `MarkdownBlockParser` — for setext headings it points at
/// the text line, not the underline).
struct ToCEntry: Identifiable, Sendable {
    let id: String
    let level: Int
    let title: String
    let sourceLine: Int
}

// MARK: - Heading Anchors

/// In-document links (`[Install](#install)`, #43) use the ids GitHub gives
/// headings, so a hand-written table of contents works as it does there.
/// Every rule below was checked against GitHub's renderer (2026-10-29).
enum HeadingAnchors {

    /// GitHub's id of one heading, from its RENDERED text (`**data**` is
    /// "data"): lowercased; letters, marks, decimal and letter numbers, `_`,
    /// joiners and `-` kept, each space a `-`, everything else dropped —
    /// `What's new in 1.2?` is `whats-new-in-12`, `C++ & C# notes` is
    /// `c--c-notes`.
    static func slug(_ text: String) -> String {
        var slug = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            if scalar == " " {
                slug.append("-")
            } else if scalar == "-" || isWordScalar(scalar) {
                slug.append(scalar)
            }
        }
        return String(slug)
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .letterNumber, .connectorPunctuation:
            return true
        default:
            // ZWJ inside an emoji sequence stays, as on GitHub
            return scalar.properties.isJoinControl
        }
    }

    /// The ids of headings in document order: a repeat gets `-1`, `-2`, …
    /// counted the way github-slugger counts (`Intro`, `Intro`, `Intro-1`,
    /// `Intro` are `intro`, `intro-1`, `intro-1-1`, `intro-2`).
    static func ids(for texts: [String]) -> [String] {
        var occurrences: [String: Int] = [:]
        return texts.map { text in
            let base = slug(text)
            var id = base
            while occurrences[id] != nil {
                occurrences[base, default: 0] += 1
                id = "\(base)-\(occurrences[base, default: 0])"
            }
            occurrences[id] = 0
            return id
        }
    }

    /// The headings of `blocks` as links see them: block id and the text the
    /// heading shows (`renderHeader`'s characters, as `HeadingBlockView`).
    static func headings(of blocks: [MarkdownBlock],
                         renderer: MarkdownRenderer) -> [(id: String, text: String)] {
        blocks.compactMap { block in
            guard case .heading(let level, let title, _) = block.content else { return nil }
            return (block.id, String(renderer.renderHeader(title, level: level).characters))
        }
    }

    /// The heading a link fragment points at: GitHub's id exactly, else the
    /// fragment's own slug — hand-written `#Install Guide` or `#Install-Guide`.
    /// nil when no heading has that id.
    static func headingId(forFragment fragment: String,
                          in headings: [(id: String, text: String)]) -> String? {
        let ids = ids(for: headings.map(\.text))
        guard let index = ids.firstIndex(of: fragment) ?? ids.firstIndex(of: slug(fragment)) else {
            return nil
        }
        return headings[index].id
    }

    /// The percent-decoded fragment of an in-document link (`#install`), nil
    /// for any other link. Read from the link as written: a destination
    /// `URL(string:)` rejects (non-ASCII or spaces on macOS 13) arrives
    /// percent-encoded, its `#` as `%23`.
    static func inDocumentFragment(of url: URL) -> String? {
        guard url.scheme == nil else { return nil }
        let written = url.relativeString.removingPercentEncoding ?? url.relativeString
        guard written.hasPrefix("#") else { return nil }
        return String(written.dropFirst())
    }
}

// MARK: - Section Extractor

/// Extracts the raw markdown of a section: from a heading line to the next
/// heading of the same or higher level (exclusive), trimming trailing blanks.
///
/// Section boundaries come from the parser via `ToCEntry.sourceLine` — the
/// parser is the single authority on what counts as a heading (it already
/// skips `#` lines inside fenced code blocks and multi-line math). An earlier
/// implementation re-scanned the raw text with its own heading regex and
/// diverged from the parser on exactly those cases, copying the wrong section.
enum SectionExtractor {

    static func extractSection(from text: String, entry: ToCEntry, headings: [ToCEntry]) -> String? {
        guard let entryIndex = headings.firstIndex(where: { $0.id == entry.id }) else { return nil }

        let lines = text.components(separatedBy: "\n")
        let start = entry.sourceLine
        guard start >= 0 && start < lines.count else { return nil }

        // The section ends right before the next heading at the same or a
        // higher level; if none follows, it runs to the end of the document.
        var end = lines.count
        for next in headings[(entryIndex + 1)...] where next.level <= entry.level {
            end = min(max(next.sourceLine, start), lines.count)
            break
        }
        guard end > start else { return nil }

        var section = Array(lines[start..<end])
        while let last = section.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            section.removeLast()
        }
        return section.joined(separator: "\n")
    }
}
