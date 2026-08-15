import XCTest
import SwiftUI
import AppKit

/// Document font families (issue #18): resolution + fallback in
/// `DocumentFonts`, theme/Settings merging, and — the part that matters —
/// that every styled run the renderer and parser produce carries the chosen
/// family in the AppKit scope (the NSTextView pipeline), with the SwiftUI
/// scope populated alongside.
///
/// Uses families every macOS ships with (Menlo, Georgia) so the assertions
/// hold on CI runners too.
final class FontTests: XCTestCase {

    private static let body = "Georgia"
    private static let code = "Menlo"

    private var customTheme: MarkdownTheme {
        MarkdownTheme.cached(for: .light)
            .resolvingFonts(defaults: DocumentFonts(body: Self.body, code: Self.code))
    }

    // MARK: - DocumentFonts resolution

    func testSystemFontsMatchPreFeatureDefaults() {
        let fonts = DocumentFonts.system
        XCTAssertEqual(fonts.appKit(size: 14).fontName, NSFont.systemFont(ofSize: 14).fontName)
        XCTAssertEqual(fonts.appKit(size: 14, weight: .bold).fontName,
                       NSFont.systemFont(ofSize: 14, weight: .bold).fontName)
        XCTAssertEqual(fonts.appKit(size: 13, monospaced: true).fontName,
                       NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName)
    }

