# Compose a PDF from scratch: text, a rule, a box, a circle, and an image.
#
#   mix run examples/create.exs [out.pdf]
#
# Writes to the given path (default: a temp file) and prints where.

out =
  case System.argv() do
    [path | _] -> path
    _ -> Path.join(System.tmp_dir!(), "ex_pdfium_created.pdf")
  end

# A 64x64 RGBA gradient swatch to place on the page (no image file needed).
swatch =
  for y <- 0..63, x <- 0..63, into: <<>> do
    <<x * 4, y * 4, 128, 255>>
  end

bitmap = %ExPdfium.Bitmap{data: swatch, width: 64, height: 64, stride: 64 * 4, format: :rgba}

with {:ok, doc} <- ExPdfium.new(),
     {:ok, doc} <- ExPdfium.add_page(doc, :letter),
     {:ok, doc} <-
       ExPdfium.draw_text(doc, 0, {72, 720}, "ExPdfium", font: :helvetica_bold, size: 28),
     {:ok, doc} <-
       ExPdfium.draw_text(doc, 0, {72, 700}, "a PDF composed from scratch",
         font: :helvetica,
         size: 12,
         color: {90, 90, 90}
       ),
     {:ok, doc} <- ExPdfium.draw_line(doc, 0, {72, 690}, {540, 690}, stroke: {0, 0, 0}),
     {:ok, doc} <-
       ExPdfium.draw_rectangle(doc, 0, %{left: 72, bottom: 560, right: 540, top: 660},
         fill: {245, 245, 245},
         stroke: {200, 200, 200},
         stroke_width: 1
       ),
     {:ok, doc} <- ExPdfium.draw_circle(doc, 0, {120, 610}, 28, fill: {220, 50, 50}),
     {:ok, doc} <-
       ExPdfium.draw_image(doc, 0, bitmap, at: %{left: 440, bottom: 580, right: 520, top: 660}),
     :ok <- ExPdfium.save_to_file(doc, out) do
  IO.puts("wrote #{out}")
else
  {:error, reason} ->
    IO.puts("creation failed: #{inspect(reason)}")
    System.halt(1)
end
