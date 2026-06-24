defmodule ExPdfium do
  @moduledoc """
  Elixir bindings for [pdfium](https://pdfium.googlesource.com/pdfium/), Google's
  Chromium PDF engine, via the Rust [`pdfium-render`](https://github.com/ajrcarey/pdfium-render)
  crate. The native library ships **precompiled** (`rustler_precompiled`), so
  there is no Rust toolchain or separately-installed pdfium to set up.

  > #### Scaffold {: .warning}
  > This module is a skeleton. The functions delegate to NIFs that are not
  > implemented yet — see `PORTING.md` for the staged plan. Phase 0 (prove the
  > static-link + precompiled-release path) comes first.

  ## Example (target API)

      {:ok, doc} = ExPdfium.open("file.pdf")
      {:ok, 3} = ExPdfium.page_count(doc)
      {:ok, %ExPdfium.Bitmap{data: data, width: w, height: h}} =
        ExPdfium.render_page(doc, 0, dpi: 300)
      {:ok, image} = Vix.Vips.Image.new_from_binary(data, w, h, 4, :VIPS_FORMAT_UCHAR)
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

  Options:
    * `:password` — for encrypted PDFs (default `nil`)
  """
  @spec open(Path.t() | binary(), keyword()) :: {:ok, Document.t()} | {:error, term()}
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

  @doc "Number of pages in the document."
  @spec page_count(Document.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def page_count(%Document{ref: ref}), do: Native.document_page_count(ref)

  @doc """
  Render a 0-indexed page to an `ExPdfium.Bitmap`.

  Sizing options (provide one): `:dpi` (e.g. `300`), `:scale`, or `:width`/`:height`.
  """
  @spec render_page(Document.t(), non_neg_integer(), keyword()) ::
          {:ok, Bitmap.t()} | {:error, term()}
  def render_page(%Document{ref: ref}, page_index, opts \\ []) do
    case Native.document_render_page(ref, page_index, Map.new(opts)) do
      {:ok, {data, w, h, stride, format}} ->
        {:ok, %Bitmap{data: data, width: w, height: h, stride: stride, format: format}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Explicitly close a document, releasing pdfium memory early. Optional — documents
  are also closed when garbage-collected. Idempotent.
  """
  @spec close(Document.t()) :: :ok
  def close(%Document{ref: ref}), do: Native.document_close(ref)
end
