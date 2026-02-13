# QuickMD Sprint Test File

Ten plik testuje wszystkie nowe funkcje ze sprintu (D1, D2, D5, C4).

---

## D5: Search (Cmd+F)

Wyszukaj slowo **MARKER** zeby przetestowac wyszukiwanie.

To jest pierwszy akapit z MARKER do znalezienia.

To jest drugi akapit **bez** szukanego slowa.

A tu jest trzeci akapit, znow z MARKER w tekscie.

I jeszcze jeden blok z MARKER na samym koncu sekcji.

---

## D1: Double-backtick inline code

Pojedynczy backtick: `normalny inline code`

Podwojny backtick: ``kod z ` backtick wewnatrz``

Jeszcze raz: ``console.log(`template literal`)``

Zwykly backtick po podwojnym: `prosty` i ``podwojny``

Potrójne backtick NIE powinno byc inline: ``` to nie zadziala ```

---

## D2: Blockquotes

### Prosty blockquote

> To jest prosty cytat.
> Druga linia tego samego cytatu.

### Zagniezdzone blockquotes

> Poziom 1
>> Poziom 2 - zagniezdzone
>>> Poziom 3 - jeszcze glebiej

### Blockquote z formatowaniem

> Cytat z **boldiem**, *kursywa* i `kodem`.
> A takze [link](https://qmd.app/) w cytacie.

### Pusty blockquote

>
> Linia po pustej linii blockquote
>

---

## Tabele (istniejaca funkcja)

| Funkcja | Status | Sprint |
|:--------|:------:|-------:|
| Search Cmd+F | Done | Luty 2026 |
| Blockquotes | Done | Luty 2026 |
| Double-backtick | Done | Luty 2026 |
| PDF per-block | Done | Luty 2026 |

---

## Code Blocks (istniejaca funkcja)

### Swift

```swift
struct BlockquoteView: View {
    let content: String
    let level: Int  // nesting depth
    let theme: MarkdownTheme

    var body: some View {
        HStack(alignment: .top) {
            ForEach(0..<level, id: \.self) { _ in
                Rectangle()
                    .fill(theme.blockquoteColor)
                    .frame(width: 3)
            }
            Text(content)
        }
    }
}
```

### Python

```python
def search_markdown(text, query):
    """Find all occurrences of query in text."""
    results = []
    lower_text = text.lower()
    lower_query = query.lower()
    start = 0
    while True:
        pos = lower_text.find(lower_query, start)
        if pos == -1:
            break
        results.append(pos)
        start = pos + 1
    return results  # MARKER in code block
```

### JavaScript

```javascript
// Double-backtick test in comments
const renderBlockquote = (content, level) => {
    const prefix = '>'.repeat(level);
    return `${prefix} ${content}`;  // MARKER in JS
};
```

---

## Listy (istniejaca funkcja)

- Pierwszy element
    - Zagniezdzone
    - Drugie zagniezdzone
- Drugi element
    1. Numerowane zagniezdzone
    2. Jeszcze jedno

### Task list

- [x] Zaimplementowac Search
- [x] Zaimplementowac Blockquotes
- [x] Zaimplementowac Double-backtick
- [x] Zaimplementowac PDF per-block
- [ ] Przetestowac wszystko

---

## Formatowanie inline (istniejaca funkcja)

**Bold text** i *italic text* i ***bold italic*** i ~~strikethrough~~.

Podkreslenie _italic_ ale nie srodek_slowa_tutaj (snake_case).

Escape: \*to nie jest bold\* i \`to nie jest code\`.

Link: [QuickMD Website](https://qmd.app/)

Autolink: https://github.com/b451c/quickmd

---

## Naglowki roznych poziomow

# H1 - Naglowek pierwszy
## H2 - Naglowek drugi
### H3 - Naglowek trzeci
#### H4 - Naglowek czwarty
##### H5 - Naglowek piaty
###### H6 - Naglowek szosty

---

## Setext Headers

Naglowek pierwszy setext
=========================

Naglowek drugi setext
-------------------------

---

## Linie poziome

***

---

___

---

## Ostatni blok z MARKER

Ten akapit na samym dole tez zawiera MARKER — sprawdz czy search doscrolluje az tutaj.

*QuickMD v1.2.1 — Sprint Test Complete*
