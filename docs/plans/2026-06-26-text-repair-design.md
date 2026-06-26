# Text repair: recovering canonical Unicode from legacy font encodings

Status: accepted (2026-06-26). A new pure-Elixir layer over the faithful raw
text the NIF already returns. Ships Thai PUA repair first; the contract is shaped
to grow to other scripts and to legacy-encoding conversion later.

## Problem

pdfium returns exactly what a PDF's ToUnicode CMap specifies. For a large class
of real-world PDFs that text is *not* the canonical Unicode a reader expects:

- **PUA positioning variants.** Thai (and Lao) fonts encode repositioned
  tone-mark/vowel glyphs in the legacy "Windows Thai" Private Use block
  (U+F700–F71A). A born-digital Thai gazette extracts `เจ` + `U+F70B` + `า`
  where the canonical text is `เจ้า` (the `U+F70B` should be `U+0E49`, MAI THO).
  The text layer is real and complete; only the codepoints are private-use.
- **Legacy encodings mapped onto ASCII.** Other fonts (Myanmar Zawgyi, Indic
  Kruti Dev / DevLys, Vietnamese VNI) map the script onto Latin/ASCII positions.
  Extraction yields scrambled Latin. This is recoverable only with a
  font-specific, context-sensitive converter, and detection is probabilistic.
- **Unrecoverable.** A genuinely broken or absent ToUnicode CMap. No table
  recovers it; the only path is OCR of the rendered page.

We confirmed all three against the live corpus: one Thai source extracts clean
Thai once F700 is remapped (98 PUA hits/page, 6 distinct codepoints); another
extracts ~370 Latin letters vs ~220 Thai — the legacy-encoding/unrecoverable
class.

## Why this is a repair layer, not a pdfium change, and not "normalization"

- **Raw stays raw.** The NIF (`extract_text`, `chars`, `text_segments`) keeps
  returning pdfium's faithful output, unchanged. Repair is a separate, explicit
  step. The raw/repaired boundary is the language boundary: Rust = faithful
  binding, Elixir = repair.
- **Pure Elixir, not Rust.** ex_pdfium ships a *precompiled* NIF. A mapping
  table in Rust would force a tagged release + build matrix + checksum regen for
  every table edit. In Elixir it is a one-line change, testable without a PDF.
- **"repair", not "normalize".** In Elixir, `normalize` already means Unicode
  NFC/NFKC (`String.normalize/2`). This layer does font-encoding canonicalization
  — related but distinct. Naming it `normalize` would mis-set the reader's model.

## There is no universal PUA table — by definition

The Unicode Standard assigns no meaning to the Private Use Area; interpretation
is by private agreement, so the same codepoint differs across fonts. An omnibus
"fix all PUA" table cannot exist. What exists instead:

- **Adobe Glyph List (AGL/AGLFN)** — the de-facto standard for the *common*
  symbol/typographic case (©, ™, ligatures, small caps), keyed by glyph *name*,
  in Adobe's Corporate Use Subarea. Every PDF tool uses it, and pdfium almost
  certainly already applies it during extraction. It does **not** cover Thai
  F700 (a Microsoft per-script convention, keyed by codepoint, not name).
- **Per-script convention tables** — Thai F700 from TLWG / the Windows Thai
  convention (~27 deterministic entries).
- **Per-encoding transforms** — ICU 58+ ships `Zawgyi-my` from CLDR; Google
  `myanmar-tools` detects + converts; Indic converters publish tables. These are
  the wells we draw the *encoding-conversion* regimes from later — we wrap, we do
  not write converters.
- **`String.normalize(text, :nfkc)`** — the standardized class (ligatures,
  presentation forms, fullwidth). Free in the stdlib; never a bespoke table.

So the deterministic source for Thai is a small, validated, hand-transcribed
table — not because we are reinventing a wheel, but because no wheel exists for
the private case, and the data is ~27 rows.

## Public API (minimal, extendable)

