import SwiftUI

// MARK: - Search Bar

/// Search bar for finding text within the document
/// Supports Cmd+F toggle, Enter/Shift+Enter navigation
struct SearchBar: View {
    @Binding var searchText: String
    @Binding var isVisible: Bool
    let matchCount: Int
    let currentMatch: Int
    let onNext: () -> Void
    let onPrevious: () -> Void

    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))

                TextField("Search...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isSearchFieldFocused)
                    .onSubmit {
                        onNext()
                    }

                if !searchText.isEmpty {
                    Text(matchCount > 0 ? "\(currentMatch + 1)/\(matchCount)" : "0 results")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 1))

            // Navigation buttons
            if !searchText.isEmpty && matchCount > 0 {
                Button(action: onPrevious) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Previous match")

                Button(action: onNext) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Next match")
            }

            // Close button
            Button {
                isVisible = false
                searchText = ""
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close search (Esc)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .onAppear {
            isSearchFieldFocused = true
        }
    }
}
