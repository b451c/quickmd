import SwiftUI

/// Shared theme for consistent colors across all markdown views
struct MarkdownTheme {
    let colorScheme: ColorScheme

    // MARK: - Text Colors

    var textColor: Color {
        colorScheme == .dark ? .white : .black
    }

    var secondaryTextColor: Color {
        colorScheme == .dark ? Color.gray : Color(white: 0.4)
    }

    var linkColor: Color {
        .blue
    }

    var blockquoteColor: Color {
        .gray
    }

    // MARK: - Background Colors

    var backgroundColor: Color {
        colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.98)
    }

    var codeBackgroundColor: Color {
        colorScheme == .dark ? Color(white: 0.18) : Color(white: 0.95)
    }

    var headerBackgroundColor: Color {
        colorScheme == .dark ? Color(white: 0.2) : Color(white: 0.9)
    }

    // MARK: - Border Colors

    var borderColor: Color {
        colorScheme == .dark ? Color.gray.opacity(0.5) : Color.gray.opacity(0.3)
    }

    // MARK: - Syntax Highlighting Colors

    var keywordColor: Color {
        colorScheme == .dark ? Color(red: 0.8, green: 0.4, blue: 0.8) : Color(red: 0.6, green: 0.1, blue: 0.6)
    }

    var stringColor: Color {
        colorScheme == .dark ? Color(red: 0.8, green: 0.6, blue: 0.4) : Color(red: 0.6, green: 0.3, blue: 0.1)
    }

    var commentColor: Color {
        colorScheme == .dark ? Color.gray : Color(white: 0.4)
    }

    var numberColor: Color {
        colorScheme == .dark ? Color(red: 0.6, green: 0.8, blue: 0.6) : Color(red: 0.2, green: 0.5, blue: 0.2)
    }

    var typeColor: Color {
        colorScheme == .dark ? Color(red: 0.5, green: 0.8, blue: 0.9) : Color(red: 0.1, green: 0.4, blue: 0.6)
    }

    var checkboxColor: Color {
        .green
    }

    // MARK: - Regex Patterns (shared constants)

    static let tableSeparatorPattern = #"^\|?[\s\-:|]+\|?$"#
    static let headerPattern = #"^(#{1,6})\s+(.*)$"#
    static let horizontalRulePattern = #"^(\*{3,}|-{3,}|_{3,})\s*$"#
    static let imagePattern = #"^!\[(.*?)\]\((.*?)\)\s*$"#
    static let taskListPattern = #"^(\s*)[-*+]\s+\[([ xX])\]\s+(.*)$"#
}
