defmodule ExPdfium.Text.Repair.ThaiPua do
  @moduledoc """
  Repairs the legacy "Windows Thai" Private Use Area (U+F700–F71A).

  Pre-OpenType Thai fonts encode repositioned tone-mark and vowel glyphs in this
  private block; their ToUnicode CMaps therefore report PUA codepoints, which
  pdfium returns verbatim. Each is a positioning variant of a canonical Thai
  character (U+0E00–0E7F); this regime maps it back, 1:1 per codepoint.

  Source: TLWG Thai shaping (https://linux.thai.net/~thep/th-otf/shaping.html) and
  the Microsoft Thai PUA convention. Each entry corroborated against a second
  source and validated against the rendered fixture (`test/fixtures/thai_pua.pdf`).
  """

  # Phase-1 regime; see ExPdfium.Text for the dispatch contract.

  # PUA variant => canonical Thai. Many-to-one: several positioning variants of a
  # mark collapse to the same canonical codepoint.
  @pua_map %{
    # descenderless THO THAN
    0xF700 => 0x0E10,
    # SARA I (left-shifted)
    0xF701 => 0x0E34,
    # SARA II (left-shifted)
    0xF702 => 0x0E35,
    # SARA UE (left-shifted)
    0xF703 => 0x0E36,
    # SARA UEE (left-shifted)
    0xF704 => 0x0E37,
    # MAI EK (low-left)
    0xF705 => 0x0E48,
    # MAI THO (low-left)
    0xF706 => 0x0E49,
    # MAI TRI (low-left)
    0xF707 => 0x0E4A,
    # MAI CHATTAWA (low-left)
    0xF708 => 0x0E4B,
    # THANTHAKHAT (low-left)
    0xF709 => 0x0E4C,
    # MAI EK (low)
    0xF70A => 0x0E48,
    # MAI THO (low)
    0xF70B => 0x0E49,
    # MAI TRI (low)
    0xF70C => 0x0E4A,
    # MAI CHATTAWA (low)
    0xF70D => 0x0E4B,
    # THANTHAKHAT (low)
    0xF70E => 0x0E4C,
    # descenderless YO YING
    0xF70F => 0x0E0D,
    # MAI HAN-AKAT  (NOT 0E46 — see provenance note)
    0xF710 => 0x0E31,
    # NIKHAHIT
    0xF711 => 0x0E4D,
    # MAITAIKHU
    0xF712 => 0x0E47,
    # MAI EK (left)
    0xF713 => 0x0E48,
    # MAI THO (left)
    0xF714 => 0x0E49,
    # MAI TRI (left)
    0xF715 => 0x0E4A,
    # MAI CHATTAWA (left)
    0xF716 => 0x0E4B,
    # THANTHAKHAT (left)
    0xF717 => 0x0E4C,
    # SARA U (low)
    0xF718 => 0x0E38,
    # SARA UU (low)
    0xF719 => 0x0E39,
    # PHINTHU (low)
    0xF71A => 0x0E3A
  }

  def id, do: :thai_pua
  def kind, do: :pua_repair
  def source, do: "https://linux.thai.net/~thep/th-otf/shaping.html"

  @doc "Returns {repairable?, evidence} where evidence is the count of mappable PUA codepoints."
  def detect(text) when is_binary(text) do
    count = text |> String.to_charlist() |> Enum.count(&Map.has_key?(@pua_map, &1))
    {count > 0, count}
  end

  @doc "Returns {repaired_text, substitution_count}."
  def apply(text) when is_binary(text) do
    {chars, n} =
      text
      |> String.to_charlist()
      |> Enum.map_reduce(0, fn cp, n ->
        case @pua_map do
          %{^cp => canonical} -> {canonical, n + 1}
          _ -> {cp, n}
        end
      end)

    {List.to_string(chars), n}
  end

  @doc false
  def __map__, do: @pua_map
end
