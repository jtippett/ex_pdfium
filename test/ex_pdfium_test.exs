defmodule ExPdfiumTest do
  use ExUnit.Case, async: false

  # Phase 0 — the only test that should pass on a fresh scaffold once the NIF
  # links pdfium. Everything below is @tag :skip until its phase lands.
  describe "Phase 0: the NIF loads and pdfium initializes" do
    test "pdfium_version/0 returns a string" do
      assert is_binary(ExPdfium.pdfium_version())
    end
  end

  @sample Path.join([__DIR__, "..", "..", "pdfium", "custom", "test.pdf"])

  describe "Phase 1: open + page_count" do
    @describetag :skip
    test "opens a file and counts pages" do
      assert {:ok, doc} = ExPdfium.open(@sample)
      assert {:ok, 2} = ExPdfium.page_count(doc)
      assert :ok = ExPdfium.close(doc)
    end
  end

  describe "Phase 2: render_page" do
    @describetag :skip
    test "renders page 0 to an RGBA/BGRA bitmap" do
      {:ok, doc} = ExPdfium.open(@sample)

      assert {:ok, %ExPdfium.Bitmap{data: data, width: w, height: h}} =
               ExPdfium.render_page(doc, 0, dpi: 72)

      assert byte_size(data) == w * h * 4
    end
  end
end
