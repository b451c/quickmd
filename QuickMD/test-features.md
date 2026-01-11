# QuickMD Feature Test

This is a **bold** and *italic* text example with `inline code` and ~~strikethrough~~.

## Task Lists

- [x] Image rendering ✓
- [x] Syntax highlighting ✓
- [x] Task lists ✓
- [x] Nested lists ✓
- [ ] Ship to App Store

## Nested Lists

- First level item
    - Second level nested
    - Another nested item
        - Third level
- Back to first level
    1. Ordered nested
    2. Another ordered item

## Table

| Feature | Status | Priority |
|---------|--------|----------|
| Images | ✅ Done | High |
| Task Lists | ✅ Done | High |
| Syntax Highlighting | ✅ Done | Medium |
| Nested Lists | ✅ Done | Medium |

## Code Blocks

### Swift

```swift
import SwiftUI

struct ContentView: View {
    let message = "Hello, World!"
    var count = 42

    var body: some View {
        Text(message) // Display greeting
            .font(.title)
    }
}
```

### Python

```python
def calculate_total(items):
    total = 0
    for item in items:
        total += item.price  # Add price
    return total

class User:
    def __init__(self, name):
        self.name = name
```

### JavaScript

```javascript
async function fetchData(url) {
    const response = await fetch(url);
    return response.json();
}

const users = ["Alice", "Bob"];
console.log("Count:", users.length);
```

## Images

### Remote Image

![Apple Logo](https://www.apple.com/ac/structured-data/images/knowledge_graph_logo.png)

### Another Image

![SwiftUI](https://developer.apple.com/assets/elements/icons/swiftui/swiftui-96x96_2x.png)

## Blockquotes

> This is a blockquote.
> It can span multiple lines.

## Horizontal Rule

---

## Links

Check out [Apple Developer](https://developer.apple.com) for more SwiftUI resources.

---

*QuickMD - The fastest Markdown viewer for macOS*
