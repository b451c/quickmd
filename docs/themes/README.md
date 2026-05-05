# Custom Themes

QuickMD supports user-defined themes via JSON files. Drop any `*.json` matching the schema below into:

```
~/Library/Containers/pl.falami.studio.QuickMD/Data/Library/Application Support/QuickMD/Themes/
```

Or open it instantly via **Settings (⌘,) → Open Themes Folder**.

The picker also has an **Import Theme…** button that copies a chosen file into that folder.

Themes appear under a **Custom** section in the picker (live reload — no restart needed).

## JSON Schema

All 14 colors are required. Hex strings accept 6 chars (`RRGGBB`) or 8 chars with alpha (`RRGGBBAA`). Leading `#` optional.

```json
{
  "name": "My Theme",
  "isDark": true,
  "textColor": "#FFFFFF",
  "secondaryTextColor": "#C5C8C6",
  "linkColor": "#E0B558",
  "blockquoteColor": "#C5C8C6",
  "backgroundColor": "#292C33",
  "codeBackgroundColor": "#3C4150",
  "headerBackgroundColor": "#313540",
  "borderColor": "#4A4F5C",
  "keywordColor": "#C9B5E8",
  "stringColor": "#B7BD73",
  "commentColor": "#9FB6C4",
  "numberColor": "#E5AFB7",
  "typeColor": "#9FB6C4",
  "checkboxColor": "#B7BD73"
}
```

| Field | Used for |
|-------|----------|
| `name` | Display label in the picker. Must be unique across your custom themes. |
| `isDark` | Mermaid diagrams sync their theme to this flag (light vs dark variant). |
| `textColor` | Body paragraph text. |
| `secondaryTextColor` | Captions, muted UI labels. |
| `linkColor` | Inline and reference links. |
| `blockquoteColor` | Blockquote body text. |
| `backgroundColor` | Document background. |
| `codeBackgroundColor` | Inline `code` and fenced code block background. |
| `headerBackgroundColor` | (reserved for future heading background variant) |
| `borderColor` | Table borders, code block outline. |
| `keywordColor` | Syntax: `func`, `class`, `if`, etc. |
| `stringColor` | Syntax: string literals. |
| `commentColor` | Syntax: `//`, `#`, `--` comments. |
| `numberColor` | Syntax: numeric literals. |
| `typeColor` | Syntax: PascalCase type names. |
| `checkboxColor` | Task list `- [x]` checkmarks. |

## Examples

This folder ships two starter themes you can download and modify:

- [`artificer-dark.json`](artificer-dark.json) — Ghostty-inspired slate with burnished gold (contributed by @cameronsjo)
- [`artificer-paper.json`](artificer-paper.json) — Cream paper-stock light counterpart

## Tips

- **Live reload:** save the JSON file and the picker updates immediately.
- **Validation errors** are shown inline at the bottom of the picker — fix and save.
- **App Sandbox** automatically grants access to `~/Library/Containers/<bundle-id>/Data/`. The Import button uses an open panel, which grants read access to the chosen file regardless of location.
