# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html) (against *our* API,
not pdfium-render's).

## [Unreleased]

## 0.4.0 - 2026-06-25

### Added
- **`ExPdfium.chars/2`** (read): char-level text extraction — every glyph on a
  page as `%{char, bounds, font_size}`, in content-stream order (same as
  `extract_text/2`). The primitive for layout analysis (line/word grouping, column
  detection, reading order), where `text_segments/2`'s line/phrase runs are too
  coarse and can span a column gutter. `bounds` is pdfium's loose (advance-cell)
  box — consistent per-line heights — or `nil`; `font_size` is the scaled size in
  points (the standard heading-vs-body signal). pdfium's synthesized inter-word
  whitespace is included, with `bounds: nil` or a degenerate box.

## 0.3.3 - 2026-06-25

### Added
- **`ExPdfium.Bitmap.to_vix/1`**: convert a `Bitmap` straight into a
  correctly-interpreted `Vix.Vips.Image` — it reads `format`, sets the band count,
  reorders pdfium's native **BGR** order into **RGB** (`:bgr`/`:bgrx`/`:bgra`),
  drops the `:bgrx` padding byte, and strips row-stride padding, so callers stop
  branching on `.format` and getting the R↔B swap wrong. `Vix` is an **optional
  dependency** (not pulled in transitively); without it the function returns
  `{:error, :vix_not_loaded}`.
- **`ExPdfium.bounds_to_pixels/3`** (read): convert any `t:ExPdfium.bounds/0`
  (PDF points, origin bottom-left, `y`-up) into raster pixel coordinates (origin
  top-left, `y`-down) at a given DPI — the points→pixels scale plus the Y-flip that
  every overlay of `text_segments/2`/`search_text/3`/`links/2`/`annotations/2`/
  `images/2` boxes needs and that is easy to get silently wrong. Returns
  `%{left, top, right, bottom}` in pixels.
- **`ExPdfium.open_file/2` and `ExPdfium.open_blob/2`** (read): explicit
  path-only / bytes-only document openers, removing the source-kind guessing
  `open/2`'s `"%PDF"` heuristic does (which is ambiguous for PDFs with junk bytes
  before the header, or paths that begin with `"%PDF"`). `open/2` stays as the
  convenience.
- **`ExPdfium.parse_pdf_date/1`** (read): parse a PDF date string (as `metadata/1`
  returns, e.g. `"D:20210812004758+01'00'"`) into a UTC `DateTime`. Handles `Z` /
  `±HH'mm'` offsets and truncated forms; `{:error, :invalid_date}` otherwise.
- **`ExPdfium.object_display_rotation/3`** (read): the clockwise rotation in
  degrees to apply to an extracted image in a **top-left-origin raster library**
  (Vix/libvips, Pillow, ImageMagick) so it appears upright as displayed —
  `object_display_matrix/3`'s rotation already converted out of PDF's y-up frame.
  For a plain scanned page it equals `page_info/2`'s `:rotation`.

### Changed
- **Documented the y-up vs y-down handedness trap** on `object_display_matrix/3`
  and `t:ExPdfium.matrix/0`: the matrix is PDF space (origin bottom-left, `y` up),
  so a rotation angle read from it and applied directly in a y-down raster library
  comes out 180° wrong on 90°/270° pages (it cancels at 0°/180°, so it looks fine
  on unrotated docs). Negate the angle, `y`-flip the image, or use
  `object_display_rotation/3`.

## 0.3.2 - 2026-06-25

### Added
- **`ExPdfium.object_display_matrix/3`** (read): the composed **content→display**
  transform for a page object — its content-space `:matrix` multiplied by the
  page-level `/Rotate` — as a single `t:ExPdfium.matrix/0`. This is the transform
  to orient an extracted image as it appears on the page (e.g. turn a native-res
  `image_raw_data/3` JPEG the right way up for OCR) without re-rendering. The
  library hands you the transform as **data** — it deliberately does not rotate
  pixels (that belongs in your image pipeline). Pure Elixir; rotation direction is
  verified against rendered pages for all of 0/90/180/270.

