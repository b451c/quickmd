import SwiftUI

/// Shared theme for consistent colors across all markdown views
/// Use `MarkdownTheme.cached(for:)` to get a cached instance instead of creating new ones
struct MarkdownTheme {
    let colorScheme: ColorScheme

    // MARK: - Cached Instances

    /// Cached light theme instance - avoids repeated allocations
    private static let lightTheme = MarkdownTheme(colorScheme: .light)

    /// Cached dark theme instance - avoids repeated allocations
    private static let darkTheme = MarkdownTheme(colorScheme: .dark)

    /// Returns cached theme instance for the given color scheme
    /// Prefer this over creating new MarkdownTheme instances directly
    static func cached(for colorScheme: ColorScheme) -> MarkdownTheme {
        colorScheme == .dark ? darkTheme : lightTheme
    }

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

    /// Matches table separator row: |---|---|---| or variants with alignment colons
    /// Examples: |:---|:---:|---:|, |---|---|
    static let tableSeparatorPattern = #"^\|?[\s\-:|]+\|?$"#

    /// Matches ATX-style headers: # H1, ## H2, ... ###### H6
    /// Captures: (1) hash marks, (2) header text
    static let headerPattern = #"^(#{1,6})\s+(.*)$"#

    /// Matches horizontal rules: ***, ---, ___ (3 or more)
    static let horizontalRulePattern = #"^(\*{3,}|-{3,}|_{3,})\s*$"#

    /// Matches standalone image on its own line: ![alt](url)
    /// Captures: (1) alt text, (2) URL
    static let imagePattern = #"^!\[(.*?)\]\((.*?)\)\s*$"#

    /// Matches task list items: - [ ] or - [x] with optional indentation
    /// Captures: (1) indent whitespace, (2) check state (space or x), (3) content
    static let taskListPattern = #"^(\s*)[-*+]\s+\[([ xX])\]\s+(.*)$"#

    // MARK: - Escape Characters

    /// Characters that can be escaped with backslash in markdown
    /// Example: \* renders as literal asterisk instead of italic marker
    static let escapableChars: Set<Character> = ["\\", "`", "*", "_", "{", "}", "[", "]", "(", ")", "#", "+", "-", ".", "!", "|"]

    // MARK: - URL Autolinking

    /// Matches bare URLs starting with http:// or https://
    /// Stops at whitespace, brackets, parentheses, or quotes
    static let autolinkPattern = #"https?://[^\s<>\[\]()\"']+"#

    // MARK: - Setext Headers

    /// Matches setext H1 underline: one or more = signs
    /// Example: Title\n=====
    static let setextH1Pattern = #"^=+\s*$"#

    /// Matches setext H2 underline: three or more - signs
    /// Example: Subtitle\n-------
    /// Note: Must be 3+ to distinguish from horizontal rule in some contexts
    static let setextH2Pattern = #"^-{3,}\s*$"#
}
