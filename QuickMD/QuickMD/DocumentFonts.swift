import SwiftUI
import AppKit

// MARK: - Document Fonts (issue #18)

/// Font families for document content: body text (paragraphs, headings,
/// lists, tables, quotes, alerts) and code (fenced blocks, inline code).
/// `nil` means the system font — San Francisco / SF Mono — i.e. exactly what
/// QuickMD rendered before this setting existed.
///
/// Chosen globally in Settings → Fonts; a custom theme can override either
/// family with `bodyFontFamily` / `codeFontFamily` in its JSON.
/// `MarkdownTheme.resolvingFonts(defaults:)` merges the two (theme wins).
/// Only the document is affected — the app chrome (sidebar, search bar,
/// buttons, TOC) always keeps the system UI font.
///
/// Sizes and zoom are untouched: callers keep passing the same point sizes,
/// only the family changes. Resolution goes through `NSFontDescriptor` and is
/// cached; an uninstalled family resolves to the system font, so a stale
/// Settings value or a misspelled theme key can never break rendering.
struct DocumentFonts: Sendable, Hashable {
    /// Family for body text, or nil for the system font.
    var body: String?
    /// Family for code, or nil for the system monospaced font.
    var code: String?

    static let system = DocumentFonts()

    init(body: String? = nil, code: String? = nil) {
        self.body = Self.cleaned(body)
        self.code = Self.cleaned(code)
    }

    /// Empty / whitespace-only → nil (the Settings pickers store "" for "System").
    private static func cleaned(_ family: String?) -> String? {
        guard let trimmed = family?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - Settings (global choice)

    static let bodyDefaultsKey = "bodyFontFamily"
    static let codeDefaultsKey = "codeFontFamily"

    /// The global Settings choice. Missing / "" = system.
    static func fromUserDefaults(_ defaults: UserDefaults = .standard) -> DocumentFonts {
        DocumentFonts(body: defaults.string(forKey: bodyDefaultsKey),
                      code: defaults.string(forKey: codeDefaultsKey))
    }

    /// Fills the families this value leaves unset from `defaults` — a theme's
    /// explicit choice wins over the global setting.
    func resolving(defaults: DocumentFonts) -> DocumentFonts {
        DocumentFonts(body: body ?? defaults.body, code: code ?? defaults.code)
    }

    // MARK: - Availability

    /// Whether a family with this name is installed. Same lookup the resolver
    /// uses, so "installed" here means "will actually render in that family".
    static func isInstalled(_ family: String) -> Bool {
        guard let family = cleaned(family) else { return false }
        return cachedFont(family: family, size: 12, weight: .regular, italic: false) != nil
    }

    /// Families available for the Settings pickers, sorted for display.
    /// (~3 ms — fine for a settings pane, never called on a render path.)
    /// Also forgets remembered misses: the picker is the one place a family
    /// installed mid-session becomes selectable, so it must resolve again.
    static func installedFamilies() -> [String] {
        cache.forgetMisses()
        return NSFontManager.shared.availableFontFamilies
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Resolution

    /// AppKit font for the NSTextView pipelines (renderer AppKit scope, code
    /// blocks, list-marker measurement).
    func appKit(size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false,
                monospaced: Bool = false) -> NSFont {
        if let family = monospaced ? code : body,
           let font = Self.cachedFont(family: family, size: size, weight: weight, italic: italic) {
            return font
        }
        let base: NSFont = monospaced
            ? .monospacedSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
        guard italic else { return base }
        let descriptor = base.fontDescriptor.withSymbolicTraits(
            base.fontDescriptor.symbolicTraits.union(.italic))
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// SwiftUI font for the `Text` pipelines (renderer SwiftUI scope, table
    /// cells, print/PDF views). A custom family wraps the very same NSFont the
    /// AppKit pipeline gets, so both scopes always agree on the face.
    func swiftUI(size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false,
                 monospaced: Bool = false) -> Font {
        if let family = monospaced ? code : body,
           let font = Self.cachedFont(family: family, size: size,
                                      weight: Self.nsWeight(weight), italic: italic) {
            return Font(font as CTFont)
        }
        var font: Font = monospaced
            ? .system(size: size, weight: weight, design: .monospaced)
            : .system(size: size, weight: weight)
        if italic { font = font.italic() }
        return font
    }

    private static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    // MARK: - Descriptor lookup + cache

    /// Family + weight + italic through `NSFontDescriptor`. CoreText returns
    /// nil for an unknown family (→ system fallback) and the closest installed
    /// face otherwise: a family without an italic or bold cut degrades to its
    /// regular face rather than to a different family. The family-name check
    /// guards against a fuzzy match landing in some other family.
    private static func resolvedFont(family: String, size: CGFloat, weight: NSFont.Weight,
                                     italic: Bool) -> NSFont? {
        var traits: [NSFontDescriptor.TraitKey: Any] = [.weight: weight.rawValue]
        if italic { traits[.symbolic] = NSFontDescriptor.SymbolicTraits.italic.rawValue }
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .traits: traits])
        guard let font = NSFont(descriptor: descriptor, size: size),
              font.familyName?.caseInsensitiveCompare(family) == .orderedSame else { return nil }
        return font
    }

    private struct FontKey: Hashable {
        let family: String
        let size: CGFloat
        let weight: CGFloat
        let italic: Bool
    }

    /// Descriptor matching costs ~25 µs (vs ~3 µs for a system font) and the
    /// renderer asks once per styled run, so a large document would pay
    /// hundreds of milliseconds without this. NSFont is immutable and safe to
    /// share; the parse runs off the main thread, hence the lock. Misses are
    /// remembered too, so an uninstalled family doesn't re-query CoreText per run.
    private final class FontCache: @unchecked Sendable {
        private let lock = NSLock()
        private var hits: [FontKey: NSFont] = [:]
        private var misses: Set<FontKey> = []

        func font(for key: FontKey, resolve: () -> NSFont?) -> NSFont? {
            lock.lock()
            if let hit = hits[key] { lock.unlock(); return hit }
            if misses.contains(key) { lock.unlock(); return nil }
            lock.unlock()

            let resolved = resolve()

            lock.lock()
            if let resolved { hits[key] = resolved } else { misses.insert(key) }
            lock.unlock()
            return resolved
        }

        func forgetMisses() {
            lock.lock(); misses.removeAll(); lock.unlock()
        }
    }

    private static let cache = FontCache()

    private static func cachedFont(family: String, size: CGFloat, weight: NSFont.Weight,
                                   italic: Bool) -> NSFont? {
        let key = FontKey(family: family, size: size, weight: weight.rawValue, italic: italic)
        return cache.font(for: key) {
            resolvedFont(family: family, size: size, weight: weight, italic: italic)
        }
    }
}
