# Annotation authoring (0.3.x)

Status: accepted (2026-06-25). Closes the last write surface before the 0.3.0
Hex release. Builds on the document-creation and page-assembly work already on
`main`.

## Scope

Author the annotation types pdfium-render 0.8.37 supports cleanly, with
auto-generated appearance streams so they render in non-pdfium viewers (Preview,
Acrobat) as well as our own renderer.

In scope:

- **Text** (sticky note) — icon at a point + popup contents.
- **FreeText** — a visible text box drawn on the page.
- **Square** — a rectangle box with fill/stroke.
- **Link** — a clickable URI over a rectangle.
- **Delete** — remove an annotation by its 0-based page index.

Out of scope (deferred): **the text-markup family** (highlight, underline,
strikeout, squiggly), **Ink** (freehand polylines — more complex input, lower
demand), **Circle** (pdfium-render 0.8.37 exposes no `create_circle_annotation`,
only `create_square_annotation`), **Popup/Stamp** authoring, and any form-field
(widget) authoring (form-filling remains explicitly out of scope).

### Why the markup family was dropped (decided 2026-06-25)

pdfium attaches highlight/underline/strikeout/squiggly annotations correctly —
they read back via `annotations/2` with the right type, bounds, and color, and
are valid, portable PDFs. But **pdfium's own renderer does not display text-markup
annotations without an explicit `/AP` appearance stream**, which pdfium does not
auto-generate (verified empirically: no render delta even after a save/reopen
round-trip, whereas Square renders directly). Conforming viewers (Acrobat,
Preview, browsers) generate the appearance from the QuadPoints + color per
PDF 32000-1 §12.5.6.10, but pdfium specifically requires the stream.

The two ways to close that gap were both rejected for 0.3: documenting the
self-render caveat (poor ergonomics — author a highlight, render a thumbnail, see
nothing), and synthesizing the appearance by attaching a path object to each
markup annotation (reintroduces the page-object-on-annotation crash surface the
hardness sweep just closed, and amounts to us generating appearances rather than
pdfium). The markup family is deferred until appearance generation can be solved
cleanly. The other four types all render correctly in our own renderer.

## Why this is lower-risk than the draw primitives

`create_*_annotation` calls `FPDFPage_CreateAnnot`, which **attaches the
annotation to the page immediately**, then sets properties on the attached
handle. The orphaned-build-then-drop SEGFAULT class that bit document creation
(an object built but never added, then dropped) **does not arise here** — there
is no detached, never-added annotation to drop. The faithful mapping is simply:
create, then set properties, then regenerate.

## Public API

Mirrors the existing `draw_*` family: `{doc, page_index, geometry, …, opts}`,
returns `{:ok, doc}` and mutates in place. Rectangles use the **bounds map**
`%{left:, bottom:, right:, top:}` — the exact shape the read side returns as
`t:bounds/0`, giving read/write symmetry. Points use a `{x, y}` tuple, matching
`draw_text/5`. Colors go through `normalize_color/1` (`{r,g,b}` → `{r,g,b,255}`).

```elixir
add_text_annotation(doc, page_index, {x, y}, text, opts \\ [])
#   opts: :color  (icon color; default {255, 230, 0})

add_free_text_annotation(doc, page_index, bounds, text, opts \\ [])
#   opts: :fill (interior background), :stroke (border)
#   NOTE: text renders in pdfium's default appearance color (black). Setting the
#   FreeText font color needs FPDFAnnot_SetFontColor, gated behind pdfium-render's
#   `pdfium_7350`/`pdfium_future` features — NOT enabled by our `pdfium_latest`
#   (=`pdfium_7543`, which does not transitively enable `pdfium_7350`). We do not
#   expose a text-color option we cannot honor.

add_square_annotation(doc, page_index, bounds, opts \\ [])      # :fill (default nil), :stroke (default {0,0,0})

add_link_annotation(doc, page_index, bounds, uri, opts \\ [])

delete_annotation(doc, page_index, annot_index)                # 0-based index on the page
```

## Mapping notes (golden rule: follow pdfium-render, don't reinvent)

- **Square** uses `set_fill_color` (interior) + `set_stroke_color` (border) on
  the common annotation trait.
- **Link** uses `set_link(uri)` plus `set_bounds`.
- **Text** (sticky note) uses `set_position` + `set_contents`; `:color` maps to
  the icon color via `set_fill_color`.
- **Appearance streams.** Pages default to
  `PdfPageContentRegenerationStrategy::AutomaticOnEveryChange`, so pdfium
  regenerates content/appearance as properties are set. We verify rendering
  empirically in tests (render the page before/after; assert pixels changed).

## NIF surface (native.ex stubs + lib.rs)

- `document_add_text_annotation(ref, page, x, y, text, color)`
- `document_add_free_text_annotation(ref, page, l, b, r, t, text, fill, stroke)`
- `document_add_square_annotation(ref, page, l, b, r, t, fill, stroke)`
- `document_add_link_annotation(ref, page, l, b, r, t, uri)`
- `document_delete_annotation(ref, page, annot_index)`

All `DirtyCpu`, all under `with_pdfium` + `PDFIUM_LOCK`, page validated up front
via the existing `check_page`. Colors are `(u8,u8,u8,u8)`; optional fill/stroke
are `Option<(u8,u8,u8,u8)>` exactly like `draw_rectangle`.

## Tests

Round-trip every type: author it, then read it back with `annotations/2`
(asserting `type`, `bounds`, `contents` where applicable) and render the page to
confirm it visibly draws (pixel delta vs the blank page). `delete_annotation`
removes the right one (count drops, survivors unchanged). Error paths:
out-of-bounds page → `{:error, :page_out_of_bounds}`; out-of-range annot index on
delete → error. Save/reopen round-trip to confirm persistence.
