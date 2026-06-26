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
end
