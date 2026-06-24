defmodule ExPdfium.Document do
  @moduledoc """
  An opaque handle to an open PDF document.

  Wraps a Rust resource (`ResourceArc<Mutex<PdfDocument>>`). The document is
  closed automatically when this handle is garbage-collected; call
  `ExPdfium.close/1` to release it early.
  """

  @enforce_keys [:ref]
  defstruct [:ref]

  @type t :: %__MODULE__{ref: reference()}
end
