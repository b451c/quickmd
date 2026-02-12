# QuickMD — Plan Rozwoju

> Dokument roboczy. Prace realizowane z koordynacją zespołu agentów AI (Claude Code Agent Teams).

---

## Zrealizowane prace

### Audyt kodu v1.2.1 (luty 2026)

Pełny audyt przeprowadzony przez 4 wyspecjalizowanych agentów:

| Agent | Obszar | Wynik |
|-------|--------|-------|
| Swift Concurrency & Safety | Wątkowość, pamięć, force unwrapy, error handling | 0 critical, 7 warnings |
| SwiftUI Patterns & Views | Wzorce UI, wydajność widoków, dostępność | 1 critical, 7 warnings |
| Parser Correctness | Poprawność parsera, edge cases, regex, ReDoS | 4 critical, 11 warnings |
| PDF Export & StoreKit | Eksport, druk, IAP, entitlements | 2 critical, 6 warnings |

### Implementacja poprawek

Realizacja przez 6 równoległych agentów, każdy z przypisanymi plikami (zero konfliktów):

| Agent | Pliki | Zakres |
|-------|-------|--------|
| A | TipJarManager, TipJarView | StoreKit Transaction.updates, @StateObject, Task.sleep |
| B | MarkdownBlockParser, MarkdownTheme | Fenced code blocks, table detection, tilde fences, Sendable |
| C | MarkdownRenderer | Underscore italic, recursive bold/italic, link parser, autolink perf |
| D | CodeBlockView | Range exclusion, highlight priority, isLargeBlock, cacheKey |
| E | MarkdownExport | FocusedValue, PDF double-render, logging, print modal |
| F | 7 plików (Views, Types, Build) | Task identity, Sendable, AppURLs, entitlements, build settings |

**Wynik: 35 zmian w 14 plikach, +222/-152 LOC. Oba buildy (GitHub + App Store) przechodzą.**

#### Faza A — Krytyczne naprawy: 5/5

- [x] A1: Transaction.updates listener w StoreKit (przerwane zakupy)
- [x] A2: Fix podwójne renderowanie PDF (pamięć)
- [x] A3: Fix underscore italic mid-word (snake_case)
- [x] A4: Fix zamykanie fenced code blocks (+ tilde fences)
- [x] A5: Ostrzejszy tableSeparatorPattern + wymaganie 2+ pipes

#### Faza B — Ważne poprawki: 7/7

- [x] B1: FocusedValue zamiast ExportStateManager singleton (multi-window)
- [x] B2: @StateObject zamiast @ObservedObject dla singletonów
- [x] B3: Struct-based .task(id:) zamiast hash XOR
- [x] B4: Fix entitlements vs build settings (printing, user-selected-files)
- [x] B5: Rekursywne parsowanie bold/italic (nesting)
- [x] B6: Syntax highlighting range exclusion (string > comment > keyword)
- [x] B7: NSSupportsSuddenTermination = false

#### Faza C — Jakość kodu: 5/6

- [x] C1: Sendable conformance (MarkdownBlock, Document, Parser, Renderer, Theme)
- [x] C2: Offload parsing z MainActor (Task.detached)
- [x] C3: Dynamic Type — świadoma decyzja: nie zmieniamy (viewer = stałe proporcje)
- [x] C4: PDF rendering per-block — zrealizowane w sprincie (luty 2026)
- [x] C5: Link/image parser — bracket/paren depth counting
- [x] C6: Deduplikacja AppURLs (jeden enum w QuickMDApp.swift)

---

## Pozostałe prace

### C4: PDF rendering per-block — ZREALIZOWANE

**Status:** Zrealizowane (luty 2026) | **Wysiłek:** Duży

Pełna zamiana renderowania PDF z single-image na per-block:
- Iteracja po `[MarkdownBlock]`, renderowanie każdego bloku osobno przez `ImageRenderer`
- Nowy `MarkdownPrintableBlockView` renderuje pojedyncze bloki
- Śledzenie akumulowanej wysokości, page break tylko między blokami
- Eliminacja ryzyka OOM dla dużych dokumentów

**Agent:** export-agent (1 agent, 1 plik: `MarkdownExport.swift`)

---

### Faza D: Rozwój funkcjonalny — sprint luty 2026

#### D1: Double-backtick inline code — ZREALIZOWANE

