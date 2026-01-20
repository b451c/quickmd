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

    private var renderer: MarkdownRenderer {
        MarkdownRenderer(colorScheme: theme.colorScheme)
    }

    private var columnCount: Int { headers.count }

    // MARK: - Vertical Dividers

    /// Overlay for vertical dividers using GeometryReader
    /// Provides consistent column separators across all rows
    private func verticalDividers() -> some View {
        GeometryReader { geo in
            let cellWidth = geo.size.width / CGFloat(columnCount)
            ForEach(1..<columnCount, id: \.self) { i in
                Rectangle()
                    .fill(theme.borderColor)
                    .frame(width: 1, height: geo.size.height)
                    .position(x: cellWidth * CGFloat(i), y: geo.size.height / 2)
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                ForEach(0..<columnCount, id: \.self) { index in
                    Text(renderer.renderInline(headers[index]))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.textColor)
                        .multilineTextAlignment(textAlignmentFor(index))
                        .frame(maxWidth: .infinity, alignment: alignmentFor(index))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
            .background(theme.headerBackgroundColor)
            .overlay(verticalDividers())

            // Header separator
            Rectangle().fill(theme.borderColor).frame(height: 1)

            // Data rows
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { colIndex in
                        let cell = colIndex < row.count ? row[colIndex] : ""
                        Text(renderer.renderInline(cell))
                            .font(.system(size: 13))
                            .foregroundColor(theme.textColor)
                            .multilineTextAlignment(textAlignmentFor(colIndex))
                            .frame(maxWidth: .infinity, alignment: alignmentFor(colIndex))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                }
                .overlay(verticalDividers())

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
}
