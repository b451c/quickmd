import SwiftUI

// MARK: - Theme Name (built-in identifiers)

/// String identifiers for built-in themes. Custom themes use arbitrary names.
enum ThemeName {
    static let auto = "Auto"
    static let solarizedLight = "Solarized Light"
    static let solarizedDark = "Solarized Dark"
    static let dracula = "Dracula"
    static let github = "GitHub"
    static let gruvboxDark = "Gruvbox Dark"
    static let nord = "Nord"

    /// Display order for the built-in section of the picker
    static let allBuiltIn: [String] = [
        auto, solarizedLight, solarizedDark, dracula, github, gruvboxDark, nord
    ]
}

// MARK: - Theme

/// Shared theme for consistent colors across all markdown views.
/// Use `MarkdownTheme.theme(named:colorScheme:)` to resolve by name (built-in or custom).
struct MarkdownTheme: Sendable, Identifiable {
    let name: String
    let isDark: Bool

    var id: String { name }

    // MARK: - Text Colors

    let textColor: Color
    let secondaryTextColor: Color
    let linkColor: Color
    let blockquoteColor: Color

    // MARK: - Background Colors

    let backgroundColor: Color
    let codeBackgroundColor: Color
    let headerBackgroundColor: Color

    // MARK: - Border Colors

    let borderColor: Color

    // MARK: - Syntax Highlighting Colors

    let keywordColor: Color
    let stringColor: Color
    let commentColor: Color
    let numberColor: Color
    let typeColor: Color
    let checkboxColor: Color

    // MARK: - Factory

    /// Resolves a theme by name. Order: built-in → custom store → fallback (auto).
    /// Auto resolves to its light/dark variant based on `colorScheme`.
    static func theme(named name: String, colorScheme: ColorScheme) -> MarkdownTheme {
        if name == ThemeName.auto {
            return colorScheme == .dark ? _autoDark : _autoLight
        }
        if let builtIn = _builtInByName[name] {
            return builtIn
        }
        if let custom = CustomThemeStore.shared.theme(named: name) {
            return custom
        }
        return colorScheme == .dark ? _autoDark : _autoLight
    }

    /// Convenience for export/print code that always uses light theme
    static func cached(for colorScheme: ColorScheme) -> MarkdownTheme {
        theme(named: ThemeName.auto, colorScheme: colorScheme)
    }

    /// All built-in themes for picker display (Auto resolved to light variant for preview).
    static var allBuiltInThemes: [MarkdownTheme] {
        [_autoLight, _solarizedLight, _solarizedDark, _dracula, _github, _gruvboxDark, _nord]
    }

    private static let _builtInByName: [String: MarkdownTheme] = [
        ThemeName.solarizedLight: _solarizedLight,
        ThemeName.solarizedDark: _solarizedDark,
        ThemeName.dracula: _dracula,
        ThemeName.github: _github,
        ThemeName.gruvboxDark: _gruvboxDark,
        ThemeName.nord: _nord,
    ]

    // MARK: - Static Theme Instances

    private static let _autoLight = MarkdownTheme(
        name: ThemeName.auto,
        isDark: false,
        textColor: .black,
        secondaryTextColor: Color(white: 0.4),
        linkColor: .blue,
        blockquoteColor: .gray,
        backgroundColor: Color(white: 0.98),
        codeBackgroundColor: Color(white: 0.95),
        headerBackgroundColor: Color(white: 0.9),
        borderColor: Color.gray.opacity(0.3),
        keywordColor: Color(red: 0.6, green: 0.1, blue: 0.6),
        stringColor: Color(red: 0.6, green: 0.3, blue: 0.1),
        commentColor: Color(white: 0.4),
        numberColor: Color(red: 0.2, green: 0.5, blue: 0.2),
        typeColor: Color(red: 0.1, green: 0.4, blue: 0.6),
        checkboxColor: .green
    )

