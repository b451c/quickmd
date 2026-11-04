import Foundation

// MARK: - YAML front matter as properties (v1.14.2)

/// Reads a document's YAML front matter as a flat list of `key: value`
/// properties — the shape Obsidian's Properties panel shows — so the parser can
/// render it as a two-column `.properties` table instead of a yaml code block.
///
/// Deliberately NOT a YAML parser. It accepts one small, unambiguous subset
/// (top-level scalars, block and flow sequences of scalars, quoted scalars,
/// comments) and returns nil for EVERYTHING else, so the caller keeps showing
/// the source as a yaml code block. Nil is the lossless answer: a structure we
/// would have to flatten or guess at (nested maps, block scalars, anchors,
/// multi-line scalars) is better read as the author wrote it than shown wrong.
///
/// Pure and `Sendable`-safe: the parser calls it on the parse task.
enum FrontMatter {

    typealias Property = (key: String, value: String)

    /// The properties of `yaml` (the lines BETWEEN the `---` fences), in source
    /// order, or nil when the text leaves the subset (see the type comment) or
    /// holds no property at all (only comments).
    ///
    /// - `key: value` at column 0; the key is the text before the first `: `
    ///   (or before a trailing `:`), spaces allowed, never starting with a YAML
    ///   indicator.
    /// - `key:` followed by `- item` lines (indented or at column 0, one
    ///   indentation per list) → the items joined with ", "; `key:` alone → "".
    /// - `key: [a, b, "c, d"]` → "a, b, c, d"; `[]` → "".
    /// - `"…"` unescapes only `\"` and `\\`; `'…'` turns `''` into `'` (a `#`
    ///   inside quotes is text); plain values are trimmed.
    /// - A comment anywhere in a value (` #`, or a value starting with `#`) →
    ///   nil: a viewer never hides text, and `issue: Fix #42` or
    ///   `tags: #project` show in full only in the code block. Full-line `#`
    ///   comments are skipped; `a#b` and `https://x.y/#frag` are plain text.
    static func properties(fromYAML yaml: String) -> [Property]? {
        var properties: [Property] = []
        /// The last key whose inline value was empty: it may still collect
        /// block-sequence items.
        var openKey: (index: Int, items: [String], indent: Int?)?

        func closeOpenKey() {
            guard let open = openKey else { return }
            properties[open.index].value = open.items.joined(separator: ", ")
            openKey = nil
        }

        for rawLine in yaml.components(separatedBy: "\n") {
            let line = rawLine.trimmingTrailingWhitespace()
            let indentPrefix = line.prefix { $0 == " " || $0 == "\t" }
            let content = line.dropFirst(indentPrefix.count)
            // Blank lines and full-line comments carry nothing.
            if content.isEmpty || content.hasPrefix("#") { continue }
            // YAML forbids tabs in indentation; whatever was meant, it is not ours.
            if indentPrefix.contains("\t") { return nil }
            let indent = indentPrefix.count

            if content == "-" || content.hasPrefix("- ") {
                // A block-sequence item: only directly under an open `key:`,
                // and every item of one list at the same indentation.
                guard var open = openKey else { return nil }
                if let listIndent = open.indent, listIndent != indent { return nil }
                guard let item = sequenceItem(content.dropFirst().trimmingLeadingWhitespace()) else { return nil }
                open.indent = indent
                open.items.append(item)
                openKey = open
                continue
            }

            // Anything else indented is a nested mapping or a continuation line.
            guard indent == 0 else { return nil }
            closeOpenKey()
            guard let (key, rest) = splitKey(content) else { return nil }
            let valueText = rest.trimmingLeadingWhitespace()
            if valueText.hasPrefix("#") { return nil }
            if valueText.isEmpty {
                properties.append((key, ""))
                openKey = (properties.count - 1, [], nil)
            } else {
                guard let value = inlineValue(valueText) else { return nil }
                properties.append((key, value))
            }
        }
        closeOpenKey()
        return properties.isEmpty ? nil : properties
    }

    // MARK: - Pieces

    /// Characters that make a line or value something other than a plain
    /// scalar / plain key (YAML indicators). A key starting with one is out of
    /// the subset.
    private static let keyIndicators: Set<Character> = ["-", "#", "[", "{", "\"", "'", "?", "&", "*", "!", "|", ">"]

    /// `key` and the text after its `:` for a column-0 line, or nil when the
    /// line is not `key: …` / `key:`.
    private static func splitKey(_ line: Substring) -> (String, Substring)? {
        let keyPart: Substring
        let rest: Substring
        if let separator = line.range(of: ": ") {
            keyPart = line[..<separator.lowerBound]
            rest = line[separator.upperBound...]
        } else if line.hasSuffix(":") {
            keyPart = line.dropLast()
            rest = ""
        } else {
            return nil
        }
        let key = keyPart.trimmingTrailingWhitespace()
        guard let first = key.first, !keyIndicators.contains(first) else { return nil }
        return (String(key), rest)
    }

