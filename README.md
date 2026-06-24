# ExPdfium

Elixir bindings for [pdfium](https://pdfium.googlesource.com/pdfium/) — Google's
Chromium PDF engine — via the Rust
[`pdfium-render`](https://github.com/ajrcarey/pdfium-render) crate, shipped as a
**precompiled NIF** with [`rustler_precompiled`](https://hexdocs.pm/rustler_precompiled).

No Rust toolchain. No separately-installed pdfium. Add the dep and go.

> **Status: scaffold.** Nothing is implemented yet. This repo is set up to be
> built out by following [`PORTING.md`](PORTING.md). The sections below describe
> the *target* API.

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

## Usage (target API)

```elixir
{:ok, doc} = ExPdfium.open("file.pdf")          # or open(<<"%PDF...">> = bytes)
{:ok, n}   = ExPdfium.page_count(doc)

{:ok, %ExPdfium.Bitmap{data: data, width: w, height: h}} =
  ExPdfium.render_page(doc, 0, dpi: 300)

# Hand the raw buffer straight to Vix/Image:
{:ok, image} = Vix.Vips.Image.new_from_binary(data, w, h, 4, :VIPS_FORMAT_UCHAR)
Image.write(image, "page.png")
```

Documents are closed automatically on garbage collection; call
`ExPdfium.close/1` to release pdfium memory early.

## Development

The shipped NIF links pdfium **statically**. For local work, the default build
binds pdfium **dynamically** — download a `libpdfium` once and point the tests at
it:

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