    private static let _autoDark = MarkdownTheme(
        name: ThemeName.auto,
        isDark: true,
        textColor: .white,
        secondaryTextColor: .gray,
        linkColor: .blue,
        blockquoteColor: .gray,
        backgroundColor: Color(white: 0.12),
        codeBackgroundColor: Color(white: 0.18),
        headerBackgroundColor: Color(white: 0.2),
        borderColor: Color.gray.opacity(0.5),
        keywordColor: Color(red: 0.8, green: 0.4, blue: 0.8),
        stringColor: Color(red: 0.8, green: 0.6, blue: 0.4),
        commentColor: .gray,
        numberColor: Color(red: 0.6, green: 0.8, blue: 0.6),
        typeColor: Color(red: 0.5, green: 0.8, blue: 0.9),
        checkboxColor: .green
    )

    // Solarized Light — cream background (#FDF6E3), dark blue-gray text
    private static let _solarizedLight = MarkdownTheme(
        name: ThemeName.solarizedLight,
        isDark: false,
        textColor: Color(hex: "657B83"),
        secondaryTextColor: Color(hex: "93A1A1"),
        linkColor: Color(hex: "268BD2"),
        blockquoteColor: Color(hex: "93A1A1"),
        backgroundColor: Color(hex: "FDF6E3"),
        codeBackgroundColor: Color(hex: "EEE8D5"),
        headerBackgroundColor: Color(hex: "EEE8D5"),
        borderColor: Color(hex: "93A1A1").opacity(0.3),
        keywordColor: Color(hex: "859900"),
        stringColor: Color(hex: "2AA198"),
        commentColor: Color(hex: "93A1A1"),
        numberColor: Color(hex: "D33682"),
        typeColor: Color(hex: "B58900"),
        checkboxColor: Color(hex: "859900")
    )

    // Solarized Dark — dark blue background (#002B36), light text
    private static let _solarizedDark = MarkdownTheme(
        name: ThemeName.solarizedDark,
        isDark: true,
        textColor: Color(hex: "839496"),
        secondaryTextColor: Color(hex: "586E75"),
        linkColor: Color(hex: "268BD2"),
        blockquoteColor: Color(hex: "586E75"),
        backgroundColor: Color(hex: "002B36"),
        codeBackgroundColor: Color(hex: "073642"),
        headerBackgroundColor: Color(hex: "073642"),
        borderColor: Color(hex: "586E75").opacity(0.5),
        keywordColor: Color(hex: "859900"),
        stringColor: Color(hex: "2AA198"),
        commentColor: Color(hex: "586E75"),
        numberColor: Color(hex: "D33682"),
        typeColor: Color(hex: "B58900"),
        checkboxColor: Color(hex: "859900")
    )

    // Dracula — purple-tinted dark background (#282A36), pastel syntax colors
    private static let _dracula = MarkdownTheme(
        name: ThemeName.dracula,
        isDark: true,
        textColor: Color(hex: "F8F8F2"),
        secondaryTextColor: Color(hex: "6272A4"),
        linkColor: Color(hex: "8BE9FD"),
        blockquoteColor: Color(hex: "6272A4"),
        backgroundColor: Color(hex: "282A36"),
        codeBackgroundColor: Color(hex: "44475A"),
        headerBackgroundColor: Color(hex: "44475A"),
        borderColor: Color(hex: "6272A4").opacity(0.5),
        keywordColor: Color(hex: "FF79C6"),
        stringColor: Color(hex: "F1FA8C"),
        commentColor: Color(hex: "6272A4"),
        numberColor: Color(hex: "BD93F9"),
        typeColor: Color(hex: "8BE9FD"),
        checkboxColor: Color(hex: "50FA7B")
    )

    // GitHub — clean white background, blue links, familiar GitHub style
    private static let _github = MarkdownTheme(
        name: ThemeName.github,
        isDark: false,
        textColor: Color(hex: "24292F"),
        secondaryTextColor: Color(hex: "57606A"),
        linkColor: Color(hex: "0969DA"),
        blockquoteColor: Color(hex: "57606A"),
        backgroundColor: .white,
        codeBackgroundColor: Color(hex: "F6F8FA"),
        headerBackgroundColor: Color(hex: "F6F8FA"),
        borderColor: Color(hex: "D0D7DE"),
        keywordColor: Color(hex: "CF222E"),
        stringColor: Color(hex: "0A3069"),
        commentColor: Color(hex: "6E7781"),
        numberColor: Color(hex: "0550AE"),
        typeColor: Color(hex: "8250DF"),
        checkboxColor: Color(hex: "1A7F37")
    )

