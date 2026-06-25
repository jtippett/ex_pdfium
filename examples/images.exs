# Inventory a page's objects and extract its images.
#
#   mix run examples/images.exs [path/to/file.pdf [page]]
#
# With no path, falls back to the bundled images fixture. For each image it prints
# the metadata, the decoded bitmap size, and — for DCTDecode (JPEG) images — writes
# the original stream straight out as a .jpg (lossless, no re-encoding).

{path, page} =
  case System.argv() do
    [p, page | _] -> {p, String.to_integer(page)}
    [p | _] -> {p, 0}
    _ -> {Path.join(__DIR__, "../test/fixtures/images.pdf"), 0}
  end

case ExPdfium.open(path) do
  {:ok, doc} ->
    IO.puts("# #{Path.basename(path)} — page #{page}")

    {:ok, objects} = ExPdfium.page_objects(doc, page)

    counts =
      objects
      |> Enum.frequencies_by(& &1.type)
      |> Enum.map_join(", ", fn {t, n} -> "#{n} #{t}" end)

    IO.puts("\n## Objects: #{counts}")

    {:ok, images} = ExPdfium.images(doc, page)

    if images == [] do
      IO.puts("\n## Images: (none)")
    else
      IO.puts("\n## Images")

      for img <- images do
        {:ok, bmp} = ExPdfium.image_data(doc, page, img.index)

        IO.puts(
          "  ##{img.index}: #{img.width}x#{img.height}px, #{img.bits_per_pixel}bpp, " <>
            "filters #{inspect(img.filters)} — decoded #{byte_size(bmp.data)} bytes (#{bmp.format})"
        )

        # A DCTDecode raw stream is already a JPEG file; write it out losslessly.
        if "DCTDecode" in img.filters do
          {:ok, raw} = ExPdfium.image_raw_data(doc, page, img.index)
          out = Path.join(System.tmp_dir!(), "ex_pdfium_image_#{img.index}.jpg")
          File.write!(out, raw)
          IO.puts("    wrote original JPEG -> #{out}")
        end
      end
    end

    ExPdfium.close(doc)

  {:error, reason} ->
    IO.puts("failed to open #{path}: #{inspect(reason)}")
    System.halt(1)
end
