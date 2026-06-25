# ExPdfium

Elixir bindings for [pdfium](https://pdfium.googlesource.com/pdfium/) — Google's
Chromium PDF engine — via the Rust
[`pdfium-render`](https://github.com/ajrcarey/pdfium-render) crate, shipped as a
**precompiled NIF** with [`rustler_precompiled`](https://hexdocs.pm/rustler_precompiled).

No Rust toolchain. No separately-installed pdfium. Add the dep and go.

> **A read & extract toolkit.** Open documents and count pages, render pages to
> bitmaps, extract and search text, read metadata, page geometry and permissions,
> walk structure (bookmarks, links, attachments), and read forms and annotations.
> It does **not** create, edit, or save PDFs.

## Why

The native PDF-rendering gap in Elixir: `Vix`/`Image` (libvips) ships without PDF
support, so rasterizing a PDF normally means building libvips from source with
poppler/pdfium. ExPdfium fills that gap with a precompiled pdfium binding —
rendering, plus text extraction and metadata that pure-libvips can't give you.

This is a ground-up Rust rewrite of the older
[`gmile/pdfium`](https://github.com/gmile/pdfium) C++ NIF, adopting the
`rustler_precompiled` release model so every supported OTP (27/28/29+) gets a
precompiled binary from one build matrix.

## Installation

```elixir
def deps do
  [{:ex_pdfium, "~> 0.1"}]
end
```

## Usage

```elixir
{:ok, doc} = ExPdfium.open("file.pdf")          # or open(<<"%PDF...">> = bytes)
{:ok, n}   = ExPdfium.page_count(doc)
:ok        = ExPdfium.close(doc)

# Encrypted documents:
{:ok, doc} = ExPdfium.open("secret.pdf", password: "hunter2")
```

Documents are closed automatically on garbage collection; call
`ExPdfium.close/1` to release pdfium memory early. `open/2` returns
`{:error, reason}` for problems like `:enoent`, `:invalid_pdf`, or
`:password_error`.

### Rendering

```elixir
{:ok, %ExPdfium.Bitmap{data: data, width: w, height: h}} =
  ExPdfium.render_page(doc, 0, dpi: 300)   # or scale:, or width:/height:

# Hand the raw RGBA buffer straight to Vix/Image:
{:ok, image} = Vix.Vips.Image.new_from_binary(data, w, h, 4, :VIPS_FORMAT_UCHAR)
Image.write(image, "page.png")
```

`render_page/3` takes `:dpi` / `:scale` / `:width` / `:height` for sizing,
`format: :rgba | :bgra`, `background: :white | :transparent`, plus `grayscale:`,
`annotations:`, and `form_fields:` toggles. The bitmap is an uncompressed 4-channel
buffer (`width * height * 4` bytes).

```elixir
# Suppress the annotation overlay, in grayscale:
{:ok, bmp} = ExPdfium.render_page(doc, 0, dpi: 150, grayscale: true, annotations: false)

# One small bitmap per page (defaults to width 200):
{:ok, thumbs} = ExPdfium.thumbnails(doc, width: 160)
```

### Text & search

```elixir
{:ok, text} = ExPdfium.extract_text(doc, 0)   # one page
{:ok, text} = ExPdfium.extract_text(doc)      # whole document

# Text runs with bounding boxes (PDF points, origin bottom-left):
{:ok, segments} = ExPdfium.text_segments(doc, 0)
# => [%{text: "Hello", bounds: %{left: 41.9, bottom: 115.2, right: 89.0, top: 137.5}}, ...]

# Search a page (case-insensitive by default):
{:ok, matches} = ExPdfium.search_text(doc, 0, "invoice", match_case: false)
# => [%{text: "Invoice", rects: [%{left: ..., bottom: ..., right: ..., top: ...}]}, ...]
```

### Metadata, geometry & permissions

```elixir
{:ok, meta} = ExPdfium.metadata(doc)
# => %{title: "…", author: "…", creation_date: "D:…", producer: "…",
#      version: "1.7", page_count: 12, page_mode: :none, ...}  # /Info + doc properties

{:ok, info} = ExPdfium.page_info(doc, 0)
# => %{width: 612.0, height: 792.0, rotation: 0, label: nil,
#      boxes: %{media: %{left: 0.0, bottom: 0.0, right: 612.0, top: 792.0},
#               crop: nil, bleed: nil, trim: nil, art: nil}}  # non-media boxes often nil

{:ok, perms} = ExPdfium.permissions(doc)
# => %{print_high_quality: true, extract_text_and_graphics: true, modify_content: true, ...}
```

### Structure & navigation

```elixir
{:ok, tree} = ExPdfium.outline(doc)        # bookmark tree
# => [%{title: "Chapter 1", page: 0, children: [%{title: "1.1", page: 0, children: []}]}, ...]

{:ok, links} = ExPdfium.links(doc, 0)      # links on a page
# => [%{bounds: %{...}, uri: "https://example.com", page: nil},
#     %{bounds: %{...}, uri: nil, page: 1}]               # internal link to page 1

{:ok, files} = ExPdfium.attachments(doc)   # => [%{index: 0, name: "note.txt", size: 25}]
{:ok, bytes} = ExPdfium.attachment_data(doc, 0)
```

### Forms & annotations (read)

```elixir
{:ok, :acrobat} = ExPdfium.form_type(doc)  # :none | :acrobat | :xfa_full | :xfa_foreground

{:ok, fields} = ExPdfium.form_fields(doc)  # AcroForm fields, one per widget
# => [%{name: "full_name", type: :text, value: "Ada Lovelace", checked: nil,
#       read_only: false, required: false, page: 0, bounds: %{...}},
#     %{name: "subscribe", type: :checkbox, value: "Yes", checked: true, ...}]

{:ok, anns} = ExPdfium.annotations(doc, 0) # annotations on a page (markup + widgets)
# => [%{type: :highlight, contents: "Important", bounds: %{...}, name: nil,
#       hidden: false, printed: false}, ...]
```

> XFA form data needs a V8-enabled pdfium build, which is not shipped; `:xfa_full`
> documents may expose an empty or partial AcroForm view.

### Images & page objects

```elixir
# What's on the page, typed, with bounds:
{:ok, objects} = ExPdfium.page_objects(doc, 0)
# => [%{index: 0, type: :text, bounds: %{...}},
#     %{index: 2, type: :image, bounds: %{...}}, ...]  # :text|:path|:image|:shading|:form

# The image objects, and how they're stored:
{:ok, images} = ExPdfium.images(doc, 0)
# => [%{index: 2, width: 800, height: 600, bits_per_pixel: 24, filters: ["DCTDecode"],
#       bounds: %{...}, matrix: %{a: 800.0, b: 0.0, c: 0.0, d: 600.0, e: 40.0, f: 100.0}}]

# Decoded pixels (native channel order — Vix-ready):
{:ok, %ExPdfium.Bitmap{data: data, width: w, height: h, format: fmt}} =
  ExPdfium.image_data(doc, 0, 2)              # fmt: :gray | :bgr | :bgrx | :bgra

# …or the original encoded stream (a DCTDecode image IS a .jpg):
{:ok, jpg} = ExPdfium.image_raw_data(doc, 0, 2)
```

The `:matrix` on each object/image is its `[a b c d e f]` transform, in the page's
**unrotated content space**. For an image it maps the unit square onto the page, so
you can recover the transform baked into the object (scale, plus any object-level
rotation/flip) without re-rendering. For the **as-displayed** orientation — e.g. a
scanned page bound for OCR — compose it with `page_info/2`'s `:rotation`, which
carries the page-level `/Rotate` the matrix does not. (`page_info/2`'s
`:width`/`:height` are already display-oriented — a different frame from the matrix.)

### Writing — page assembly

```elixir
# Merge, rotate, and save. In-place ops return {:ok, doc} (the same handle), so
# they thread through `with`:
with {:ok, doc} <- ExPdfium.open("a.pdf"),
     {:ok, other} <- ExPdfium.open("b.pdf"),
     {:ok, doc} <- ExPdfium.append(doc, other),       # merge b's pages onto a
     {:ok, doc} <- ExPdfium.delete_pages(doc, 2..3),   # drop a page or a range
     {:ok, doc} <- ExPdfium.rotate_page(doc, 0, 90),   # 0 | 90 | 180 | 270
     :ok <- ExPdfium.save_to_file(doc, "merged.pdf") do
  :ok
end

# Split / subset — build a NEW document from selected pages, in any order:
{:ok, subset} = ExPdfium.extract_pages(doc, [0, 2, 5])
{:ok, bytes}  = ExPdfium.save_to_bytes(subset)
```

`save_to_bytes/1` / `save_to_file/2` write a full snapshot and leave `doc` open
for further edits.

### Creating documents

Build a PDF from scratch — pages, text (Standard-14 fonts), shapes, and images.
Coordinates are PDF points, origin bottom-left; colors are `{r,g,b}`/`{r,g,b,a}`
(0–255).

```elixir
with {:ok, doc} <- ExPdfium.new(),
     {:ok, doc} <- ExPdfium.add_page(doc, :letter),   # :a4 | :legal | … | {w_pts, h_pts}
     {:ok, doc} <- ExPdfium.draw_text(doc, 0, {72, 720}, "Invoice #42",
                     font: :helvetica_bold, size: 18),
     {:ok, doc} <- ExPdfium.draw_line(doc, 0, {72, 710}, {540, 710}, stroke: {0, 0, 0}),
     {:ok, doc} <- ExPdfium.draw_rectangle(doc, 0, %{left: 72, bottom: 600, right: 540, top: 690},
                     fill: {245, 245, 245}, stroke: {200, 200, 200}),
     {:ok, doc} <- ExPdfium.draw_circle(doc, 0, {120, 645}, 24, fill: {220, 50, 50}),
     :ok <- ExPdfium.save_to_file(doc, "invoice.pdf") do
  :ok
end
```

#### Placing images

`draw_image/4` takes **decoded pixels** — an `ExPdfium.Bitmap`, the same struct
`render_page/3` and `image_data/3` produce — not an encoded JPEG/PNG. So you can
re-place a rendered page or an extracted image directly:

```elixir
{:ok, bmp} = ExPdfium.image_data(src_doc, 0, 2)
{:ok, doc} = ExPdfium.draw_image(doc, 0, bmp, at: %{left: 400, bottom: 700, right: 540, top: 760})
```

> #### Pixel byte order {: .info}
> pdfium stores images in **BGRA** order. `draw_image/4` takes `:bgra`, `:bgr`,
> `:bgrx`, and `:gray` bitmaps as-is, and for `:rgba`/`:rgbx` (what `render_page/3`
> yields by default, and what most image libraries produce) it **swaps R↔B for
> you** — so you never have to think about byte order.

To place an image *file*, decode it to pixels first with the optional
[Vix](https://hex.pm/packages/vix) library (the same one used for rendering):

```elixir
{:ok, vimg} = Vix.Vips.Image.new_from_file("logo.png")   # a 4-band RGBA image
{w, h, 4} = Vix.Vips.Image.shape(vimg)
{:ok, pixels} = Vix.Vips.Image.write_to_binary(vimg)

bitmap = %ExPdfium.Bitmap{data: pixels, width: w, height: h, stride: w * 4, format: :rgba}
{:ok, doc} = ExPdfium.draw_image(doc, 0, bitmap, at: %{left: 400, bottom: 700, right: 540, top: 760})
```

> If the source isn't already 4-band RGBA, convert it first (e.g.
> `Vix.Vips.Operation.colourspace/2` and add an alpha band). `draw_image/4`
> accepts `:rgba`, `:bgra`, `:bgrx`, `:bgr`, and `:gray`.

### Writing — annotations

Author annotations on a page. Rectangles take a `bounds` map
(`%{left:, bottom:, right:, top:}`, PDF points) — the same shape `annotations/2`
reads back.

```elixir
# A sticky note (icon + popup text), a visible text box, a boxed callout, a link:
{:ok, doc} = ExPdfium.add_text_annotation(doc, 0, {500, 720}, "Please review")
{:ok, doc} = ExPdfium.add_free_text_annotation(doc, 0, %{left: 72, bottom: 690, right: 320, top: 715}, "DRAFT")
{:ok, doc} = ExPdfium.add_square_annotation(doc, 0, %{left: 60, bottom: 540, right: 540, top: 660}, stroke: {220, 50, 50})
{:ok, doc} = ExPdfium.add_link_annotation(doc, 0, %{left: 72, bottom: 510, right: 260, top: 525}, "https://hex.pm")

{:ok, doc} = ExPdfium.delete_annotation(doc, 0, 0) # remove by 0-based page index
```

> The text-markup family (highlight/underline/strikeout/squiggly) is deferred:
> pdfium's own renderer won't display them without an appearance stream it does
> not auto-generate. FreeText renders its text in pdfium's default appearance
> color (black); for colored text, use `draw_text/5`.

Saving, assembly, and annotation authoring are the v0.3 write surface;
form-filling and the text-markup annotation family arrive in later 0.3.x releases.

## Development

The shipped NIF binds pdfium **dynamically** and loads a `libpdfium` bundled
**inside the precompiled tarball**, right beside the NIF (bblanchon publishes no
static `libpdfium.a`). For local work, download a `libpdfium` once and point the
tests at it:

```bash
just fetch-pdfium            # downloads libpdfium for this host into priv/pdfium
just test                    # EXPDFIUM_BUILD=1 mix test  (forces a from-source build)
just fmt                     # mix format + cargo fmt
```

`EXPDFIUM_BUILD=1` forces a from-source NIF build instead of downloading a
precompiled one. CI runs the full gate: `mix format --check-formatted`,
`cargo fmt --check`, `cargo clippy -- -D warnings`,
`mix compile --warnings-as-errors`, and `mix test`.

## Releasing

See [`UPDATE_PROCEDURE.md`](https://github.com/jtippett/ex_pdfium/blob/main/UPDATE_PROCEDURE.md).
In short: `just release` bumps
the version, rolls the CHANGELOG, tags, and pushes; the tag triggers a build
matrix that attaches one NIF per target to a GitHub release; checksums are
regenerated from those artifacts; Hex publish is gated behind a manual approval.

## License

MIT — see [LICENSE](https://github.com/jtippett/ex_pdfium/blob/main/LICENSE).
pdfium itself is BSD-3-Clause (Google/Chromium);
the precompiled pdfium binaries come from
[bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries).
