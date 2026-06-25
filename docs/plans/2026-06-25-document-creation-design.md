# ExPdfium v0.3 — Document Creation (text + shapes + images) (design)

**Date:** 2026-06-25
**Status:** approved, implementing
**Scope:** the document-creation write phase. Builds on page assembly + save and
image extraction. Creates documents and draws content from scratch.

## Decisions (locked)

1. **Scope = text + shapes + images** (the fullest first cut the user chose).
2. **In-place `{:ok, doc}`** mutation, consistent with the page-assembly track;
   `new/0` returns `{:ok, new_doc}` (a fresh resource, like `extract_pages/2`).
3. **Coordinates = PDF points, origin bottom-left**, matching `t:bounds/0`.
4. **Colors = `{r,g,b}` / `{r,g,b,a}`** integer tuples (0–255); `nil` to omit fill/stroke.
5. **Fonts = the Standard-14 built-ins** as atoms (`:helvetica`, `:helvetica_bold`,
   `:times_roman`, `:courier`, …) — no font files shipped. Custom fonts: later.
6. **Images take a decoded `%ExPdfium.Bitmap{}`** (the struct `render_page/3` and
   `image_data/3` *produce*) — NOT encoded JPEG/PNG bytes. Keeps the NIF lean (no
   `image` crate / `image_api` feature). Decode files via Vix first (documented).

## Public API

```elixir
{:ok, doc} = ExPdfium.new()
{:ok, doc} = ExPdfium.add_page(doc, :letter)        # :a4|:letter|… | {w_pts,h_pts}; opts: at: index

ExPdfium.draw_text(doc, 0, {72, 720}, "Invoice #42",
                   font: :helvetica_bold, size: 18, color: {0,0,0})
ExPdfium.draw_rectangle(doc, 0, bounds, fill: {240,240,240}, stroke: {0,0,0}, stroke_width: 1)
ExPdfium.draw_line(doc, 0, {50,595}, {560,595}, stroke: {0,0,0}, stroke_width: 1)
ExPdfium.draw_circle(doc, 0, {100,500}, 30, fill: {255,0,0})
ExPdfium.draw_image(doc, 0, bitmap, at: bounds)     # bitmap = %ExPdfium.Bitmap{}

{:ok, bytes} = ExPdfium.save_to_bytes(doc)          # reuses existing save
```

All draw ops + add_page return `{:ok, doc}` (same handle). New `@doc group: :creation`.

## pdfium-render mapping (faithful, marshal-only)

- `new/0`: `pdfium().create_new_pdf()` → fresh `DocumentResource` (reuses GC/cleanup).
- `add_page`: Elixir resolves the size preset → explicit points, so the NIF takes
  `(width_pts, height_pts, at_index)`; `pages_mut().create_page_at_index/end`.
- `draw_text`: `fonts_mut()` built-in token → `PdfPageTextObject::new(doc, text, font,
  size)` → `set_fill_color` → translate to `{x,y}` → `objects_mut().add_object`.
- shapes: `PdfPagePathObject::new_rect/new_line/new_circle` with optional
  stroke/fill colors + stroke width → `add_object`.
- `draw_image`: build a `PdfBitmap` from the supplied pixels (`PdfBitmap::from_bytes`,
  unsafe — validate buffer length == w*h*bytes_per_pixel) → `PdfPageImageObject::new`
  + `set_bitmap` → scale + translate the (unit) image object to the `at:` bounds.
- After adds, pdfium-render's default content-regeneration strategy commits the
  page; call `regenerate_content()` explicitly if the round-trip shows otherwise.

## The image pixel-format juggling (important)

pdfium's native bitmap order is **BGRA**, not RGBA. `draw_image`:
- accepts `:bgra` / `:bgr` / `:bgrx` / `:gray` and maps them straight to the
  pdfium bitmap format;
- for `:rgba` / `:rgbx` (what `render_page/3` yields by default, and Vix's order)
  swaps R↔B while copying into the buffer.

So any Bitmap from `render_page/3` (either format), `image_data/3`, or Vix works
without the caller thinking about byte order. A buffer whose length doesn't match
`width*height*channels` → `{:error, :bad_image_data}`.

## Architecture / safety

- All NIFs serialize through `PDFIUM_LOCK`; creation/draw NIFs take `.as_mut()`
  (they need `&mut PdfDocument` for `pages_mut`/`objects_mut`/`fonts_mut`).
- Validate before mutating: page index in range, known font atom, image buffer
  length correct — so a bad arg fails cleanly with no half-drawn object.
- Errors (mapped): `:document_closed`, `:page_out_of_bounds`, `:unknown_font`,
  `:bad_image_data`, `:unsupported_image_format`, and op-failure atoms
  (`:create_failed` / `:draw_failed`).

## Testing — all round-trip, no fixtures (we create the docs)

- `new` + `add_page(:letter)` → reopen → 1 page, `page_info` width 612 / height 792.
- `draw_text` → save → reopen → `extract_text` contains the string (placement +
  regeneration).
- shapes → reopen → `page_objects` shows the `:path` objects.
- `draw_image` → reopen → **`images/2` round-trips it** (our own extractor) with the
  expected dimensions; verify an `:rgba` source and a `:bgra` source both embed.
- errors: closed doc, bad page index, unknown font atom, mismatched image buffer.
- concurrency: parallel draw/save on a shared created doc stays consistent.

## Docs & release

- README **"Creating documents"** section, including (a) a note on the image-format
  juggling and (b) a worked **Vix/`Image` convenience example** decoding a file →
  pixels → `draw_image`.
- `examples/create.exs` (compose a small page: text + rule + box + image),
  CHANGELOG entry, `@doc group: :creation` in the sidebar.
- Working loop per phase (TDD → gate → code-reviewer → commit → push → CI). Rounds
  out the v0.3 write story (assembly + creation). Hex release still needs a fresh
  go-ahead.
