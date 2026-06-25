defmodule ExPdfium.Bitmap do
  @moduledoc """
  A raw pixel bitmap — produced by `ExPdfium.render_page/3` (a rendered page) or
  `ExPdfium.image_data/3` (a decoded embedded image).

  `data` is a raw pixel buffer. `format` records the byte order and channel count
  so consumers can interpret it: `:rgba`/`:bgra` (4 channels), `:bgrx` (4, with a
  padding byte), `:bgr` (3), or `:gray` (1). `render_page/3` yields `:rgba`
  (default) or `:bgra`; an image decoded with `image_data/3` keeps its native
  pdfium format. With `width`, `height`, and `stride` (bytes per row), the buffer
  feeds directly into e.g. `Vix.Vips.Image.new_from_binary/5`.
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
end
