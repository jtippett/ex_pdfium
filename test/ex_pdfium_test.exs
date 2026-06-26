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
  @forms Path.join(@fixtures, "forms.pdf")
  @images Path.join(@fixtures, "images.pdf")
  @huge_page Path.join(@fixtures, "huge_page.pdf")
  @attachment_bomb Path.join(@fixtures, "attachment_bomb.pdf")

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

  describe "Phase 3: chars (char-level geometry)" do
    setup do
      {:ok, doc} = ExPdfium.open(@text)
      {:ok, doc: doc}
    end

    test "chars/2 returns per-glyph char, bounds, font size, and origin", %{doc: doc} do
      assert {:ok, chars} = ExPdfium.chars(doc, 0)
      assert chars != []

      # Each entry has the documented shape.
      for c <- chars do
        assert is_binary(c.char)
        assert is_float(c.font_size)
        assert c.bounds == nil or match?(%{left: _, bottom: _, right: _, top: _}, c.bounds)
        assert c.origin == nil or match?(%{x: x, y: y} when is_float(x) and is_float(y), c.origin)
        # Default path is lean: no style sub-map unless asked for.
        refute Map.has_key?(c, :style)
      end

      # A real glyph (non-whitespace) carries a positive box and font size.
      glyph = Enum.find(chars, &(String.trim(&1.char) != "" and &1.bounds != nil))
      assert glyph.font_size > 0
      assert glyph.bounds.left < glyph.bounds.right
      assert glyph.bounds.bottom < glyph.bounds.top
    end

    test "origin is the glyph's pen position: x at the left edge, y on the baseline",
         %{doc: doc} do
      {:ok, chars} = ExPdfium.chars(doc, 0)
      glyph = Enum.find(chars, &(String.trim(&1.char) != "" and &1.bounds != nil and &1.origin))

      # The baseline (origin.y) lies within the glyph's vertical advance cell.
      assert glyph.bounds.bottom <= glyph.origin.y
      assert glyph.origin.y <= glyph.bounds.top
      # The pen origin (origin.x) starts at the left of the advance cell.
      assert_in_delta glyph.origin.x, glyph.bounds.left, 1.0
    end

    test "chars are in content-stream order (reconstruct extract_text)", %{doc: doc} do
      {:ok, chars} = ExPdfium.chars(doc, 0)
      {:ok, text} = ExPdfium.extract_text(doc, 0)
      joined = chars |> Enum.map(& &1.char) |> Enum.join()
      assert String.trim(joined) == String.trim(text)
    end

    test "a blank page has no chars" do
      {:ok, blank} = ExPdfium.open(@sample)
      assert {:ok, []} = ExPdfium.chars(blank, 0)
    end

    test "chars error cases", %{doc: doc} do
      assert {:error, :page_out_of_bounds} = ExPdfium.chars(doc, 99)
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.chars(doc, 0)
    end

    test "chars/3 with style: true adds a best-effort style sub-map", %{doc: doc} do
      assert {:ok, chars} = ExPdfium.chars(doc, 0, style: true)
      glyph = Enum.find(chars, &(String.trim(&1.char) != ""))

      # Style is present and well-shaped on every char when requested.
      for c <- chars do
        assert match?(
                 %{
                   font_name: _,
                   weight: _,
                   bold?: _,
                   italic?: _,
                   serif?: _,
                   fixed_pitch?: _
                 },
                 c.style
               )

        assert is_binary(c.style.font_name)
        assert c.style.weight == nil or is_integer(c.style.weight)
        assert is_boolean(c.style.bold?)
        assert is_boolean(c.style.italic?)
        assert is_boolean(c.style.serif?)
        assert is_boolean(c.style.fixed_pitch?)
      end

      # The geometry fields are still there alongside style.
      assert is_float(glyph.font_size)
      assert match?(%{x: _, y: _}, glyph.origin)
    end

    test "style: false (the default) omits the style sub-map", %{doc: doc} do
      {:ok, chars} = ExPdfium.chars(doc, 0, style: false)
      assert Enum.all?(chars, &(not Map.has_key?(&1, :style)))
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

    test "metadata/1 includes document-level properties" do
      {:ok, doc} = ExPdfium.open(@meta)
      {:ok, count} = ExPdfium.page_count(doc)
      assert {:ok, meta} = ExPdfium.metadata(doc)

      # PDF version is a "MAJOR.MINOR" string (or nil if the file omits it).
      assert is_nil(meta.version) or meta.version =~ ~r/^\d\.\d$/
      assert meta.page_count == count

      assert meta.page_mode in [
               :none,
               :outline,
               :thumbnails,
               :fullscreen,
               :optional_content,
               :attachments,
               :unset
             ]
    end

    test "version is reported for a fixture that declares one" do
      {:ok, doc} = ExPdfium.open(@text)
      assert {:ok, %{version: version}} = ExPdfium.metadata(doc)
      assert version =~ ~r/^1\.\d$/
    end

    test "a document with no info dict yields all-nil fields but real properties" do
      {:ok, doc} = ExPdfium.open(@sample)
      assert {:ok, meta} = ExPdfium.metadata(doc)
      assert meta.title == nil
      assert meta.author == nil
      # Document-level properties are still present.
      assert meta.page_count == 2
      assert is_atom(meta.page_mode)
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

    test "a decompression-bomb attachment is rejected without decoding it" do
      # attachment_bomb.pdf is ~100 KB but its embedded file decodes to 105 MB.
      {:ok, doc} = ExPdfium.open(@attachment_bomb)
      # Listing reports the declared size cheaply (no allocation)...
      assert {:ok, [%{name: "bomb.bin", size: 105_000_000}]} = ExPdfium.attachments(doc)
      # ...but extracting it is capped, so the 105 MB is never materialized.
      assert {:error, :attachment_too_large} = ExPdfium.attachment_data(doc, 0)
    end

    test "attachments and attachment_data on a closed document" do
      {:ok, doc} = ExPdfium.open(@structure)
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.attachments(doc)
      assert {:error, :document_closed} = ExPdfium.attachment_data(doc, 0)
    end
  end

  describe "Phase 6: form type & fields" do
    test "form_type/1 is :acrobat for an AcroForm document" do
      {:ok, doc} = ExPdfium.open(@forms)
      assert {:ok, :acrobat} = ExPdfium.form_type(doc)
    end

    test "form_type/1 is :none for a document with no form" do
      {:ok, doc} = ExPdfium.open(@sample)
      assert {:ok, :none} = ExPdfium.form_type(doc)
    end

    test "form_fields/1 reads text, checkbox, and radio values" do
      {:ok, doc} = ExPdfium.open(@forms)
      assert {:ok, fields} = ExPdfium.form_fields(doc)

      by_name = fn name -> Enum.filter(fields, &(&1.name == name)) end

      assert [full_name] = by_name.("full_name")
      assert full_name.type == :text
      assert full_name.value == "Ada Lovelace"
      assert full_name.checked == nil
      assert full_name.read_only == false
      assert full_name.required == false
      assert full_name.page == 0
      assert %{left: 100.0, bottom: 700.0, right: 400.0, top: 720.0} = full_name.bounds

      assert [comments] = by_name.("comments")
      assert comments.type == :text
      assert comments.value == nil

      assert [subscribe] = by_name.("subscribe")
      assert subscribe.type == :checkbox
      assert subscribe.checked == true
      assert subscribe.value == "Yes"

      # A radio group surfaces one entry per option widget, all sharing the name.
      # pdfium reports the group's *selected* value on every widget, so `value`
      # is "pro" on both; `checked` flags which widget is the selected one.
      plan = by_name.("plan")
      assert length(plan) == 2
      assert Enum.all?(plan, &(&1.type == :radio_button))
      assert Enum.all?(plan, &(&1.value == "pro"))
      assert Enum.count(plan, & &1.checked) == 1
    end

    test "form_fields/1 is empty for a document without a form" do
      {:ok, doc} = ExPdfium.open(@sample)
      assert {:ok, []} = ExPdfium.form_fields(doc)
    end

    test "form_type/1 and form_fields/1 on a closed document" do
      {:ok, doc} = ExPdfium.open(@forms)
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.form_type(doc)
      assert {:error, :document_closed} = ExPdfium.form_fields(doc)
    end
  end

  describe "Phase 6: annotations" do
    test "annotations/2 lists widget, text, and highlight annotations" do
      {:ok, doc} = ExPdfium.open(@forms)
      assert {:ok, anns} = ExPdfium.annotations(doc, 0)

      assert Enum.count(anns, &(&1.type == :widget)) == 5

      assert note = Enum.find(anns, &(&1.type == :text))
      assert note.contents == "A reviewer note"
      assert note.name == "note-1"
      assert note.hidden == false
      assert %{left: 500.0, top: 720.0} = note.bounds

      assert hl = Enum.find(anns, &(&1.type == :highlight))
      assert hl.contents == "Important passage"
    end

    test "annotations/2 is empty for a page with no annotations" do
      {:ok, doc} = ExPdfium.open(@sample)
      assert {:ok, []} = ExPdfium.annotations(doc, 0)
    end

    test "annotations/2 out-of-bounds page" do
      {:ok, doc} = ExPdfium.open(@forms)
      assert {:error, :page_out_of_bounds} = ExPdfium.annotations(doc, 99)
    end

    test "annotations/2 on a closed document" do
      {:ok, doc} = ExPdfium.open(@forms)
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.annotations(doc, 0)
    end
  end

  describe "Phase 6: concurrency" do
    test "form_type/form_fields/annotations are safe under concurrency" do
      {:ok, doc} = ExPdfium.open(@forms)

      ok? =
        1..100
        |> Task.async_stream(
          fn _ ->
            {:ok, :acrobat} = ExPdfium.form_type(doc)
            {:ok, fields} = ExPdfium.form_fields(doc)
            {:ok, anns} = ExPdfium.annotations(doc, 0)
            length(fields) == 5 and length(anns) == 7
          end,
          max_concurrency: 32,
          ordered: false
        )
        |> Enum.all?(fn {:ok, v} -> v end)

      assert ok?
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

  describe "Reading: page_objects/2" do
    test "lists every object on the page, typed, with bounds" do
      {:ok, doc} = ExPdfium.open(@images)
      assert {:ok, objects} = ExPdfium.page_objects(doc, 0)

      types = Enum.map(objects, & &1.type)
      assert :text in types
      assert :path in types
      assert :image in types

      # Each object reports a 0-based index and a bounds map (or nil).
      assert Enum.all?(objects, &(is_integer(&1.index) and &1.index >= 0))

      image = Enum.find(objects, &(&1.type == :image))
      assert %{left: _, bottom: _, right: _, top: _} = image.bounds
    end

    test "every object carries its transformation matrix" do
      {:ok, doc} = ExPdfium.open(@images)
      {:ok, objects} = ExPdfium.page_objects(doc, 0)

      for obj <- objects do
        assert %{a: a, b: b, c: c, d: d, e: e, f: f} = obj.matrix
        assert Enum.all?([a, b, c, d, e, f], &is_float/1)
      end
    end

    test "out-of-bounds page and closed document" do
      {:ok, doc} = ExPdfium.open(@images)
      assert {:error, :page_out_of_bounds} = ExPdfium.page_objects(doc, 9)
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.page_objects(doc, 0)
    end
  end

  describe "Reading: images/2" do
    test "lists image objects with intrinsic dimensions and filters" do
      {:ok, doc} = ExPdfium.open(@images)
      assert {:ok, images} = ExPdfium.images(doc, 0)
      assert length(images) == 3

      rgb = Enum.find(images, &(&1.filters == ["FlateDecode"] and &1.bits_per_pixel == 24))
      assert rgb.width == 4
      assert rgb.height == 4
      assert %{left: _, bottom: _, right: _, top: _} = rgb.bounds
      assert is_integer(rgb.index)

      gray = Enum.find(images, &(&1.bits_per_pixel == 8))
      assert gray.filters == ["FlateDecode"]

      jpeg = Enum.find(images, &(&1.filters == ["DCTDecode"]))
      assert jpeg.width == 16
      assert jpeg.height == 12
    end

    test "the image matrix recovers placement, scale, and orientation" do
      {:ok, doc} = ExPdfium.open(@images)
      {:ok, images} = ExPdfium.images(doc, 0)

      # The fixture places the RGB image with `64 0 0 64 300 400 cm`: a pure
      # scale-and-translate, no rotation or flip. The matrix lets a caller recover
      # that deterministically instead of guessing from the extracted stream.
      rgb = Enum.find(images, &(&1.filters == ["FlateDecode"] and &1.bits_per_pixel == 24))
      assert %{a: a, b: b, c: c, d: d, e: e, f: f} = rgb.matrix
      assert_in_delta a, 64.0, 0.01
      assert_in_delta d, 64.0, 0.01
      assert_in_delta b, 0.0, 0.01
      assert_in_delta c, 0.0, 0.01
      assert_in_delta e, 300.0, 0.01
      assert_in_delta f, 400.0, 0.01

      # The JPEG is placed `96 0 0 72 300 250 cm` (non-square scale).
      jpeg = Enum.find(images, &(&1.filters == ["DCTDecode"]))
      assert_in_delta jpeg.matrix.a, 96.0, 0.01
      assert_in_delta jpeg.matrix.d, 72.0, 0.01
    end

    test "a page with no images returns an empty list" do
      {:ok, doc} = ExPdfium.open(@text)
      assert {:ok, []} = ExPdfium.images(doc, 0)
    end
  end

  describe "Bitmap.to_vix/1" do
    # Convert a 1×N bitmap and read back its first pixel + shape.
    defp px(data, w, h, stride, fmt) do
      bmp = %ExPdfium.Bitmap{data: data, width: w, height: h, stride: stride, format: fmt}
      {:ok, img} = ExPdfium.Bitmap.to_vix(bmp)
      {Vix.Vips.Operation.getpoint!(img, 0, 0), Vix.Vips.Image.shape(img)}
    end

    test "reorders pdfium BGR into RGB, dropping the :bgrx padding byte" do
      # B=10, G=20, R=30(, A=40) — all should read back R, G, B[, A].
      assert {[30.0, 20.0, 10.0, 40.0], {1, 1, 4}} = px(<<10, 20, 30, 40>>, 1, 1, 4, :bgra)
      assert {[30.0, 20.0, 10.0], {1, 1, 3}} = px(<<10, 20, 30>>, 1, 1, 3, :bgr)
      # :bgrx — the 4th byte is padding and is dropped (3-band result).
      assert {[30.0, 20.0, 10.0], {1, 1, 3}} = px(<<10, 20, 30, 99>>, 1, 1, 4, :bgrx)
    end

    test "passes :rgba and :gray through unchanged" do
      assert {[30.0, 20.0, 10.0, 40.0], {1, 1, 4}} = px(<<30, 20, 10, 40>>, 1, 1, 4, :rgba)
      assert {[99.0], {1, 1, 1}} = px(<<99>>, 1, 1, 1, :gray)
    end

    test "strips row stride padding" do
      # width 1 :gray with a 4-byte aligned stride (3 padding bytes per row).
      assert {[99.0], {1, 1, 1}} = px(<<99, 0, 0, 0>>, 1, 1, 4, :gray)
    end

    test "converts a real decoded image and writes a PNG" do
      {:ok, doc} = ExPdfium.open(@images)
      {:ok, [img | _]} = ExPdfium.images(doc, 0)
      {:ok, bmp} = ExPdfium.image_data(doc, 0, img.index)

      assert {:ok, vix} = ExPdfium.Bitmap.to_vix(bmp)
      assert {w, h, _bands} = Vix.Vips.Image.shape(vix)
      assert w == bmp.width and h == bmp.height

      path = Path.join(System.tmp_dir!(), "ex_pdfium_to_vix_test.png")
      assert :ok = Vix.Vips.Image.write_to_file(vix, path)
      assert File.stat!(path).size > 0
      File.rm(path)
    end
  end

  describe "Reading: object_display_matrix/3" do
    defp red_image_doc do
      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, {200, 400})
      red = for _ <- 1..(40 * 40), into: <<>>, do: <<255, 0, 0, 255>>
      bmp = %ExPdfium.Bitmap{data: red, width: 40, height: 40, stride: 40 * 4, format: :rgba}
      # Placed at the content bottom-left corner: object matrix ~ {40,0,0,40,0,0}.
      {:ok, doc} = ExPdfium.draw_image(doc, 0, bmp, at: %{left: 0, bottom: 0, right: 40, top: 40})
      {:ok, [img]} = ExPdfium.images(doc, 0)
      {doc, img}
    end

    # Centroid (x, y) of the strongly-red pixels in a rendered RGBA bitmap.
    defp red_centroid(%ExPdfium.Bitmap{data: data, width: w}) do
      reds =
        for {{r, g, b}, i} <- Enum.with_index(for(<<r, g, b, _a <- data>>, do: {r, g, b})),
            r > 200 and g < 80 and b < 80,
            do: {rem(i, w), div(i, w)}

      n = length(reds)
      {sx, sy} = Enum.reduce(reds, {0, 0}, fn {x, y}, {ax, ay} -> {ax + x, ay + y} end)
      {sx / n, sy / n}
    end

    test "with no page rotation it equals the object's own matrix" do
      {doc, img} = red_image_doc()
      {:ok, m} = ExPdfium.object_display_matrix(doc, 0, img.index)

      for k <- [:a, :b, :c, :d, :e, :f] do
        assert_in_delta(m[k], img.matrix[k], 0.01)
      end
    end

    test "it composes every page /Rotate, matching where the image actually renders" do
      for rot <- [0, 90, 180, 270] do
        {doc, img} = red_image_doc()
        {:ok, doc} = ExPdfium.rotate_page(doc, 0, rot)

        {:ok, m} = ExPdfium.object_display_matrix(doc, 0, img.index)
        # The image's unit-square centre, mapped to display PDF coords (y up):
        cx = m.a * 0.5 + m.c * 0.5 + m.e
        cy = m.b * 0.5 + m.d * 0.5 + m.f

        # Render the rotated page (display-oriented) and find the red blob.
        {:ok, render} = ExPdfium.render_page(doc, 0, dpi: 72)
        {rx, ry} = red_centroid(render)

        # Bitmap is top-left origin / y-down; display PDF is bottom-left / y-up.
        assert_in_delta rx, cx, 8, "x mismatch at /Rotate #{rot}"
        assert_in_delta ry, render.height - cy, 8, "y mismatch at /Rotate #{rot}"
      end
    end

    test "errors on a missing object or page" do
      {doc, _img} = red_image_doc()
      assert {:error, :object_not_found} = ExPdfium.object_display_matrix(doc, 0, 999)
      assert {:error, :page_out_of_bounds} = ExPdfium.object_display_matrix(doc, 9, 0)
    end

    test "object_display_rotation/3 returns clockwise raster degrees (= page /Rotate here)" do
      # The image has no object-level rotation, so the display rotation is purely
      # the page /Rotate — and in raster (top-left, clockwise) convention that is
      # the page rotation value itself.
      for rot <- [0, 90, 180, 270] do
        {doc, img} = red_image_doc()
        {:ok, doc} = ExPdfium.rotate_page(doc, 0, rot)
        {:ok, deg} = ExPdfium.object_display_rotation(doc, 0, img.index)
        assert_in_delta deg, rot, 0.01, "raster rotation should equal /Rotate #{rot}"
      end
    end

    test "object_display_rotation/3 propagates errors" do
      {doc, _img} = red_image_doc()
      assert {:error, :object_not_found} = ExPdfium.object_display_rotation(doc, 0, 999)
    end
  end

  describe "Reading: image_data/3 (decoded pixels)" do
    test "returns a decoded bitmap for an image object" do
      {:ok, doc} = ExPdfium.open(@images)
      {:ok, images} = ExPdfium.images(doc, 0)
      rgb = Enum.find(images, &(&1.filters == ["FlateDecode"] and &1.bits_per_pixel == 24))

      assert {:ok, %ExPdfium.Bitmap{} = bmp} = ExPdfium.image_data(doc, 0, rgb.index)
      assert bmp.width == 4
      assert bmp.height == 4
      assert bmp.format in [:gray, :bgr, :bgrx, :bgra]
      assert byte_size(bmp.data) > 0
      assert bmp.stride > 0
    end

    test "decodes a grayscale image to a single-channel bitmap" do
      {:ok, doc} = ExPdfium.open(@images)
      {:ok, images} = ExPdfium.images(doc, 0)
      gray = Enum.find(images, &(&1.bits_per_pixel == 8))

      assert {:ok, bmp} = ExPdfium.image_data(doc, 0, gray.index)
      assert bmp.format == :gray
      # one byte per pixel, so the row stride equals the width
      assert bmp.stride == bmp.width
    end

    test "a non-image object returns :not_an_image" do
      {:ok, doc} = ExPdfium.open(@images)
      {:ok, objects} = ExPdfium.page_objects(doc, 0)
      text = Enum.find(objects, &(&1.type == :text))
      assert {:error, :not_an_image} = ExPdfium.image_data(doc, 0, text.index)
    end

    test "a bad object index returns :object_not_found" do
      {:ok, doc} = ExPdfium.open(@images)
      assert {:error, :object_not_found} = ExPdfium.image_data(doc, 0, 999)
    end
  end

  describe "Reading: image_raw_data/3 (original encoded stream)" do
    test "returns the stored, still-encoded image stream" do
      {:ok, doc} = ExPdfium.open(@images)
      {:ok, images} = ExPdfium.images(doc, 0)
      rgb = Enum.find(images, &(&1.filters == ["FlateDecode"]))

      assert {:ok, raw} = ExPdfium.image_raw_data(doc, 0, rgb.index)
      assert is_binary(raw)
      assert byte_size(raw) > 0
    end

    test "a DCTDecode image's raw stream is a ready-to-write JPEG" do
      {:ok, doc} = ExPdfium.open(@images)
      {:ok, images} = ExPdfium.images(doc, 0)
      jpeg = Enum.find(images, &(&1.filters == ["DCTDecode"]))

      assert {:ok, <<0xFF, 0xD8, _::binary>>} = ExPdfium.image_raw_data(doc, 0, jpeg.index)
    end

    test "a non-image object returns :not_an_image" do
      {:ok, doc} = ExPdfium.open(@images)
      {:ok, objects} = ExPdfium.page_objects(doc, 0)
      path = Enum.find(objects, &(&1.type == :path))
      assert {:error, :not_an_image} = ExPdfium.image_raw_data(doc, 0, path.index)
    end
  end

  describe "Reading: image extraction concurrency" do
    test "page_objects/images/image_data are safe under concurrency" do
      {:ok, doc} = ExPdfium.open(@images)

      ok? =
        1..100
        |> Task.async_stream(
          fn _ ->
            {:ok, imgs} = ExPdfium.images(doc, 0)
            {:ok, objs} = ExPdfium.page_objects(doc, 0)
            img = Enum.find(imgs, &(&1.width == 4 and &1.bits_per_pixel == 24))
            {:ok, %ExPdfium.Bitmap{width: 4}} = ExPdfium.image_data(doc, 0, img.index)
            length(objs) >= 5 and length(imgs) == 3
          end,
          max_concurrency: 32,
          ordered: false
        )
        |> Enum.all?(fn {:ok, v} -> v end)

      assert ok?
    end
  end

  describe "Rendering: refinements" do
    test ":grayscale renders equal color channels on a red page" do
      {:ok, doc} = ExPdfium.open(@color)
      {:ok, color} = ExPdfium.render_page(doc, 0, dpi: 72)
      {:ok, gray} = ExPdfium.render_page(doc, 0, dpi: 72, grayscale: true)

      <<r, g, b, _, _::binary>> = color.data
      # The color render is genuinely red (R > B); grayscale equalizes the channels.
      assert r > b
      <<gr, gg, gb, _, _::binary>> = gray.data
      assert gr == gg and gg == gb
    end

    test ":annotations false changes the output on a page with annotations" do
      {:ok, doc} = ExPdfium.open(@forms)
      {:ok, with_annots} = ExPdfium.render_page(doc, 0, dpi: 72)
      {:ok, without} = ExPdfium.render_page(doc, 0, dpi: 72, annotations: false)

      assert {with_annots.width, with_annots.height} == {without.width, without.height}
      # forms.pdf has a highlight annotation, so suppressing annotations differs.
      assert with_annots.data != without.data
    end

    test ":form_fields false still renders a valid bitmap" do
      {:ok, doc} = ExPdfium.open(@forms)

      assert {:ok, %ExPdfium.Bitmap{data: data, width: w, height: h}} =
               ExPdfium.render_page(doc, 0, dpi: 72, form_fields: false)

      assert byte_size(data) == w * h * 4
    end

    test "a non-boolean toggle is rejected" do
      {:ok, doc} = ExPdfium.open(@sample)
      assert {:error, :bad_option} = ExPdfium.render_page(doc, 0, grayscale: "yes")
    end

    test "absurd render dimensions/scales are rejected before reaching pdfium" do
      {:ok, doc} = ExPdfium.open(@sample)
      assert {:error, :bad_option} = ExPdfium.render_page(doc, 0, width: 100_000)
      assert {:error, :bad_option} = ExPdfium.render_page(doc, 0, height: 1_000_000)
      assert {:error, :bad_option} = ExPdfium.render_page(doc, 0, dpi: 1.0e9)
      assert {:error, :bad_option} = ExPdfium.render_page(doc, 0, scale: 1000)
    end

    test "a hostile huge-MediaBox page is bounded, not OOM (no VM crash)" do
      # huge_page.pdf has a 40000x40000 MediaBox; the output-area check rejects it
      # before pdfium allocates a multi-GB bitmap.
      {:ok, doc} = ExPdfium.open(@huge_page)
      assert {:error, :render_failed} = ExPdfium.render_page(doc, 0)
      # The VM is fine and the document is still usable.
      assert {:ok, 1} = ExPdfium.page_count(doc)
    end
  end

  describe "Rendering: thumbnails/2" do
    test "renders one bitmap per page, defaulting to width 200" do
      {:ok, doc} = ExPdfium.open(@text)
      assert {:ok, [a, b]} = ExPdfium.thumbnails(doc)
      assert a.width == 200
      assert b.width == 200
      assert byte_size(a.data) == a.width * a.height * 4
    end

    test "passes sizing and other options through" do
      {:ok, doc} = ExPdfium.open(@text)
      assert {:ok, thumbs} = ExPdfium.thumbnails(doc, width: 64, grayscale: true)
      assert Enum.all?(thumbs, &(&1.width == 64))
    end

    test "a document with no pages returns an empty list" do
      {:ok, doc} = ExPdfium.new()
      assert {:ok, []} = ExPdfium.thumbnails(doc)
    end

    test "a closed document returns an error" do
      {:ok, doc} = ExPdfium.open(@text)
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.thumbnails(doc)
    end
  end

  describe "Editing: flatten" do
    test "flatten_page bakes annotations into content, removing them" do
      {:ok, doc} = ExPdfium.open(@forms)
      assert {:ok, annots} = ExPdfium.annotations(doc, 0)
      assert annots != []

      assert {:ok, ^doc} = ExPdfium.flatten_page(doc, 0)
      {:ok, bytes} = ExPdfium.save_to_bytes(doc)
      {:ok, re} = ExPdfium.open(bytes)
      # The annotations are now part of the page content, not annotation objects.
      assert {:ok, []} = ExPdfium.annotations(re, 0)
    end

    test "flattening a page with nothing to flatten is a no-op" do
      {:ok, doc} = ExPdfium.open(@sample)
      assert {:ok, ^doc} = ExPdfium.flatten_page(doc, 0)
    end

    test "flatten/1 flattens every page" do
      {:ok, doc} = ExPdfium.open(@forms)
      assert {:ok, ^doc} = ExPdfium.flatten(doc)
    end

    test "flatten errors on a bad page index and a closed document" do
      {:ok, doc} = ExPdfium.open(@forms)
      assert {:error, :page_out_of_bounds} = ExPdfium.flatten_page(doc, 9)
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.flatten_page(doc, 0)
      assert {:error, :document_closed} = ExPdfium.flatten(doc)
    end
  end

  describe "Reading: signatures/1" do
    test "an unsigned document returns an empty list" do
      {:ok, doc} = ExPdfium.open(@sample)
      assert {:ok, []} = ExPdfium.signatures(doc)
    end

    test "signatures on a closed document" do
      {:ok, doc} = ExPdfium.open(@sample)
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.signatures(doc)
    end
  end

  describe "Creating: new/0 and add_page" do
    test "creates an empty document and appends a sized page" do
      assert {:ok, doc} = ExPdfium.new()
      assert {:ok, 0} = ExPdfium.page_count(doc)
      assert {:ok, ^doc} = ExPdfium.add_page(doc, :letter)
      assert {:ok, 1} = ExPdfium.page_count(doc)

      {:ok, bytes} = ExPdfium.save_to_bytes(doc)
      {:ok, re} = ExPdfium.open(bytes)
      assert {:ok, %{width: 612.0, height: 792.0}} = ExPdfium.page_info(re, 0)
    end

    test "a custom page size in points" do
      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, {200, 300})
      assert {:ok, %{width: 200.0, height: 300.0}} = ExPdfium.page_info(doc, 0)
    end

    test "inserts a page at an index" do
      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, :letter)
      {:ok, doc} = ExPdfium.add_page(doc, :a4, at: 0)
      assert {:ok, 2} = ExPdfium.page_count(doc)
      {:ok, %{width: w}} = ExPdfium.page_info(doc, 0)
      assert round(w) == 595
    end

    test "an out-of-range insert index appends (pdfium clamps)" do
      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, :letter)
      assert {:ok, ^doc} = ExPdfium.add_page(doc, :a4, at: 99)
      assert {:ok, 2} = ExPdfium.page_count(doc)
    end

    test "an unrecognized page size is rejected" do
      {:ok, doc} = ExPdfium.new()
      assert {:error, :bad_page_size} = ExPdfium.add_page(doc, :a0)
    end
  end

  describe "Creating: draw_text/5" do
    test "draws text that round-trips through a save" do
      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, :letter)

      assert {:ok, ^doc} =
               ExPdfium.draw_text(doc, 0, {72, 700}, "Hello PDF",
                 font: :helvetica_bold,
                 size: 24,
                 color: {10, 20, 30}
               )

      {:ok, bytes} = ExPdfium.save_to_bytes(doc)
      {:ok, re} = ExPdfium.open(bytes)
      {:ok, text} = ExPdfium.extract_text(re, 0)
      assert text =~ "Hello PDF"
    end

    test "an unknown font is rejected" do
      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, :letter)

      assert {:error, :unknown_font} =
               ExPdfium.draw_text(doc, 0, {10, 10}, "x", font: :comic_sans)
    end

    test "drawing on an out-of-range page" do
      {:ok, doc} = ExPdfium.new()
      assert {:error, :page_out_of_bounds} = ExPdfium.draw_text(doc, 0, {10, 10}, "x")
    end

    test "drawing on a closed document returns an error, not a crash" do
      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, :letter)
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.draw_text(doc, 0, {10, 10}, "x")
    end

    test "an explicit alpha channel in the color is accepted" do
      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, :letter)

      assert {:ok, ^doc} =
               ExPdfium.draw_text(doc, 0, {72, 700}, "translucent", color: {0, 0, 0, 128})
    end
  end

  describe "Creating: shapes" do
    test "draws shapes that come back as path objects" do
      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, :letter)

      {:ok, doc} =
        ExPdfium.draw_rectangle(doc, 0, %{left: 50, bottom: 600, right: 300, top: 700},
          fill: {200, 200, 200},
          stroke: {0, 0, 0},
          stroke_width: 2
        )

      {:ok, doc} = ExPdfium.draw_line(doc, 0, {50, 590}, {300, 590}, stroke: {0, 0, 0})
      {:ok, doc} = ExPdfium.draw_circle(doc, 0, {150, 500}, 40, fill: {255, 0, 0})

      {:ok, bytes} = ExPdfium.save_to_bytes(doc)
      {:ok, re} = ExPdfium.open(bytes)
      {:ok, objects} = ExPdfium.page_objects(re, 0)
      assert Enum.count(objects, &(&1.type == :path)) >= 3
    end

    test "a negative stroke width is rejected when a stroke is drawn" do
      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, :letter)
      bounds = %{left: 0, bottom: 0, right: 10, top: 10}

      assert {:error, :bad_option} =
               ExPdfium.draw_line(doc, 0, {0, 0}, {10, 10}, stroke_width: -1.0)

      assert {:error, :bad_option} =
               ExPdfium.draw_rectangle(doc, 0, bounds, stroke: {0, 0, 0}, stroke_width: -1.0)

      assert {:error, :bad_option} =
               ExPdfium.draw_circle(doc, 0, {50, 50}, 10, stroke: {0, 0, 0}, stroke_width: -1.0)

      # A negative stroke width with no stroke is harmless (ignored).
      assert {:ok, ^doc} =
               ExPdfium.draw_rectangle(doc, 0, bounds, fill: {0, 0, 0}, stroke_width: -1.0)
    end
  end

  describe "Creating: draw_image/4" do
    test "embeds an :rgba bitmap that round-trips via images/2" do
      data = for _ <- 1..16, into: <<>>, do: <<255, 0, 0, 255>>
      bmp = %ExPdfium.Bitmap{data: data, width: 4, height: 4, stride: 16, format: :rgba}

      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, :letter)

      assert {:ok, ^doc} =
               ExPdfium.draw_image(doc, 0, bmp,
                 at: %{left: 100, bottom: 100, right: 300, top: 300}
               )

      {:ok, bytes} = ExPdfium.save_to_bytes(doc)
      {:ok, re} = ExPdfium.open(bytes)
      assert {:ok, [img]} = ExPdfium.images(re, 0)
      assert img.width == 4
      assert img.height == 4
    end

    test "embeds a :bgra bitmap that round-trips via images/2" do
      data = for _ <- 1..16, into: <<>>, do: <<0, 0, 255, 255>>
      bmp = %ExPdfium.Bitmap{data: data, width: 4, height: 4, stride: 16, format: :bgra}

      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, :letter)
      {:ok, doc} = ExPdfium.draw_image(doc, 0, bmp, at: %{left: 0, bottom: 0, right: 50, top: 50})

      {:ok, bytes} = ExPdfium.save_to_bytes(doc)
      {:ok, re} = ExPdfium.open(bytes)
      assert {:ok, [%{width: 4, height: 4}]} = ExPdfium.images(re, 0)
    end

    test "embeds a single-channel :gray bitmap" do
      bmp = %ExPdfium.Bitmap{
        data: :binary.copy(<<128>>, 16),
        width: 4,
        height: 4,
        stride: 4,
        format: :gray
      }

      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, :letter)
      {:ok, doc} = ExPdfium.draw_image(doc, 0, bmp, at: %{left: 0, bottom: 0, right: 40, top: 40})

      {:ok, bytes} = ExPdfium.save_to_bytes(doc)
      {:ok, re} = ExPdfium.open(bytes)
      assert {:ok, [%{width: 4, height: 4, bits_per_pixel: 8}]} = ExPdfium.images(re, 0)
    end

    test "drawing an image on a closed document returns an error, not a crash" do
      bmp = %ExPdfium.Bitmap{
        data: <<0, 0, 0, 255>>,
        width: 1,
        height: 1,
        stride: 4,
        format: :rgba
      }

      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, :letter)
      :ok = ExPdfium.close(doc)

      assert {:error, :document_closed} =
               ExPdfium.draw_image(doc, 0, bmp, at: %{left: 0, bottom: 0, right: 1, top: 1})
    end

    test "a bitmap whose buffer length doesn't match its dimensions is rejected" do
      bmp = %ExPdfium.Bitmap{data: <<1, 2, 3>>, width: 4, height: 4, stride: 16, format: :rgba}
      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, :letter)

      assert {:error, :bad_image_data} =
               ExPdfium.draw_image(doc, 0, bmp, at: %{left: 0, bottom: 0, right: 50, top: 50})
    end

    test "embeds :bgr and :gray bitmaps whose rows aren't 4-byte aligned (stride padding)" do
      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, :letter)

      # :bgr, width 1 -> 3 bytes/row, which pdfium pads to a 4-byte stride.
      bgr = %ExPdfium.Bitmap{
        data: <<10, 20, 30, 40, 50, 60>>,
        width: 1,
        height: 2,
        stride: 3,
        format: :bgr
      }

      assert {:ok, ^doc} =
               ExPdfium.draw_image(doc, 0, bgr, at: %{left: 0, bottom: 0, right: 10, top: 20})

      # :gray, width 3 -> 3 bytes/row, also padded.
      gray = %ExPdfium.Bitmap{
        data: <<1, 2, 3, 4, 5, 6>>,
        width: 3,
        height: 2,
        stride: 3,
        format: :gray
      }

      assert {:ok, ^doc} =
               ExPdfium.draw_image(doc, 0, gray, at: %{left: 20, bottom: 0, right: 40, top: 20})

      {:ok, bytes} = ExPdfium.save_to_bytes(doc)
      {:ok, re} = ExPdfium.open(bytes)
      assert {:ok, imgs} = ExPdfium.images(re, 0)
      assert length(imgs) == 2
    end

    test "a zero dimension is rejected" do
      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, :letter)
      bmp = %ExPdfium.Bitmap{data: <<>>, width: 0, height: 2, stride: 0, format: :rgba}

      assert {:error, :bad_image_data} =
               ExPdfium.draw_image(doc, 0, bmp, at: %{left: 0, bottom: 0, right: 10, top: 10})
    end

    test "absurd image dimensions are rejected (no overflow, no huge allocation)" do
      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, :letter)

      bmp = %ExPdfium.Bitmap{
        data: <<>>,
        width: 100_000,
        height: 100_000,
        stride: 0,
        format: :rgba
      }

      assert {:error, :bad_image_data} =
               ExPdfium.draw_image(doc, 0, bmp, at: %{left: 0, bottom: 0, right: 10, top: 10})
    end
  end

  describe "Annotating: authoring" do
    defp blank_page do
      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, :letter)
      doc
    end

    defp pixels(doc) do
      {:ok, bm} = ExPdfium.render_page(doc, 0, dpi: 72)
      bm.data
    end

    test "add_text_annotation/5 creates a sticky note that reads back" do
      doc = blank_page()
      before = pixels(doc)

      {:ok, doc} =
        ExPdfium.add_text_annotation(doc, 0, {72, 700}, "Check this", color: {255, 0, 0})

      {:ok, anns} = ExPdfium.annotations(doc, 0)
      assert note = Enum.find(anns, &(&1.type == :text))
      assert note.contents == "Check this"
      # A note icon visibly draws on the page.
      assert pixels(doc) != before
    end

    test "add_free_text_annotation/5 creates a visible text box" do
      doc = blank_page()
      before = pixels(doc)
      bounds = %{left: 72, bottom: 650, right: 300, top: 700}

      {:ok, doc} =
        ExPdfium.add_free_text_annotation(doc, 0, bounds, "DRAFT", fill: {255, 255, 0})

      {:ok, anns} = ExPdfium.annotations(doc, 0)
      assert ft = Enum.find(anns, &(&1.type == :free_text))
      assert ft.contents == "DRAFT"
      assert pixels(doc) != before
    end

    test "add_square_annotation/4 draws a box" do
      doc = blank_page()
      before = pixels(doc)
      bounds = %{left: 100, bottom: 500, right: 400, top: 650}

      {:ok, doc} =
        ExPdfium.add_square_annotation(doc, 0, bounds, fill: {0, 200, 255}, stroke: {0, 0, 0})

      {:ok, anns} = ExPdfium.annotations(doc, 0)
      assert Enum.find(anns, &(&1.type == :square))
      assert pixels(doc) != before
    end

    test "add_link_annotation/5 attaches a clickable URI" do
      doc = blank_page()
      bounds = %{left: 72, bottom: 690, right: 300, top: 705}

      {:ok, doc} =
        ExPdfium.add_link_annotation(doc, 0, bounds, "https://example.com")

      {:ok, links} = ExPdfium.links(doc, 0)
      assert Enum.any?(links, &(&1.uri == "https://example.com"))
    end

    test "annotations persist across save/reopen" do
      doc = blank_page()
      {:ok, doc} = ExPdfium.add_text_annotation(doc, 0, {72, 700}, "kept", [])
      {:ok, bytes} = ExPdfium.save_to_bytes(doc)

      {:ok, re} = ExPdfium.open(bytes)
      {:ok, anns} = ExPdfium.annotations(re, 0)
      assert Enum.find(anns, &(&1.contents == "kept"))
    end

    test "delete_annotation/3 removes one annotation by index" do
      doc = blank_page()
      {:ok, doc} = ExPdfium.add_text_annotation(doc, 0, {72, 700}, "first", [])

      {:ok, doc} =
        ExPdfium.add_square_annotation(doc, 0, %{left: 1, bottom: 1, right: 9, top: 9}, [])

      {:ok, before} = ExPdfium.annotations(doc, 0)
      assert length(before) == 2

      {:ok, doc} = ExPdfium.delete_annotation(doc, 0, 0)
      {:ok, after_} = ExPdfium.annotations(doc, 0)
      assert length(after_) == 1
      assert hd(after_).type == :square
    end

    test "delete_annotation/3 on an out-of-range index errors" do
      doc = blank_page()
      assert {:error, _} = ExPdfium.delete_annotation(doc, 0, 0)
    end

    test "authoring on an out-of-bounds page errors" do
      doc = blank_page()
      bounds = %{left: 0, bottom: 0, right: 10, top: 10}
      assert {:error, :page_out_of_bounds} = ExPdfium.add_square_annotation(doc, 99, bounds, [])

      assert {:error, :page_out_of_bounds} =
               ExPdfium.add_text_annotation(doc, 99, {0, 0}, "x", [])
    end

    test "authoring is safe under concurrency" do
      doc = blank_page()

      ok? =
        1..100
        |> Task.async_stream(
          fn i ->
            b = %{left: 10, bottom: 10 + rem(i, 50), right: 100, top: 30 + rem(i, 50)}
            match?({:ok, _}, ExPdfium.add_square_annotation(doc, 0, b, fill: {0, 200, 255}))
          end,
          max_concurrency: 16
        )
        |> Enum.all?(fn {:ok, v} -> v end)

      assert ok?
    end
  end

  describe "Creating: concurrency" do
    test "draw/save on a shared created document stays consistent" do
      {:ok, doc} = ExPdfium.new()
      {:ok, doc} = ExPdfium.add_page(doc, :letter)

      ok? =
        1..100
        |> Task.async_stream(
          fn i ->
            {:ok, ^doc} = ExPdfium.draw_text(doc, 0, {72, rem(i * 7, 700) + 20}, "line #{i}")
            {:ok, bytes} = ExPdfium.save_to_bytes(doc)
            byte_size(bytes) > 0
          end,
          max_concurrency: 16,
          ordered: false
        )
        |> Enum.all?(fn {:ok, v} -> v end)

      assert ok?
    end
  end

  describe "Writing: save_to_bytes/1 and save_to_file/2" do
    test "round-trips a document through bytes" do
      {:ok, doc} = ExPdfium.open(@text)
      assert {:ok, <<"%PDF", _::binary>> = bytes} = ExPdfium.save_to_bytes(doc)
      assert {:ok, reopened} = ExPdfium.open(bytes)
      assert {:ok, 2} = ExPdfium.page_count(reopened)
    end

    test "save_to_file writes a reopenable file" do
      {:ok, doc} = ExPdfium.open(@text)
      path = Path.join(System.tmp_dir!(), "ex_pdfium_#{System.unique_integer([:positive])}.pdf")
      on_exit(fn -> File.rm(path) end)
      assert :ok = ExPdfium.save_to_file(doc, path)
      assert {:ok, reopened} = ExPdfium.open(path)
      assert {:ok, 2} = ExPdfium.page_count(reopened)
    end

    test "saving does not close or alter the document" do
      {:ok, doc} = ExPdfium.open(@text)
      assert {:ok, _bytes} = ExPdfium.save_to_bytes(doc)
      assert {:ok, 2} = ExPdfium.page_count(doc)
    end

    test "save on a closed document" do
      {:ok, doc} = ExPdfium.open(@text)
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.save_to_bytes(doc)
      path = Path.join(System.tmp_dir!(), "ex_pdfium_closed.pdf")
      assert {:error, :document_closed} = ExPdfium.save_to_file(doc, path)
    end
  end

  describe "Writing: append/2" do
    test "merges another document's pages onto the end, returning the same handle" do
      {:ok, doc} = ExPdfium.open(@text)
      {:ok, src} = ExPdfium.open(@sample)
      assert {:ok, ^doc} = ExPdfium.append(doc, src)
      assert {:ok, 4} = ExPdfium.page_count(doc)

      {:ok, bytes} = ExPdfium.save_to_bytes(doc)
      {:ok, reopened} = ExPdfium.open(bytes)
      assert {:ok, 4} = ExPdfium.page_count(reopened)
      assert {:ok, t0} = ExPdfium.extract_text(reopened, 0)
      assert t0 =~ "Hello pdfium world"
    end

    test "appending a document to itself is rejected" do
      {:ok, doc} = ExPdfium.open(@text)
      assert {:error, :same_document} = ExPdfium.append(doc, doc)
    end

    test "append on a closed destination" do
      {:ok, doc} = ExPdfium.open(@text)
      {:ok, src} = ExPdfium.open(@sample)
      :ok = ExPdfium.close(doc)
      assert {:error, :document_closed} = ExPdfium.append(doc, src)
    end
  end

  describe "Writing: extract_pages/2" do
    test "creates a new document with the selected pages, in the given order" do
      {:ok, src} = ExPdfium.open(@text)
      assert {:ok, doc} = ExPdfium.extract_pages(src, [1, 0])
      assert {:ok, 2} = ExPdfium.page_count(doc)

      {:ok, bytes} = ExPdfium.save_to_bytes(doc)
      {:ok, reopened} = ExPdfium.open(bytes)
      assert {:ok, t0} = ExPdfium.extract_text(reopened, 0)
      assert {:ok, t1} = ExPdfium.extract_text(reopened, 1)
      assert t0 =~ "Second page text"
      assert t1 =~ "Hello pdfium world"
    end

    test "leaves the source document untouched" do
      {:ok, src} = ExPdfium.open(@text)
      assert {:ok, _doc} = ExPdfium.extract_pages(src, [0])
      assert {:ok, 2} = ExPdfium.page_count(src)
    end

    test "an out-of-range index is rejected before any copying" do
      {:ok, src} = ExPdfium.open(@text)
      assert {:error, :page_out_of_bounds} = ExPdfium.extract_pages(src, [0, 9])
    end

    test "a selection larger than the max page count is rejected up front" do
      {:ok, src} = ExPdfium.open(@text)

      assert {:error, :page_out_of_bounds} =
               ExPdfium.extract_pages(src, List.duplicate(0, 70_000))
    end

    test "an empty selection is rejected" do
      {:ok, src} = ExPdfium.open(@text)
      assert {:error, :empty_selection} = ExPdfium.extract_pages(src, [])
    end

    test "extract_pages on a closed document" do
      {:ok, src} = ExPdfium.open(@text)
      :ok = ExPdfium.close(src)
      assert {:error, :document_closed} = ExPdfium.extract_pages(src, [0])
    end
  end

  describe "Writing: delete_pages/2" do
    test "deletes a single page" do
      {:ok, doc} = ExPdfium.open(@text)
      assert {:ok, ^doc} = ExPdfium.delete_pages(doc, 0)
      assert {:ok, 1} = ExPdfium.page_count(doc)

      {:ok, bytes} = ExPdfium.save_to_bytes(doc)
      {:ok, reopened} = ExPdfium.open(bytes)
      assert {:ok, t0} = ExPdfium.extract_text(reopened, 0)
      assert t0 =~ "Second page text"
    end

    test "deletes an inclusive range" do
      {:ok, doc} = ExPdfium.open(@text)
      {:ok, src} = ExPdfium.open(@sample)
      {:ok, doc} = ExPdfium.append(doc, src)
      assert {:ok, ^doc} = ExPdfium.delete_pages(doc, 1..2)
      assert {:ok, 2} = ExPdfium.page_count(doc)
    end

    test "an out-of-range index is rejected" do
      {:ok, doc} = ExPdfium.open(@text)
      assert {:error, :page_out_of_bounds} = ExPdfium.delete_pages(doc, 5)
      assert {:error, :page_out_of_bounds} = ExPdfium.delete_pages(doc, 1..9)
    end

    test "deleting every page is refused" do
      {:ok, doc} = ExPdfium.open(@text)
      assert {:error, :cannot_delete_all_pages} = ExPdfium.delete_pages(doc, 0..1)
      assert {:ok, 2} = ExPdfium.page_count(doc)
    end

    test "descending or stepped ranges are rejected, not silently reinterpreted" do
      {:ok, doc} = ExPdfium.open(@text)
      assert {:error, :bad_range} = ExPdfium.delete_pages(doc, 1..0//-1)
      assert {:error, :bad_range} = ExPdfium.delete_pages(doc, 0..1//2)
      assert {:ok, 2} = ExPdfium.page_count(doc)
    end
  end

  describe "Writing: rotate_page/3" do
    test "rotates a page and persists it through a save" do
      {:ok, doc} = ExPdfium.open(@text)
      assert {:ok, ^doc} = ExPdfium.rotate_page(doc, 0, 90)

      {:ok, bytes} = ExPdfium.save_to_bytes(doc)
      {:ok, reopened} = ExPdfium.open(bytes)
      assert {:ok, %{rotation: 90}} = ExPdfium.page_info(reopened, 0)
    end

    test "an unsupported angle is rejected" do
      {:ok, doc} = ExPdfium.open(@text)
      assert {:error, :bad_rotation} = ExPdfium.rotate_page(doc, 0, 45)
    end

    test "an out-of-range page is rejected" do
      {:ok, doc} = ExPdfium.open(@text)
      assert {:error, :page_out_of_bounds} = ExPdfium.rotate_page(doc, 9, 90)
    end
  end

  describe "Writing: concurrency" do
    test "extract_pages/save are safe under concurrency" do
      {:ok, src} = ExPdfium.open(@text)

      ok? =
        1..100
        |> Task.async_stream(
          fn _ ->
            {:ok, doc} = ExPdfium.extract_pages(src, [1, 0])
            {:ok, bytes} = ExPdfium.save_to_bytes(doc)
            byte_size(bytes) > 0 and match?({:ok, 2}, ExPdfium.page_count(doc))
          end,
          max_concurrency: 32,
          ordered: false
        )
        |> Enum.all?(fn {:ok, v} -> v end)

      assert ok?
    end

    test "in-place mutators racing reads on a shared doc stay consistent" do
      {:ok, doc} = ExPdfium.open(@text)
      angles = [0, 90, 180, 270]

      ok? =
        1..200
        |> Task.async_stream(
          fn i ->
            # Hammer rotate (a mutator) and render/page_info (reads) on one shared
            # document. The global lock serializes them, so last-write-wins but the
            # document never corrupts: page_count is stable, rotation is always
            # valid, and a save still succeeds.
            {:ok, ^doc} = ExPdfium.rotate_page(doc, 0, Enum.at(angles, rem(i, 4)))
            {:ok, %{rotation: r}} = ExPdfium.page_info(doc, 0)
            {:ok, bytes} = ExPdfium.save_to_bytes(doc)

            r in angles and byte_size(bytes) > 0 and match?({:ok, 2}, ExPdfium.page_count(doc))
          end,
          max_concurrency: 32,
          ordered: false
        )
        |> Enum.all?(fn {:ok, v} -> v end)

      assert ok?
    end
  end

  describe "Ergonomics: bounds_to_pixels/3" do
    test "scales and Y-flips PDF points into raster pixels" do
      bounds = %{left: 100, bottom: 700, right: 200, top: 750}

      # dpi 72 → 1pt == 1px; only the Y-flip happens (page height 792).
      assert %{left: 100.0, right: 200.0, top: 42.0, bottom: 92.0} =
               ExPdfium.bounds_to_pixels(bounds, 792, 72)

      # dpi 144 → 2× scale on every axis.
      assert %{left: 200.0, right: 400.0, top: 84.0, bottom: 184.0} =
               ExPdfium.bounds_to_pixels(bounds, 792, 144)

      # default dpi is 72.
      assert ExPdfium.bounds_to_pixels(bounds, 792) ==
               ExPdfium.bounds_to_pixels(bounds, 792, 72)
    end

    test "round-trips a real page's text segment box" do
      {:ok, doc} = ExPdfium.open(@text)
      {:ok, %{height: h}} = ExPdfium.page_info(doc, 0)
      {:ok, [seg | _]} = ExPdfium.text_segments(doc, 0)
      px = ExPdfium.bounds_to_pixels(seg.bounds, h, 150)
      # top is above bottom in raster (y-down) space, and all within the raster.
      assert px.top < px.bottom
      assert px.left < px.right
      assert px.bottom <= h * 150 / 72
    end
  end

  describe "Documents: open_file/2 and open_blob/2" do
    test "open_file/2 opens a path, open_blob/2 opens bytes" do
      assert {:ok, _} = ExPdfium.open_file(@sample)
      assert {:ok, bytes} = File.read(@sample)
      assert {:ok, doc} = ExPdfium.open_blob(bytes)
      assert {:ok, n} = ExPdfium.page_count(doc)
      assert n > 0
    end

    test "the explicit variants don't guess source kind" do
      # Bytes handed to open_file/2 are treated as a path → not found.
      {:ok, bytes} = File.read(@sample)
      assert {:error, _} = ExPdfium.open_file(bytes)
      # A path handed to open_blob/2 is treated as bytes → not a PDF.
      assert {:error, :invalid_pdf} = ExPdfium.open_blob(@sample)
    end
  end

  describe "Metadata: parse_pdf_date/1" do
    test "parses a full date with a positive offset, normalized to UTC" do
      assert {:ok, dt} = ExPdfium.parse_pdf_date("D:20210812004758+01'00'")
      assert dt == ~U[2021-08-11 23:47:58Z]
    end

    test "parses Z, negative offsets, and truncated forms" do
      assert {:ok, ~U[2024-01-15 12:00:00Z]} = ExPdfium.parse_pdf_date("D:20240115120000Z")
      assert {:ok, ~U[2021-08-12 05:47:58Z]} = ExPdfium.parse_pdf_date("D:20210812004758-05'00'")
      # Missing offset → treated as UTC; truncated → lowest defaults.
      assert {:ok, ~U[2024-03-04 09:00:00Z]} = ExPdfium.parse_pdf_date("D:20240304090000")
      assert {:ok, ~U[2024-01-01 00:00:00Z]} = ExPdfium.parse_pdf_date("D:2024")
    end

    test "round-trips a real document's creation_date" do
      {:ok, doc} = ExPdfium.open(@meta)
      {:ok, %{creation_date: raw}} = ExPdfium.metadata(doc)
      assert is_binary(raw)
      assert {:ok, %DateTime{}} = ExPdfium.parse_pdf_date(raw)
    end

    test "errors on nil or garbage" do
      assert {:error, :invalid_date} = ExPdfium.parse_pdf_date(nil)
      assert {:error, :invalid_date} = ExPdfium.parse_pdf_date("not a date")
      assert {:error, :invalid_date} = ExPdfium.parse_pdf_date("D:20241399000000")
    end
  end

  describe "extract_text/3 :repair" do
    @tag :pdfium
    test "extract_text/3 with repair: :auto returns canonical Thai (no PUA)" do
      {:ok, doc} = ExPdfium.open("test/fixtures/thai_pua.pdf")
      {:ok, raw} = ExPdfium.extract_text(doc, 0)
      {:ok, fixed} = ExPdfium.extract_text(doc, 0, repair: :auto)
      :ok = ExPdfium.close(doc)

      assert Enum.any?(String.to_charlist(raw), &(&1 in 0xF700..0xF71A))
      refute Enum.any?(String.to_charlist(fixed), &(&1 in 0xF700..0xF71A))
    end
  end
end
