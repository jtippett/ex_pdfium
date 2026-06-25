defmodule ExPdfium do
  @moduledoc """
  Elixir bindings for [pdfium](https://pdfium.googlesource.com/pdfium/), Google's
  Chromium PDF engine, via the Rust [`pdfium-render`](https://github.com/ajrcarey/pdfium-render)
  crate. The native library ships **precompiled** (`rustler_precompiled`), so
  there is no Rust toolchain or separately-installed pdfium to set up.

  > #### Read-only toolkit {: .info}
  > ExPdfium is a **read & extract** toolkit: open documents, page counts,
  > rendering, text extraction/search, metadata, page geometry, permissions,
  > structure (bookmarks/links/attachments), and forms/annotations (read). It
  > does not create, edit, or save PDFs.

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

  @doc """
  Return a marker string confirming the native pdfium library loaded and
  initialized. Useful as a smoke test that the precompiled NIF is healthy.

  pdfium exposes no build-version string through its public C API, so this is a
  fixed confirmation marker rather than a version number.
  """
  @spec pdfium_version() :: String.t()
  def pdfium_version, do: Native.pdfium_version()

  @doc """
  Open a PDF from a file path or an in-memory binary.

  A binary beginning with `"%PDF"` is treated as document bytes; any other binary
  is treated as a file path. (A few PDFs carry junk bytes before the header; pass
  those as an explicit path, or strip the leading bytes.)

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

  defp do_open(source, opts) do
    case Native.document_open(source, opts[:password]) do
      {:ok, ref} -> {:ok, %Document{ref: ref}}
      {:error, _} = err -> err
    end
  end

  @doc """
  Number of pages in the document.

  Returns `{:error, :document_closed}` if the document has been closed with
  `close/1`.
  """
  @spec page_count(Document.t()) ::
          {:ok, non_neg_integer()} | {:error, :document_closed | :lock_poisoned}
  def page_count(%Document{ref: ref}), do: Native.document_page_count(ref)

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

  @doc """
  Extract the plain text of a 0-indexed page.

  Returns `{:error, :document_closed}` or `{:error, :page_out_of_bounds}` as
  appropriate. A page with no text returns `{:ok, ""}`.
  """
  @spec extract_text(Document.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, atom()}
  def extract_text(%Document{ref: ref}, page_index),
    do: Native.document_extract_text(ref, page_index)

  @doc """
  Extract the plain text of the whole document. Pages are joined by a form-feed
  (`"\\f"`) character. Returns `{:error, :document_closed}` if the document has
  been closed.
  """
  @spec extract_text(Document.t()) :: {:ok, String.t()} | {:error, atom()}
  def extract_text(%Document{ref: ref}), do: Native.document_extract_text_all(ref)

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

  @doc """
  Return the document's info-dictionary metadata as a map.

  Every key is present; absent fields are `nil`. Date fields (`:creation_date`,
  `:modification_date`) are raw PDF date strings (e.g. `"D:20240115120000Z"`).

  > #### `:modification_date` caveat {: .warning}
  > pdfium-render reads this from a `"ModificationDate"` tag rather than the
  > PDF-standard `/ModDate` key, so it is `nil` for most real-world documents.

      %{title: "…", author: "…", subject: nil, keywords: nil, creator: "…",
        producer: "…", creation_date: "D:…", modification_date: nil}
  """
  @spec metadata(Document.t()) :: {:ok, %{atom() => String.t() | nil}} | {:error, atom()}
  def metadata(%Document{ref: ref}) do
    case Native.document_metadata(ref) do
      {:ok, pairs} ->
        base = Map.new(@metadata_keys, &{&1, nil})
        {:ok, Enum.into(pairs, base)}

      {:error, _} = err ->
        err
    end
  end

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

  @doc """
  Extract the bytes of the embedded file at `index` (see `attachments/1`).

  Returns `{:error, :attachment_not_found}` for an invalid index, or
  `{:error, :attachment_failed}` if pdfium cannot read the file data.
  """
  @spec attachment_data(Document.t(), non_neg_integer()) ::
          {:ok, binary()} | {:error, atom()}
  def attachment_data(%Document{ref: ref}, index),
    do: Native.document_attachment_data(ref, index)

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

  defp rect_to_map({left, bottom, right, top}),
    do: %{left: left, bottom: bottom, right: right, top: top}

  defp opt_rect(nil), do: nil
  defp opt_rect(rect), do: rect_to_map(rect)
end
