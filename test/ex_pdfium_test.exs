defmodule ExPdfiumTest do
  use ExUnit.Case, async: false

  @fixtures Path.join(__DIR__, "fixtures")
  @sample Path.join(@fixtures, "sample.pdf")
  @encrypted Path.join(@fixtures, "encrypted.pdf")

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
    @describetag :skip
    test "renders page 0 to an RGBA/BGRA bitmap" do
      {:ok, doc} = ExPdfium.open(@sample)

      assert {:ok, %ExPdfium.Bitmap{data: data, width: w, height: h}} =
               ExPdfium.render_page(doc, 0, dpi: 72)

      assert byte_size(data) == w * h * 4
    end
  end
end
