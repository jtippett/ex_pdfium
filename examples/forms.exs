# Print a document's form type, AcroForm field values, and page-0 annotations.
#
#   mix run examples/forms.exs [path/to/file.pdf]
#
# With no path, falls back to the bundled forms fixture.

path =
  case System.argv() do
    [] -> Path.join(__DIR__, "../test/fixtures/forms.pdf")
    [path | _] -> path
  end

case ExPdfium.open(path) do
  {:ok, doc} ->
    IO.puts("# #{Path.basename(path)}")

    {:ok, form_type} = ExPdfium.form_type(doc)
    IO.puts("\nForm type: #{form_type}")

    IO.puts("\n## Form fields")
    {:ok, fields} = ExPdfium.form_fields(doc)

    if fields == [] do
      IO.puts("  (none)")
    else
      for f <- fields do
        state =
          cond do
            f.checked == true -> "[x]"
            f.checked == false -> "[ ]"
            true -> inspect(f.value)
          end

        IO.puts("  #{f.name} (#{f.type}, page #{f.page}): #{state}")
      end
    end

    IO.puts("\n## Annotations on page 0")
    {:ok, anns} = ExPdfium.annotations(doc, 0)

    if anns == [] do
      IO.puts("  (none)")
    else
      for a <- anns do
        note = if a.contents, do: " — #{a.contents}", else: ""
        IO.puts("  #{a.type}#{note}")
      end
    end

    ExPdfium.close(doc)

  {:error, reason} ->
    IO.puts("failed to open #{path}: #{inspect(reason)}")
    System.halt(1)
end
