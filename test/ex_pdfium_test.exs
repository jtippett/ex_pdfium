defmodule ExPdfiumTest do
  use ExUnit.Case, async: false

  @fixtures Path.join(__DIR__, "fixtures")
  @sample Path.join(@fixtures, "sample.pdf")
  @encrypted Path.join(@fixtures, "encrypted.pdf")
  @color Path.join(@fixtures, "color.pdf")

  describe "Phase 0: the NIF loads and pdfium initializes" do
    test "pdfium_version/0 returns a string" do
      assert is_binary(ExPdfium.pdfium_version())
    end
  end

  describe "Phase 1: open + page_count" do
    test "opens a file path and counts pages" do
      assert {:ok, doc} = ExPdfium.open(@sample)
      assert {:ok, 2} = ExPdfium.page_count(doc)
      assert :ok = ExPdfium.close(doc)
    end

    test "opens from an in-memory binary" do
      bytes = File.read!(@sample)
      assert {:ok, doc} = ExPdfium.open(bytes)
      assert {:ok, 2} = ExPdfium.page_count(doc)
    end

    test "a non-existent path returns {:error, :enoent}" do
      assert {:error, :enoent} = ExPdfium.open(Path.join(@fixtures, "does-not-exist.pdf"))
    end

    test "bytes that are not a valid PDF return {:error, :invalid_pdf}" do
      # Leading "%PDF" routes open/2 to the binary path; the rest is garbage.
      assert {:error, :invalid_pdf} = ExPdfium.open("%PDF-1.7\nnot really a pdf")
    end
  end

  describe "Phase 1: password-protected documents" do
    test "opening an encrypted doc without a password returns {:error, :password_error}" do
      assert {:error, :password_error} = ExPdfium.open(@encrypted)
    end

    test "opening with the wrong password returns {:error, :password_error}" do
      assert {:error, :password_error} = ExPdfium.open(@encrypted, password: "wrong")
    end

    test "opening with the correct password succeeds" do
      assert {:ok, doc} = ExPdfium.open(@encrypted, password: "secret")
      assert {:ok, 2} = ExPdfium.page_count(doc)
    end
  end

  describe "Phase 1: close/1 lifecycle" do
    test "close/1 is idempotent" do
      {:ok, doc} = ExPdfium.open(@sample)
      assert :ok = ExPdfium.close(doc)
      assert :ok = ExPdfium.close(doc)
    end

    test "operating on a closed document returns {:error, :document_closed}" do
      {:ok, doc} = ExPdfium.open(@sample)
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.page_count(doc)
    end
  end

  describe "Phase 1: concurrency (the reason for the global-lock design)" do
    # pdfium is not thread-safe; these hammer it from many BEAM schedulers at
    # once. Before the global lock, this surfaced intermittent {:error, :invalid_pdf}.
    test "many processes open/count/close concurrently" do
      results =
        1..400
        |> Task.async_stream(
          fn _ ->
            {:ok, doc} = ExPdfium.open(@sample)
            {:ok, n} = ExPdfium.page_count(doc)
            :ok = ExPdfium.close(doc)
            n
          end,
          max_concurrency: 64,
          ordered: false
        )
        |> Enum.map(fn {:ok, n} -> n end)

      assert results == List.duplicate(2, 400)
    end

    test "concurrent reads of one shared document are safe" do
      {:ok, doc} = ExPdfium.open(@sample)

      results =
        1..400
        |> Task.async_stream(fn _ -> ExPdfium.page_count(doc) end,
          max_concurrency: 64,
          ordered: false
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.all?(results, &(&1 == {:ok, 2}))
      assert :ok = ExPdfium.close(doc)
    end

    test "GC-driven closes race against concurrent opens without crashing" do
      # Half the workers drop their doc without closing (GC must close it, under
      # the global lock) while the other half keep opening/counting. Force GC to
      # make the destructor races likely.
      results =
        1..400
        |> Task.async_stream(
          fn i ->
            {:ok, doc} = ExPdfium.open(@sample)
            {:ok, n} = ExPdfium.page_count(doc)
            # Even workers leak the ref to GC; odd workers close explicitly.
            if rem(i, 2) == 0, do: :erlang.garbage_collect(), else: ExPdfium.close(doc)
            n
          end,
          max_concurrency: 64,
          ordered: false
        )
        |> Enum.map(fn {:ok, n} -> n end)

      assert results == List.duplicate(2, 400)
      assert is_binary(ExPdfium.pdfium_version())
    end
  end

  describe "Phase 1: garbage collection" do
    test "a document is closed on GC without crashing the VM" do
      # Open and drop the only reference, then force GC: the Drop destructor
      # closes the document in pdfium. The VM must survive.
      (fn ->
         {:ok, _doc} = ExPdfium.open(@sample)
         :ok
       end).()

      :erlang.garbage_collect()
      assert is_binary(ExPdfium.pdfium_version())
    end
  end

  describe "Phase 2: render_page" do
    setup do
      {:ok, doc} = ExPdfium.open(@sample)
      {:ok, doc: doc}
    end

    test "renders page 0 to a 4-channel RGBA bitmap by default", %{doc: doc} do
      assert {:ok,
              %ExPdfium.Bitmap{data: data, width: w, height: h, stride: stride, format: :rgba}} =
               ExPdfium.render_page(doc, 0, dpi: 72)

      assert w > 0 and h > 0
      assert stride == w * 4
      assert byte_size(data) == w * h * 4
    end

    test ":scale scales the output dimensions", %{doc: doc} do
      {:ok, base} = ExPdfium.render_page(doc, 0, scale: 1.0)
      {:ok, big} = ExPdfium.render_page(doc, 0, scale: 2.0)
      assert_in_delta big.width, base.width * 2, 2
      assert_in_delta big.height, base.height * 2, 2
    end

    test ":dpi 144 is twice the size of :dpi 72", %{doc: doc} do
      {:ok, low} = ExPdfium.render_page(doc, 0, dpi: 72)
      {:ok, high} = ExPdfium.render_page(doc, 0, dpi: 144)
      assert_in_delta high.width, low.width * 2, 2
    end

    test ":width sets the output width", %{doc: doc} do
      {:ok, bm} = ExPdfium.render_page(doc, 0, width: 200)
      assert bm.width == 200
      assert byte_size(bm.data) == bm.width * bm.height * 4
    end

    test ":format :bgra returns native BGRA bytes", %{doc: doc} do
      {:ok, bm} = ExPdfium.render_page(doc, 0, dpi: 72, format: :bgra)
      assert bm.format == :bgra
      assert byte_size(bm.data) == bm.width * bm.height * 4
    end

    test ":rgba and :bgra are the byte-swapped channel order (on a red page)" do
      {:ok, doc} = ExPdfium.open(@color)
      {:ok, rgba} = ExPdfium.render_page(doc, 0, dpi: 72, format: :rgba)
      {:ok, bgra} = ExPdfium.render_page(doc, 0, dpi: 72, format: :bgra)
      assert {rgba.width, rgba.height} == {bgra.width, bgra.height}

      <<r, g, b, a, _::binary>> = rgba.data
      <<b2, g2, r2, a2, _::binary>> = bgra.data
      # Same logical color, channels swapped R<->B.
      assert {r, g, b, a} == {r2, g2, b2, a2}
      # And it's genuinely a colored (non-gray) pixel, so the swap is meaningful.
      assert r > b
    end

    test ":height-only and :width+:height sizing both work", %{doc: doc} do
      {:ok, h_only} = ExPdfium.render_page(doc, 0, height: 300)
      assert h_only.height == 300

      {:ok, boxed} = ExPdfium.render_page(doc, 0, width: 300, height: 300)
      assert boxed.width <= 300 and boxed.height <= 300
      assert byte_size(boxed.data) == boxed.width * boxed.height * 4
    end

    test "an unknown :format is rejected", %{doc: doc} do
      assert {:error, :unsupported_format} = ExPdfium.render_page(doc, 0, format: :argb)
    end

    test "an unknown :background is rejected", %{doc: doc} do
      assert {:error, :unsupported_background} = ExPdfium.render_page(doc, 0, background: :pink)
    end

    test "a wrong-typed or non-positive option is rejected", %{doc: doc} do
      assert {:error, :bad_option} = ExPdfium.render_page(doc, 0, dpi: "300")
      assert {:error, :bad_option} = ExPdfium.render_page(doc, 0, width: 0)
      assert {:error, :bad_option} = ExPdfium.render_page(doc, 0, scale: -1.0)
    end

    test ":transparent background renders", %{doc: doc} do
      assert {:ok, %ExPdfium.Bitmap{}} =
               ExPdfium.render_page(doc, 0, dpi: 72, background: :transparent)
    end

    test "an out-of-range page index returns {:error, :page_out_of_bounds}", %{doc: doc} do
      assert {:error, :page_out_of_bounds} = ExPdfium.render_page(doc, 99)
    end

    test "rendering a closed document returns {:error, :document_closed}", %{doc: doc} do
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.render_page(doc, 0)
    end

    test "renders are safe under concurrency", %{doc: doc} do
      results =
        1..100
        |> Task.async_stream(fn _ -> ExPdfium.render_page(doc, 0, dpi: 72) end,
          max_concurrency: 32,
          ordered: false
        )
        |> Enum.map(fn {:ok, {:ok, bm}} -> byte_size(bm.data) == bm.width * bm.height * 4 end)

      assert Enum.all?(results)
    end

    test "GC document closes are safe while renders hold the lock", %{doc: doc} do
      # While one task renders (holding PDFIUM_LOCK for ~ms), another opens and
      # drops documents whose GC close is deferred to the cleanup thread (which
      # also needs the lock). Exercises the close path the new machinery guards.
      render =
        Task.async(fn ->
          Enum.map(1..60, fn _ ->
            {:ok, bm} = ExPdfium.render_page(doc, 0, dpi: 100)
            byte_size(bm.data)
          end)
        end)

      churn =
        Task.async(fn ->
          Enum.each(1..300, fn _ ->
            {:ok, _dropped} = ExPdfium.open(@sample)
            :erlang.garbage_collect()
          end)
        end)

      sizes = Task.await(render, 60_000)
      :ok = Task.await(churn, 60_000)

      assert Enum.all?(sizes, &(&1 > 0))
      assert is_binary(ExPdfium.pdfium_version())
    end
  end
end
