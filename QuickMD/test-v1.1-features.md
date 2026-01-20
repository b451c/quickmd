# QuickMD v1.1 Feature Test

This file demonstrates all new features in QuickMD v1.1.

---

## 1. Escape Characters

These should show literal characters, not formatting:

- \*not bold\* → shows asterisks
- \_not italic\_ → shows underscores
- \`not code\` → shows backticks
- \[not a link\] → shows brackets
- \| pipe in text → shows pipe
- \\ backslash → shows backslash

---

## 2. Markdown in Table Cells

| Feature | Example | Status |
|---------|---------|--------|
| **Bold** | **works** | ✅ |
| *Italic* | *works* | ✅ |
| `Code` | `works` | ✅ |
| [Link](https://apple.com) | [click](https://apple.com) | ✅ |
| **Bold** + *Italic* | **bold** and *italic* | ✅ |

---

## 3. Table Column Alignment

| Left | Center | Right |
|:-----|:------:|------:|
| L1 | C1 | R1 |
| Left aligned | Centered | Right aligned |
| €10,000 | €25,000 | €50,000 |

---

## 4. URL Autolinking

Plain URLs become clickable:

- Visit https://apple.com for more info
- Documentation: https://github.com/b451c/quickmd
- Support: https://qmd.app

---

## 5. Setext-Style Headers

Main Title Here
===============

This is content under a Setext H1 header.

Subtitle Here
-------------

This is content under a Setext H2 header.

---

## 6. Table Normalization

This malformed table should render correctly:

| Col A | Col B | Col C |
|-------|-------|-------|
| Has all three |  |  |
| Missing cols |
| Extra | cols | here | ignored |

---

## 7. Combined Features

| Product | Price | Link |
|:--------|------:|:----:|
| **MacBook Pro** | €2,499 | [Buy](https://apple.com) |
| *iPad Air* | €799 | [Buy](https://apple.com) |
| `AirPods` | €199 | [Buy](https://apple.com) |

---

## Standard Features (Unchanged)

### Code Block
```swift
func greet(_ name: String) -> String {
    return "Hello, \(name)!"
}
```

### Task List
- [x] Escape characters
- [x] Markdown in tables
- [x] Table alignment
- [x] URL autolinking
- [x] Setext headers
- [ ] Future features

### Blockquote
> QuickMD - The fastest Markdown viewer for macOS.

### Image
![QuickMD](https://qmd.app/icon.png)

---

*End of v1.1 feature test*
