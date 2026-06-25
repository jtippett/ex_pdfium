defmodule ExPdfium.Bitmap do
  @moduledoc """
  A raw pixel bitmap — produced by `ExPdfium.render_page/3` (a rendered page) or
  `ExPdfium.image_data/3` (a decoded embedded image).

  `data` is a raw pixel buffer. `format` records the byte order and channel count
  so consumers can interpret it: `:rgba`/`:bgra` (4 channels), `:bgrx` (4, with a
  padding byte), `:bgr` (3), or `:gray` (1). `render_page/3` yields `:rgba`
  (default) or `:bgra`; an image decoded with `image_data/3` keeps its native
  pdfium format. With `width`, `height`, and `stride` (bytes per row), the buffer
  feeds directly into e.g. `Vix.Vips.Image.new_from_binary/5` — or use `to_vix/1`,
  which reads `format` and hands back a correctly-interpreted image (band count +
  BGR→RGB), so you don't have to branch on the channel order yourself.
  """

  @enforce_keys [:data, :width, :height, :stride, :format]
  defstruct [:data, :width, :height, :stride, :format]

  @type format :: :rgba | :bgra | :bgrx | :bgr | :gray
  @type t :: %__MODULE__{
          data: binary(),
          width: non_neg_integer(),
          height: non_neg_integer(),
          stride: non_neg_integer(),
          format: format()
        }

  # Vix is an optional dependency (see mix.exs). The module is referenced only
  # inside to_vix/1, guarded at runtime — suppress the "undefined module" warnings
  # for builds where Vix isn't present (incl. our --warnings-as-errors CI).
  @compile {:no_warn_undefined, [Vix.Vips.Image, Vix.Vips.Operation]}

  @doc """
  Convert this bitmap into a correctly-interpreted `Vix.Vips.Image`.

  Reads `format` so the caller doesn't have to: it sets the right band count and
  reorders pdfium's native **BGR** channel order into **RGB** (`:bgr`, `:bgrx`,
  `:bgra`), drops the padding byte of `:bgrx`, and passes `:rgba`/`:gray` straight
  through. Row `stride` padding is stripped first. The result is ready for the rest
  of a `Vix`/`Image` pipeline (resize, `Image.write_to_file/2`, …):

      {:ok, bmp} = ExPdfium.image_data(doc, 0, 2)
      {:ok, img} = ExPdfium.Bitmap.to_vix(bmp)
      :ok = Vix.Vips.Image.write_to_file(img, "out.png")

  `Vix` is an **optional dependency**. If it isn't in your project, this returns
  `{:error, :vix_not_loaded}` (add `{:vix, "~> 0.39"}` to your deps). Returns
  `{:error, :vix_failed}` if libvips rejects the buffer.
  """
  @spec to_vix(t()) :: {:ok, struct()} | {:error, :vix_not_loaded | :vix_failed}
  def to_vix(%__MODULE__{} = bitmap) do
    if Code.ensure_loaded?(Vix.Vips.Image) do
      build_vix(bitmap)
    else
      {:error, :vix_not_loaded}
    end
  end

  defp build_vix(%__MODULE__{data: data, width: w, height: h, stride: stride, format: fmt}) do
    bands = band_count(fmt)
    packed = strip_stride(data, w, h, stride, bands)

    case Vix.Vips.Image.new_from_binary(packed, w, h, bands, :VIPS_FORMAT_UCHAR) do
      {:ok, img} -> reorder(img, fmt)
      {:error, _} -> {:error, :vix_failed}
    end
  rescue
    _ -> {:error, :vix_failed}
  end

  defp band_count(:gray), do: 1
  defp band_count(:bgr), do: 3
  defp band_count(_four), do: 4

  # Channel indices that put pdfium's order into R, G, B[, A]. :rgba/:gray are
  # already correct, so they skip the reorder entirely.
  defp reorder(img, fmt) when fmt in [:rgba, :gray], do: {:ok, img}

  defp reorder(img, fmt) do
    order =
      case fmt do
        :bgr -> [2, 1, 0]
        :bgrx -> [2, 1, 0]
        :bgra -> [2, 1, 0, 3]
      end

    bands = Enum.map(order, &Vix.Vips.Operation.extract_band!(img, &1))

    case Vix.Vips.Operation.bandjoin(bands) do
      {:ok, out} -> {:ok, out}
      {:error, _} -> {:error, :vix_failed}
    end
  end

  # pdfium uses a 4-byte-aligned row stride; drop any per-row padding so the buffer
  # is exactly width*bands per row before handing it to libvips.
  defp strip_stride(data, w, h, stride, bands) do
    row = w * bands

    if stride == row do
      data
    else
      for r <- 0..(h - 1)//1, into: <<>>, do: binary_part(data, r * stride, row)
    end
  end
end
