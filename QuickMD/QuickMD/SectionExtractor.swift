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