    /// The value after `key: ` (non-empty, trimmed on the left).
    private static func inlineValue(_ text: Substring) -> String? {
        switch text.first {
        case "[": return flowSequence(text)
        case "\"", "'":
            guard let (value, rest) = quotedScalar(text), isNothingAfter(rest) else { return nil }
            return value
        default: return plainScalar(text)
        }
    }

    /// One `- item` of a block sequence (the text after `- `): a scalar only —
    /// a nested list, a mapping (`- name: x`) or an empty item is out.
    private static func sequenceItem(_ text: Substring) -> String? {
        guard !text.isEmpty, !text.hasPrefix("#") else { return nil }
        switch text.first {
        case "\"", "'":
            guard let (value, rest) = quotedScalar(text), isNothingAfter(rest) else { return nil }
            return value
        default:
            guard let value = plainScalar(text), !isMappingEntry(value) else { return nil }
            return value
        }
    }

    /// A plain (unquoted) scalar, trimmed. Nil when it starts with an
    /// indicator that would make it something else (block scalar, anchor,
    /// alias, tag, flow mapping, comment, reserved characters) or holds a
    /// comment (` #`) — see `properties(fromYAML:)`.
    private static let plainIndicators: Set<Character> = ["|", ">", "&", "*", "!", "{", "[", "@", "`", "\"", "'", "#"]
    private static func plainScalar(_ text: Substring) -> String? {
        guard let first = text.first, !plainIndicators.contains(first),
              text != "-", !text.hasPrefix("- ") else { return nil }
        guard !text.contains(" #") else { return nil }
        let trimmed = text.trimmingTrailingWhitespace()
        return trimmed.isEmpty ? nil : String(trimmed)
    }

    /// `key: value` / `key:` shape (a sequence item that is itself a mapping).
    private static func isMappingEntry(_ text: String) -> Bool {
        text.contains(": ") || text.hasSuffix(":")
    }

    /// Nothing but spaces after a closed quote / flow sequence (a comment
    /// there is text the table would hide → nil).
    private static func isNothingAfter(_ rest: Substring) -> Bool {
        rest.trimmingLeadingWhitespace().isEmpty
    }

    /// A quoted scalar at the start of `text` and what follows its closing
    /// quote; nil when unterminated (a multi-line scalar) or when a `"…"`
    /// string uses an escape other than `\"` / `\\`.
    private static func quotedScalar(_ text: Substring) -> (String, Substring)? {
        guard let quote = text.first else { return nil }
        var value = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if quote == "\"" {
                if character == "\\" {
                    guard next < text.endIndex, text[next] == "\"" || text[next] == "\\" else { return nil }
                    value.append(text[next])
                    index = text.index(after: next)
                    continue
                }
                if character == "\"" { return (value, text[next...]) }
            } else if character == "'" {
                if next < text.endIndex, text[next] == "'" {
                    value.append("'")
                    index = text.index(after: next)
                    continue
                }
                return (value, text[next...])
            }
            value.append(character)
            index = next
        }
        return nil
    }

    /// `[a, b, "c, d"]` → "a, b, c, d" (`[]` → ""). Items are plain or quoted
    /// scalars; nesting (`[`, `{`), an empty item or a missing `]` → nil.
    private static func flowSequence(_ text: Substring) -> String? {
        var items: [String] = []
        var index = text.index(after: text.startIndex)
        func skipSpaces() {
            while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        }
        skipSpaces()
        if index < text.endIndex, text[index] == "]" {
            return isNothingAfter(text[text.index(after: index)...]) ? "" : nil
        }
        while true {
            skipSpaces()
            guard index < text.endIndex else { return nil }
            let item: String
            if text[index] == "\"" || text[index] == "'" {
                guard let (value, rest) = quotedScalar(text[index...]) else { return nil }
                item = value
                index = rest.startIndex
            } else {
                let start = index
                while index < text.endIndex, text[index] != ",", text[index] != "]" {
                    index = text.index(after: index)
                }
                let raw = text[start..<index].trimmingTrailingWhitespace()
                guard let first = raw.first, !plainIndicators.contains(first),
                      !raw.contains("["), !raw.contains("{"), !raw.contains(" #") else { return nil }
                item = String(raw)
            }
            items.append(item)
            skipSpaces()
            guard index < text.endIndex else { return nil }
            if text[index] == "]" {
                return isNothingAfter(text[text.index(after: index)...]) ? items.joined(separator: ", ") : nil
            }
            guard text[index] == "," else { return nil }
            index = text.index(after: index)
        }
    }
}

private extension StringProtocol {
    func trimmingTrailingWhitespace() -> SubSequence {
        var end = endIndex
        while end > startIndex {
            let previous = index(before: end)
            guard self[previous] == " " || self[previous] == "\t" else { break }
            end = previous
        }
        return self[startIndex..<end]
    }

    func trimmingLeadingWhitespace() -> SubSequence {
        var start = startIndex
        while start < endIndex, self[start] == " " || self[start] == "\t" { start = index(after: start) }
        return self[start..<endIndex]
    }
}
