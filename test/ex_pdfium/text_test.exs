defmodule ExPdfium.TextTest do
  use ExUnit.Case, async: true
  alias ExPdfium.Text

  test "repair/1 auto-applies thai_pua and reports provenance" do
    {out, report} = Text.repair("เจ" <> <<0xF70B::utf8>> <> "า")
    assert out == "เจ้า"
    assert [%{regime: :thai_pua, substitutions: 1, source: src}] = report.applied
    assert src =~ "linux.thai.net"
    assert report.flagged == []
  end

  test "repair/1 is a no-op (empty report) on clean text" do
    assert {"สวัสดี", %{applied: [], flagged: []}} = Text.repair("สวัสดี")
  end

  test "repair/2 with explicit regimes" do
    {"เจ้า", report} = Text.repair("เจ" <> <<0xF70B::utf8>> <> "า", regimes: [:thai_pua])
    assert [%{regime: :thai_pua}] = report.applied
  end

  test "repair/2 raises on an unknown regime id" do
    assert_raise ArgumentError, ~r/unknown regime/, fn ->
      Text.repair("x", regimes: [:klingon])
    end
  end

  test "detect/1 lists repairable regimes with evidence" do
    assert [%{regime: :thai_pua, repairable?: true, evidence: 1, source: _}] =
             Text.detect("เจ" <> <<0xF70B::utf8>> <> "า")
  end

  test "detect/1 returns [] on clean text" do
    assert [] = Text.detect("สวัสดี")
  end

  test "repair/2 raises a clear error on a non-:auto, non-list :regimes value" do
    assert_raise ArgumentError, ~r/must be :auto or a list/, fn ->
      Text.repair("x", regimes: :thai_pua)
    end
  end

  test "repair/2 with a present-but-nil :regimes falls back to :auto" do
    {out, report} = Text.repair("เจ" <> <<0xF70B::utf8>> <> "า", regimes: nil)
    assert out == "เจ้า"
    assert [%{regime: :thai_pua}] = report.applied
  end
end