    func testCustomFamilyResolvesWithTraits() {
        let fonts = DocumentFonts(body: Self.body, code: Self.code)
        let regular = fonts.appKit(size: 14)
        XCTAssertEqual(regular.familyName, Self.body)
        XCTAssertEqual(regular.pointSize, 14)

        let bold = fonts.appKit(size: 14, weight: .bold)
        XCTAssertEqual(bold.familyName, Self.body)
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold))

        let italic = fonts.appKit(size: 14, italic: true)
        XCTAssertEqual(italic.familyName, Self.body)
        XCTAssertTrue(italic.fontDescriptor.symbolicTraits.contains(.italic))

        let mono = fonts.appKit(size: 13, monospaced: true)
        XCTAssertEqual(mono.familyName, Self.code)
    }

    func testUnknownFamilyFallsBackToSystem() {
        let fonts = DocumentFonts(body: "NoSuchFamily-QuickMD-Test", code: "AlsoNotAFont-QuickMD")
        XCTAssertEqual(fonts.appKit(size: 14).fontName, NSFont.systemFont(ofSize: 14).fontName)
        XCTAssertEqual(fonts.appKit(size: 13, monospaced: true).fontName,
                       NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName)
        XCTAssertFalse(DocumentFonts.isInstalled("NoSuchFamily-QuickMD-Test"))
        XCTAssertTrue(DocumentFonts.isInstalled(Self.body))
    }

    func testEmptyAndWhitespaceMeanSystem() {
        XCTAssertNil(DocumentFonts(body: "", code: "   ").body)
        XCTAssertNil(DocumentFonts(body: "", code: "   ").code)
        XCTAssertEqual(DocumentFonts(body: "", code: ""), .system)
        XCTAssertEqual(DocumentFonts(body: "  Georgia  ").body, "Georgia")
    }

    func testThemeFontsWinOverSettingsDefaults() {
        let theme = DocumentFonts(body: Self.body)                       // theme sets body only
        let settings = DocumentFonts(body: "Helvetica", code: Self.code)  // user picked both
        let merged = theme.resolving(defaults: settings)
        XCTAssertEqual(merged.body, Self.body, "theme's explicit family must win")
        XCTAssertEqual(merged.code, Self.code, "unset theme family falls back to Settings")
        XCTAssertEqual(DocumentFonts.system.resolving(defaults: settings), settings)
    }

    func testUserDefaultsRoundTrip() throws {
        let suite = "pl.falami.studio.QuickMD.FontTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(DocumentFonts.fromUserDefaults(defaults), .system)
        defaults.set(Self.body, forKey: DocumentFonts.bodyDefaultsKey)
        defaults.set("", forKey: DocumentFonts.codeDefaultsKey)
        XCTAssertEqual(DocumentFonts.fromUserDefaults(defaults), DocumentFonts(body: Self.body))
    }

    // MARK: - Renderer: every run carries the family in BOTH scopes

    /// Walks every run of the rendered string and asserts the AppKit font's
    /// family. `expected` maps run text → family (nil = don't care).
    private func assertFamilies(_ attributed: AttributedString, body: String, code: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        var checked = 0
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let nsFont = run[AttributeScopes.AppKitAttributes.FontAttribute.self]
            XCTAssertNotNil(nsFont, "run \u{201C}\(text)\u{201D} has no AppKit font", file: file, line: line)
            XCTAssertNotNil(run.font, "run \u{201C}\(text)\u{201D} has no SwiftUI font", file: file, line: line)
            let family = nsFont?.familyName ?? "-"
            XCTAssertTrue(family == body || family == code,
                          "run \u{201C}\(text)\u{201D} rendered in \(family)", file: file, line: line)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "nothing was rendered", file: file, line: line)
    }

    func testParagraphAndInlineStylesUseBodyFamily() {
        let renderer = MarkdownRenderer(theme: customTheme)
        let out = renderer.render("Plain **bold** *italic* ~~struck~~ [link](https://x.y) plain")
        assertFamilies(out, body: Self.body, code: Self.body)  // no code here
        for run in out.runs {
            let text = String(out[run.range].characters)
            if text == "bold" {
                XCTAssertTrue(run[AttributeScopes.AppKitAttributes.FontAttribute.self]?
                    .fontDescriptor.symbolicTraits.contains(.bold) ?? false)
            }
            if text == "italic" {
                XCTAssertTrue(run[AttributeScopes.AppKitAttributes.FontAttribute.self]?
                    .fontDescriptor.symbolicTraits.contains(.italic) ?? false)
            }
        }
    }

    func testInlineCodeUsesCodeFamilyAndProseUsesBodyFamily() {
        let renderer = MarkdownRenderer(theme: customTheme)
        let out = renderer.render("prose `code()` prose")
        var sawCode = false, sawBody = false
        for run in out.runs {
            let text = String(out[run.range].characters)
            let family = run[AttributeScopes.AppKitAttributes.FontAttribute.self]?.familyName
            if text == "code()" { XCTAssertEqual(family, Self.code); sawCode = true }
            if text.contains("prose") { XCTAssertEqual(family, Self.body); sawBody = true }
        }
        XCTAssertTrue(sawCode && sawBody)
    }

    func testHeadingsListsTasksAndRulesUseBodyFamily() {
        let renderer = MarkdownRenderer(theme: customTheme)
        let doc = """
        # Heading
        - bullet item
        1. numbered item
        - [x] done task
        ***
        Footnote ref[^1]
        """
        assertFamilies(renderer.render(doc), body: Self.body, code: Self.code)
        let heading = renderer.renderHeader("Title", level: 2)
        assertFamilies(heading, body: Self.body, code: Self.code)
        XCTAssertTrue(heading.runs.allSatisfy {
            $0[AttributeScopes.AppKitAttributes.FontAttribute.self]?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
        })
    }

    func testFootnoteBlockFromParserUsesBodyFamily() {
        let blocks = MarkdownBlockParser(theme: customTheme).parse("Text[^1]\n\n[^1]: The note")
        guard case .text(let footnotes)? = blocks.last?.content else {
            return XCTFail("expected trailing footnote text block")
        }
        assertFamilies(footnotes, body: Self.body, code: Self.code)
    }

    func testSystemThemeIsUnchangedByTheFeature() {
        // Regression guard: default themes must still render in the system font.
        let out = MarkdownRenderer(theme: MarkdownTheme.cached(for: .light)).render("plain **bold** `code`")
        for run in out.runs {
            let text = String(out[run.range].characters)
            guard let font = run[AttributeScopes.AppKitAttributes.FontAttribute.self] else { continue }
            if text == "code" {
                XCTAssertEqual(font.fontName, NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName)
            } else if text == "bold" {
                XCTAssertEqual(font.fontName, NSFont.systemFont(ofSize: 14, weight: .bold).fontName)
            } else if text.hasPrefix("plain") {
                XCTAssertEqual(font.fontName, NSFont.systemFont(ofSize: 14).fontName)
            }
        }
    }

    // MARK: - Hanging indent measured with the body font

    func testListHangingIndentUsesBodyFontMetrics() {
        // "• " is wider in a serif face than in San Francisco; the hang must
        // follow the family actually used for the marker.
        func headIndent(_ theme: MarkdownTheme) -> CGFloat? {
            let out = MarkdownRenderer(theme: theme).render("- item")
            return out.runs.first?[AttributeScopes.AppKitAttributes.ParagraphStyleAttribute.self]?.headIndent
        }
        let system = try? XCTUnwrap(headIndent(MarkdownTheme.cached(for: .light)))
        let serif = try? XCTUnwrap(headIndent(customTheme))
        let expectedSerif = 16 + ("• " as NSString)
            .size(withAttributes: [.font: DocumentFonts(body: Self.body).appKit(size: 14)]).width
        XCTAssertEqual(serif ?? -1, expectedSerif, accuracy: 0.01)
        XCTAssertNotEqual(system ?? -1, serif ?? -1, "hang should track the marker's real width")
    }

    // MARK: - Custom theme JSON

    private func decodeTheme(_ extraFields: String) throws -> CustomThemeDTO {
        let json = """
        {"name": "Font Test", "isDark": false,
         "textColor": "000000", "secondaryTextColor": "666666", "linkColor": "0000FF",
         "blockquoteColor": "666666", "backgroundColor": "FFFFFF", "codeBackgroundColor": "EEEEEE",
         "headerBackgroundColor": "DDDDDD", "borderColor": "CCCCCC", "keywordColor": "AA00AA",
         "stringColor": "AA5500", "commentColor": "666666", "numberColor": "22AA22",
         "typeColor": "1166AA", "checkboxColor": "00AA00"\(extraFields)}
        """
        return try JSONDecoder().decode(CustomThemeDTO.self, from: Data(json.utf8))
    }

    func testThemeWithoutFontKeysStaysSystem() throws {
        let dto = try decodeTheme("")
        XCTAssertNil(dto.validationError)
        XCTAssertNil(dto.fontWarning)
        XCTAssertEqual(dto.toTheme().fonts, .system)
    }

    func testThemeFontKeysAreCarriedIntoTheme() throws {
        let dto = try decodeTheme(", \"bodyFontFamily\": \"\(Self.body)\", \"codeFontFamily\": \"\(Self.code)\"")
        XCTAssertNil(dto.validationError)
        XCTAssertNil(dto.fontWarning)
        XCTAssertEqual(dto.toTheme().fonts, DocumentFonts(body: Self.body, code: Self.code))
    }

    func testUninstalledThemeFontWarnsButLoadsWithoutIt() throws {
        let dto = try decodeTheme(", \"bodyFontFamily\": \"NoSuchFamily-QuickMD-Test\", \"codeFontFamily\": \"\(Self.code)\"")
        XCTAssertNil(dto.validationError, "a missing font must not reject the theme")
        let warning = try XCTUnwrap(dto.fontWarning)
        XCTAssertTrue(warning.contains("bodyFontFamily"))
        XCTAssertTrue(warning.contains("NoSuchFamily-QuickMD-Test"))
        // Dropped, so it can't shadow the user's Settings font in resolvingFonts.
        XCTAssertNil(dto.toTheme().fonts.body)
        XCTAssertEqual(dto.toTheme().fonts.code, Self.code)
    }
}
