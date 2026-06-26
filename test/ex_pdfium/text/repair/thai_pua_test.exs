defmodule ExPdfium.Text.Repair.ThaiPuaTest do
  use ExUnit.Case, async: true
  alias ExPdfium.Text.Repair.ThaiPua

  # "เจ" + U+F70B (low MAI THO) + "า"  =>  "เจ้า"  (U+F70B -> U+0E49)
  test "apply/1 remaps a tone-mark PUA variant to canonical" do
    input = "เจ" <> <<0xF70B::utf8>> <> "า"
    assert {"เจ้า", 1} = ThaiPua.apply(input)
  end

  test "apply/1 leaves clean Thai untouched and reports zero substitutions" do
    assert {"สวัสดี", 0} = ThaiPua.apply("สวัสดี")
  end

  test "apply/1 remaps every distinct PUA codepoint in the fixture" do
    input = <<0xF701::utf8, 0xF702::utf8, 0xF70A::utf8, 0xF70B::utf8, 0xF70E::utf8, 0xF712::utf8>>
    {out, 6} = ThaiPua.apply(input)

    assert out ==
             <<0x0E34::utf8, 0x0E35::utf8, 0x0E48::utf8, 0x0E49::utf8, 0x0E4C::utf8,
               0x0E47::utf8>>
  end

  test "apply/1 is idempotent (no PUA survives a second pass)" do
    input = "เจ" <> <<0xF70B::utf8>> <> "า"
    {once, _} = ThaiPua.apply(input)
    assert {^once, 0} = ThaiPua.apply(once)
  end

  property_no_pua = "no U+F700-F71A codepoint survives apply/1"

  test property_no_pua do
    input = <<0xF700::utf8, 0xF71A::utf8, ?a, 0xF70B::utf8>>
    {out, _} = ThaiPua.apply(input)
    refute Enum.any?(String.to_charlist(out), fn c -> c in 0xF700..0xF71A end)
  end

  test "detect/1 fires with evidence on PUA text" do
    assert {true, 1} = ThaiPua.detect("เจ" <> <<0xF70B::utf8>> <> "า")
  end

  test "detect/1 is false on clean Thai" do
    assert {false, 0} = ThaiPua.detect("สวัสดี")
  end

  test "every table key is in the Thai PUA block and every target is canonical Thai" do
    for {pua, canonical} <- ThaiPua.__map__() do
      assert pua in 0xF700..0xF71A,
             "key U+#{Integer.to_string(pua, 16)} is outside the Thai PUA block F700-F71A"

      assert canonical in 0x0E00..0x0E7F,
             "target U+#{Integer.to_string(canonical, 16)} is outside the Thai block 0E00-0E7F"
    end
  end

  # The bulk of the table is three positioning families of the five tone marks.
  # Each family must map IN ORDER onto MAI EK..THANTHAKHAT (U+0E48–0E4C). This is
  # the structural guard that catches a transcription slip in the repetitive rows
  # (the failure mode that produced the original F710 -> 0E46 error).
  test "each tone-mark family maps in order onto MAI EK..THANTHAKHAT (0E48-0E4C)" do
    map = ThaiPua.__map__()
    tone_marks = [0x0E48, 0x0E49, 0x0E4A, 0x0E4B, 0x0E4C]

    for {family, base} <- [{"low-left", 0xF705}, {"low", 0xF70A}, {"left", 0xF713}] do
      actual = for offset <- 0..4, do: Map.fetch!(map, base + offset)

      assert actual == tone_marks,
             "#{family} tone family (U+#{Integer.to_string(base, 16)}..) must map to " <>
               "0E48..0E4C in order, got #{inspect(Enum.map(actual, &Integer.to_string(&1, 16)))}"
    end
  end
end
