import Foundation

// MARK: - HTML character references in Markdown text

/// Decodes HTML character references the way CommonMark (and so GitHub) does
/// in inline text: `AT&amp;T` → "AT&T", `&copy;` → "©", `&rarr;` → "→".
///
/// - Named: `&name;` for every HTML5 entity (`HTMLEntityTable`, generated);
///   the semicolon is required (`&amp` stays as written), unknown names stay.
/// - Decimal `&#N;` (1–7 digits) and hex `&#xH;` / `&#XH;` (1–6 digits); a
///   code point of 0, a surrogate or one above U+10FFFF becomes U+FFFD.
///
/// The renderer applies it to text AFTER inline parsing (`&#42;` is a literal
/// `*`, never emphasis) and never to code spans or code blocks. Pure and
/// thread-safe: the parse task, the measurer and the main thread all call it.
enum HTMLEntities {

    /// Name (without `&` and `;`) → replacement, built once from the table.
    private static let named: [String: String] = {
        var table: [String: String] = [:]
        table.reserveCapacity(2_200)
        for line in HTMLEntityTable.source.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            var value = String.UnicodeScalarView()
            for hex in line[line.index(after: colon)...].split(separator: ",") {
                if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) { value.append(scalar) }
            }
            table[String(line[..<colon])] = String(value)
        }
        return table
    }()

    /// Longest name in the table (`CounterClockwiseContourIntegral`): bounds
    /// the look-ahead after an `&`.
    private static let maxNameLength = 32

    /// `text` with every valid reference replaced; unchanged (same storage)
    /// when it has no `&`.
    static func decode(_ text: String) -> String {
        guard text.utf8.contains(UInt8(ascii: "&")) else { return text }
        let scalars = text.unicodeScalars
        var out = String.UnicodeScalarView()
        var index = scalars.startIndex
        while index < scalars.endIndex {
            if scalars[index] == "&", let (replacement, next) = reference(in: scalars, at: index) {
                out.append(contentsOf: replacement.unicodeScalars)
                index = next
            } else {
                out.append(scalars[index])
                index = scalars.index(after: index)
            }
        }
        return String(out)
    }

    /// The reference at `start` (an `&`): its replacement and the index past
    /// its `;`, or nil when the text there is not a valid reference.
    private static func reference(in scalars: String.UnicodeScalarView,
                                  at start: String.Index) -> (String, String.Index)? {
        var index = scalars.index(after: start)
        guard index < scalars.endIndex else { return nil }

        if scalars[index] == "#" {
            index = scalars.index(after: index)
            guard index < scalars.endIndex else { return nil }
            let hex = scalars[index] == "x" || scalars[index] == "X"
            if hex { index = scalars.index(after: index) }
            var digits = ""
            while index < scalars.endIndex, digits.unicodeScalars.count <= (hex ? 6 : 7) {
                let scalar = scalars[index]
                let isDigit = hex ? scalar.properties.isASCIIHexDigit : ("0"..."9").contains(scalar)
                guard isDigit else { break }
                digits.unicodeScalars.append(scalar)
                index = scalars.index(after: index)
            }
            guard !digits.isEmpty, digits.unicodeScalars.count <= (hex ? 6 : 7),
                  index < scalars.endIndex, scalars[index] == ";",
                  let value = UInt32(digits, radix: hex ? 16 : 10) else { return nil }
            let scalar = value == 0 ? nil : Unicode.Scalar(value)  // nil for surrogates and > U+10FFFF
            return (String(scalar ?? "\u{FFFD}"), scalars.index(after: index))
        }

        var name = ""
        while index < scalars.endIndex, name.unicodeScalars.count <= maxNameLength {
            let scalar = scalars[index]
            if scalar == ";" {
                guard let value = named[name] else { return nil }
                return (value, scalars.index(after: index))
            }
            guard scalar.isASCII, scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) else { return nil }
            name.unicodeScalars.append(scalar)
            index = scalars.index(after: index)
        }
        return nil
    }
}
