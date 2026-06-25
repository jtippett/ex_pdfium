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

    test "a page with no images returns an empty list" do
      {:ok, doc} = ExPdfium.open(@text)
      assert {:ok, []} = ExPdfium.images(doc, 0)
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
end
