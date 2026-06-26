# Text Repair (Thai PUA) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a pure-Elixir layer that repairs Thai Private Use Area (U+F700–F71A) positioning-variant codepoints in extracted text back to canonical Thai Unicode, leaving raw extraction untouched.

**Architecture:** The Rust NIF keeps returning pdfium's faithful raw text. A new `ExPdfium.Text` module exposes `repair/1,2` and `detect/1`, dispatching to an internal list of regime modules (one today: `ExPdfium.Text.Repair.ThaiPua`, a deterministic codepoint table). `extract_text/3` gains a `repair:` option as sugar. No behaviour/plugin API yet — a plain module list, extracted into a behaviour only when a third regime arrives. See the design doc: `docs/plans/2026-06-26-text-repair-design.md`.

**Tech Stack:** Elixir, ExUnit. No new deps (NFKC, if ever needed, is `String.normalize/2`). Pure string functions — most tests need no PDF.

---

## Background the engineer needs

- **What a "regime" is:** a named text-encoding pathology + its repair. Phase 1 ships one: `:thai_pua`. A regime module exposes `id/0`, `kind/0`, `source/0`, `detect/1`, `apply/1`.
- **The Thai PUA problem:** legacy "Windows Thai" fonts encode repositioned tone-mark/vowel glyphs in U+F700–F71A. pdfium returns those private-use codepoints verbatim. They must be remapped to the canonical Thai block (U+0E00–0E7F). The map is **many-to-one** (several positioning variants → one canonical mark) and **1:1 per codepoint** (each PUA char → exactly one canonical char), so it is a safe per-codepoint substitution.
- **Provenance gate (important):** the table below is transcribed from the TLWG Thai-shaping doc + the Microsoft Thai PUA convention. The first web source we pulled had at least one transcription error (`F710→0E46`, but 0E46 is MAIYAMOK; MAI HAN-AKAT is `0E31`). **Every entry must be corroborated against a second source AND validated against the rendered fixture before this ships.** Targets must all fall in U+0E00–0E7F (a test enforces this).
- **Fixture already in place:** `test/fixtures/thai_pua.pdf` (single page, public-domain Thai Government Gazette union-dissolution notice — no personal PII). It contains 25 PUA chars, 6 distinct: F701, F702, F70A, F70B, F70E, F712. `test/fixtures/thai_pua.raw.txt` is the raw extraction, kept only as a build reference (delete in the final task).

---

## Task 1: ThaiPua regime — the table and `apply/1`

**Files:**
- Create: `lib/ex_pdfium/text/repair/thai_pua.ex`
- Test: `test/ex_pdfium/text/repair/thai_pua_test.exs`

**Step 1: Write the failing test**

```elixir
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
    assert out == <<0x0E34::utf8, 0x0E35::utf8, 0x0E48::utf8, 0x0E49::utf8, 0x0E4C::utf8, 0x0E47::utf8>>
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
end
```

**Step 2: Run test to verify it fails**

Run: `mix test test/ex_pdfium/text/repair/thai_pua_test.exs`
Expected: FAIL — `ExPdfium.Text.Repair.ThaiPua` is undefined.

**Step 3: Write minimal implementation**

```elixir
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

  @behaviour_note "Phase-1 regime; see ExPdfium.Text for the dispatch contract."

  # PUA variant => canonical Thai. Many-to-one: several positioning variants of a
  # mark collapse to the same canonical codepoint.
  @pua_map %{
    0xF700 => 0x0E10, # descenderless THO THAN
    0xF701 => 0x0E34, # SARA I (left-shifted)
    0xF702 => 0x0E35, # SARA II (left-shifted)
    0xF703 => 0x0E36, # SARA UE (left-shifted)
    0xF704 => 0x0E37, # SARA UEE (left-shifted)
    0xF705 => 0x0E48, # MAI EK (low-left)
    0xF706 => 0x0E49, # MAI THO (low-left)
    0xF707 => 0x0E4A, # MAI TRI (low-left)
    0xF708 => 0x0E4B, # MAI CHATTAWA (low-left)
    0xF709 => 0x0E4C, # THANTHAKHAT (low-left)
    0xF70A => 0x0E48, # MAI EK (low)
    0xF70B => 0x0E49, # MAI THO (low)
    0xF70C => 0x0E4A, # MAI TRI (low)
    0xF70D => 0x0E4B, # MAI CHATTAWA (low)
    0xF70E => 0x0E4C, # THANTHAKHAT (low)
    0xF70F => 0x0E0D, # descenderless YO YING
    0xF710 => 0x0E31, # MAI HAN-AKAT  (NOT 0E46 — see provenance note)
    0xF711 => 0x0E4D, # NIKHAHIT
    0xF712 => 0x0E47, # MAITAIKHU
    0xF713 => 0x0E48, # MAI EK (left)
    0xF714 => 0x0E49, # MAI THO (left)
    0xF715 => 0x0E4A, # MAI TRI (left)
    0xF716 => 0x0E4B, # MAI CHATTAWA (left)
    0xF717 => 0x0E4C, # THANTHAKHAT (left)
    0xF718 => 0x0E38, # SARA U (low)
    0xF719 => 0x0E39, # SARA UU (low)
    0xF71A => 0x0E3A  # PHINTHU (low)
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
```

