defmodule ExPdfium.Bitmap do
  @moduledoc """
  A rendered page bitmap.

  `data` is a raw pixel buffer. pdfium renders natively as **BGRA** (8 bits per
  channel); `format` records the actual byte order so consumers can convert. With
  `width`, `height`, and `stride` (bytes per row), the buffer feeds directly into
  e.g. `Vix.Vips.Image.new_from_binary/5`.
  """

  @enforce_keys [:data, :width, :height, :stride, :format]
  defstruct [:data, :width, :height, :stride, :format]

  @type format :: :bgra | :rgba
  @type t :: %__MODULE__{
          data: binary(),
          width: non_neg_integer(),
          height: non_neg_integer(),
          stride: non_neg_integer(),
          format: format()
        }
end
