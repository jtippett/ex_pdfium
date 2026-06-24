defmodule ExPdfium.Native do
  @moduledoc false

  # RustlerPrecompiled downloads a prebuilt NIF for the user's target from the
  # matching GitHub release. Local development / CI forces a from-source build
  # with EXPDFIUM_BUILD=1 (see README "Development").
  #
  # IMPORTANT release ordering (see UPDATE_PROCEDURE.md): the precompiled download
  # is verified against `checksum-Elixir.ExPdfium.Native.exs`. That file is
  # regenerated AFTER the release workflow uploads the NIF artifacts, via
  #   mix rustler_precompiled.download ExPdfium.Native --all --print
  # and must be committed before publishing to Hex.
  #
  # No per-OTP artifacts: rustler targets NIF ABI 2.15, which loads on OTP 27/28/
  # 29+. One artifact per platform target covers every supported OTP.

  @version Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :ex_pdfium,
    crate: "ex_pdfium",
    base_url: "https://github.com/jtippett/ex_pdfium/releases/download/v#{@version}",
    version: @version,
    targets: ~w(
      aarch64-apple-darwin
      x86_64-apple-darwin
      x86_64-unknown-linux-gnu
      aarch64-unknown-linux-gnu
    ),
    force_build: System.get_env("EXPDFIUM_BUILD") in ["1", "true"]

  # Keep these stubs in sync with the #[rustler::nif] fns in
  # native/ex_pdfium/src/lib.rs. Each raises until the NIF library loads.

  # Phase 0 — proves pdfium links & initializes.
  def pdfium_version, do: :erlang.nif_error(:nif_not_loaded)

  # Phase 1 — open documents (path or binary) + page count.
  # `source` is {:path, path} | {:binary, bytes}; password is binary | nil.
  def document_open(_source, _password), do: :erlang.nif_error(:nif_not_loaded)
  def document_close(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def document_page_count(_doc), do: :erlang.nif_error(:nif_not_loaded)

  # Phase 2 — render a page to a bitmap.
  # Returns {data, width, height, stride, format}.
  def document_render_page(_doc, _page_index, _opts), do: :erlang.nif_error(:nif_not_loaded)
end