### Changed
- **Clarified the `:matrix` orientation story** on `page_objects/2`, `images/2`,
  and `t:ExPdfium.matrix/0`: the matrix is in the page's **unrotated content
  space** and does **not** carry the page-level `/Rotate` (the usual rotation for
  scanned pages). For the as-displayed orientation, compose it with
  `page_info/2`'s `:rotation` — whose `:width`/`:height` are already
  display-oriented, a different coordinate frame. Docs only; no API change.

## 0.3.1 - 2026-06-25

### Added
- **Object transformation matrix** (read): `page_objects/2` and `images/2` now
  include a `:matrix` key — the object's `[a b c d e f]` transform as
  `t:ExPdfium.matrix/0` (`%{a:, b:, c:, d:, e:, f:}`), or `nil` if pdfium can't
  report it. It maps an image's unit square onto the page in content space, so a
  caller can recover the transform baked into the object (scale, plus any
  object-level rotation/flip) without re-rendering. (Note: this is content space,
  not display space — compose with `page_info/2`'s `:rotation` for the page-level
  `/Rotate`; see the 0.3.2 doc clarification.) Additive and backwards-compatible.

## 0.3.0 - 2026-06-25

### Added
- **Annotation authoring** (write): create annotations on a page.
  - `ExPdfium.add_text_annotation/5` (sticky note: icon + popup contents),
    `add_free_text_annotation/5` (a visible text box), `add_square_annotation/4`
    (rectangle box with fill/stroke), and `add_link_annotation/5` (clickable URI).
  - `ExPdfium.delete_annotation/3` removes an annotation by its 0-based page index.
  - Rectangles take a `t:ExPdfium.bounds/0` map (`%{left:, bottom:, right:, top:}`),
    matching what `annotations/2` reads back. The text-markup family
    (highlight/underline/strikeout/squiggly) is intentionally deferred: pdfium's own
    renderer does not display them without an explicit appearance stream it will not
    auto-generate.
- **Flatten** (write): `ExPdfium.flatten_page/2` and `flatten/1` bake a page's (or
  the whole document's) annotations and form fields into static page content, so
  they render identically everywhere and can no longer be edited as annotations.
- **Signatures** (read): `ExPdfium.signatures/1` returns the document's digital
  signatures as `%{reason, signing_date, bytes}` (the raw PKCS#7 `/Contents`; the
  signer identity lives inside `bytes`). Unsigned documents return `{:ok, []}`.
- **Render refinements & thumbnails**:
  - `ExPdfium.render_page/3` gains `:grayscale`, `:annotations`, and `:form_fields`
    toggles (annotations/form fields render by default).
  - `ExPdfium.thumbnails/2` renders one small `ExPdfium.Bitmap` per page (defaults
    to `width: 200`), accepting the same options as `render_page/3`.
- **Document creation** (write): build PDFs from scratch.
  - `ExPdfium.new/0` (empty document) and `ExPdfium.add_page/3` (named sizes
    `:letter`/`:a4`/… or `{w, h}` points; `at:` to insert).
  - `ExPdfium.draw_text/5` (Standard-14 fonts, size, color), `draw_rectangle/4`,
    `draw_line/5`, `draw_circle/5` (fill/stroke/width), and `draw_image/4` (place an
    `ExPdfium.Bitmap`; pdfium is BGRA-native, so `:rgba`/`:rgbx` are R↔B swapped
    automatically — any Bitmap from `render_page/3`, `image_data/3`, or Vix works).
  - Coordinates are PDF points (origin bottom-left); colors are `{r,g,b}`/`{r,g,b,a}`.
