# Test: Reference-style Links (D3)

## 1. Full reference links: [text][id]

Click here to visit [Google][google] or check out [Apple's website][apple].

You can also visit [Example][example] which uses angle brackets in definition.

[google]: https://www.google.com
[apple]: https://www.apple.com
[example]: https://example.com

---

## 2. Collapsed reference links: [text][]

Visit [GitHub][] for source code or [Wikipedia][] for encyclopedic knowledge.

[GitHub]: https://github.com
[Wikipedia]: https://en.wikipedia.org

---

## 3. Shortcut reference links: [text]

The simplest form: just use [MDN] or [Stack Overflow] directly.

[MDN]: https://developer.mozilla.org
[Stack Overflow]: https://stackoverflow.com

---

## 4. Case insensitive matching

These should all resolve: [Link One][LINK-ONE], [Link Two][link-two], [Link Three][Link-Three].

[link-one]: https://example.com/one
[LINK-TWO]: https://example.com/two
[Link-Three]: https://example.com/three

---

## 5. Mixed with inline links

Here is an [inline link](https://inline.example.com) and a [reference link][ref1] in the same paragraph.

Also: **bold [ref link][ref1]** and *italic [ref link][ref2]*.

[ref1]: https://reference1.example.com
[ref2]: https://reference2.example.com

---

## 6. Definitions should be hidden

The lines below define references — they should NOT appear as visible text:

[hidden1]: https://should-not-be-visible.com
[hidden2]: https://also-invisible.com "With title"

If you see raw `[hidden1]:` or `[hidden2]:` text above, the pre-pass filter is broken.

---

## 7. Non-matching brackets (should render as plain text)

This is [not a link] because there is no matching definition.

And [also not][missing-id] because the ID doesn't exist.

---

## 8. Definitions at document end

All definitions can be at the bottom of the document:

Check [Python][] and [Rust][] — definitions are below.

[Python]: https://python.org
[Rust]: https://rust-lang.org
