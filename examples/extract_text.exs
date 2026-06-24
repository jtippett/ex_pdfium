# Extract a page's text and (optionally) search it.
#
#   mix run examples/extract_text.exs [path/to/file.pdf] [page_index] [search term]
#
# With no path, falls back to the bundled text fixture.

{path, page, query} =
  case System.argv() do
    [] -> {Path.join(__DIR__, "../test/fixtures/text.pdf"), 0, "pdfium"}
    [path] -> {path, 0, nil}
    [path, page] -> {path, String.to_integer(page), nil}
    [path, page, query | _] -> {path, String.to_integer(page), query}
  end

with {:ok, doc} <- ExPdfium.open(path),
     {:ok, text} <- ExPdfium.extract_text(doc, page) do
  IO.puts("--- #{Path.basename(path)} page #{page} text ---")
  IO.puts(text)

  if query do
    case ExPdfium.search_text(doc, page, query) do
      {:ok, matches} ->
        IO.puts("\n--- #{length(matches)} match(es) for #{inspect(query)} ---")

        for %{text: t, rects: rects} <- matches do
          IO.puts("#{inspect(t)} at #{length(rects)} rect(s)")
        end

      {:error, reason} ->
        IO.puts("search failed: #{inspect(reason)}")
    end
  end

  ExPdfium.close(doc)
else
  {:error, reason} ->
    IO.puts("failed: #{inspect(reason)}")
    System.halt(1)
end
