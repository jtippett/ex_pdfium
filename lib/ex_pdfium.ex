defmodule ExPdfium do
  @moduledoc """
  Elixir bindings for [pdfium](https://pdfium.googlesource.com/pdfium/), Google's
  Chromium PDF engine, via the Rust [`pdfium-render`](https://github.com/ajrcarey/pdfium-render)
  crate. The native library ships **precompiled** (`rustler_precompiled`), so
  there is no Rust toolchain or separately-installed pdfium to set up.

  > #### A read & write toolkit {: .info}
  > **Read:** open, render, extract/search text, metadata, page geometry,
  > permissions, structure (bookmarks/links/attachments), forms/annotations, and
  > images & page objects.
  > **Write:** page assembly — merge (`append/2`), split/subset
  > (`extract_pages/2`), `delete_pages/2`, `rotate_page/3`; document creation —
  > `new/0`, `add_page/3`, and `draw_text`/`draw_rectangle`/`draw_line`/
  > `draw_circle`/`draw_image`; annotation authoring — `add_text_annotation/5`,
  > `add_free_text_annotation/5`, `add_square_annotation/4`, `add_link_annotation/5`,
  > `delete_annotation/3`; and `save_to_bytes/1` / `save_to_file/2`.
  > Form-filling and the text-markup annotation family (highlight/underline/…) are
  > arriving in later 0.3.x releases.

  > #### Untrusted input {: .warning}
  > pdfium runs **in-process** as a native library, so a genuine crash in it would
  > take down the BEAM VM (a Rust panic is contained; a native fault is not).
  > ExPdfium validates and bounds caller arguments and capped page-render/image
  > decode sizes, but **extraction returns data proportional to the document's
  > content** — a large (or maliciously compressed) embedded file, image, or
  > signature blob allocates memory proportional to its decoded size. When
  > processing **untrusted PDFs at scale**, run that work behind OS memory limits
  > and/or in an isolated, supervised OS process (e.g. a dedicated, restartable
  > node) rather than relying on per-call caps.

  ## Example

      {:ok, doc} = ExPdfium.open("file.pdf")
      {:ok, 3} = ExPdfium.page_count(doc)

      {:ok, %ExPdfium.Bitmap{data: data, width: w, height: h}} =
        ExPdfium.render_page(doc, 0, dpi: 300)
      {:ok, image} = Vix.Vips.Image.new_from_binary(data, w, h, 4, :VIPS_FORMAT_UCHAR)

      :ok = ExPdfium.close(doc)

      # Encrypted documents:
      {:ok, doc} = ExPdfium.open("secret.pdf", password: "hunter2")
  """

  alias ExPdfium.{Bitmap, Document, Native}

  @doc group: :diagnostics
  @doc """
  Return a marker string confirming the native pdfium library loaded and
  initialized. Useful as a smoke test that the precompiled NIF is healthy.

  pdfium exposes no build-version string through its public C API, so this is a
  fixed confirmation marker rather than a version number.
  """
  @spec pdfium_version() :: String.t()
  def pdfium_version, do: Native.pdfium_version()

  @doc group: :documents
  @doc """
  Open a PDF from a file path or an in-memory binary.

  A binary beginning with `"%PDF"` is treated as document bytes; any other binary
  is treated as a file path. The heuristic is ambiguous at the edges (a PDF with
  junk bytes before the header reads as a path; a path that somehow starts with
  `"%PDF"` reads as bytes) — use `open_file/2` or `open_blob/2` when the source
  kind is known.

  ## Options
    * `:password` — password for an encrypted PDF (default `nil`)

  ## Errors
  Returns `{:error, reason}` where `reason` is one of:
    * `:enoent` — the path does not exist
    * `:invalid_pdf` — the bytes are not a parseable PDF
    * `:password_error` — the document is encrypted and the password was missing
      or incorrect
    * `:unsupported_security` — unsupported encryption/security handler
    * `:file_error` / `:io_error` / `:open_failed` — other read/open failures
    * `:bad_source` — internal: malformed source argument (e.g. a non-UTF-8 path)
  """
  @spec open(Path.t() | binary(), keyword()) :: {:ok, Document.t()} | {:error, atom()}
  def open(path_or_binary, opts \\ [])

  def open(<<"%PDF", _rest::binary>> = bytes, opts),
    do: do_open({:binary, bytes}, opts)

  def open(path, opts) when is_binary(path),
    do: do_open({:path, path}, opts)

  @doc group: :documents
  @doc """
  Open a PDF from a file path, with no source-kind guessing.

  The explicit counterpart to `open/2` for a path (same `:password` option and
  errors). Use this when the argument is always a path — including a path that
  might begin with `"%PDF"`, which `open/2` would misread as document bytes.
  """
  @spec open_file(Path.t(), keyword()) :: {:ok, Document.t()} | {:error, atom()}
  def open_file(path, opts \\ []) when is_binary(path), do: do_open({:path, path}, opts)

  @doc group: :documents
  @doc """
  Open a PDF from an in-memory binary, with no source-kind guessing.

  The explicit counterpart to `open/2` for document bytes (same `:password` option
  and errors). Use this when the argument is always PDF data — including data with
  junk bytes before the `%PDF` header, which `open/2` would misread as a path.
  """
  @spec open_blob(binary(), keyword()) :: {:ok, Document.t()} | {:error, atom()}
  def open_blob(bytes, opts \\ []) when is_binary(bytes), do: do_open({:binary, bytes}, opts)

  defp do_open(source, opts) do
    case Native.document_open(source, opts[:password]) do
      {:ok, ref} -> {:ok, %Document{ref: ref}}
      {:error, _} = err -> err
    end
  end

  @doc group: :documents
  @doc """
  Number of pages in the document.

  Returns `{:error, :document_closed}` if the document has been closed with
  `close/1`.

  > #### 65,535-page limit {: .info}
  > pdfium-render represents page indices as a 16-bit integer, so documents with
  > more than 65,535 pages are not supported and this count wraps (reports
  > `count mod 65536`). Such documents are pathological; if you handle untrusted
  > input that might contain one, treat the page count as unreliable above that
  > bound.
  """
  @spec page_count(Document.t()) ::
          {:ok, non_neg_integer()} | {:error, :document_closed | :lock_poisoned}
  def page_count(%Document{ref: ref}), do: Native.document_page_count(ref)

  @doc group: :rendering
  @doc """
  Render a 0-indexed page to an `ExPdfium.Bitmap` (an uncompressed 4-channel
  pixel buffer).

  ## Options

  Sizing (highest precedence first; the default is `dpi: 72`):
    * `:width` and/or `:height` — output size in pixels (aspect-preserving if only
      one is given)
    * `:scale` — multiple of the natural size (`1.0` == 72 DPI)
    * `:dpi` — dots per inch (e.g. `150`, `300`)

  Other:
    * `:format` — `:rgba` (default) or `:bgra` (pdfium's native order, no conversion)
    * `:background` — `:white` (default) or `:transparent`
    * `:grayscale` — render in grayscale (default `false`). The bitmap is still
      4-channel; the color channels just carry equal gray values.
    * `:annotations` — draw annotations (default `true`); set `false` to render the
      page without its markup/widget overlay
    * `:form_fields` — draw interactive form-field content (default `true`)

  ## Bitmap layout

  `data` is `width * height * 4` bytes, row-major, `stride` (== `width * 4`) bytes
  per row, 8 bits per channel. Hand it straight to `Vix`/`Image`:

      {:ok, %ExPdfium.Bitmap{data: data, width: w, height: h}} =
        ExPdfium.render_page(doc, 0, dpi: 300)
      {:ok, image} = Vix.Vips.Image.new_from_binary(data, w, h, 4, :VIPS_FORMAT_UCHAR)

  ## Errors
    * `:page_out_of_bounds` — no such page index
    * `:document_closed` — the document was closed
    * `:unsupported_format` / `:unsupported_background` — bad option value
    * `:render_failed` — pdfium failed to render the page
  """
  @spec render_page(Document.t(), non_neg_integer(), keyword()) ::
          {:ok, Bitmap.t()} | {:error, atom()}
  def render_page(%Document{ref: ref}, page_index, opts \\ []) do
    case Native.document_render_page(ref, page_index, Map.new(opts)) do
      {:ok, {data, w, h, stride, format}} ->
        {:ok, %Bitmap{data: data, width: w, height: h, stride: stride, format: format}}

      {:error, _} = err ->
        err
    end
  end

  @doc group: :rendering
  @doc """
  Render every page to a small bitmap, returned in page order.

  Takes the same options as `render_page/3` (sizing, `:format`, `:grayscale`, …).
  When no sizing option is given, sizing defaults to `width: 200`. A document with
  no pages returns `{:ok, []}`; if any page fails to render, the first error is
  returned.

      {:ok, thumbs} = ExPdfium.thumbnails(doc, width: 160)
      # => [%ExPdfium.Bitmap{...}, ...]   # one per page
  """
  @spec thumbnails(Document.t(), keyword()) :: {:ok, [Bitmap.t()]} | {:error, atom()}
  def thumbnails(%Document{} = doc, opts \\ []) do
    opts =
      if Enum.any?([:width, :height, :scale, :dpi], &Keyword.has_key?(opts, &1)),
        do: opts,
        else: Keyword.put(opts, :width, 200)

    with {:ok, count} <- page_count(doc) do
      render_each_page(doc, count, opts)
    end
  end

  defp render_each_page(_doc, 0, _opts), do: {:ok, []}

  defp render_each_page(doc, count, opts) do
    Enum.reduce_while(0..(count - 1), {:ok, []}, fn page, {:ok, acc} ->
      case render_page(doc, page, opts) do
        {:ok, bitmap} -> {:cont, {:ok, [bitmap | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, bitmaps} -> {:ok, Enum.reverse(bitmaps)}
      {:error, _} = err -> err
    end
  end

  @typedoc """
  A bounding rectangle in PDF user-space points (1/72 inch). The origin is the
  page's bottom-left corner and `y` increases upward, so `top >= bottom`.
  """
  @type bounds :: %{
          left: float(),
          bottom: float(),
          right: float(),
          top: float()
        }

  @typedoc """
  A page object's transformation matrix, the six values `a, b, c, d, e, f` of the
  PDF `cm` transform `[a b c d e f]`. A point `(x, y)` in the object's own space
  maps to `(a·x + c·y + e, b·x + d·y + f)` on the page.

  These are **PDF coordinates** — origin bottom-left, `y` increasing **up** — so a
  positive `atan2(b, a)` is a *counter-clockwise* rotation. Top-left-origin raster
  libraries (Vix/libvips, Pillow, ImageMagick) are `y`-down, where the same angle
  rotates the other way; negate it (or `y`-flip the image) before applying. See
  `object_display_rotation/3` for the rotation already in raster convention.

  For an image object the matrix maps the unit square `[0,1]×[0,1]` onto the
  placement, so `a`/`d` carry scale, `b`/`c` shear/rotation, and `e`/`f` the
  translation.

  > #### Content space, not display space {: .info}
  > This matrix lives in the page's **unrotated content coordinate space**. It does
  > **not** include the page-level `/Rotate` (the dominant rotation for scanned
  > documents). `page_info/2` reports that separately as `:rotation` (0/90/180/270),
  > and its `:width`/`:height` are already display-oriented — a different frame from
  > this matrix. To get an object's **as-displayed** orientation, compose this matrix
  > with the page rotation; the matrix alone recovers only the transform baked into
  > the object itself.
  """
  @type matrix :: %{
          a: float(),
          b: float(),
          c: float(),
          d: float(),
          e: float(),
          f: float()
        }

  @doc group: :metadata
  @doc """
  Convert a `t:bounds/0` rectangle (PDF points, origin bottom-left, `y` up) into
  **raster pixel** coordinates (origin top-left, `y` down) at the given DPI.

  Every spatial result in this library — `text_segments/2`, `search_text/3`,
  `links/2`, `annotations/2`, `images/2` bounds — is in PDF points. Overlaying any
  of them on a page rastered at some DPI needs the same per-box conversion, and the
  **Y-flip is the step everyone forgets**:

      px = pt_x * dpi / 72
      py = (page_height - pt_y) * dpi / 72   # the flip

  `page_height` is the page height in points (from `page_info/2`'s `:height`). DPI
  defaults to `72` (1 point = 1 pixel). Returns a map with raster-sense keys
  `%{left, top, right, bottom}` (floats; `top < bottom`), aligned with how image
  libraries address pixels:

      {:ok, %{height: h}} = ExPdfium.page_info(doc, 0)
      {:ok, segs} = ExPdfium.text_segments(doc, 0)
      box = ExPdfium.bounds_to_pixels(hd(segs).bounds, h, 150)
      # => %{left: 120.0, top: 95.0, right: 360.0, bottom: 130.0}  # pixels @150dpi

  > #### Assumes an unrotated page {: .info}
  > This applies only the points→pixels scale and the Y-flip. If the page has a
  > `/Rotate` (see `page_info/2`), the rastered image is rotated but these bounds
  > are in unrotated content space, so you must also account for the rotation —
  > the same y-up/raster seam as `object_display_rotation/3`.
  """
  @spec bounds_to_pixels(bounds(), number(), number()) :: %{
          left: float(),
          top: float(),
          right: float(),
          bottom: float()
        }
  def bounds_to_pixels(%{left: l, bottom: b, right: r, top: t}, page_height, dpi \\ 72) do
    s = dpi / 72

    %{
      left: l * s,
      right: r * s,
      top: (page_height - t) * s,
      bottom: (page_height - b) * s
    }
  end

  @doc group: :text
  @doc """
  Extract the plain text of a 0-indexed page.

  Returns `{:error, :document_closed}` or `{:error, :page_out_of_bounds}` as
  appropriate. A page with no text returns `{:ok, ""}`.

  ## Options

    * `:repair` — when set, the raw text is piped through `ExPdfium.Text.repair/2`
      to recover canonical Unicode from legacy font encodings before being
      returned. Accepts `:auto` (or `true`) to run every regime, a list of regime
      ids (`[:thai_pua]`), or a bare regime id (`:thai_pua`, forgiven as a
      single-element list). `nil` or `false` (the default) means no repair — the
      faithful raw extraction is returned. An unknown regime id raises
      `ArgumentError`.

  When `:repair` is set, only the repaired text is returned; the repair report is
  dropped. Call `ExPdfium.Text.repair/2` directly if you need the report.
  """
  @spec extract_text(Document.t(), non_neg_integer(), keyword()) ::
          {:ok, String.t()} | {:error, atom()}
  def extract_text(%Document{ref: ref}, page_index, opts \\ []) do
    with {:ok, raw} <- Native.document_extract_text(ref, page_index) do
      case normalize_repair(Keyword.get(opts, :repair)) do
        :none ->
          {:ok, raw}

        selection ->
          {text, _report} = ExPdfium.Text.repair(raw, regimes: selection)
          {:ok, text}
      end
    end
  end

  # Normalize the friendly :repair sugar into a Text.repair/2 :regimes selection.
  # nil/false => off; true/:auto => auto; a bare regime id => [id] (forgiving the
  # common `repair: :thai_pua` instead of `repair: [:thai_pua]`). Genuinely bad
  # values (unknown ids, strings, maps) are forwarded so Text.repair raises.
  defp normalize_repair(r) when r in [nil, false], do: :none
  defp normalize_repair(r) when r in [true, :auto], do: :auto
  defp normalize_repair(r) when is_list(r), do: r
  defp normalize_repair(r) when is_atom(r), do: [r]
  defp normalize_repair(r), do: r

  @doc group: :text
  @doc """
  Extract the plain text of the whole document. Pages are joined by a form-feed
  (`"\\f"`) character. Returns `{:error, :document_closed}` if the document has
  been closed.

  There is no `:repair` option here (the second argument is reserved for the
  per-page arity). To repair legacy font encodings across a whole document, pipe
  the result through `ExPdfium.Text.repair/2`:

      {:ok, raw} = ExPdfium.extract_text(doc)
      {text, _report} = ExPdfium.Text.repair(raw)
  """
  @spec extract_text(Document.t()) :: {:ok, String.t()} | {:error, atom()}
  def extract_text(%Document{ref: ref}), do: Native.document_extract_text_all(ref)

  @doc group: :text
  @doc """
  Return the page's text as runs (segments), each with its bounding box.

  Each element is `%{text: String.t(), bounds: t:bounds/0}`. Bounds are in PDF
  points (see `t:bounds/0`).
  """
  @spec text_segments(Document.t(), non_neg_integer()) ::
          {:ok, [%{text: String.t(), bounds: bounds()}]} | {:error, atom()}
  def text_segments(%Document{ref: ref}, page_index) do
    case Native.document_text_segments(ref, page_index) do
      {:ok, segments} ->
        {:ok, Enum.map(segments, fn {text, rect} -> %{text: text, bounds: rect_to_map(rect)} end)}

      {:error, _} = err ->
        err
    end
  end

  @doc group: :text
  @doc """
  Return the page's text one **character** at a time, with per-glyph boxes.

  Where `text_segments/2` gives line/phrase-level runs, this gives the underlying
  glyphs — the primitive for layout analysis (line/word grouping, column detection,
  reading order), where a run can be wider than a column gutter and merge columns.

  Each element is:

      %{
        char: String.t(),       # the Unicode character (may be "" if pdfium has none)
        bounds: t:bounds/0 | nil,
        font_size: float(),     # scaled font size, in points
        origin: %{x: float(), y: float()} | nil
      }

  Characters come in **content-stream order** — the same order as `extract_text/2`
  — including the whitespace pdfium synthesizes between words. Those generated
  spaces carry `bounds: nil` (or a degenerate box); use or skip them as you like.

  `bounds` is pdfium's **loose** bound (the glyph advance cell), so per-line glyph
  heights are consistent — what line/word grouping wants — falling back to the
  tight (ink) bound, and `nil` when pdfium reports neither.

  `font_size` is exposed because it's the standard signal for heading/title vs body
  detection: a run-in heading at normal leading is otherwise indistinguishable from
  body text by position alone.

  `origin` is the glyph's **pen position**: `x` is the start of the advance cell and
  `y` is the **text baseline**. The baseline is the canonical anchor for clustering
  glyphs into lines — far more stable than the loose-box bottom, whose advance cell
  runs ~1.4× the font height and makes offset baselines in adjacent columns hard to
  separate. `nil` when pdfium reports no origin (e.g. synthesized whitespace).

  ## Options

    * `:style` — when `true`, each char gains a best-effort `:style` sub-map:

          style: %{
            font_name: String.t(),      # e.g. "Helvetica", "ABCDEE+Calibri-Bold"
            weight: non_neg_integer() | nil,  # numeric font weight (700 ≈ bold)
            bold?: boolean(),
            italic?: boolean(),
            serif?: boolean(),
            fixed_pitch?: boolean()
          }

      This is opt-in because it costs several extra FFI calls per glyph. It is **off
      by default**, and when off the `:style` key is absent entirely (the lean path).

      The booleans derive from the PDF FontDescriptor flags (and weight), which
      pdfium reports **unreliably for non-embedded/built-in fonts** — treat them as
      hints, not ground truth. `font_name` (often carrying a `-Bold`/`-Italic`
      suffix) is the most trustworthy style signal. Use `style: true` to preserve
      emphasis (bold/italic runs carry meaning) through downstream text processing.
  """
  @spec chars(Document.t(), non_neg_integer(), keyword()) ::
          {:ok,
           [
             %{
               :char => String.t(),
               :bounds => bounds() | nil,
               :font_size => float(),
               :origin => %{x: float(), y: float()} | nil,
               optional(:style) => %{
                 font_name: String.t(),
                 weight: non_neg_integer() | nil,
                 bold?: boolean(),
                 italic?: boolean(),
                 serif?: boolean(),
                 fixed_pitch?: boolean()
               }
             }
           ]}
          | {:error, atom()}
  def chars(%Document{ref: ref}, page_index, opts \\ []) do
    with_style = Keyword.get(opts, :style, false) == true

    case Native.document_text_chars(ref, page_index, with_style) do
      {:ok, chars} ->
        {:ok, Enum.map(chars, &char_map/1)}

      {:error, _} = err ->
        err
    end
  end

  @doc group: :text
  @doc """
  Search a page for `query`, returning the matches.

  Each match is `%{text: String.t(), rects: [t:bounds/0]}` — a match can span more
  than one rect when it wraps across lines.

  ## Options
    * `:match_case` — case-sensitive (default `false`)
    * `:whole_word` — match whole words only (default `false`)

  An empty `query` returns `{:error, :empty_query}`.
  """
  @spec search_text(Document.t(), non_neg_integer(), String.t(), keyword()) ::
          {:ok, [%{text: String.t(), rects: [bounds()]}]} | {:error, atom()}
  def search_text(%Document{ref: ref}, page_index, query, opts \\ []) do
    match_case = Keyword.get(opts, :match_case, false)
    whole_word = Keyword.get(opts, :whole_word, false)

    case Native.document_search_text(ref, page_index, query, match_case, whole_word) do
      {:ok, matches} ->
        {:ok,
         Enum.map(matches, fn {text, rects} ->
           %{text: text, rects: Enum.map(rects, &rect_to_map/1)}
         end)}

      {:error, _} = err ->
        err
    end
  end

  @metadata_keys ~w(title author subject keywords creator producer creation_date
                    modification_date)a

  @doc group: :metadata
  @doc """
  Return the document's metadata: the `/Info` dictionary plus document-level
  properties, as one map.

      %{
        # /Info dictionary — each key always present, absent fields nil
        title: "…", author: "…", subject: nil, keywords: nil,
        creator: "…", producer: "…",
        creation_date: "D:20240115120000Z",  # raw PDF date string — parse_pdf_date/1
        modification_date: nil,
        # document-level properties — always present
        version: "1.7",                       # PDF version, or nil if undeclared
        page_count: 12,
        page_mode: :none                      # how viewers should open it (below)
      }

  `:page_mode` is the catalog `/PageMode`: `:none`, `:outline` (show bookmarks),
  `:thumbnails`, `:fullscreen`, `:optional_content` (layers panel),
  `:attachments`, or `:unset`.

  > #### Limits of pdfium's metadata {: .info}
  > These are the only metadata pdfium exposes. Two things are **not** reachable
  > through it: custom/non-standard `/Info` keys (pdfium can't enumerate dictionary
  > keys, and only the eight standard ones are queryable), and **XMP** metadata
  > (the `/Metadata` XML stream) — pdfium has no XMP API.

  > #### `:modification_date` caveat {: .warning}
  > pdfium-render reads this from a `"ModificationDate"` tag rather than the
  > PDF-standard `/ModDate` key, so it is `nil` for most real-world documents.
  """
  @spec metadata(Document.t()) :: {:ok, map()} | {:error, atom()}
  def metadata(%Document{ref: ref}) do
    case Native.document_metadata(ref) do
      {:ok, {pairs, version, page_count, page_mode}} ->
        info = Enum.into(pairs, Map.new(@metadata_keys, &{&1, nil}))

        {:ok, Map.merge(info, %{version: version, page_count: page_count, page_mode: page_mode})}

      {:error, _} = err ->
        err
    end
  end

  @doc group: :metadata
  @doc """
  Parse a PDF date string (as `metadata/1` returns) into a `DateTime`.

  PDF dates look like `"D:20210812004758+01'00'"` —
  `D:YYYYMMDDHHmmSS` followed by a timezone (`Z`, or `±HH'mm'`). Everything after
  the year is optional and defaults to its lowest value (month/day `01`, time
  `00:00:00`, offset UTC). The result is normalized to **UTC**; a missing offset is
  treated as UTC.

      {:ok, ~U[2021-08-11 23:47:58Z]} = ExPdfium.parse_pdf_date("D:20210812004758+01'00'")
      {:ok, meta} = ExPdfium.metadata(doc)
      {:ok, created} = ExPdfium.parse_pdf_date(meta.creation_date)

  Returns `{:error, :invalid_date}` for `nil`, an unparseable string, or
  out-of-range components.
  """
  @spec parse_pdf_date(String.t() | nil) :: {:ok, DateTime.t()} | {:error, :invalid_date}
  def parse_pdf_date("D:" <> rest), do: parse_pdf_date(rest)

  def parse_pdf_date(str) when is_binary(str) do
    re =
      ~r/^\s*(\d{4})(\d{2})?(\d{2})?(\d{2})?(\d{2})?(\d{2})?(?:([Zz+\-])(\d{2})?'?(\d{2})?'?)?/

    case Regex.run(re, str) do
      # Regex.run drops trailing groups that didn't participate; pad back to 9.
      [_ | parts] -> build_pdf_datetime(parts ++ List.duplicate("", 9 - length(parts)))
      nil -> {:error, :invalid_date}
    end
  end

  def parse_pdf_date(_), do: {:error, :invalid_date}

  @doc group: :metadata
  @doc """
  Geometry of a 0-indexed page: size (points), rotation (degrees), label, and the
  boundary boxes.

      %{
        width: 612.0, height: 792.0,
        rotation: 0,           # 0 | 90 | 180 | 270
        label: nil,            # page label string, if any
        boxes: %{media: %{left: 0.0, bottom: 0.0, right: 612.0, top: 792.0},
                 crop: nil, bleed: nil, trim: nil, art: nil}
      }

  Each boundary box is a `t:bounds/0` (PDF points) or `nil` when not defined.
  Most documents define only a media box, so `crop`/`bleed`/`trim`/`art` are
  commonly `nil` (pdfium does not fall back to the media box).
  """
  @spec page_info(Document.t(), non_neg_integer()) :: {:ok, map()} | {:error, atom()}
  def page_info(%Document{ref: ref}, page_index) do
    case Native.document_page_info(ref, page_index) do
      {:ok, {width, height, rotation, label, {media, crop, bleed, trim, art}}} ->
        {:ok,
         %{
           width: width,
           height: height,
           rotation: rotation,
           label: label,
           boxes: %{
             media: opt_rect(media),
             crop: opt_rect(crop),
             bleed: opt_rect(bleed),
             trim: opt_rect(trim),
             art: opt_rect(art)
           }
         }}

      {:error, _} = err ->
        err
    end
  end

  @doc group: :metadata
  @doc """
  Return the document's permission flags as a map of booleans.

  Keys: `:print_high_quality`, `:print_low_quality`, `:assemble`,
  `:modify_content`, `:extract_text_and_graphics`, `:fill_form_fields`,
  `:create_form_fields`, `:annotate`. An unencrypted document permits everything.

  Returns `{:error, :unsupported_security}` for documents whose security handler
  pdfium can't interpret (e.g. AES-256 / PDF 2.0 encryption) — rather than
  reporting a misleading all-`false` set.
  """
  @spec permissions(Document.t()) :: {:ok, %{atom() => boolean()}} | {:error, atom()}
  def permissions(%Document{ref: ref}) do
    case Native.document_permissions(ref) do
      {:ok, pairs} -> {:ok, Map.new(pairs)}
      {:error, _} = err -> err
    end
  end

  @doc group: :metadata
  @doc """
  Read the document's digital signatures.

  Each is `%{reason: String.t() | nil, signing_date: String.t() | nil, bytes:
  binary()}` — the signature's `/Reason`, its date string, and the raw `/Contents`
  (the PKCS#7/CMS signature blob). The **signer's identity and the signing
  certificate live inside `bytes`** (a PKCS#7 structure); pdfium does not expose
  them separately, so parse `bytes` with a CMS/PKCS#7 library if you need them.
  An unsigned document returns `{:ok, []}`.
  """
  @spec signatures(Document.t()) :: {:ok, [map()]} | {:error, atom()}
  def signatures(%Document{ref: ref}) do
    case Native.document_signatures(ref) do
      {:ok, sigs} ->
        {:ok,
         Enum.map(sigs, fn {reason, signing_date, bytes} ->
           %{reason: reason, signing_date: signing_date, bytes: bytes}
         end)}

      {:error, _} = err ->
        err
    end
  end

  @doc group: :structure
  @doc """
  Return the document outline (bookmarks) as a nested tree.

  Each node is `%{title: String.t(), page: non_neg_integer() | nil, children:
  [node]}`, where `page` is the 0-indexed destination page (or `nil`). A document
  with no outline returns `{:ok, []}`.

  `page` is `nil` for a bookmark whose target is a GoTo *action* rather than a
  `/Dest`. The tree is capped (depth 64, 50_000 nodes) to bound pathological or
  cyclic outlines; beyond that it is silently truncated.
  """
  @spec outline(Document.t()) :: {:ok, [map()]} | {:error, atom()}
  def outline(%Document{ref: ref}), do: Native.document_outline(ref)

  @doc group: :structure
  @doc """
  Return the links on a 0-indexed page.

  Each link is `%{bounds: t:bounds/0 | nil, uri: String.t() | nil, page:
  non_neg_integer() | nil}` — `uri` for a web link, `page` for an internal
  `/Dest` destination. `bounds` is `nil` if the link has no rectangle; `uri` and
  `page` are both `nil` for an unsupported or action-based link.
  """
  @spec links(Document.t(), non_neg_integer()) ::
          {:ok, [%{bounds: bounds() | nil, uri: String.t() | nil, page: non_neg_integer() | nil}]}
          | {:error, atom()}
  def links(%Document{ref: ref}, page_index) do
    case Native.document_links(ref, page_index) do
      {:ok, links} ->
        {:ok,
         Enum.map(links, fn {bounds, uri, page} ->
           %{bounds: opt_rect(bounds), uri: uri, page: page}
         end)}

      {:error, _} = err ->
        err
    end
  end

  @doc group: :structure
  @doc """
  List the document's embedded files.

  Each is `%{index: non_neg_integer(), name: String.t(), size: non_neg_integer()}`.
  Use `attachment_data/2` with the `index` to extract the bytes.
  """
  @spec attachments(Document.t()) ::
          {:ok, [%{index: non_neg_integer(), name: String.t(), size: non_neg_integer()}]}
          | {:error, atom()}
  def attachments(%Document{ref: ref}) do
    case Native.document_attachments(ref) do
      {:ok, list} ->
        {:ok,
         list
         |> Enum.with_index()
         |> Enum.map(fn {{name, size}, index} -> %{index: index, name: name, size: size} end)}

      {:error, _} = err ->
        err
    end
  end

  @doc group: :structure
  @doc """
  Extract the bytes of the embedded file at `index` (see `attachments/1`).

  Returns `{:error, :attachment_not_found}` for an invalid index,
  `{:error, :attachment_failed}` if pdfium cannot read the file data, or
  `{:error, :attachment_too_large}` if the **decoded** file exceeds a safety cap
  (embedded files are stored compressed, so a small PDF can decode to a much
  larger file — see the "Untrusted input" note on the module).
  """
  @spec attachment_data(Document.t(), non_neg_integer()) ::
          {:ok, binary()} | {:error, atom()}
  def attachment_data(%Document{ref: ref}, index),
    do: Native.document_attachment_data(ref, index)

  @doc group: :forms
  @doc """
  Return which interactive-form technology the document uses.

  One of `:none`, `:acrobat` (a classic AcroForm), `:xfa_full`, or
  `:xfa_foreground` (XFA forms). A document with no form returns `{:ok, :none}`.

  > #### XFA caveat {: .warning}
  > Reading XFA form data requires a pdfium build with the V8 JavaScript engine,
  > which ExPdfium does not ship. `form_fields/1` reads AcroForm fields; for an
  > `:xfa_full` document the AcroForm view may be empty or partial.
  """
  @spec form_type(Document.t()) ::
          {:ok, :none | :acrobat | :xfa_full | :xfa_foreground} | {:error, atom()}
  def form_type(%Document{ref: ref}), do: Native.document_form_type(ref)

  @doc group: :forms
  @doc """
  Read the document's AcroForm fields, one entry per widget, across all pages.

  Each field is:

      %{
        name: String.t() | nil,   # the field's /T name
        type: :text | :checkbox | :radio_button | :combo_box | :list_box |
              :push_button | :signature | :unknown,
        value: String.t() | nil,  # text/combo/list value, or the selected on-state of a button group
        checked: boolean() | nil, # checkbox/radio only; nil for other types
        read_only: boolean(),
        required: boolean(),
        page: non_neg_integer(),  # 0-indexed page the widget sits on
        bounds: t:bounds/0 | nil
      }

  A checkbox or radio group shares one `name` across its option widgets, so it
  surfaces as **one entry per option widget**. For these, `value` is the group's
  *currently-selected* on-state (the same string on every widget in the group),
  and `checked` flags which widget is the selected one — so to find a radio
  group's answer, take the `value` of the entry whose `checked` is `true`. A
  document with no form returns `{:ok, []}`.

  `value` and `checked` are read straight from pdfium without coercion: a
  checked checkbox is `%{value: "Yes", checked: true}`, never flattened to a
  string.

  > #### Limitations {: .info}
  > * This reads a group's *selected* value, not its available options — pdfium
  >   does not expose per-option export names for checkbox/radio groups. A naive
  >   `Map.new(fields, &{&1.name, &1.value})` collapses a group to one entry; to
  >   find a group's answer, take the `value` of the entry whose `checked` is `true`.
  > * A multi-select list box reports only pdfium's single `value` string, so
  >   additional selections beyond the first are not surfaced.
  """
  @spec form_fields(Document.t()) :: {:ok, [map()]} | {:error, atom()}
  def form_fields(%Document{ref: ref}) do
    case Native.document_form_fields(ref) do
      {:ok, fields} ->
        {:ok,
         Enum.map(fields, fn {name, type, value, checked, read_only, required, {page, bounds}} ->
           %{
             name: name,
             type: type,
             value: value,
             checked: checked,
             read_only: read_only,
             required: required,
             page: page,
             bounds: opt_rect(bounds)
           }
         end)}

      {:error, _} = err ->
        err
    end
  end

  @doc group: :forms
  @doc """
  Return the annotations on a 0-indexed page, in page order.

  Each annotation is:

      %{
        type: atom(),                # the PDF /Subtype, e.g. :text, :highlight,
                                     # :link, :widget, :ink, :stamp, :free_text…
        bounds: t:bounds/0 | nil,    # the annotation rectangle, in PDF points
        contents: String.t() | nil,  # the /Contents text
        name: String.t() | nil,      # the annotation's /NM name (not a field name)
        hidden: boolean(),
        printed: boolean()
      }

  Widget annotations (form-field controls) are listed alongside markup
  annotations; use `form_fields/1` to read their field values. A page with no
  annotations returns `{:ok, []}`.
  """
  @spec annotations(Document.t(), non_neg_integer()) :: {:ok, [map()]} | {:error, atom()}
  def annotations(%Document{ref: ref}, page_index) do
    case Native.document_annotations(ref, page_index) do
      {:ok, anns} ->
        {:ok,
         Enum.map(anns, fn {type, bounds, contents, name, hidden, printed} ->
           %{
             type: type,
             bounds: opt_rect(bounds),
             contents: contents,
             name: name,
             hidden: hidden,
             printed: printed
           }
         end)}

      {:error, _} = err ->
        err
    end
  end

  @doc group: :extraction
  @doc """
  List every object on a 0-indexed page, in page order.

  Each object is `%{index: non_neg_integer(), type: atom(), bounds: t:bounds/0 |
  nil, matrix: t:matrix/0 | nil}`, where `type` is one of `:text`, `:path`,
  `:image`, `:shading`, `:form` (an XObject form), or `:unsupported`. `index` is
  the object's position in the page's object list — pass it to `image_data/3` /
  `image_raw_data/3`. It is valid only until the document is mutated (a write op
  can shift object indices).

  `matrix` is the object's transformation matrix (see `t:matrix/0`); it is `nil`
  only if pdfium cannot report it.
  """
  @spec page_objects(Document.t(), non_neg_integer()) :: {:ok, [map()]} | {:error, atom()}
  def page_objects(%Document{ref: ref}, page_index) do
    case Native.document_page_objects(ref, page_index) do
      {:ok, objects} ->
        {:ok,
         Enum.map(objects, fn {index, type, bounds, matrix} ->
           %{index: index, type: type, bounds: opt_rect(bounds), matrix: opt_matrix(matrix)}
         end)}

      {:error, _} = err ->
        err
    end
  end

  @doc group: :extraction
  @doc """
  List the image objects on a 0-indexed page, with how each is stored.

  Each is:

      %{
        index: non_neg_integer(),         # object index, for image_data/3
        width: non_neg_integer(),         # intrinsic image width, in pixels
        height: non_neg_integer(),        # intrinsic image height, in pixels
        bits_per_pixel: non_neg_integer(),
        filters: [String.t()],            # PDF stream filters, e.g. ["DCTDecode"]
        bounds: t:bounds/0 | nil,         # where it sits on the page, in points
        matrix: t:matrix/0 | nil          # placement transform (scale/rotation/flip)
      }

  `width`/`height` are pdfium's reported pixel dimensions (a `0` means pdfium
  couldn't read it), and `index` is valid only until the document is mutated.

  Use `image_data/3` to get decoded pixels, or `image_raw_data/3` for the original
  encoded bytes — `filters` tells you the encoding (a `"DCTDecode"` raw stream is a
  ready JPEG; `"FlateDecode"` is zlib-compressed samples, not a standalone file).

  `matrix` is the image's placement transform (see `t:matrix/0`). Because it maps
  the unit square onto the page, a caller can recover the transform baked into the
  image object — scale, plus any object-level rotation or flip — without
  re-rendering.

  > #### Orientation needs the page rotation too {: .warning}
  > The matrix is in **content space** and does not carry the page-level `/Rotate`,
  > which is the usual rotation for scanned pages. For the **as-displayed**
  > orientation, compose this matrix with `page_info/2`'s `:rotation`. (Note also
  > that `page_info/2`'s `:width`/`:height` are already display-oriented, a
  > different frame from this matrix — easy to conflate.) Using the object matrix
  > alone will leave a `/Rotate`-rotated scan turned the wrong way.
  >
  > `object_display_matrix/3` does this composition for you, returning the
  > content→display transform directly.
  """
  @spec images(Document.t(), non_neg_integer()) :: {:ok, [map()]} | {:error, atom()}
  def images(%Document{ref: ref}, page_index) do
    case Native.document_images(ref, page_index) do
      {:ok, images} ->
        {:ok,
         Enum.map(images, fn {index, width, height, bpp, filters, bounds, matrix} ->
           %{
             index: index,
             width: width,
             height: height,
             bits_per_pixel: bpp,
             filters: filters,
             bounds: opt_rect(bounds),
             matrix: opt_matrix(matrix)
           }
         end)}

      {:error, _} = err ->
        err
    end
  end

  @doc group: :extraction
  @doc """
  Decode the image object at `object_index` (see `page_objects/2` / `images/2`) to
  a pixel bitmap.

  Returns `{:ok, %ExPdfium.Bitmap{}}`. Unlike `render_page/3` (always 4-channel),
  an extracted image keeps its native channel order — `format` is `:gray` (1
  channel), `:bgr` (3), or `:bgrx` / `:bgra` (4) — so check it before handing
  `data` to an image library.

  These are the image's **raw stored samples**: image masks (soft/stencil) and
  object transforms are not applied, so a masked image comes back without its
  transparency, and the bitmap size may differ from `images/2`'s reported
  dimensions. For the composited, as-displayed result, render the page with
  `render_page/3` instead.

  Errors: `:object_not_found` (no object at that index), `:not_an_image` (the
  object isn't an image), `:image_too_large` (the image's declared pixel count
  exceeds a safety cap, so it isn't decoded), `:page_out_of_bounds`,
  `:image_failed`.
  """
  @spec image_data(Document.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, Bitmap.t()} | {:error, atom()}
  def image_data(%Document{ref: ref}, page_index, object_index) do
    case Native.document_image_data(ref, page_index, object_index) do
      {:ok, {data, width, height, stride, format}} ->
        {:ok, %Bitmap{data: data, width: width, height: height, stride: stride, format: format}}

      {:error, _} = err ->
        err
    end
  end

  @doc group: :extraction
  @doc """
  Return the original, still-encoded stream of the image object at `object_index`.

  This is the image exactly as stored, with its PDF filters **not** applied: for a
  `"DCTDecode"` image the bytes are a ready-to-write JPEG; for `"FlateDecode"`
  they are zlib-compressed samples, not a standalone image file. Check `filters`
  from `images/2` to know which. For always-decodable pixels, use `image_data/3`.

  Errors: `:object_not_found`, `:not_an_image`, `:page_out_of_bounds`,
  `:image_failed`.
  """
  @spec image_raw_data(Document.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, atom()}
  def image_raw_data(%Document{ref: ref}, page_index, object_index),
    do: Native.document_image_raw_data(ref, page_index, object_index)

  @doc group: :extraction
  @doc """
  The composed **content→display** transformation matrix for a 0-indexed object on
  a 0-indexed page.

  `page_objects/2` and `images/2` give an object's `:matrix` in the page's
  *unrotated content space*. This composes that matrix with the page-level
  `/Rotate` (from `page_info/2`), returning the single `t:matrix/0` that maps the
  object's own space straight to **display** coordinates (origin bottom-left of the
  page as shown, `y` up). `object_index` is the same index `page_objects/2` /
  `images/2` report.

  That is exactly the transform needed to orient an extracted image as it appears
  on the page — e.g. to turn a native-resolution `image_raw_data/3` JPEG the right
  way up for OCR — composing the object's own scale/rotation/flip with the page
  rotation, without re-rendering.

  This library deliberately does **not** rotate pixels for you (that is image
  processing best left to your image pipeline); it hands you the transform as data.
  Apply it in `Vix`/`Image`, or read the rotation off it to pass an orientation
  hint to your OCR engine.

  > #### This matrix is PDF y-up — raster libraries are y-down {: .warning}
  > These values are in PDF space: origin **bottom-left**, `y` increasing **up**, so
  > a positive `atan2(b, a)` is a *counter-clockwise* angle. Raster libraries
  > (Vix/libvips, Pillow, ImageMagick) put the origin **top-left** with `y` going
  > **down**, where the same numeric angle rotates the *opposite* way. Deriving an
  > angle here and applying it directly turns 90°/270° pages 180° the wrong way
  > (it cancels at 0°/180°, so it looks fine on unrotated docs). Negate the angle
  > (or flip the image in `y`) first — or just call `object_display_rotation/3`,
  > which returns the clockwise degrees already in raster convention.

  Returns `{:error, :object_not_found}` if there is no such object, or
  `{:error, :no_matrix}` if pdfium could not report the object's matrix.

  > #### Discrete page rotation only {: .info}
  > The page-rotation part covers PDF `/Rotate` (0/90/180/270). Any sub-90°
  > rotation or skew lives in the object matrix itself and is preserved exactly in
  > the composition.
  """
  @spec object_display_matrix(Document.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, matrix()} | {:error, atom()}
  def object_display_matrix(%Document{} = doc, page_index, object_index) do
    with {:ok, objects} <- page_objects(doc, page_index),
         {:ok, obj} <- fetch_object(objects, object_index),
         {:ok, info} <- page_info(doc, page_index) do
      case obj.matrix do
        nil -> {:error, :no_matrix}
        m -> {:ok, compose_display_matrix(m, info)}
      end
    end
  end

  @doc group: :extraction
  @doc """
  The clockwise rotation, in degrees, to apply to an extracted image in a
  **top-left-origin raster library** (Vix/libvips, Pillow, ImageMagick) so it
  appears upright, as the page displays it.

  This is the raster-convention companion to `object_display_matrix/3`. That
  matrix is in PDF space (origin bottom-left, `y` up); raster libraries put the
  origin top-left with `y` increasing downward, which **inverts the rotation
  sense**. So an angle read straight off the PDF matrix (`atan2(b, a)`) and handed
  to a raster library comes out 180° wrong on 90°/270° pages — and, because it
  cancels at 0°/180°, passes casual testing on unrotated documents. This function
  returns the already-converted clockwise angle, normalized to `[0, 360)`.

      {:ok, raw} = ExPdfium.image_raw_data(doc, 0, 0)
      {:ok, deg} = ExPdfium.object_display_rotation(doc, 0, 0)
      {:ok, img} = Image.from_binary(raw)
      {:ok, upright} = Image.rotate(img, deg)   # Vips is clockwise; upright as on the page

  For a plain scanned page — a single full-page image, rotated only by the page
  `/Rotate` — this equals `page_info/2`'s `:rotation`. It captures **rotation
  only**: any flip or skew carried in the object matrix is not reducible to an
  angle, so use `object_display_matrix/3` for the full transform in that case.

  Returns `{:error, :object_not_found}` or `{:error, :no_matrix}` exactly as
  `object_display_matrix/3` does.
  """
  @spec object_display_rotation(Document.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, float()} | {:error, atom()}
  def object_display_rotation(%Document{} = doc, page_index, object_index) do
    with {:ok, m} <- object_display_matrix(doc, page_index, object_index) do
      # PDF space is y-up (positive angle = counter-clockwise); raster space is
      # y-down (positive = clockwise). Negate the matrix-derived angle to convert.
      deg = -:math.atan2(m.b, m.a) * 180.0 / :math.pi()
      {:ok, normalize_degrees(deg)}
    end
  end

  @page_sizes %{
    letter: {612.0, 792.0},
    legal: {612.0, 1008.0},
    tabloid: {792.0, 1224.0},
    a3: {841.89, 1190.55},
    a4: {595.28, 841.89},
    a5: {419.53, 595.28}
  }

  @doc group: :creation
  @doc """
  Create a new, empty in-memory PDF document. Add pages with `add_page/3` and
  content with the `draw_*` functions, then `save_to_bytes/1` / `save_to_file/2`.
  """
  @spec new() :: {:ok, Document.t()} | {:error, atom()}
  def new do
    case Native.document_new() do
      {:ok, ref} -> {:ok, %Document{ref: ref}}
      {:error, _} = err -> err
    end
  end

  @doc group: :creation
  @doc """
  Add a blank page to `doc`.

  `size` is a named paper size (`:letter`, `:legal`, `:tabloid`, `:a3`, `:a4`,
  `:a5`) or `{width, height}` in PDF points. By default the page is appended; pass
  `at: index` to insert it at a 0-based position (an index past the end appends).
  Returns `{:ok, doc}`, or `{:error, :bad_page_size}` for an unrecognized `size`.
  """
  @spec add_page(Document.t(), atom() | {number(), number()}, keyword()) ::
          {:ok, Document.t()} | {:error, atom()}
  def add_page(doc, size, opts \\ [])

  def add_page(%Document{ref: ref} = doc, size, opts) do
    case page_size(size) do
      {:ok, {w, h}} ->
        wrap(doc, Native.document_add_page(ref, w * 1.0, h * 1.0, Keyword.get(opts, :at, -1)))

      :error ->
        {:error, :bad_page_size}
    end
  end

  @doc group: :creation
  @doc """
  Draw `text` with its baseline starting at `{x, y}` (PDF points, bottom-left
  origin) on a 0-indexed page.

  ## Options
    * `:font` — a Standard-14 font atom: `:helvetica`, `:helvetica_bold`,
      `:helvetica_oblique`, `:helvetica_bold_oblique`, `:times_roman`,
      `:times_bold`, `:times_italic`, `:times_bold_italic`, `:courier`,
      `:courier_bold`, `:courier_oblique`, `:courier_bold_oblique`, `:symbol`,
      `:zapf_dingbats` (default `:helvetica`). An unknown font → `:unknown_font`.
    * `:size` — font size in points (default `12`)
    * `:color` — `{r, g, b}` or `{r, g, b, a}`, 0–255 (default black)
  """
  @spec draw_text(Document.t(), non_neg_integer(), {number(), number()}, String.t(), keyword()) ::
          {:ok, Document.t()} | {:error, atom()}
  def draw_text(%Document{ref: ref} = doc, page, {x, y}, text, opts \\ []) do
    font = opts |> Keyword.get(:font, :helvetica) |> Atom.to_string()
    size = Keyword.get(opts, :size, 12)
    color = normalize_color(Keyword.get(opts, :color, {0, 0, 0}))

    wrap(
      doc,
      Native.document_draw_text(ref, page, x * 1.0, y * 1.0, text, font, size * 1.0, color)
    )
  end

  @doc group: :creation
  @doc """
  Draw a rectangle covering the `t:bounds/0` rectangle on a 0-indexed page.

  ## Options
    * `:fill` — fill color `{r,g,b}`/`{r,g,b,a}`, or `nil` for no fill (default `nil`)
    * `:stroke` — outline color, or `nil` for no outline (default `nil`)
    * `:stroke_width` — outline width in points (default `1`)
  """
  @spec draw_rectangle(Document.t(), non_neg_integer(), bounds(), keyword()) ::
          {:ok, Document.t()} | {:error, atom()}
  def draw_rectangle(%Document{ref: ref} = doc, page, %{} = bounds, opts \\ []) do
    %{left: l, bottom: b, right: r, top: t} = bounds
    sw = Keyword.get(opts, :stroke_width, 1)

    wrap(
      doc,
      Native.document_draw_rectangle(
        ref,
        page,
        l * 1.0,
        b * 1.0,
        r * 1.0,
        t * 1.0,
        normalize_color(Keyword.get(opts, :fill)),
        normalize_color(Keyword.get(opts, :stroke)),
        sw * 1.0
      )
    )
  end

  @doc group: :creation
  @doc """
  Draw a straight line from `{x1, y1}` to `{x2, y2}` on a 0-indexed page.

  ## Options
    * `:stroke` — line color (default black)
    * `:stroke_width` — line width in points (default `1`)
  """
  @spec draw_line(
          Document.t(),
          non_neg_integer(),
          {number(), number()},
          {number(), number()},
          keyword()
        ) :: {:ok, Document.t()} | {:error, atom()}
  def draw_line(%Document{ref: ref} = doc, page, {x1, y1}, {x2, y2}, opts \\ []) do
    stroke = normalize_color(Keyword.get(opts, :stroke, {0, 0, 0}))
    sw = Keyword.get(opts, :stroke_width, 1)

    wrap(
      doc,
      Native.document_draw_line(
        ref,
        page,
        x1 * 1.0,
        y1 * 1.0,
        x2 * 1.0,
        y2 * 1.0,
        stroke,
        sw * 1.0
      )
    )
  end

  @doc group: :creation
  @doc """
  Draw a circle of `radius` centered at `{cx, cy}` on a 0-indexed page.

  ## Options
    * `:fill` — fill color, or `nil` (default `nil`)
    * `:stroke` — outline color, or `nil` (default `nil`)
    * `:stroke_width` — outline width in points (default `1`)
  """
  @spec draw_circle(Document.t(), non_neg_integer(), {number(), number()}, number(), keyword()) ::
          {:ok, Document.t()} | {:error, atom()}
  def draw_circle(%Document{ref: ref} = doc, page, {cx, cy}, radius, opts \\ []) do
    sw = Keyword.get(opts, :stroke_width, 1)

    wrap(
      doc,
      Native.document_draw_circle(
        ref,
        page,
        cx * 1.0,
        cy * 1.0,
        radius * 1.0,
        normalize_color(Keyword.get(opts, :fill)),
        normalize_color(Keyword.get(opts, :stroke)),
        sw * 1.0
      )
    )
  end

  @doc group: :creation
  @doc """
  Place a decoded image (an `ExPdfium.Bitmap`) into the `:at` rectangle on a
  0-indexed page, scaling it to fill those bounds.

  The bitmap is the same struct `render_page/3` and `image_data/3` produce, so you
  can place a rendered page or an extracted image; to place a file, decode it to
  pixels first (e.g. with Vix — see the README). pdfium stores images in BGR order
  and ExPdfium handles the byte-order conversion, so `:rgba`, `:bgra`, `:bgrx`,
  `:bgr`, and `:gray` bitmaps all work.

  ## Options
    * `:at` — the `t:bounds/0` rectangle to fill (required; left/bottom should be
      the lower-left corner — inverted bounds mirror the image)

  A bitmap whose `data` length doesn't match `width * height * channels` returns
  `{:error, :bad_image_data}`.
  """
  @spec draw_image(Document.t(), non_neg_integer(), Bitmap.t(), keyword()) ::
          {:ok, Document.t()} | {:error, atom()}
  def draw_image(%Document{ref: ref} = doc, page, %Bitmap{} = bitmap, opts) do
    %{left: l, bottom: b, right: r, top: t} = Keyword.fetch!(opts, :at)

    wrap(
      doc,
      Native.document_draw_image(
        ref,
        page,
        bitmap.data,
        bitmap.width,
        bitmap.height,
        Atom.to_string(bitmap.format),
        l * 1.0,
        b * 1.0,
        r * 1.0,
        t * 1.0
      )
    )
  end

  @doc group: :annotations
  @doc """
  Add a text (sticky-note) annotation at a point, in PDF points (bottom-left origin).

  The note shows as an icon at `{x, y}`; `text` is its popup contents, returned by
  `annotations/2` as `:contents`. `:color` (default `{255, 230, 0}`) sets the icon
  color. Returns `{:ok, doc}`.
  """
  @spec add_text_annotation(
          Document.t(),
          non_neg_integer(),
          {number(), number()},
          String.t(),
          keyword()
        ) :: {:ok, Document.t()} | {:error, atom()}
  def add_text_annotation(%Document{ref: ref} = doc, page, {x, y}, text, opts \\ []) do
    color = normalize_color(Keyword.get(opts, :color, {255, 230, 0}))
    wrap(doc, Native.document_add_text_annotation(ref, page, x * 1.0, y * 1.0, text, color))
  end

  @doc group: :annotations
  @doc """
  Add a free-text annotation: a visible text box inside `bounds`.

  `bounds` is a `t:bounds/0` map (`%{left:, bottom:, right:, top:}`, PDF points).
  `:fill` sets the box's interior background and `:stroke` its border (each a
  color or `nil`, default `nil`). Returns `{:ok, doc}`.

  > #### Text color {: .info}
  >
  > The text itself renders in pdfium's default appearance (black). Setting the
  > FreeText font color needs an FFI entry point (`FPDFAnnot_SetFontColor`) that
  > the bundled pdfium build does not expose, so no text-color option is offered.
  > For colored text, draw it with `draw_text/5` instead.
  """
  @spec add_free_text_annotation(
          Document.t(),
          non_neg_integer(),
          bounds(),
          String.t(),
          keyword()
        ) :: {:ok, Document.t()} | {:error, atom()}
  def add_free_text_annotation(%Document{ref: ref} = doc, page, %{} = bounds, text, opts \\ []) do
    %{left: l, bottom: b, right: r, top: t} = bounds

    wrap(
      doc,
      Native.document_add_free_text_annotation(
        ref,
        page,
        l * 1.0,
        b * 1.0,
        r * 1.0,
        t * 1.0,
        text,
        normalize_color(Keyword.get(opts, :fill)),
        normalize_color(Keyword.get(opts, :stroke))
      )
    )
  end

  @doc group: :annotations
  @doc """
  Add a square (rectangle) annotation filling `bounds`.

  `bounds` is a `t:bounds/0` map (PDF points). `:fill` is the interior color
  (default `nil`, transparent) and `:stroke` the border color (default
  `{0, 0, 0}`). Returns `{:ok, doc}`.
  """
  @spec add_square_annotation(Document.t(), non_neg_integer(), bounds(), keyword()) ::
          {:ok, Document.t()} | {:error, atom()}
  def add_square_annotation(%Document{ref: ref} = doc, page, %{} = bounds, opts \\ []) do
    %{left: l, bottom: b, right: r, top: t} = bounds

    wrap(
      doc,
      Native.document_add_square_annotation(
        ref,
        page,
        l * 1.0,
        b * 1.0,
        r * 1.0,
        t * 1.0,
        normalize_color(Keyword.get(opts, :fill)),
        normalize_color(Keyword.get(opts, :stroke, {0, 0, 0}))
      )
    )
  end

  @doc group: :annotations
  @doc """
  Add a link annotation covering `bounds` that opens `uri` when clicked.

  `bounds` is a `t:bounds/0` map (PDF points). The link reads back via
  `links/2`. Returns `{:ok, doc}`.
  """
  @spec add_link_annotation(Document.t(), non_neg_integer(), bounds(), String.t(), keyword()) ::
          {:ok, Document.t()} | {:error, atom()}
  def add_link_annotation(%Document{ref: ref} = doc, page, %{} = bounds, uri, _opts \\ []) do
    %{left: l, bottom: b, right: r, top: t} = bounds

    wrap(
      doc,
      Native.document_add_link_annotation(ref, page, l * 1.0, b * 1.0, r * 1.0, t * 1.0, uri)
    )
  end

  @doc group: :annotations
  @doc """
  Delete the annotation at 0-based `index` on a 0-indexed page.

  The index matches the order returned by `annotations/2`. Returns `{:ok, doc}`,
  or `{:error, :annotation_not_found}` if the index is out of range.
  """
  @spec delete_annotation(Document.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, Document.t()} | {:error, atom()}
  def delete_annotation(%Document{ref: ref} = doc, page, index) do
    wrap(doc, Native.document_delete_annotation(ref, page, index))
  end

  @doc group: :writing
  @doc """
  Serialize the document to PDF bytes.

  A full save (pdfium's `FPDF_SaveAsCopy`) reflecting any edits made via the
  writing functions. It does **not** close or alter `doc`, so you can keep
  editing and save again. Returns `{:error, :document_closed}` if the document
  has been closed, or `{:error, :save_failed}` if pdfium cannot serialize it.

  The whole document is buffered in memory (there is no streaming save), so peak
  usage is roughly the document size; this is fine for typical PDFs.
  """
  @spec save_to_bytes(Document.t()) :: {:ok, binary()} | {:error, atom()}
  def save_to_bytes(%Document{ref: ref}), do: Native.document_save(ref)

  @doc group: :writing
  @doc """
  Save the document to a file at `path`.

  Equivalent to `save_to_bytes/1` followed by `File.write/2`. Returns `:ok`, or
  `{:error, reason}` — either a document error (e.g. `:document_closed`) or a
  `File.write/2` posix reason (e.g. `:enoent`, `:eacces`).
  """
  @spec save_to_file(Document.t(), Path.t()) :: :ok | {:error, atom()}
  def save_to_file(%Document{} = doc, path) do
    case save_to_bytes(doc) do
      {:ok, bytes} -> File.write(path, bytes)
      {:error, _} = err -> err
    end
  end

  @doc group: :writing
  @doc """
  Append a copy of every page of `source` onto the end of `doc` (merge).

  Mutates `doc` in place and returns `{:ok, doc}` (the same handle). `source` is
  not modified. Appending a document to itself returns `{:error, :same_document}`.
  Returns `{:error, :document_closed}` if either document is closed.
  """
  @spec append(Document.t(), Document.t()) :: {:ok, Document.t()} | {:error, atom()}
  def append(%Document{ref: dest_ref} = doc, %Document{ref: source_ref}),
    do: wrap(doc, Native.document_append(dest_ref, source_ref))

  @doc group: :writing
  @doc """
  Build a **new** document from the given 0-indexed pages of `source`.

  `indices` is a list of page indices in the desired output order; duplicates are
  allowed (e.g. `[2, 0, 0, 1]`). This is the split/subset primitive — splitting a
  document is a few `extract_pages/2` calls. `source` is left untouched, and the
  returned document is independent (close/GC it separately).

  Returns `{:error, :empty_selection}` for an empty list, or
  `{:error, :page_out_of_bounds}` if any index is out of range (validated before
  any page is copied, so no partial document is produced).
  """
  @spec extract_pages(Document.t(), [non_neg_integer()]) ::
          {:ok, Document.t()} | {:error, atom()}
  def extract_pages(%Document{ref: ref}, indices) when is_list(indices) do
    case Native.document_extract_pages(ref, indices) do
      {:ok, new_ref} -> {:ok, %Document{ref: new_ref}}
      {:error, _} = err -> err
    end
  end

  @doc group: :writing
  @doc """
  Delete a page, or an inclusive range of pages, from `doc`.

  Pass a single 0-indexed page (`delete_pages(doc, 3)`) or an **inclusive,
  ascending, unit-step** range (`delete_pages(doc, 2..4)` deletes pages 2, 3, and
  4). Mutates `doc` in place and returns `{:ok, doc}`.

  Errors:
    * `:page_out_of_bounds` — the index/range falls outside the document
    * `:cannot_delete_all_pages` — the range would remove every page (a zero-page
      document is degenerate); extract what you want with `extract_pages/2` instead
    * `:bad_range` — a descending or non-unit-step range (e.g. `4..2` or `0..6//2`);
      these are rejected rather than silently reinterpreted
  """
  @spec delete_pages(Document.t(), non_neg_integer() | Range.t()) ::
          {:ok, Document.t()} | {:error, atom()}
  def delete_pages(%Document{ref: ref} = doc, index) when is_integer(index) and index >= 0,
    do: wrap(doc, Native.document_delete_pages(ref, index, index))

  def delete_pages(%Document{ref: ref} = doc, %Range{first: first, last: last, step: 1})
      when first >= 0 and last >= 0,
      do: wrap(doc, Native.document_delete_pages(ref, first, last))

  def delete_pages(%Document{}, %Range{}), do: {:error, :bad_range}

  @doc group: :writing
  @doc """
  Set a page's absolute rotation, in degrees.

  `degrees` must be `0`, `90`, `180`, or `270`; anything else returns
  `{:error, :bad_rotation}`. Mutates `doc` in place and returns `{:ok, doc}`. The
  rotation persists through `save_to_bytes/1` / `save_to_file/2`.
  """
  @spec rotate_page(Document.t(), non_neg_integer(), 0 | 90 | 180 | 270) ::
          {:ok, Document.t()} | {:error, atom()}
  def rotate_page(%Document{ref: ref} = doc, page_index, degrees)
      when is_integer(page_index) and page_index >= 0 and is_integer(degrees),
      do: wrap(doc, Native.document_rotate_page(ref, page_index, degrees))

  @doc group: :writing
  @doc """
  Flatten a 0-indexed page's annotations and form fields into its static content.

  After flattening, the annotation/form overlay is baked into the page and renders
  identically everywhere (and can no longer be edited as annotations). pdfium uses
  the *print* appearance. A page with nothing to flatten is a no-op. Mutates `doc`
  in place; returns `{:ok, doc}`.
  """
  @spec flatten_page(Document.t(), non_neg_integer()) :: {:ok, Document.t()} | {:error, atom()}
  def flatten_page(%Document{ref: ref} = doc, page_index),
    do: wrap(doc, Native.document_flatten_page(ref, page_index))

  @doc group: :writing
  @doc """
  Flatten every page (see `flatten_page/2`). Returns `{:ok, doc}`.
  """
  @spec flatten(Document.t()) :: {:ok, Document.t()} | {:error, atom()}
  def flatten(%Document{ref: ref} = doc), do: wrap(doc, Native.document_flatten(ref))

  @doc group: :documents
  @doc """
  Explicitly close a document, releasing pdfium memory early. Optional and
  idempotent.

  Documents are also closed when garbage-collected, but that close is processed
  asynchronously (on a background thread, so it can't stall a scheduler while a
  long render holds the pdfium lock). Call this for deterministic, immediate
  release.
  """
  @spec close(Document.t()) :: :ok
  def close(%Document{ref: ref}), do: Native.document_close(ref)

  # In-place write ops return `:ok` from the NIF (encoded as `{:ok, :ok}`); thread
  # the original handle back as `{:ok, doc}`, and pass errors through unchanged.
  defp wrap(doc, {:ok, _}), do: {:ok, doc}
  defp wrap(_doc, {:error, _} = err), do: err

  defp page_size({w, h}) when is_number(w) and is_number(h), do: {:ok, {w, h}}

  defp page_size(name) when is_atom(name) do
    case Map.fetch(@page_sizes, name) do
      {:ok, wh} -> {:ok, wh}
      :error -> :error
    end
  end

  defp page_size(_), do: :error

  defp normalize_color(nil), do: nil
  defp normalize_color({r, g, b}), do: {r, g, b, 255}
  defp normalize_color({_r, _g, _b, _a} = color), do: color

  defp rect_to_map({left, bottom, right, top}),
    do: %{left: left, bottom: bottom, right: right, top: top}

  defp opt_rect(nil), do: nil
  defp opt_rect(rect), do: rect_to_map(rect)

  defp opt_origin(nil), do: nil
  defp opt_origin({x, y}), do: %{x: x, y: y}

  defp char_map({char, rect, size, origin, style}) do
    base = %{char: char, bounds: opt_rect(rect), font_size: size, origin: opt_origin(origin)}

    case style do
      nil ->
        base

      {name, weight, bold?, italic?, serif?, fixed?} ->
        Map.put(base, :style, %{
          font_name: name,
          weight: weight,
          bold?: bold?,
          italic?: italic?,
          serif?: serif?,
          fixed_pitch?: fixed?
        })
    end
  end

  defp opt_matrix(nil), do: nil

  defp opt_matrix({a, b, c, d, e, f}),
    do: %{a: a, b: b, c: c, d: d, e: e, f: f}

  defp fetch_object(objects, index) do
    case Enum.find(objects, &(&1.index == index)) do
      nil -> {:error, :object_not_found}
      obj -> {:ok, obj}
    end
  end

  # Compose an object's content-space matrix with the page's /Rotate to get the
  # object→display transform. PDF matrices use the row-vector convention
  # ([x y 1]·M), so the content→display product is `object · rotation`.
  defp compose_display_matrix(m, info) do
    {ox, oy, w, h} = content_box(info)
    mat_to_map(mat_mul(map_to_mat(m), rotation_matrix(info.rotation, ox, oy, w, h)))
  end

  # The page's unrotated content box as {origin_x, origin_y, width, height}. The
  # media box is already in content space; fall back to display dims un-swapped by
  # the rotation when it's absent.
  defp content_box(%{boxes: %{media: %{left: l, bottom: b, right: r, top: t}}}),
    do: {l, b, r - l, t - b}

  defp content_box(%{width: w, height: h, rotation: rot}) do
    if rem(rot, 180) == 0, do: {0.0, 0.0, w, h}, else: {0.0, 0.0, h, w}
  end

  # Content→display rotation as a PDF matrix, for a content box at (ox, oy) of size
  # (w, h). Translates the box origin to (0,0), then rotates clockwise by /Rotate so
  # the result lands in the displayed page's positive quadrant. (Direction verified
  # against a rendered, rotated page — see the test suite.)
  defp rotation_matrix(rot, ox, oy, w, h) do
    t = {1.0, 0.0, 0.0, 1.0, -ox, -oy}

    rot =
      case rem(rem(round(rot), 360) + 360, 360) do
        0 -> {1.0, 0.0, 0.0, 1.0, 0.0, 0.0}
        90 -> {0.0, -1.0, 1.0, 0.0, 0.0, w}
        180 -> {-1.0, 0.0, 0.0, -1.0, w, h}
        270 -> {0.0, 1.0, -1.0, 0.0, h, 0.0}
        # Non-multiple-of-90 /Rotate is invalid per spec; treat as no rotation.
        _ -> {1.0, 0.0, 0.0, 1.0, 0.0, 0.0}
      end

    mat_mul(t, rot)
  end

  defp map_to_mat(%{a: a, b: b, c: c, d: d, e: e, f: f}), do: {a, b, c, d, e, f}
  defp mat_to_map({a, b, c, d, e, f}), do: %{a: a, b: b, c: c, d: d, e: e, f: f}

  # Wrap a degree value into [0, 360).
  defp normalize_degrees(deg) do
    r = :math.fmod(deg, 360.0)
    if r < 0.0, do: r + 360.0, else: r
  end

  # Build a UTC DateTime from PDF-date regex parts [Y, Mo, D, H, Mi, S, sign, OH, OM]
  # (unmatched optional groups are ""). The naive local time is shifted to UTC by
  # its offset; a missing offset is treated as UTC.
  defp build_pdf_datetime([y, mo, d, h, mi, s, sign, oh, om]) do
    with {:ok, naive} <-
           NaiveDateTime.new(
             to_int(y, 0),
             to_int(mo, 1),
             to_int(d, 1),
             to_int(h, 0),
             to_int(mi, 0),
             to_int(s, 0)
           ) do
      offset = pdf_offset_seconds(sign, oh, om)
      {:ok, DateTime.add(DateTime.from_naive!(naive, "Etc/UTC"), -offset, :second)}
    else
      _ -> {:error, :invalid_date}
    end
  end

  defp to_int("", default), do: default
  defp to_int(s, _default), do: String.to_integer(s)

  defp pdf_offset_seconds(sign, oh, om) when sign in ["+", "-"] do
    secs = to_int(oh, 0) * 3600 + to_int(om, 0) * 60
    if sign == "-", do: -secs, else: secs
  end

  defp pdf_offset_seconds(_sign, _oh, _om), do: 0

  # Multiply two PDF matrices in the row-vector convention: result = A · B, so a
  # point transformed by the result is `(p · A) · B`.
  defp mat_mul({aa, ab, ac, ad, ae, af}, {ba, bb, bc, bd, be, bf}) do
    {
      aa * ba + ab * bc,
      aa * bb + ab * bd,
      ac * ba + ad * bc,
      ac * bb + ad * bd,
      ae * ba + af * bc + be,
      ae * bb + af * bd + bf
    }
  end
end
