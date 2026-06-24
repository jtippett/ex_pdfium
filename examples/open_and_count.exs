# Open a PDF and report its page count.
#
#   mix run examples/open_and_count.exs [path/to/file.pdf] [password]
#
# With no path, falls back to the bundled test fixture.

{path, opts} =
  case System.argv() do
    [] -> {Path.join(__DIR__, "../test/fixtures/sample.pdf"), []}
    [path] -> {path, []}
    [path, password | _] -> {path, [password: password]}
  end

case ExPdfium.open(path, opts) do
  {:ok, doc} ->
    {:ok, count} = ExPdfium.page_count(doc)
    IO.puts("#{Path.basename(path)}: #{count} page(s)")
    :ok = ExPdfium.close(doc)

  {:error, reason} ->
    IO.puts("could not open #{path}: #{inspect(reason)}")
    System.halt(1)
end
