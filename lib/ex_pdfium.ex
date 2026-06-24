defmodule ExPdfium do
  @moduledoc """
  Elixir bindings for [pdfium](https://pdfium.googlesource.com/pdfium/), Google's
  Chromium PDF engine, via the Rust [`pdfium-render`](https://github.com/ajrcarey/pdfium-render)
  crate. The native library ships **precompiled** (`rustler_precompiled`), so
  there is no Rust toolchain or separately-installed pdfium to set up.

  > #### Work in progress {: .info}
  > Opening documents, page counts, rendering, and text extraction/search work
  > today. Metadata and structure are landing phase by phase — see `PORTING.md`.
  > Functions for unimplemented phases raise until then.

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
end
