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

  # Dev/test only — point the dynamic binding at a dir holding libpdfium before
  # the first pdfium call. No-op on the shipped (statically-linked) build. Called
  # from test/test_helper.exs; env vars can't carry this into a NIF (os:putenv
  # doesn't reach a NIF's getenv).
  def set_dynamic_lib_dir(_dir), do: :erlang.nif_error(:nif_not_loaded)

  # Phase 1 — open documents (path or binary) + page count.
  # `source` is {:path, path} | {:binary, bytes}; password is binary | nil.
  def document_open(_source, _password), do: :erlang.nif_error(:nif_not_loaded)
  def document_close(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def document_page_count(_doc), do: :erlang.nif_error(:nif_not_loaded)

  # Phase 2 — render a page to a bitmap.
  # Returns {data, width, height, stride, format}.
  def document_render_page(_doc, _page_index, _opts), do: :erlang.nif_error(:nif_not_loaded)

  # Phase 3 — text extraction & search.
  def document_extract_text(_doc, _page_index), do: :erlang.nif_error(:nif_not_loaded)
  def document_extract_text_all(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def document_text_segments(_doc, _page_index), do: :erlang.nif_error(:nif_not_loaded)

  # `query` is binary; `match_case`/`whole_word` are booleans.
  def document_search_text(_doc, _page_index, _query, _match_case, _whole_word),
    do: :erlang.nif_error(:nif_not_loaded)

  # Phase 4 — metadata, geometry & permissions.
  def document_metadata(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def document_page_info(_doc, _page_index), do: :erlang.nif_error(:nif_not_loaded)
  def document_permissions(_doc), do: :erlang.nif_error(:nif_not_loaded)

  # Phase 5 — structure & navigation.
  def document_outline(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def document_links(_doc, _page_index), do: :erlang.nif_error(:nif_not_loaded)
  def document_attachments(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def document_attachment_data(_doc, _index), do: :erlang.nif_error(:nif_not_loaded)

  # Phase 6 — forms & annotations (read).
  def document_form_type(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def document_form_fields(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def document_annotations(_doc, _page_index), do: :erlang.nif_error(:nif_not_loaded)

  # Image & object extraction.
  def document_page_objects(_doc, _page_index), do: :erlang.nif_error(:nif_not_loaded)
  def document_images(_doc, _page_index), do: :erlang.nif_error(:nif_not_loaded)

  def document_image_data(_doc, _page_index, _object_index),
    do: :erlang.nif_error(:nif_not_loaded)

  def document_image_raw_data(_doc, _page_index, _object_index),
    do: :erlang.nif_error(:nif_not_loaded)

  # Document creation: pages, text, shapes, images.
  def document_new, do: :erlang.nif_error(:nif_not_loaded)
  def document_add_page(_doc, _w, _h, _at), do: :erlang.nif_error(:nif_not_loaded)

  def document_draw_text(_doc, _page, _x, _y, _text, _font, _size, _color),
    do: :erlang.nif_error(:nif_not_loaded)

  def document_draw_rectangle(_doc, _page, _l, _b, _r, _t, _fill, _stroke, _sw),
    do: :erlang.nif_error(:nif_not_loaded)

  def document_draw_line(_doc, _page, _x1, _y1, _x2, _y2, _stroke, _sw),
    do: :erlang.nif_error(:nif_not_loaded)

  def document_draw_circle(_doc, _page, _cx, _cy, _r, _fill, _stroke, _sw),
    do: :erlang.nif_error(:nif_not_loaded)

  def document_draw_image(_doc, _page, _data, _w, _h, _fmt, _l, _b, _r, _t),
    do: :erlang.nif_error(:nif_not_loaded)

  # Annotation authoring.
  def document_add_text_annotation(_doc, _page, _x, _y, _text, _color),
    do: :erlang.nif_error(:nif_not_loaded)

  def document_add_free_text_annotation(_doc, _page, _l, _b, _r, _t, _text, _fill, _stroke),
    do: :erlang.nif_error(:nif_not_loaded)

  def document_add_square_annotation(_doc, _page, _l, _b, _r, _t, _fill, _stroke),
    do: :erlang.nif_error(:nif_not_loaded)

  def document_add_link_annotation(_doc, _page, _l, _b, _r, _t, _uri),
    do: :erlang.nif_error(:nif_not_loaded)

  def document_delete_annotation(_doc, _page, _index), do: :erlang.nif_error(:nif_not_loaded)

  # Flatten & signatures.
  def document_flatten_page(_doc, _page), do: :erlang.nif_error(:nif_not_loaded)
  def document_flatten(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def document_signatures(_doc), do: :erlang.nif_error(:nif_not_loaded)

  # v0.3 — writing: page assembly & save.
  def document_save(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def document_append(_dest, _src), do: :erlang.nif_error(:nif_not_loaded)
  def document_extract_pages(_src, _indices), do: :erlang.nif_error(:nif_not_loaded)
  def document_delete_pages(_doc, _from, _to), do: :erlang.nif_error(:nif_not_loaded)
  def document_rotate_page(_doc, _page_index, _degrees), do: :erlang.nif_error(:nif_not_loaded)
end
