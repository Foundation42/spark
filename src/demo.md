# text_engine

## Stage 3 — markdown source becomes the tree

Same renderer as before — only the construction path changed. This document is parsed by *cmark* into an AST, then walked into an `element.Element` tree.

## Inline cascade

This paragraph uses *italic* and **bold** and ***bold-italic*** and `inline code` and a [link](https://example.com).

Underlines honour wrap — [this is a longer link with enough text inside its anchor that it spans more than one line, producing one underline quad per visible line of the link](https://example.com).

## Nesting

- block kinds nest
- indent shrinks `max_w` for nested content
- and items hold multiple blocks:
  1. first nested
  2. second nested

> Quotes indent their content, and indent propagates through Constraints so the inline-flow inside this quote wraps on the narrower available width — not on the full viewport width.

---

## Code

```zig
fn render(elem: Element) !void {
    // code blocks: monospace, preformatted
}
```
