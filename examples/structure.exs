# Print a document's outline, page-0 links, and embedded files.
#
#   mix run examples/structure.exs [path/to/file.pdf]
#
# With no path, falls back to the bundled structure fixture.

path =
  case System.argv() do
    [] -> Path.join(__DIR__, "../test/fixtures/structure.pdf")
    [path | _] -> path
  end

defmodule Outline do
  def print(nodes, indent \\ 0) do
    for node <- nodes do
      page = if node.page, do: " -> page #{node.page}", else: ""
      IO.puts("#{String.duplicate("  ", indent)}- #{node.title}#{page}")
      print(node.children, indent + 1)
    end
  end
end

case ExPdfium.open(path) do
  {:ok, doc} ->
    IO.puts("# #{Path.basename(path)}")

    IO.puts("\n## Outline")
    {:ok, tree} = ExPdfium.outline(doc)
    if tree == [], do: IO.puts("  (none)"), else: Outline.print(tree)

    IO.puts("\n## Links on page 0")
    {:ok, links} = ExPdfium.links(doc, 0)

    for link <- links do
      target = link.uri || (link.page && "page #{link.page}") || "(unsupported)"
      IO.puts("  #{target}")
    end

    IO.puts("\n## Attachments")
    {:ok, files} = ExPdfium.attachments(doc)
    for f <- files, do: IO.puts("  [#{f.index}] #{f.name} (#{f.size} bytes)")

    ExPdfium.close(doc)

  {:error, reason} ->
    IO.puts("failed to open #{path}: #{inspect(reason)}")
    System.halt(1)
end
