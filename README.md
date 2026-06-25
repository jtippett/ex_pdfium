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
`format: :rgba | :bgra`, and `background: :white | :transparent`. The bitmap is an
uncompressed 4-channel buffer (`width * height * 4` bytes).

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
# => %{title: "…", author: "…", creation_date: "D:…", producer: "…", ...}

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
# => [%{index: 2, width: 800, height: 600, bits_per_pixel: 24,
#       filters: ["DCTDecode"], bounds: %{...}}]

# Decoded pixels (native channel order — Vix-ready):
{:ok, %ExPdfium.Bitmap{data: data, width: w, height: h, format: fmt}} =
  ExPdfium.image_data(doc, 0, 2)              # fmt: :gray | :bgr | :bgrx | :bgra

# …or the original encoded stream (a DCTDecode image IS a .jpg):
{:ok, jpg} = ExPdfium.image_raw_data(doc, 0, 2)
```

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
for further edits. Saving and assembly are the v0.3 starting point; form-filling,
annotation authoring, and new-document creation arrive in later 0.3.x releases.

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