`tryParseInlineCode()` wspiera `` ``code with ` backtick`` `` — zlicza backticki, szuka pasującego zamknięcia, strip spacji per CommonMark.

**Agent:** renderer-agent (`MarkdownRenderer.swift`)

---

#### D2: Nested blockquotes i multi-line blockquotes — ZREALIZOWANE

- Nowy `.blockquote(index, content, level)` case w `MarkdownBlock`
- Block-level parser akumuluje consecutive `>` linie, liczy nesting depth
- Nowy `BlockquoteView` z lewą krawędzią per nesting level
- `PrintableBlockquoteView` dla PDF/print
- Usunięty stary inline blockquote handler z `MarkdownRenderer`

**Agenci:** parser-agent (`MarkdownBlock.swift`, `MarkdownBlockParser.swift`), views-agent (`BlockquoteView.swift`, `MarkdownView.swift`), export-agent (`MarkdownExport.swift`)

---

#### D3: Reference-style links
**Wysiłek:** Średni | **Priorytet:** Niski

```markdown
[link text][id]
...
[id]: https://example.com "Optional Title"
```

**Podejście:**
1. Pre-pass w `MarkdownBlockParser`: skanowanie pliku w poszukiwaniu definicji `[id]: url`
2. Budowanie słownika `[String: (url: String, title: String?)]`
3. Przekazanie słownika do `MarkdownRenderer`
4. W `tryParseLink`: sprawdzanie formatu `[text][id]` obok `[text](url)`

**Pliki:** `MarkdownBlockParser.swift`, `MarkdownRenderer.swift`

**Planowanie agentowe:** Jeden agent, oba pliki. Parser musi być pierwszy (pre-pass).

---

#### D4: Table of Contents / Spis treści
**Wysiłek:** Duży | **Priorytet:** Średni

Sidebar lub popover z nagłówkami dokumentu, umożliwiający nawigację.

**Podejście:**
1. Po parsowaniu, ekstrakcja nagłówków (H1-H6) z `[MarkdownBlock]`
2. Sidebar z `List` + wcięciami per level
3. `ScrollViewReader` + `.id()` na blokach dla nawigacji
4. Toggle sidebar (Cmd+T lub toolbar button)

**Pliki:** Nowy `Views/TableOfContentsView.swift`, modyfikacja `MarkdownView.swift`

**Planowanie agentowe:** 2 agentów — jeden na ekstrakcję + model, drugi na UI.

---

#### D5: Find & Search w dokumencie — ZREALIZOWANE

Cmd+F wyszukiwanie z podświetlaniem i nawigacją:
- `SearchBar` z polem tekstowym, licznikiem wyników ("1/5"), prev/next
- Cmd+F toggle, Cmd+G / Shift+Cmd+G nawigacja, Escape zamknięcie
- `ScrollViewReader` + `.id(block.id)` do scroll-to-match
- Żółty highlight na matchach w `AttributedString` (index mapping String→AttributedString)
- `NSEvent.addLocalMonitorForEvents` dla macOS 13 kompatybilności
- `MarkdownRenderer` z opcjonalnym `searchTerm` parametrem

**Agenci:** renderer-agent (`MarkdownRenderer.swift`), views-agent (`SearchBar.swift`, `MarkdownView.swift`)

---

#### D6: Custom themes
**Wysiłek:** Duży | **Priorytet:** Niski

Użytkownik wybiera motyw kolorystyczny (np. Solarized, Dracula, GitHub).

**Podejście:**
1. Definicja protokołu `ThemeProtocol` lub rozszerzenie `MarkdownTheme`
2. Predefiniowane tematy jako statyczne instancje
3. `@AppStorage` dla persystencji wyboru
4. Panel preferencji (Settings scene) z podglądem
5. Integracja z `MarkdownTheme.cached(for:)` — cache per tema + colorScheme

**Pliki:** `MarkdownTheme.swift` (rozszerzenie), nowy `Views/ThemePickerView.swift`, modyfikacja `QuickMDApp.swift`

**Planowanie agentowe:** 2 agentów — model/dane, UI.

---

## Priorytety

| Priorytet | Zadania | Status |
|-----------|---------|--------|
| ~~**Następne**~~ | ~~D5 (Search)~~ | **ZREALIZOWANE** (luty 2026) |
| ~~**Wkrótce**~~ | ~~D2 (Blockquotes), C4 (PDF per-block)~~ | **ZREALIZOWANE** (luty 2026) |
| ~~**Później**~~ | ~~D1 (double-backtick)~~ | **ZREALIZOWANE** (luty 2026) |
| **Następne** | D4 (ToC) | Nawigacja po nagłówkach z sidebar |
| **Później** | D3 (Reference links), D6 (Themes) | Rzadko używane / kosmetyczne |

---

## Metodologia: Agent Teams

Prace realizowane w modelu **Agent Teams** — koordynowany zespół agentów AI:

### Workflow

1. **Audyt** — specjalistyczne agenty analizują kod (każdy swój obszar)
2. **Plan** — koordynator konsoliduje wyniki i planuje zmiany
3. **Implementacja** — agenty implementujące z przypisanymi plikami (zero konfliktów)
4. **Weryfikacja** — build test obu wariantów (GitHub + App Store)
5. **Commit** — jeden spójny commit z pełnym opisem zmian

### Zasady przydziału

- **Jeden plik = jeden agent** — eliminuje merge conflicts
- **Skoordynowane interfejsy** — agenty dzielące API (np. FocusedValue) dostają identyczną specyfikację
- **Równoległość** — niezależne zmiany realizowane jednocześnie
- **Weryfikacja po złączeniu** — build test po zakończeniu wszystkich agentów