- **Comprehensive document metadata**: `ExPdfium.metadata/1` now also returns
  document-level properties alongside the `/Info` dictionary — `:version` (the PDF
  version, e.g. `"1.7"`, or `nil`), `:page_count`, and `:page_mode` (the catalog
  `/PageMode`: `:none` / `:outline` / `:thumbnails` / `:fullscreen` /
  `:optional_content` / `:attachments` / `:unset`). (Custom `/Info` keys and XMP
  metadata remain out of reach — pdfium exposes no API for either.)
- **Image & object extraction** (read):
  - `ExPdfium.page_objects/2` → every object on a page, typed (`:text` / `:path` /
    `:image` / `:shading` / `:form` / `:unsupported`) with bounds and an index.
  - `ExPdfium.images/2` → image objects with intrinsic size, bits-per-pixel, and
    PDF stream `filters` (e.g. `["DCTDecode"]`).
  - `ExPdfium.image_data/3` → decoded pixels as an `%ExPdfium.Bitmap{}` (native
    channel order: `:gray` / `:bgr` / `:bgrx` / `:bgra`).
  - `ExPdfium.image_raw_data/3` → the original encoded stream (a `"DCTDecode"`
    image's bytes are a ready JPEG).
  - `ExPdfium.Bitmap`'s `format` type now also covers `:bgrx`, `:bgr`, and `:gray`
    (image extraction); `render_page/3` still yields `:rgba`/`:bgra`.
- **Writing — page assembly & save** (v0.3, reopening the write scope that was
  out of scope through v0.2):
  - `ExPdfium.save_to_bytes/1` and `save_to_file/2` — full save (`FPDF_SaveAsCopy`)
    that leaves the document open for further edits.
  - `ExPdfium.append/2` — merge: copy all of another document's pages onto the end.
  - `ExPdfium.extract_pages/2` — build a new document from selected pages, in any
    order (the split/subset primitive).
  - `ExPdfium.delete_pages/2` — delete a page index or an inclusive range.
  - `ExPdfium.rotate_page/3` — set a page's absolute rotation (0/90/180/270).
  - In-place mutators return `{:ok, doc}` (the same handle) so they thread through
    `with`/pipelines; `extract_pages/2` returns `{:ok, new_doc}`. All writes are
    serialized through the same global pdfium lock as reads. New error atoms:
    `:same_document`, `:empty_selection`, `:cannot_delete_all_pages`, `:bad_range`,
    `:bad_rotation`, `:save_failed`, and the operation-failure atoms
    `:create_failed` / `:copy_failed` / `:append_failed` / `:delete_failed`.

## 0.2.0 - 2026-06-25

### Added
- Phase 6 — forms & annotations (read), completing the read-only scope:
  - `ExPdfium.form_type/1` → `:none` | `:acrobat` | `:xfa_full` | `:xfa_foreground`.
  - `ExPdfium.form_fields/1` → AcroForm fields, one entry per widget across all
    pages (`%{name, type, value, checked, read_only, required, page, bounds}`).
    For checkbox/radio groups, `value` is the group's selected on-state and
    `checked` flags the selected widget (pdfium does not expose per-option export
    names). XFA form data is unavailable without a V8-enabled pdfium build.
  - `ExPdfium.annotations/2` → a page's annotations, markup and widget alike
    (`%{type, bounds, contents, name, hidden, printed}`; `type` is the PDF
    `/Subtype`).
- Phase 5 — structure & navigation:
  - `ExPdfium.outline/1` → the bookmark tree (`%{title, page, children}` nodes).
  - `ExPdfium.links/2` → a page's links (`%{bounds, uri, page}`; `uri` for web
    links, `page` for internal destinations).
  - `ExPdfium.attachments/1` → embedded files (`%{index, name, size}`) and
    `ExPdfium.attachment_data/2` → an attachment's bytes.
