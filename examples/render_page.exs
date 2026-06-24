# Render a PDF page to a raw RGBA bitmap and report its dimensions.
#
#   mix run examples/render_page.exs [path/to/file.pdf] [page_index] [dpi]
#
# With no path, falls back to the bundled test fixture. To write a PNG you'd hand
# `data` to Vix/Image (see the README); this example just prints the buffer stats.

{path, page, dpi} =
  case System.argv() do
    [] -> {Path.join(__DIR__, "../test/fixtures/sample.pdf"), 0, 150}
    [path] -> {path, 0, 150}
    [path, page] -> {path, String.to_integer(page), 150}
    [path, page, dpi | _] -> {path, String.to_integer(page), String.to_integer(dpi)}
  end

with {:ok, doc} <- ExPdfium.open(path),
     {:ok, bm} <- ExPdfium.render_page(doc, page, dpi: dpi) do
  IO.puts(
    "#{Path.basename(path)} page #{page} @ #{dpi}dpi: " <>
      "#{bm.width}x#{bm.height} #{bm.format}, #{byte_size(bm.data)} bytes"
  )

  ExPdfium.close(doc)
else
  {:error, reason} ->
    IO.puts("render failed: #{inspect(reason)}")
    System.halt(1)
end
