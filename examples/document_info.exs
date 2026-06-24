# Print a document's metadata, first-page geometry, and permission flags.
#
#   mix run examples/document_info.exs [path/to/file.pdf]
#
# With no path, falls back to the bundled metadata fixture.

path =
  case System.argv() do
    [] -> Path.join(__DIR__, "../test/fixtures/meta.pdf")
    [path | _] -> path
  end

case ExPdfium.open(path) do
  {:ok, doc} ->
    {:ok, meta} = ExPdfium.metadata(doc)
    {:ok, info} = ExPdfium.page_info(doc, 0)
    {:ok, perms} = ExPdfium.permissions(doc)

    IO.puts("# #{Path.basename(path)}")
    IO.puts("\n## Metadata")
    for {k, v} <- meta, v != nil, do: IO.puts("  #{k}: #{v}")

    IO.puts("\n## Page 0")
    IO.puts("  #{info.width} x #{info.height} pts, rotation #{info.rotation}")
    IO.puts("  media box: #{inspect(info.boxes.media)}")

    IO.puts("\n## Permissions")
    for {k, v} <- Enum.sort(perms), do: IO.puts("  #{k}: #{v}")

    ExPdfium.close(doc)

  {:error, reason} ->
    IO.puts("failed to open #{path}: #{inspect(reason)}")
    System.halt(1)
end
