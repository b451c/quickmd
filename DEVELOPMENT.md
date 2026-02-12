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
- [ ] **C4: PDF rendering per-block** — patrz sekcja poniżej
- [x] C5: Link/image parser — bracket/paren depth counting
- [x] C6: Deduplikacja AppURLs (jeden enum w QuickMDApp.swift)

---

## Pozostałe prace

### C4: PDF rendering per-block

**Status:** Niezrealizowane | **Wysiłek:** Duży | **Priorytet:** Średni

**Problem:** `generateMultiPagePDF` renderuje cały dokument jako jeden obraz (ImageRenderer), potem tnie na strony. Powoduje:
- Ryzyko OOM dla dokumentów 50+ stron (obraz ~150MB+ na Retina)
- Page breaks tnące przez środek tekstu/tabel/obrazów
- Brak inteligentnej paginacji

**Quick fix zrobiony (A2):** Eliminacja podwójnego renderowania + maxHeight na obrazach.

**Docelowe rozwiązanie:** Renderowanie blok-po-bloku z śledzeniem wysokości:
1. Iteracja po `[MarkdownBlock]`
2. Renderowanie każdego bloku osobno przez ImageRenderer
3. Śledzenie akumulowanej wysokości na stronie
4. Page break między blokami (nigdy w środku)
5. Opcjonalnie: dzielenie długich code blocks na linie

**Pliki do zmiany:** `MarkdownExport.swift` (sekcja `generateMultiPagePDF`)

**Planowanie agentowe:** Jeden agent, pełna odpowiedzialność za plik. Wymaga testów z dokumentami różnych rozmiarów.

---

### Faza D: Rozwój funkcjonalny

#### D1: Double-backtick inline code
**Wysiłek:** Mały | **Priorytet:** Niski

Tilde fences (`~~~`) zostały dodane w ramach audytu. Pozostaje wsparcie dla double-backtick inline code:
```markdown
``code with ` backtick``
```
Pozwala na umieszczenie backtick'a wewnątrz inline code.

**Plik:** `MarkdownRenderer.swift` (tryParseInlineCode)

---

#### D2: Nested blockquotes i multi-line blockquotes
**Wysiłek:** Średni | **Priorytet:** Średni

**Obecny stan:** Każda linia `>` jest przetwarzana niezależnie. Brak:
- Łączenia kolejnych linii `>` w jeden blok
- Zagnieżdżenia (`>> nested blockquote`)
- Lazy continuation (linia bez `>` kontynuująca blockquote)

**Podejście:**
1. Block-level: `MarkdownBlockParser` rozpoznaje ciągłe bloki `>` i tworzy nowy typ `.blockquote`
2. Rendering: Nowy `BlockquoteView` z szarą lewą krawędzią i rekursywnym parsowaniem zawartości
3. Nesting: Stripowanie `>` prefix per level, rendering zagnieżdżony

**Pliki:** `MarkdownBlock.swift` (nowy case), `MarkdownBlockParser.swift`, nowy `Views/BlockquoteView.swift`

**Planowanie agentowe:** 2 agentów — jeden na parser, drugi na view.

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

#### D5: Find & Search w dokumencie
**Wysiłek:** Duży | **Priorytet:** Wysoki

Cmd+F — wyszukiwanie tekstu w dokumencie z podświetlaniem wyników.

**Podejście:**
1. Toolbar z polem tekstowym (Cmd+F toggle)
2. Wyszukiwanie w `document.text` (raw markdown)
3. Podświetlanie wyników w renderowanych blokach (dodanie `.backgroundColor` do AttributedString)
4. Nawigacja między wynikami (Enter / Shift+Enter)
5. Integracja z `ScrollViewReader` do scrollowania do wyniku

**Wyzwania:**
- Mapowanie pozycji w raw text → pozycji w renderowanych blokach
- Podświetlanie w `AttributedString` wymaga re-renderingu z informacją o wyszukiwaniu
- Wydajność dla dużych dokumentów

**Pliki:** Nowy `Views/SearchBar.swift`, modyfikacja `MarkdownView.swift`, `MarkdownRenderer.swift`

**Planowanie agentowe:** 3 agentów — search logic, UI, renderer integration.

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

| Priorytet | Zadania | Uzasadnienie |
|-----------|---------|-------------|
| **Następne** | D5 (Search) | Najczęściej zgłaszana brakująca funkcja w viewerach MD |
| **Wkrótce** | D2 (Blockquotes), C4 (PDF per-block) | Poprawność renderingu + jakość eksportu |
| **Później** | D4 (ToC), D1 (double-backtick) | Nawigacja + drobna poprawka parsera |
| **Kiedyś** | D3 (Reference links), D6 (Themes) | Rzadko używane / kosmetyczne |

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