    // Gruvbox Dark — warm earthy tones (#282828), retro feel
    private static let _gruvboxDark = MarkdownTheme(
        name: ThemeName.gruvboxDark,
        isDark: true,
        textColor: Color(hex: "EBDBB2"),
        secondaryTextColor: Color(hex: "A89984"),
        linkColor: Color(hex: "83A598"),
        blockquoteColor: Color(hex: "A89984"),
        backgroundColor: Color(hex: "282828"),
        codeBackgroundColor: Color(hex: "3C3836"),
        headerBackgroundColor: Color(hex: "3C3836"),
        borderColor: Color(hex: "504945").opacity(0.7),
        keywordColor: Color(hex: "FB4934"),
        stringColor: Color(hex: "B8BB26"),
        commentColor: Color(hex: "928374"),
        numberColor: Color(hex: "D3869B"),
        typeColor: Color(hex: "FABD2F"),
        checkboxColor: Color(hex: "B8BB26")
    )

    // Nord — arctic blue palette (#2E3440), cool and calming
    private static let _nord = MarkdownTheme(
        name: ThemeName.nord,
        isDark: true,
        textColor: Color(hex: "D8DEE9"),
        secondaryTextColor: Color(hex: "4C566A"),
        linkColor: Color(hex: "88C0D0"),
        blockquoteColor: Color(hex: "4C566A"),
        backgroundColor: Color(hex: "2E3440"),
        codeBackgroundColor: Color(hex: "3B4252"),
        headerBackgroundColor: Color(hex: "3B4252"),
        borderColor: Color(hex: "4C566A").opacity(0.5),
        keywordColor: Color(hex: "81A1C1"),
        stringColor: Color(hex: "A3BE8C"),
        commentColor: Color(hex: "616E88"),
        numberColor: Color(hex: "B48EAD"),
        typeColor: Color(hex: "8FBCBB"),
        checkboxColor: Color(hex: "A3BE8C")
    )

    // MARK: - Regex Patterns (shared constants)

    /// Matches table separator row: |---|---|---| or variants with alignment colons
    /// Examples: |:---|:---:|---:|, |---|---|
    static let tableSeparatorPattern = #"^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#

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

    // MARK: - Reference Link Definitions

    /// Matches reference link definitions: [id]: url or [id]: <url> with optional title
    /// Captures: (1) reference ID, (2) URL
    static let referenceLinkDefinitionPattern = #"^\s*\[([^\]]+)\]:\s+<?([^\s>]+)>?"#

    /// Matches footnote definitions: [^id]: text
    /// Captures: (1) footnote ID, (2) content
    static let footnoteDefinitionPattern = #"^\s*\[\^([^\]]+)\]:\s+(.*)"#

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

// MARK: - Color Hex Extension

extension Color {
    /// Initialize Color from a hex string. Supports 6-char (RRGGBB) and 8-char (RRGGBBAA) hex,
    /// with or without leading "#". Invalid input falls back to black.
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces))
        var rgb: UInt64 = 0
        let scanned = Scanner(string: trimmed).scanHexInt64(&rgb)
        guard scanned, trimmed.count == 6 || trimmed.count == 8 else {
            self.init(red: 0, green: 0, blue: 0)
            return
        }
        if trimmed.count == 8 {
            self.init(
                .sRGB,
                red: Double((rgb >> 24) & 0xFF) / 255.0,
                green: Double((rgb >> 16) & 0xFF) / 255.0,
                blue: Double((rgb >> 8) & 0xFF) / 255.0,
                opacity: Double(rgb & 0xFF) / 255.0
            )
        } else {
            self.init(
                .sRGB,
                red: Double((rgb >> 16) & 0xFF) / 255.0,
                green: Double((rgb >> 8) & 0xFF) / 255.0,
                blue: Double(rgb & 0xFF) / 255.0,
                opacity: 1.0
            )
        }
    }
}
