defmodule ExPdfiumTest do
  use ExUnit.Case, async: false

  @fixtures Path.join(__DIR__, "fixtures")
  @sample Path.join(@fixtures, "sample.pdf")
  @encrypted Path.join(@fixtures, "encrypted.pdf")
  @color Path.join(@fixtures, "color.pdf")
  @text Path.join(@fixtures, "text.pdf")
  @meta Path.join(@fixtures, "meta.pdf")
  @restricted Path.join(@fixtures, "restricted.pdf")
  @structure Path.join(@fixtures, "structure.pdf")

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

  describe "Phase 3: text extraction" do
    setup do
      {:ok, doc} = ExPdfium.open(@text)
      {:ok, doc: doc}
    end

    test "extract_text/2 returns a page's text", %{doc: doc} do
      assert {:ok, text} = ExPdfium.extract_text(doc, 0)
      assert text =~ "Hello pdfium world"
    end

    test "extract_text/1 returns the whole document, pages joined by form feed", %{doc: doc} do
      assert {:ok, text} = ExPdfium.extract_text(doc)
      assert text =~ "Hello pdfium world"
      assert text =~ "Second page text"
      assert [page0, page1] = String.split(text, "\f")
      assert page0 =~ "Hello pdfium" and page1 =~ "Second page"
    end

    test "a blank page yields empty text" do
      {:ok, blank} = ExPdfium.open(@sample)
      assert {:ok, text} = ExPdfium.extract_text(blank, 0)
      assert String.trim(text) == ""
    end

    test "extract_text on a closed document", %{doc: doc} do
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.extract_text(doc, 0)
    end

    test "extract_text on an out-of-range page", %{doc: doc} do
      assert {:error, :page_out_of_bounds} = ExPdfium.extract_text(doc, 99)
    end
  end

  describe "Phase 3: text segments (geometry)" do
    setup do
      {:ok, doc} = ExPdfium.open(@text)
      {:ok, doc: doc}
    end

    test "text_segments/2 returns text runs with point bounds", %{doc: doc} do
      assert {:ok, segments} = ExPdfium.text_segments(doc, 0)
      assert segments != []

      joined = segments |> Enum.map(& &1.text) |> Enum.join()
      assert joined =~ "pdfium"

      for %{bounds: b} <- segments do
        assert b.left < b.right
        # PDF coordinates: origin bottom-left, y increases upward.
        assert b.bottom < b.top
      end
    end

    test "a blank page has no segments" do
      {:ok, blank} = ExPdfium.open(@sample)
      assert {:ok, []} = ExPdfium.text_segments(blank, 0)
    end

    test "text_segments error cases", %{doc: doc} do
      assert {:error, :page_out_of_bounds} = ExPdfium.text_segments(doc, 99)
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.text_segments(doc, 0)
    end
  end

  describe "Phase 3: text search" do
    setup do
      {:ok, doc} = ExPdfium.open(@text)
      {:ok, doc: doc}
    end

    test "finds a term and returns bounding rects", %{doc: doc} do
      assert {:ok, [match]} = ExPdfium.search_text(doc, 0, "pdfium")
      assert match.text =~ "pdfium"
      assert [%{left: l, right: r} | _] = match.rects
      assert l < r
    end

    test "is case-insensitive by default, case-sensitive on request", %{doc: doc} do
      assert {:ok, [_]} = ExPdfium.search_text(doc, 0, "World")
      assert {:ok, []} = ExPdfium.search_text(doc, 0, "World", match_case: true)
      assert {:ok, [_]} = ExPdfium.search_text(doc, 0, "world", match_case: true)
    end

    test "whole-word matching", %{doc: doc} do
      assert {:ok, [_]} = ExPdfium.search_text(doc, 0, "world", whole_word: true)
      assert {:ok, []} = ExPdfium.search_text(doc, 0, "orl", whole_word: true)
    end

    test "no match returns an empty list", %{doc: doc} do
      assert {:ok, []} = ExPdfium.search_text(doc, 0, "absent")
    end

    test "an empty query is rejected", %{doc: doc} do
      assert {:error, :empty_query} = ExPdfium.search_text(doc, 0, "")
    end

    test "search error cases", %{doc: doc} do
      assert {:error, :page_out_of_bounds} = ExPdfium.search_text(doc, 99, "x")
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.search_text(doc, 0, "x")
    end

    test "text and search are safe under concurrency", %{doc: doc} do
      ok? =
        1..100
        |> Task.async_stream(
          fn _ ->
            {:ok, t} = ExPdfium.extract_text(doc, 0)
            {:ok, m} = ExPdfium.search_text(doc, 0, "pdfium")
            t =~ "pdfium" and length(m) == 1
          end,
          max_concurrency: 32,
          ordered: false
        )
        |> Enum.all?(fn {:ok, v} -> v end)

      assert ok?
    end
  end

  describe "Phase 4: metadata" do
    test "metadata/1 returns the document info dictionary" do
      {:ok, doc} = ExPdfium.open(@meta)
      assert {:ok, meta} = ExPdfium.metadata(doc)
      assert meta.title == "The Great Test"
      assert meta.author == "Ada Lovelace"
      assert meta.subject == "Unit Testing"
      assert meta.keywords == "pdf, test, meta"
      assert meta.creator == "ExPdfium Suite"
      assert meta.producer == "Hand Rolled"
      # creation_date is a raw PDF date string (D:YYYYMMDD...). modification_date
      # relies on pdfium-render's "ModificationDate" tag, which doesn't match the
      # standard /ModDate key, so it stays nil here — see the moduledoc.
      assert meta.creation_date =~ "2024"
      assert meta.modification_date == nil
    end

    test "a document with no info dict yields all-nil fields" do
      {:ok, doc} = ExPdfium.open(@sample)
      assert {:ok, meta} = ExPdfium.metadata(doc)
      assert meta.title == nil
      assert meta.author == nil
    end

    test "metadata on a closed document" do
      {:ok, doc} = ExPdfium.open(@meta)
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.metadata(doc)
    end
  end

  describe "Phase 4: page geometry" do
    test "page_info/2 returns size, rotation, label and boxes" do
      {:ok, doc} = ExPdfium.open(@meta)
      assert {:ok, info} = ExPdfium.page_info(doc, 0)
      assert info.width == 200.0
      assert info.height == 300.0
      assert info.rotation == 0
      assert info.label == nil
      assert info.boxes.media == %{left: 0.0, bottom: 0.0, right: 200.0, top: 300.0}
      # meta.pdf defines only a MediaBox; pdfium returns no fallback for the rest
      # (not even crop -> media).
      assert info.boxes.crop == nil
      assert info.boxes.bleed == nil
      assert info.boxes.trim == nil
      assert info.boxes.art == nil
    end

    test "page_info error cases" do
      {:ok, doc} = ExPdfium.open(@meta)
      assert {:error, :page_out_of_bounds} = ExPdfium.page_info(doc, 99)
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.page_info(doc, 0)
    end
  end

  describe "Phase 4: permissions" do
    test "an unencrypted document permits everything" do
      {:ok, doc} = ExPdfium.open(@sample)
      assert {:ok, perms} = ExPdfium.permissions(doc)
      assert perms.print_high_quality == true
      assert perms.extract_text_and_graphics == true
      assert perms.modify_content == true
    end

    test "a restricted (AES-128) document reports its limits" do
      {:ok, doc} = ExPdfium.open(@restricted)
      assert {:ok, perms} = ExPdfium.permissions(doc)
      # restricted.pdf: AES-128, --print=none --modify=none (copy still allowed).
      assert perms.print_high_quality == false
      assert perms.modify_content == false
      assert perms.annotate == false
      assert perms.extract_text_and_graphics == true
    end

    test "an unreadable security handler (AES-256) errors rather than reporting all-false" do
      {:ok, doc} = ExPdfium.open(@encrypted, password: "secret")
      assert {:error, :unsupported_security} = ExPdfium.permissions(doc)
    end

    test "permissions on a closed document" do
      {:ok, doc} = ExPdfium.open(@sample)
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.permissions(doc)
    end
  end

  describe "Phase 5: outline (bookmarks)" do
    test "outline/1 returns the nested bookmark tree" do
      {:ok, doc} = ExPdfium.open(@structure)
      assert {:ok, [ch1, ch2]} = ExPdfium.outline(doc)

      assert ch1.title == "Chapter 1"
      assert ch1.page == 0
      assert [sec] = ch1.children
      assert sec.title == "Section 1.1"
      assert sec.page == 0
      assert sec.children == []

      assert ch2.title == "Chapter 2"
      assert ch2.page == 1
      assert ch2.children == []
    end

    test "a document with no outline returns an empty list" do
      {:ok, doc} = ExPdfium.open(@sample)
      assert {:ok, []} = ExPdfium.outline(doc)
    end

    test "outline on a closed document" do
      {:ok, doc} = ExPdfium.open(@structure)
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.outline(doc)
    end
  end

  describe "Phase 5: links" do
    test "links/2 returns web, internal, and unsupported links with bounds" do
      {:ok, doc} = ExPdfium.open(@structure)
      assert {:ok, links} = ExPdfium.links(doc, 0)
      assert length(links) == 3

      web = Enum.find(links, &(&1.uri != nil))
      assert web.uri =~ "example.com"
      assert web.bounds.left < web.bounds.right

      internal = Enum.find(links, &(&1.page != nil))
      assert internal.page == 1

      # A link with neither a URI nor a destination still appears, with both nil.
      unsupported = Enum.find(links, &(&1.uri == nil and &1.page == nil))
      assert unsupported != nil
    end

    test "a page with no links returns an empty list" do
      {:ok, doc} = ExPdfium.open(@structure)
      assert {:ok, []} = ExPdfium.links(doc, 1)
    end

    test "links error cases" do
      {:ok, doc} = ExPdfium.open(@structure)
      assert {:error, :page_out_of_bounds} = ExPdfium.links(doc, 99)
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.links(doc, 0)
    end
  end

  describe "Phase 5: attachments" do
    test "attachments/1 lists embedded files; attachment_data/2 extracts them" do
      {:ok, doc} = ExPdfium.open(@structure)
      assert {:ok, [att]} = ExPdfium.attachments(doc)
      assert att.index == 0
      assert att.name == "note.txt"
      assert att.size > 0

      assert {:ok, data} = ExPdfium.attachment_data(doc, 0)
      assert data =~ "hello from an attachment"
    end

    test "a document with no attachments returns an empty list" do
      {:ok, doc} = ExPdfium.open(@sample)
      assert {:ok, []} = ExPdfium.attachments(doc)
    end

    test "attachment_data for a bad index" do
      {:ok, doc} = ExPdfium.open(@structure)
      assert {:error, :attachment_not_found} = ExPdfium.attachment_data(doc, 99)
    end

    test "attachments and attachment_data on a closed document" do
      {:ok, doc} = ExPdfium.open(@structure)
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.attachments(doc)
      assert {:error, :document_closed} = ExPdfium.attachment_data(doc, 0)
    end
  end

  describe "Phase 5: concurrency" do
    test "outline/links/attachments are safe under concurrency" do
      {:ok, doc} = ExPdfium.open(@structure)

      ok? =
        1..100
        |> Task.async_stream(
          fn _ ->
            {:ok, [_, _]} = ExPdfium.outline(doc)
            {:ok, links} = ExPdfium.links(doc, 0)
            {:ok, [att]} = ExPdfium.attachments(doc)
            length(links) == 3 and att.name == "note.txt"
          end,
          max_concurrency: 32,
          ordered: false
        )
        |> Enum.all?(fn {:ok, v} -> v end)

      assert ok?
    end
  end

  describe "Phase 4: concurrency" do
    test "metadata/page_info/permissions are safe under concurrency" do
      {:ok, doc} = ExPdfium.open(@meta)

      ok? =
        1..100
        |> Task.async_stream(
          fn _ ->
            {:ok, m} = ExPdfium.metadata(doc)
            {:ok, i} = ExPdfium.page_info(doc, 0)
            {:ok, p} = ExPdfium.permissions(doc)
            m.title == "The Great Test" and i.width == 200.0 and p.print_high_quality == true
          end,
          max_concurrency: 32,
          ordered: false
        )
        |> Enum.all?(fn {:ok, v} -> v end)

      assert ok?
    end
  end
end
