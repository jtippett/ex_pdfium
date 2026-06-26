defmodule ExPdfium.TextGoldenTest do
  use ExUnit.Case, async: true

  @tag :pdfium
  test "repair of the fixture matches the human-verified golden" do
    {:ok, doc} = ExPdfium.open("test/fixtures/thai_pua.pdf")
    {:ok, raw} = ExPdfium.extract_text(doc, 0)
    :ok = ExPdfium.close(doc)

    # The fixture genuinely exercises the regime.
    assert Enum.any?(String.to_charlist(raw), &(&1 in 0xF700..0xF71A))

    {fixed, report} = ExPdfium.Text.repair(raw)
    expected = File.read!("test/fixtures/thai_pua.expected.txt")

    assert fixed == expected
    assert [%{regime: :thai_pua}] = report.applied
    refute Enum.any?(String.to_charlist(fixed), &(&1 in 0xF700..0xF71A))
  end
end
