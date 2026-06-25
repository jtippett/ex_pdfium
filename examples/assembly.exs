# Assemble PDFs: merge two documents, rotate a page, save; then extract a subset.
#
#   mix run examples/assembly.exs [a.pdf b.pdf]
#
# With no paths, falls back to the bundled text + sample fixtures.

{a_path, b_path} =
  case System.argv() do
    [a, b | _] ->
      {a, b}

    _ ->
      {Path.join(__DIR__, "../test/fixtures/text.pdf"),
       Path.join(__DIR__, "../test/fixtures/sample.pdf")}
  end

out_dir = System.tmp_dir!()

with {:ok, a} <- ExPdfium.open(a_path),
     {:ok, b} <- ExPdfium.open(b_path),
     {:ok, na} <- ExPdfium.page_count(a),
     {:ok, nb} <- ExPdfium.page_count(b),
     # Merge b onto a, rotate the first page, and save the combined document.
     {:ok, a} <- ExPdfium.append(a, b),
     {:ok, a} <- ExPdfium.rotate_page(a, 0, 90),
     merged = Path.join(out_dir, "ex_pdfium_merged.pdf"),
     :ok <- ExPdfium.save_to_file(a, merged),
     {:ok, total} <- ExPdfium.page_count(a),
     # Extract a reversed subset of the first document into a new file.
     {:ok, subset} <- ExPdfium.extract_pages(a, Enum.to_list((na - 1)..0//-1)),
     subset_path = Path.join(out_dir, "ex_pdfium_subset.pdf"),
     :ok <- ExPdfium.save_to_file(subset, subset_path) do
  IO.puts("Merged #{na} + #{nb} pages -> #{total} pages")
  IO.puts("  wrote #{merged} (page 0 rotated 90°)")
  IO.puts("  wrote #{subset_path} (first #{na} pages, reversed)")
else
  {:error, reason} ->
    IO.puts("assembly failed: #{inspect(reason)}")
    System.halt(1)
end