```elixir
# Pure primitive — the raw/repaired split is explicit and testable without a PDF.
ExPdfium.Text.repair(raw)                       # :auto — detect + apply all repairable regimes
ExPdfium.Text.repair(raw, regimes: [:thai_pua]) # explicit subset
# => {repaired, %{
#      applied: [%{regime: :thai_pua, substitutions: 98, source: "linux.thai.net/~thep/..."}],
#      flagged: []   # detected-but-not-repairable, e.g. %{regime: :broken_cmap, recommend: :ocr}
#    }}

# Detection without transforming — drives an extract-vs-OCR gate downstream.
ExPdfium.Text.detect(raw)
# => [%{regime: :thai_pua, repairable?: true, evidence: 98,
#       source: "linux.thai.net/~thep/..."}]

# Sugar on extraction; raw remains the default.
ExPdfium.extract_text(doc, page, repair: :auto | [regimes])
```

Rules, each grounded in prior art:

- **`:auto` applies only repairable regimes whose detector fires.** PUA detection
  is structural (presence of F700–F71A) — near-zero false positive, because PUA
  has no legitimate meaning in output text.
- **Unrecoverable regimes are flag-only.** `detect/1` reports them with
  `repairable?: false` and `recommend: :ocr`; `repair/2` never mutates them.
- **`chars/3` repair is restricted to 1:1 regimes.** A codepoint swap leaves
  bounds/origin/font_size valid; many-to-one transforms (NFKC ligature splits)
  do not, so they are text-level only.

## Internal structure — a list, not a behaviour

No public plugin API yet (one real regime does not justify a framework). A
private registry the team appends to:

```elixir
# lib/ex_pdfium/text/repair.ex
@regimes [ExPdfium.Text.Repair.ThaiPua]   # add modules here as scripts are added

# Each regime module exposes:
#   id()       :: atom                         # :thai_pua
#   kind()     :: :pua_repair | :encoding_convert | :unrecoverable
#   source()   :: String.t                     # citation, shown in the report
#   detect(t)  :: {repairable? :: boolean, evidence :: term}   # structural now; room for probability
#   apply(t)   :: {String.t, substitutions :: non_neg_integer}
```

`detect/1` returning `{boolean, evidence}` rather than a bare boolean is the one
deliberate hook for the future `:encoding_convert` class, whose detection is
probabilistic (e.g. a Zawgyi probability). It costs nothing now and avoids a
contract change later. When a third regime arrives, this list + module shape
extracts cleanly into a behaviour — not before.

## Phase 1 scope

In scope:

- `ExPdfium.Text.repair/1,2` and `ExPdfium.Text.detect/1`.
- `ExPdfium.Text.Repair.ThaiPua` — the F700–F71A table, every entry corroborated
  against ≥2 sources (TLWG + Microsoft/ICU/CLDR) before shipping. Entries that
  cannot be corroborated are omitted, not guessed. (The first web source we
  pulled had at least one transcription error — `F710→0E46` where MAI HAN-AKAT
  is 0E31 — which is exactly why corroboration is a hard gate.)
- The `repair:` option on `extract_text/3`.

Out of scope (deferred until a real case appears):

- Any `:encoding_convert` regime (Zawgyi, Indic) — these wrap ICU/myanmar-tools.
- A `:symbol_pua` regime — AGL covers it and pdfium likely already applies it.
- An NFKC/compat regime — callers pipe through `String.normalize/2` themselves;
  we do not re-export the stdlib.
- A public behaviour / plugin API.

## Testing

- **Pure unit tests (no PDF).** One assertion per table row
  (`"เจ" <> <<0xF70B::utf8>> <> "า"` → `"เจ้า"`); idempotence (`repair` twice ==
  once); a property that no F700-block codepoint survives `repair`; `detect/1`
  true/false on with/without-PUA strings.
- **Golden fixture from a real offending PDF.** Add a single-page Thai PUA PDF as
  `test/fixtures/thai_pua.pdf` with a human-verified `thai_pua.expected.txt`. The
  test asserts: raw `extract_text` *contains* F700 codepoints (the fixture truly
  exercises the regime), and `repair` removes all of them, equals the golden
  text, and reports `applied: [:thai_pua]`. Pin correctness once; guard forever.
  Source the fixture from the public Royal Thai Government Gazette and prefer a
  page without a named private individual.
- **Table provenance test.** A test that scans the table for any codepoint
  outside F700–F71A (catch stray entries) and asserts every target is in the
  Thai block U+0E00–0E7F.

## Open follow-ons (not phase 1)

- Corpus-wide PUA sweep once multi-market data exists, to prioritise the next
  regime by evidence rather than assumption.
- A `quality/1` helper if the flag-only signal wants its own home separate from
  `detect/1`.