**Step 4: Run test to verify it passes**

Run: `mix test test/ex_pdfium/text/repair/thai_pua_test.exs`
Expected: PASS (5 tests).

**Step 5: Commit**

```bash
git add lib/ex_pdfium/text/repair/thai_pua.ex test/ex_pdfium/text/repair/thai_pua_test.exs
git commit -m "feat(text): Thai PUA repair regime (table + apply/1)"
```

---

## Task 2: ThaiPua `detect/1`

Already implemented in Task 1, but give it explicit coverage.

**Files:**
- Modify: `test/ex_pdfium/text/repair/thai_pua_test.exs`

**Step 1: Write the failing test (append to the test module)**

```elixir
  test "detect/1 fires with evidence on PUA text" do
    assert {true, 1} = ThaiPua.detect("เจ" <> <<0xF70B::utf8>> <> "า")
  end

  test "detect/1 is false on clean Thai" do
    assert {false, 0} = ThaiPua.detect("สวัสดี")
  end
```

**Step 2–4: Run / verify**

Run: `mix test test/ex_pdfium/text/repair/thai_pua_test.exs`
Expected: PASS (7 tests). (Implementation already exists, so these pass immediately — that is acceptable for a behaviour already covered by Task 1's code.)

**Step 5: Commit**

```bash
git add test/ex_pdfium/text/repair/thai_pua_test.exs
git commit -m "test(text): cover ThaiPua.detect/1"
```

---

## Task 3: Public `ExPdfium.Text` — `repair/1,2` + `detect/1` + dispatch

**Files:**
- Create: `lib/ex_pdfium/text.ex`
- Test: `test/ex_pdfium/text_test.exs`

**Step 1: Write the failing test**

```elixir
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
end
```

**Step 2: Run to verify it fails**

Run: `mix test test/ex_pdfium/text_test.exs`
Expected: FAIL — `ExPdfium.Text` undefined.

**Step 3: Write minimal implementation**

```elixir
defmodule ExPdfium.Text do
  @moduledoc """
  Repair extracted text degraded by legacy font encodings, recovering canonical
  Unicode. This is a deliberate, explicit layer *over* the raw text the NIF
  returns — `extract_text/2` is never silently changed.

  > This is font-encoding canonicalization, **not** Unicode Normalization. For
  > NFC/NFKC (ligatures, presentation forms), pipe through `String.normalize/2`.

  ## Regimes

  A regime names a text-encoding pathology and (when recoverable) its repair.
  Phase 1 ships one: `:thai_pua` (see `ExPdfium.Text.Repair.ThaiPua`).

      {text, report} = ExPdfium.Text.repair(raw)              # :auto
      {text, report} = ExPdfium.Text.repair(raw, regimes: [:thai_pua])
      regimes        = ExPdfium.Text.detect(raw)
  """

  # Internal registry. Append modules here as scripts are added; extract into a
  # behaviour only when a third regime justifies it (YAGNI).
  @regimes [ExPdfium.Text.Repair.ThaiPua]

  @type report :: %{applied: [map()], flagged: [map()]}

  @doc "Detect (don't transform) which regimes apply. Returns one entry per firing regime."
  @spec detect(binary()) :: [map()]
  def detect(text) when is_binary(text) do
    for r <- @regimes, {true, evidence} = detect_one(r, text) do
      %{regime: r.id(), repairable?: r.kind() != :unrecoverable, evidence: evidence, source: r.source()}
    end
  end

  @doc "Repair `text`. `:regimes` is `:auto` (default) or a list of regime ids."
  @spec repair(binary(), keyword()) :: {binary(), report()}
  def repair(text, opts \\ []) when is_binary(text) do
    regimes = resolve(Keyword.get(opts, :regimes, :auto))

    {out, report} =
      Enum.reduce(regimes, {text, %{applied: [], flagged: []}}, fn r, {t, rep} ->
        case r.detect(t) do
          {false, _} ->
            {t, rep}

          {true, evidence} ->
            if r.kind() == :unrecoverable do
              {t, update(rep, :flagged, %{regime: r.id(), recommend: :ocr, evidence: evidence})}
            else
              {t2, n} = r.apply(t)
              {t2, update(rep, :applied, %{regime: r.id(), substitutions: n, source: r.source()})}
            end
        end
      end)

    {out, %{applied: Enum.reverse(report.applied), flagged: Enum.reverse(report.flagged)}}
  end

  # A regime only "fires" for detect/1 when evidence is non-zero.
  defp detect_one(regime, text) do
    case regime.detect(text) do
      {true, ev} when ev > 0 -> {true, ev}
      _ -> {false, 0}
    end
  end

  defp resolve(:auto), do: @regimes

  defp resolve(ids) when is_list(ids) do
    known = Map.new(@regimes, &{&1.id(), &1})

    Enum.map(ids, fn id ->
      Map.get(known, id) || raise ArgumentError, "unknown regime: #{inspect(id)}"
    end)
  end

  defp update(report, key, entry), do: Map.update!(report, key, &[entry | &1])
end
```

**Step 4: Run to verify it passes**

Run: `mix test test/ex_pdfium/text_test.exs`
Expected: PASS (6 tests).

**Step 5: Commit**

```bash
git add lib/ex_pdfium/text.ex test/ex_pdfium/text_test.exs
git commit -m "feat(text): ExPdfium.Text.repair/2 + detect/1 with regime dispatch"
```

---

## Task 4: `extract_text/3` `:repair` sugar

**Files:**
- Modify: `lib/ex_pdfium.ex:326` (the `extract_text(%Document{}, page_index)` clause)
- Test: `test/ex_pdfium_test.exs` (append) — pure test, no PDF needed via a thin seam OR mark NIF-backed

**Step 1: Write the failing test (append to `test/ex_pdfium_test.exs`)**

> This test is NIF-backed (it opens the fixture). It needs `priv/pdfium` present
> (`just fetch-pdfium`). Tag it so the pure suite stays PDF-free.

```elixir
  @tag :pdfium
  test "extract_text/3 with repair: :auto returns canonical Thai (no PUA)" do
    {:ok, doc} = ExPdfium.open("test/fixtures/thai_pua.pdf")
    {:ok, raw} = ExPdfium.extract_text(doc, 0)
    {:ok, fixed} = ExPdfium.extract_text(doc, 0, repair: :auto)
    :ok = ExPdfium.close(doc)

    assert Enum.any?(String.to_charlist(raw), &(&1 in 0xF700..0xF71A))
    refute Enum.any?(String.to_charlist(fixed), &(&1 in 0xF700..0xF71A))
  end
```

**Step 2: Run to verify it fails**

Run: `mix test test/ex_pdfium_test.exs --include pdfium`
Expected: FAIL — `extract_text/3` undefined (or arity error).

**Step 3: Modify the implementation**

Change the `/2` clause to accept an optional opts list (keeps `/2` callers working, adds `/3`):

```elixir
# Before (line ~326):
#   def extract_text(%Document{ref: ref}, page_index),
#     do: Native.document_extract_text(ref, page_index)

# After:
def extract_text(%Document{ref: ref}, page_index, opts \\ []) do
  with {:ok, raw} <- Native.document_extract_text(ref, page_index) do
    case Keyword.get(opts, :repair) do
      nil -> {:ok, raw}
      selection -> {text, _report} = ExPdfium.Text.repair(raw, regimes: selection); {:ok, text}
    end
  end
end
```

Update the `@spec`/`@doc` for `extract_text` to mention the `:repair` option and that it returns repaired text (the report is dropped — call `ExPdfium.Text.repair/2` directly for it).

**Step 4: Run to verify it passes**

Run: `mix test test/ex_pdfium_test.exs --include pdfium`
Expected: PASS.

**Step 5: Commit**

```bash
git add lib/ex_pdfium.ex test/ex_pdfium_test.exs
git commit -m "feat(text): extract_text/3 :repair sugar over ExPdfium.Text.repair"
```

---

## Task 5: Golden-fixture integration test (human-verified expected text)

**Files:**
- Create: `test/fixtures/thai_pua.expected.txt` (generated, then human-verified)
- Test: `test/ex_pdfium/text_golden_test.exs`

**Step 1: Generate the candidate golden and VERIFY IT BY EYE**

Run in `iex -S mix` (with `priv/pdfium` present):

```elixir
{:ok, doc} = ExPdfium.open("test/fixtures/thai_pua.pdf")
{:ok, raw} = ExPdfium.extract_text(doc, 0)
{fixed, report} = ExPdfium.Text.repair(raw)
IO.inspect(report.applied)
File.write!("test/fixtures/thai_pua.expected.txt", fixed)
IO.puts(fixed)
```

**STOP and verify:** read the printed Thai (or have a Thai reader / compare against
the rendered page via `render_page`). Confirm tone marks/vowels are correct —
e.g. `คำสั่ง`, `เลิก`, dates. Only commit the golden once it reads correctly.
If a glyph is wrong, fix the offending `@pua_map` entry in Task 1 and regenerate.

**Step 2: Write the test**

```elixir
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
```

**Step 3: Run to verify it passes**

Run: `mix test test/ex_pdfium/text_golden_test.exs --include pdfium`
Expected: PASS.

**Step 4: Commit**

```bash
git add test/fixtures/thai_pua.expected.txt test/ex_pdfium/text_golden_test.exs
git commit -m "test(text): golden-fixture test for Thai PUA repair"
```

---

## Task 6: Provenance guard, docs, CHANGELOG, cleanup

**Files:**
- Modify: `test/ex_pdfium/text/repair/thai_pua_test.exs` (append the guard)
- Modify: `CHANGELOG.md` (under `## [Unreleased]`)
- Delete: `test/fixtures/thai_pua.raw.txt`

**Step 1: Write the table-provenance guard test**

```elixir
  test "every table target is a canonical Thai codepoint, every key is in the PUA block" do
    for {pua, canonical} <- ThaiPua.__map__() do
      assert pua in 0xF700..0xF71A, "key #{Integer.to_string(pua, 16)} outside Thai PUA block"
      assert canonical in 0x0E00..0x0E7F, "target #{Integer.to_string(canonical, 16)} outside Thai block"
    end
  end
```

**Step 2: Run to verify it passes**

Run: `mix test test/ex_pdfium/text/repair/thai_pua_test.exs`
Expected: PASS.

**Step 3: Update CHANGELOG.md** under `## [Unreleased]`:

```markdown
## [Unreleased]

### Added
- **`ExPdfium.Text.repair/2` and `ExPdfium.Text.detect/1`** — a pure-Elixir layer
  that recovers canonical Unicode from legacy font encodings, leaving raw
  extraction untouched. First regime: `:thai_pua`, remapping the Windows Thai
  Private Use Area (U+F700–F71A) positioning variants to canonical Thai
  (U+0E00–0E7F). `extract_text/3` gains a `repair:` option as sugar.
```

**Step 4: Delete the build-reference raw text**

```bash
git rm test/fixtures/thai_pua.raw.txt
```

**Step 5: Full gate + commit**

Run:
```bash
mix format && mix compile --warnings-as-errors && mix test --include pdfium
```
Expected: format clean, no warnings, all green.

```bash
git add -A
git commit -m "docs(text): provenance guard, CHANGELOG, drop build-reference fixture"
```

---

## Definition of done

- `mix test --include pdfium` green; `mix compile --warnings-as-errors` clean; `mix format` clean.
- Golden text human-verified as correct Thai.
- Every `@pua_map` entry corroborated against ≥2 sources (the `F710→0E31` correction applied).
- Raw extraction APIs unchanged; `repair` is opt-in only.
- CHANGELOG updated; no `metadata`-style grab-bags; no behaviour/plugin API introduced.
