# QuickMD - Features Showcase

## Quick Summary

Detailed breakdown of each feature with recommendations for how to present them visually on the landing page.

---

## Feature Priority Tiers

### Tier 1: Hero-worthy (Show in Hero/Above Fold)
1. Instant Preview
2. Syntax Highlighting
3. Dark Mode

### Tier 2: Feature Section (Main Features Grid)
4. Tables Support
5. Task Lists
6. Images (Local + Remote)

### Tier 3: Supporting Features (Mentioned but not highlighted)
7. Headers H1-H6
8. Bold/Italic/Strikethrough
9. Ordered/Unordered Lists
10. Blockquotes
11. Inline Code
12. Links
13. Horizontal Rules

---

## Feature Deep Dives

### 1. Instant Preview ⚡

**What it does:**
- Double-click any .md file → app opens immediately
- No splash screen, no loading indicator
- Native macOS file association

**User benefit:**
"Stop waiting. Start reading."

**Technical backing:**
- Native Swift/SwiftUI (not Electron)
- ~2MB app size
- Minimal memory footprint

**Visual showcase:**
| Type | Recommendation |
|------|----------------|
| Screenshot | Split: Finder with .md file → QuickMD window |
| Animation | GIF showing double-click → instant open |
| Video | 3-second clip of file opening |

**Best demo content:**
```markdown
# Project README
Quick overview of the project...
```

---

### 2. Syntax Highlighting 🎨

**What it does:**
- Fenced code blocks get proper coloring
- Supports 20+ languages
- Highlights: keywords, strings, comments, numbers, types

**User benefit:**
"Code that's actually readable."

**Languages supported:**
Swift, Python, JavaScript, TypeScript, Go, Rust, Java, C, C++, Ruby, PHP, SQL, HTML, CSS, Shell/Bash, YAML, JSON, and more.

**Color scheme (from code analysis):**

| Token | Light Mode | Dark Mode |
|-------|------------|-----------|
| Keywords | Purple | Light Purple |
| Strings | Brown/Orange | Orange |
| Comments | Gray | Gray |
| Numbers | Green | Light Green |
| Types | Blue | Cyan |

**Visual showcase:**
| Type | Recommendation |
|------|----------------|
| Screenshot | Code block in Swift or Python |
| Side-by-side | Raw code vs. highlighted rendering |
| Dark + Light | Same code in both modes |

**Best demo content:**
```swift
func greet(_ name: String) -> String {
    let message = "Hello, \(name)!"
    return message // Returns greeting
}
```

```python
def process_data(items):
    count = 42
    return f"Processed {count} items"
```

---

### 3. Dark Mode 🌗

**What it does:**
- Automatic detection of system preference
- Optimized colors for both modes
- All UI elements adapt (text, backgrounds, code, tables)

**User benefit:**
"Matches your Mac. Automatically."

**Technical implementation:**
- Uses `@Environment(\.colorScheme)`
- Complete theme system with light/dark variants
- No manual toggle needed

**Visual showcase:**
| Type | Recommendation |
|------|----------------|
| Screenshot | Same document in light vs dark |
| Animation | System toggle showing instant switch |
| Grid | 2x2 showing different content types in both modes |

**Best demo approach:**
Show the SAME content side-by-side in light and dark mode. Include:
- Headers
- Code block
- Table
- Regular text

---

### 4. Tables Support 📊

**What it does:**
- GitHub Flavored Markdown tables
- Header row with distinct styling
- Bordered cells with proper alignment
- Responsive to content width

**User benefit:**
"Tables that look like tables."

**Supported syntax:**
```markdown
| Header 1 | Header 2 | Header 3 |
|----------|----------|----------|
| Cell 1   | Cell 2   | Cell 3   |
| Cell 4   | Cell 5   | Cell 6   |
```

**Visual showcase:**
| Type | Recommendation |
|------|----------------|
| Screenshot | Rendered table with realistic data |
| Before/After | Raw markdown vs. rendered table |

**Best demo content:**
```markdown
| Feature    | Status | Priority |
|------------|--------|----------|
| Headers    | ✅     | High     |
| Tables     | ✅     | High     |
| Code       | ✅     | High     |
```

---

### 5. Task Lists ✅

**What it does:**
- `- [ ]` renders as ☐ (unchecked)
- `- [x]` renders as ☑ (checked, green, strikethrough)
- Supports indentation/nesting

**User benefit:**
"See progress at a glance."

**Visual showcase:**
| Type | Recommendation |
|------|----------------|
| Screenshot | Mixed checked/unchecked items |
| Animation | NOT interactive (view-only) |

**Best demo content:**
```markdown
## Project Status

- [x] Design mockups
- [x] Core implementation
- [ ] Beta testing
- [ ] App Store submission
    - [x] Screenshots
    - [ ] Review process
```

---

### 6. Images 🖼️

**What it does:**
- Renders remote images (http/https)
- Renders local images (file paths)
- Loading indicator while fetching
- Error state for broken images
- Alt text displayed below image

**User benefit:**
"Documentation with visuals, just works."

**Technical details:**
- Uses SwiftUI AsyncImage
- Max width: 600px
- Aspect ratio preserved
- Rounded corners (8px)

**Visual showcase:**
| Type | Recommendation |
|------|----------------|
| Screenshot | Document with embedded image |
| Note | Show loading state briefly in demo |

---

## Feature Comparison Matrix

For landing page comparison section:

| Feature | QuickMD | Basic Quick Look | VS Code | Typora |
|---------|:-------:|:----------------:|:-------:|:------:|
| Instant Launch | ✅ | ✅ | ❌ | ⚠️ |
| Syntax Highlighting | ✅ | ❌ | ✅ | ✅ |
| Tables | ✅ | ❌ | ✅ | ✅ |
| Task Lists | ✅ | ❌ | ✅ | ✅ |
| Images | ✅ | ❌ | ✅ | ✅ |
| Dark Mode | ✅ | ⚠️ | ✅ | ✅ |
| Free | ✅ | ✅ | ✅ | ❌ |
| Native macOS | ✅ | ✅ | ❌ | ❌ |
| Lightweight | ✅ | ✅ | ❌ | ⚠️ |

---

## Screenshot Recommendations

### Must-Have Screenshots:

1. **Hero Screenshot**
   - Full app window
   - Mixed content (headers, text, code, table)
   - Professional-looking document
   - Light OR dark mode (choose one for hero)

2. **Code Highlighting Screenshot**
   - Focus on code block
   - Multiple syntax colors visible
   - Language label showing

3. **Dark Mode Screenshot**
   - Same content as hero, but opposite mode
   - Side-by-side comparison ideal

4. **Table Screenshot**
   - Realistic data table
   - Headers clearly styled differently

5. **Task List Screenshot**
   - Mix of checked/unchecked
   - Shows progress visual

### Nice-to-Have Screenshots:

6. **File Opening Animation** (GIF)
7. **Multiple Languages Code** (Python, JS, Swift side by side)
8. **Full Document Scroll** (shows depth of content)

---

## Implementation Notes

1. **Lead with speed** - "Instant" is the #1 differentiator
2. **Show syntax highlighting prominently** - Very visual, immediately understood
3. **Dark mode sells** - Developers love it, show it off
4. **Tables are impressive** - Raw markdown tables look ugly, rendered looks great
5. **Don't oversell task lists** - They're nice but not a primary draw
6. **Images are expected** - Don't highlight unless you have space