- Phase 4 — metadata, page geometry & permissions:
  - `ExPdfium.metadata/1` → document info map (title/author/subject/keywords/
    creator/producer/creation_date; `modification_date` is usually `nil`, a
    pdfium-render limitation — see the docs).
  - `ExPdfium.page_info/2` → `%{width, height, rotation, label, boxes}` (size in
    points, rotation in degrees, boundary boxes media/crop/bleed/trim/art).
  - `ExPdfium.permissions/1` → map of 8 boolean permission flags.
- Phase 3 — text extraction & search:
  - `ExPdfium.extract_text/2` (one page) and `extract_text/1` (whole document,
    pages joined by a form feed).
  - `ExPdfium.text_segments/2` returns text runs with per-segment bounding boxes
    (PDF points, origin bottom-left).
  - `ExPdfium.search_text/3,4` with `:match_case` and `:whole_word` options; each
    match carries its text and bounding rects. Empty query → `{:error, :empty_query}`.
- Phase 2 — render a page to a bitmap: `ExPdfium.render_page/3` returns
  `{:ok, %ExPdfium.Bitmap{data, width, height, stride, format}}`, an uncompressed
  4-channel buffer ready for `Vix.Vips.Image.new_from_binary/5`.
  - Sizing by `:dpi` (default 72), `:scale`, or `:width`/`:height`.
  - `:format` `:rgba` (default) or `:bgra`; `:background` `:white` (default) or
    `:transparent`.
  - Errors: `:page_out_of_bounds`, `:document_closed`, `:render_failed`,
    `:unsupported_format`, `:unsupported_background`, `:bad_option`.
  - GC-driven document close is deferred to a dedicated cleanup thread so it never
    blocks a BEAM scheduler while a long render holds the pdfium lock.
- Phase 1 — open documents & page count:
  - `ExPdfium.open/1,2` opens a PDF from a file path or in-memory binary, with an
    optional `:password` for encrypted documents. Returns `{:ok, %ExPdfium.Document{}}`.
  - `ExPdfium.page_count/1` returns `{:ok, n}`.
  - `ExPdfium.close/1` releases the document early (idempotent); documents are
    also closed automatically on garbage collection (no manual-close leak).
  - Errors are mapped from pdfium: `:enoent`, `:invalid_pdf`, `:password_error`,
    `:unsupported_security`, `:file_error`, `:io_error`, `:document_closed`.
  - pdfium is not thread-safe, so all pdfium operations are serialized through a
    single global lock; calls are safe from any number of BEAM processes but run
    one at a time.

## [0.1.0] - 2026-06-24

First release — Phase 0: proves the toolchain and the precompiled-release path
end to end. PDF document/page/text APIs land in later phases (see `PORTING.md`).

### Added
- Project scaffold: `rustler_precompiled` config, tag-driven release pipeline,
  and the porting plan (`PORTING.md`).
- Phase 0 (toolchain): `ExPdfium.pdfium_version/0`, a load-proof NIF that binds
  and initializes pdfium. Pinned `pdfium-render = "=0.8.37"`. The dev/test build
  binds pdfium dynamically; the libpdfium directory is passed to the NIF via a
  `set_dynamic_lib_dir/1` function argument (env vars set with `System.put_env`
  don't reach a NIF).

### Changed
- pdfium-render must be built with the `sync` feature (not just `thread_safe`):
  only `sync` adds the `Send + Sync` impls that let the single global `Pdfium`
  live in a `static`. `release.yml` updated accordingly.
- Pinned pdfium binary tag bumped `chromium/7506` → `chromium/7543` to match the
  pdfium API version pdfium-render 0.8.37 binds (`pdfium_latest`).
- Shipping strategy: the precompiled NIF binds pdfium **dynamically** and bundles
  the dynamic `libpdfium` inside each per-target tarball (rustler_precompiled
  extracts it next to the NIF; the NIF self-locates it via `dladdr`). bblanchon
  ships no static `libpdfium.a`, so static linking isn't used. The optional
  `static`/`libcpp`/`libstdcpp` features remain for a user-supplied `.a`.
