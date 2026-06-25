# Author annotations on a page: a sticky note, a text box, a boxed callout, and a
# clickable link — then save.
#
#   mix run examples/annotate.exs [in.pdf] [out.pdf]
#
# With no input, starts from a blank Letter page. Writes to the given output path
# (default: a temp file) and prints where.

{src, out} =
  case System.argv() do
    [input, output | _] -> {input, output}
    [input] -> {input, Path.join(System.tmp_dir!(), "ex_pdfium_annotated.pdf")}
    _ -> {nil, Path.join(System.tmp_dir!(), "ex_pdfium_annotated.pdf")}
  end

start =
  if src do
    ExPdfium.open(src)
  else
    with {:ok, doc} <- ExPdfium.new(), do: ExPdfium.add_page(doc, :letter)
  end

with {:ok, doc} <- start,
     # A sticky-note icon with popup text.
     {:ok, doc} <-
       ExPdfium.add_text_annotation(doc, 0, {500, 720}, "Please review", color: {255, 210, 0}),
     # A visible text box (text renders in pdfium's default appearance color).
     {:ok, doc} <-
       ExPdfium.add_free_text_annotation(
         doc,
         0,
         %{left: 72, bottom: 690, right: 320, top: 715},
         "DRAFT — not for distribution",
         fill: {255, 250, 205},
         stroke: {200, 180, 0}
       ),
     # A boxed callout around a region of the page.
     {:ok, doc} <-
       ExPdfium.add_square_annotation(doc, 0, %{left: 60, bottom: 540, right: 540, top: 660},
         stroke: {220, 50, 50}
       ),
     # A clickable link covering a rectangle.
     {:ok, doc} <-
       ExPdfium.add_link_annotation(
         doc,
         0,
         %{left: 72, bottom: 510, right: 260, top: 525},
         "https://hex.pm/packages/ex_pdfium"
       ),
     :ok <- ExPdfium.save_to_file(doc, out) do
  {:ok, anns} = ExPdfium.annotations(doc, 0)
  IO.puts("wrote #{out} with #{length(anns)} annotation(s)")
else
  {:error, reason} ->
    IO.puts("annotation failed: #{inspect(reason)}")
    System.halt(1)
end
