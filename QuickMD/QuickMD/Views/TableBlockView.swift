import SwiftUI

// MARK: - Table Alignment Protocol

/// Shared protocol for table alignment logic
/// Used by both TableBlockView (live) and PrintableTableView (export)
protocol TableAlignmentProvider {
    var alignments: [TextAlignment] { get }
}

extension TableAlignmentProvider {
    /// Convert TextAlignment to SwiftUI Alignment for frame
    func alignmentFor(_ index: Int) -> Alignment {
        guard index < alignments.count else { return .leading }
        switch alignments[index] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        @unknown default: return .leading
        }
    }

    /// Get TextAlignment for multilineTextAlignment modifier
    func textAlignmentFor(_ index: Int) -> TextAlignment {
        guard index < alignments.count else { return .leading }
        return alignments[index]
    }
}

// MARK: - Table Block View

/// Renders a markdown table with headers, rows, and column alignment
/// Supports inline markdown formatting in cells (bold, italic, code, links)
struct TableBlockView: View, TableAlignmentProvider {
    let headers: [String]
    let rows: [[String]]
    let alignments: [TextAlignment]
    let theme: MarkdownTheme
    var searchText: String = ""
    var focusedOccurrence: Int? = nil

    /// Cached renderer instance - created once on init, not on every body evaluation
    private let renderer: MarkdownRenderer

    /// Stored column count - computed once on init for efficiency
    private let columnCount: Int

    init(headers: [String], rows: [[String]], alignments: [TextAlignment], theme: MarkdownTheme,
         searchText: String = "", focusedOccurrence: Int? = nil) {
        self.headers = headers
        self.rows = rows
        self.alignments = alignments
        self.theme = theme
        self.searchText = searchText
        self.focusedOccurrence = focusedOccurrence
        self.renderer = MarkdownRenderer(theme: theme)
        self.columnCount = headers.count
    }

    // MARK: - Body

    var body: some View {
        // Precompute per-cell occurrence offsets for focused highlighting
        let cellOffsets = computeCellOffsets()

        VStack(spacing: 0) {
            // Header row with inline dividers (no GeometryReader)
            HStack(spacing: 0) {
                ForEach(0..<columnCount, id: \.self) { index in
                    let rendered = renderer.renderInline(headers[index])
                    let localFocused = localFocusedOccurrence(cellOffset: cellOffsets.headerOffsets[index],
                                                               cellText: headers[index])
                    Text(searchText.isEmpty ? rendered : searchHighlight(rendered, term: searchText, focusedOccurrence: localFocused))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.textColor)
                        .multilineTextAlignment(textAlignmentFor(index))
                        .frame(maxWidth: .infinity, alignment: alignmentFor(index))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                    // Inline vertical divider (except after last column)
                    if index < columnCount - 1 {
                        Rectangle()
                            .fill(theme.borderColor)
                            .frame(width: 1)
                    }
                }
            }
            .background(theme.headerBackgroundColor)

            // Header separator
            Rectangle().fill(theme.borderColor).frame(height: 1)

            // Data rows with inline dividers
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { colIndex in
                        let cell = colIndex < row.count ? row[colIndex] : ""
                        let rendered = renderer.renderInline(cell)
                        let localFocused = localFocusedOccurrence(cellOffset: cellOffsets.rowOffsets[rowIndex][colIndex],
                                                                   cellText: cell)
                        Text(searchText.isEmpty ? rendered : searchHighlight(rendered, term: searchText, focusedOccurrence: localFocused))
                            .font(.system(size: 13))
                            .foregroundColor(theme.textColor)
                            .multilineTextAlignment(textAlignmentFor(colIndex))
                            .frame(maxWidth: .infinity, alignment: alignmentFor(colIndex))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)

                        // Inline vertical divider (except after last column)
                        if colIndex < columnCount - 1 {
                            Rectangle()
                                .fill(theme.borderColor)
                                .frame(width: 1)
                        }
                    }
                }

                // Row separator (except for last row)
                if rowIndex < rows.count - 1 {
                    Rectangle().fill(theme.borderColor).frame(height: 1)
                }
            }
        }
        .background(theme.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.borderColor, lineWidth: 1))
    }

    // MARK: - Per-Cell Occurrence Tracking

    private struct CellOffsets {
        let headerOffsets: [Int]       // occurrence offset for each header cell
        let rowOffsets: [[Int]]        // occurrence offset for each data cell
    }

    /// Compute cumulative occurrence offset for each cell (headers first, then rows L→R, T→B)
    private func computeCellOffsets() -> CellOffsets {
        guard !searchText.isEmpty else {
            return CellOffsets(headerOffsets: Array(repeating: 0, count: columnCount),
                               rowOffsets: rows.map { _ in Array(repeating: 0, count: columnCount) })
        }
        var offset = 0
        var headerOffsets: [Int] = []
        for i in 0..<columnCount {
            headerOffsets.append(offset)
            offset += countOccurrences(in: headers[i], of: searchText)
        }
        var rowOffsets: [[Int]] = []
        for row in rows {
            var rowOff: [Int] = []
            for colIndex in 0..<columnCount {
                rowOff.append(offset)
                let cell = colIndex < row.count ? row[colIndex] : ""
                offset += countOccurrences(in: cell, of: searchText)
            }
            rowOffsets.append(rowOff)
        }
        return CellOffsets(headerOffsets: headerOffsets, rowOffsets: rowOffsets)
    }

    /// Map block-level focusedOccurrence to a cell-local occurrence, or nil if not in this cell
    private func localFocusedOccurrence(cellOffset: Int, cellText: String) -> Int? {
        guard let fo = focusedOccurrence else { return nil }
        let cellCount = countOccurrences(in: cellText, of: searchText)
        let local = fo - cellOffset
        if local >= 0 && local < cellCount { return local }
        return nil
    }
}
