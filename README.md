# ExPdfium

Elixir bindings for [pdfium](https://pdfium.googlesource.com/pdfium/) — Google's
Chromium PDF engine — via the Rust
[`pdfium-render`](https://github.com/ajrcarey/pdfium-render) crate, shipped as a
**precompiled NIF** with [`rustler_precompiled`](https://hexdocs.pm/rustler_precompiled).

No Rust toolchain. No separately-installed pdfium. Add the dep and go.

> **Status: early.** Opening documents, page counts, rendering, and text
> extraction/search work today (precompiled, `v0.1`+). Metadata and structure are
> landing phase by phase — see [`PORTING.md`](PORTING.md).

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

See [`UPDATE_PROCEDURE.md`](UPDATE_PROCEDURE.md). In short: `just release` bumps
the version, rolls the CHANGELOG, tags, and pushes; the tag triggers a build
matrix that attaches one NIF per target to a GitHub release; checksums are
regenerated from those artifacts; Hex publish is gated behind a manual approval.

## License

MIT — see [LICENSE](LICENSE). pdfium itself is BSD-3-Clause (Google/Chromium);
the precompiled pdfium binaries come from
[bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries).
