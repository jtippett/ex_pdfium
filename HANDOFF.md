# ExPdfium — Session Handoff

You are working on **ExPdfium**, an Elixir NIF wrapper around
[`pdfium`](https://pdfium.googlesource.com/pdfium/) (Google's Chromium PDF
engine) via the Rust [`pdfium-render`](https://github.com/ajrcarey/pdfium-render)
crate, shipped as a **precompiled NIF** with `rustler_precompiled`.

Read this, then [`PORTING.md`](PORTING.md) (the staged plan + the real crux at
§2) and [`UPDATE_PROCEDURE.md`](UPDATE_PROCEDURE.md) (version bumps + the release
dance). This handoff is uncommitted scratch — keep it refreshed as you go.

---

## TL;DR — where things stand

**Phase 0 dev path is proven; static-release path is the remaining Phase 0 work.**
`ExPdfium.pdfium_version/0` is green: the NIF binds + initializes pdfium
**dynamically** and `EXPDFIUM_BUILD=1 mix test` passes (1 passed, 2 skipped) on
macOS arm64 / OTP 29, full gate clean (fmt, clippy `-D warnings`, warnings-as-
errors compile). Phase 1/2 stubs are deferred to their phases (see below).

**Shipping strategy CHANGED (the §2a "central decision"):** static linking is
**infeasible** — bblanchon publishes no static `libpdfium.a`, only the dynamic
lib. So the shipped NIF binds pdfium **dynamically** and **bundles the dynamic
`libpdfium` inside each per-target precompiled tarball**; rustler_precompiled
extracts the whole tarball into `priv/native/`, and the NIF **self-locates** the
sibling libpdfium via `dladdr` (no Elixir wiring, no env, no rpath). This is the
"custom tarball bundling a dynamic libpdfium" alternative the open questions
already anticipated. Proven locally on macOS arm64. `release.yml` rewritten for
this; the `static`/`libcpp`/`libstdcpp` features are kept only for a
user-supplied `.a`.

**Phase 0 is DONE end-to-end. `v0.1.0` is released and the whole point is
proven.** The tag built 4 bundled tarballs (NIF + libpdfium each), the GitHub
release has all 4, the checksum file is regenerated + committed, and a clean
precompiled install on this machine (aarch64-apple-darwin / OTP 29) works: `mix
compile` with no `EXPDFIUM_BUILD` downloaded the NIF, and `pdfium_version/0`
returned `pdfium loaded` via the bundled libpdfium — **no Rust toolchain, no
separately-installed pdfium**, dev libpdfium hidden.

- **x86_64-apple-darwin is cross-compiled on the arm64 `macos-latest` runner**
  (no C link at build time → no Intel runner needed; macos-13 queues forever).
- **NOT on Hex.** The `Publish to Hex` job ran and **failed at auth** (no
  `HEX_API_KEY` secret, no `hex` environment configured) — safe, nothing
  published. To actually publish: add the `HEX_API_KEY` repo secret, configure a
  `hex` environment with a required reviewer (so it pauses), and re-run/re-tag —
  **with a fresh go-ahead.**

> **Known limitation:** a *from-source* consumer build (force_build / unsupported
> target) compiles the NIF but does NOT auto-bundle libpdfium — such users must
> supply one (PDFIUM_DYNAMIC_LIB_PATH or a system libpdfium). The 4 precompiled
> targets are self-contained.

### What Phase 0 (dev) settled — corrections to scaffold assumptions
- **`pdfium-render` pinned `=0.8.37`** (latest 0.8.x). 0.9.x exists but reworks
  the binding API — treat as a deliberate future bump (UPDATE_PROCEDURE Part A).
- **Use the `sync` feature, NOT `thread_safe`.** Verified in 0.8.37 source: the
  `unsafe impl Send + Sync for Pdfium` is gated on `sync`; `thread_safe` alone
  only adds the per-call mutex and leaves `Pdfium` `!Send`/`!Sync`, which won't
  compile in a `static`. `sync` implies `thread_safe`. (Cargo.toml + release.yml
  updated.)
- **pdfium binary pin bumped `chromium/7506` → `chromium/7543`** to match the API
  version pdfium-render 0.8.37 binds (`pdfium_latest` == `pdfium_7543`). 7506 is
  older than the bound API → unresolved symbols at dlopen. (4 files updated.)
- **`default-features = false` drops a mandatory pdfium API-version feature.** The
  crate's default carries `pdfium_latest`; without a `pdfium_XXXX` feature there's
  no FFI surface. Re-added as a non-optional dependency feature so BOTH the dev
  build and release.yml's `--no-default-features` static build get it.
- **Env vars don't cross into a NIF.** `System.put_env` (os:putenv) updates
  Erlang's env table but not the C `getenv` a NIF reads. The dev libpdfium dir is
  now handed to the NIF via `ExPdfium.Native.set_dynamic_lib_dir/1` (a function
  argument), with an OS-level `PDFIUM_DYNAMIC_LIB_PATH` fallback.

### Phase 1 done — open + page_count + close (committed)
`ExPdfium.open/1,2` (path/binary + `:password`), `page_count/1`, `close/1`.
Document stored as `ResourceArc<Mutex<Option<PdfDocument<'static>>>>`; GC + `close`
both drop it (closes in pdfium) under the global lock. Errors mapped from
`PdfiumError` to atoms. 13 tests incl. concurrency + GC; full gate green.

**The big Phase 1 finding — pdfium-render's `thread_safe` does NOT serialize
calls.** It only locks across library Init/Destroy; data calls run unlocked. Our
many-threaded dirty NIFs were hitting pdfium concurrently → intermittent
`:invalid_pdf`/corruption (a fan-out concurrency test caught it). Fix: a
`static PDFIUM_LOCK: Mutex<()>` that **we** take around every pdfium operation
(open/count/close/drop). `sync` is kept only for its `Send + Sync` markers; that
`unsafe` is sound *because* `PDFIUM_LOCK` makes access single-threaded. Lock order
is always `PDFIUM_LOCK` → per-doc mutex. PORTING §2b/§2c corrected. (pdfium work
is now fully serialized process-wide — inherent to pdfium.)

- **Never panic inside a pdfium call** (still true, now about `PDFIUM_LOCK`): a
  panic while holding it poisons it. We recover from poison (`pdfium_lock()` uses
  `into_inner()`, since the lock guards only `()`), but no-panic is the discipline:
  `#![deny(clippy::unwrap_used, clippy::expect_used)]` on the crate (one allowed
  `expect` at init). Map `PdfiumError` → `{:error, atom}`; never unwrap.

### Phase 2 done — render_page (committed)
`ExPdfium.render_page/3` → `%Bitmap{data,width,height,stride,format}` (4-channel,
Vix-ready). Sizing `:dpi`/`:scale`/`:width`/`:height`; `:format` `:rgba`(default,
via pdfium reverse-byte-order)/`:bgra`; `:background` `:white`(default)/`:transparent`.
`stride` derived from the buffer, not assumed. 300 DPI letter ≈ 19ms. 29 tests
(incl. byte-order on a colored fixture, render concurrency, GC-close-under-load).

- **Scheduler-stall fixed.** The GC `DocumentResource::Drop` no longer blocks on
  `PDFIUM_LOCK`; it hands the document to a dedicated cleanup thread that closes
  it under the lock off-scheduler (`CLEANUP`/`cleanup_sender`). `close/1` (a dirty
  NIF) still closes synchronously. Consequence: GC close is async — `close/1` for
  deterministic release (documented).
- **MSRV bumped 1.78 → 1.82** (the 1.78 was an arbitrary scaffold floor; we ship
  precompiled + build on stable, so it only constrained our own code).

### Phase 3 done — text extraction & search (committed)
`extract_text/2` (page) + `extract_text/1` (whole doc, `\f`-joined); `text_segments/2`
(runs + bounds in PDF points, origin bottom-left); `search_text/3,4` (`:match_case`,
`:whole_word`) → `%{text, rects}`. NIFs return tuples; Elixir maps to maps with
`%{left,bottom,right,top}`. Used the non-deprecated `PdfRect` accessors
(`left()/top()/...`) — direct field access is deprecated and trips clippy. 2-page
text fixture (qpdf-built, pdftotext-verified). 44 tests.

### Phase 4 done — metadata, geometry, permissions (committed)
`metadata/1`, `page_info/2`, `permissions/1`. rustler tuples max at 7 → metadata/
permissions return `Vec<(Atom, value)>` lists; Elixir builds maps. 54 tests.

**pdfium/pdfium-render quirks found (exposed faithfully + documented):**
- `permissions/1` returns `{:error, :unsupported_security}` for AES-256/PDF-2.0
  (security-handler revisions 5-6) — pdfium-render can't read those, so every
  `can_*` errors; we surface that instead of a misleading all-false set.
- `modification_date` is usually nil: pdfium-render queries `"ModificationDate"`,
  not the PDF-standard `/ModDate`. (`creation_date` works.)
- pdfium gives no crop→media fallback; undefined boxes are nil.

### Phase 5 done — structure & navigation (committed)
`outline/1` (nested bookmark tree via recursive `#[derive(NifMap)]` struct, capped
depth 64 / 50k nodes for cycle safety), `links/2` (bounds + uri|page), `attachments/1`
+ `attachment_data/2`. 65 tests. Hand-built `structure.pdf` (pdfium can't read
pdfattach's attachment streams — hand-wrote the `/EmbeddedFile`). clippy
`type_complexity` fires on a 3-field tuple Vec return → use a `type` alias.

### Phase 6 done — forms & annotations (read) — THE READ-ONLY SCOPE IS COMPLETE
`form_type/1` (:none|:acrobat|:xfa_full|:xfa_foreground), `form_fields/1`
(AcroForm fields, one entry per widget across all pages: name/type/value/checked/
read_only/required/page/bounds), `annotations/2` (per-page markup + widget annots:
type=/Subtype, bounds, contents, name=/NM, hidden, printed). 75 tests; CI green
(commit 314609e). Hand-built `forms.pdf` via a **deterministic** generator
(`test/fixtures/forms_gen.py`, committed — re-run to regenerate byte-identical).

**pdfium-render facts found (faithful exposure, documented):**
- The **form-fill environment is initialized eagerly at open** (`PdfForm::from_pdfium`
  inside `PdfDocument::from_pdfium`) and the form handle is threaded into
  pages→annotations. So `page.annotations()` + widget `as_form_field()` Just Work
  with no `document.form()` call or extra setup.
- **Checkbox/radio `group_value()` returns the group's *selected* value** (the
  parent `/V`), identical on every option widget — NOT each widget's export name
  (pdfium-render exposes no public per-option export name). `is_checked()`
  distinguishes the selected widget. So we list per-widget and document that
  `value` is the group's answer + `checked` flags the selected one. We keep
  `value`(String)/`checked`(bool) separate rather than coercing (pdfium-render's
  own `field_values()` coerces checkbox→"true"/"false"; we don't).
- Annotation type→atom and field type→atom maps are **exhaustive matches** (no
  wildcard) so a new pdfium-render enum variant is a compile error, not a silent
  `:unknown`.
- `form_fields` 8 fields > rustler's 7-tuple limit → nested `(page, bounds)` as the
  7th element (same trick as `page_info`'s boxes tuple).

**Read scope complete at v0.2.0 (on Hex).** v0.2.0 was published to Hex by the
user (version bump + tag + release done between sessions). Docs were polished for
Hex first (grouped API via `@doc group:` + `groups_for_docs`, hexdocs-link fixes,
`mix hex.build` validated).

### v0.3 — WRITE SCOPE REOPENED. Phase 1 (page assembly + save) DONE
The user reopened write/edit at v0.3 ("we have the whole pdf exe sitting there").
Design: `docs/plans/2026-06-25-write-tools-page-assembly-design.md`. Shipped
(commit c717e93, CI green, 97 tests): `save_to_bytes/1`, `save_to_file/2` (Elixir =
save_to_bytes + File.write, to keep disk IO off the global lock), `append/2`
(merge), `extract_pages/2` (split/subset → new doc), `delete_pages/2` (int or
unit-step inclusive range), `rotate_page/3`. In-place mutators return `{:ok, doc}`
(same handle, chainable — the user's explicit pick over bare `:ok`); `extract_pages`
returns `{:ok, new_doc}`. Write NIFs take `.as_mut()` ONLY where pdfium-render needs
`&mut` (pages_mut().append); delete/rotate go through an owned PdfPage handle so
`.as_ref()` suffices. Safety: `append(doc,doc)`→`:same_document` (ptr identity),
validate-before-mutate, deleting all pages→`:cannot_delete_all_pages`, stepped/desc
ranges→`:bad_range`. Gotchas: pdfium-render's `delete_page_range` is DEPRECATED (use
`PdfPage::delete()` high→low); rustler `Result<Atom,Atom>` encodes `Ok(:ok)` as
`{:ok,:ok}` (the `wrap/2` helper maps it). Moduledoc/README/PORTING reframed
read→read+write.

### Image & object extraction (read) DONE
Commit 5523936, CI green, 109 tests. `page_objects/2` (typed objects + bounds +
index), `images/2` (image objects: width/height/bits_per_pixel/filters/bounds),
`image_data/3` (decoded pixels → `%Bitmap{}` in native `:gray|:bgr|:bgrx|:bgra`),
`image_raw_data/3` (original encoded stream — DCTDecode → ready JPEG). `Bitmap.format`
widened (render still `:rgba`/`:bgra`). Key facts: `obj.bounds()` is `PdfQuadPoints`
→ `.to_rect()`; `as_image_object()` borrow must be inlined (E0515); `image_data`
uses `get_raw_bitmap` (raw samples, masks/transforms NOT applied — documented) vs
`images/2`'s processed dims; call `bitmap.format()` before `as_raw_bytes()` (null-
handle guard). Multi-image fixture (`images_gen.py`): RGB+gray FlateDecode + a real
base64-embedded DCTDecode JPEG (ImageMagick-made once); deterministic.

### Comprehensive metadata DONE (commit b64c0af)
`metadata/1` now also returns `:version` (PDF version string), `:page_count`,
`:page_mode` (catalog /PageMode atom). Honest ceiling documented: custom /Info keys
and XMP are unreachable via pdfium.

### Document creation DONE (commit 506a27d, CI green, 128 tests)
`new/0`, `add_page/3` (named sizes/`{w,h}` points; `at:` inserts, clamps past end),
`draw_text/5` (Standard-14 fonts), `draw_rectangle/4`, `draw_line/5`, `draw_circle/5`,
`draw_image/4` (place an `ExPdfium.Bitmap`; pdfium is BGRA-native so `:rgba`/`:rgbx`
are R↔B swapped). One reviewed `unsafe` (`PdfBitmap::from_bytes`; buffer length-checked,
`set_bitmap` copies).
**CRASH LESSON:** a built-but-never-added `PdfPageObject`, if dropped, SEGFAULTS the
whole BEAM (C++ crash, not a catchable Rust panic). Fix = validate page up front
(`check_page`) AND attach the object to the page BEFORE any fallible styling
(`attach_then_style`) so a styling error can't orphan-drop. Shapes carry styling in
the constructor → safe via `add_to_page`. See journal for the full reusable writeup.

### Safety stance (user raised it, 2026-06-25)
A genuine C++ crash in pdfium takes down the **entire BEAM VM** (NIFs are in-process;
rustler contains Rust *panics* but not native segfaults). User accepts the NIF trade
but wants extra crash-safety care. **A separate Codex deep-hardness sweep is planned
AFTER the feature work** — keep the discipline tight (validate-before-mutate, no
orphan drops, length-check all buffers) but the exhaustive hardening audit is a later pass.

### Render refinements + thumbnails DONE (commit e0b57db)
`render_page/3` gained `:grayscale`/`:annotations`/`:form_fields` toggles (a 4-tuple
pdfium render-config pass-through); `thumbnails/2` is pure Elixir over `render_page/3`.
Deferred: `clip`/region render — pdfium's clip MASKS not crops; proper region-crop
needs a matrix render (do it right as a follow-up).

### Flatten + signatures DONE (commit ca3554a, CI green, 142 tests)
`flatten_page/2` + `flatten/1` (FLAT_PRINT; pdfium-render reloads the page after;
nothing-to-flatten is a no-op — verified forms.pdf 7 annots → 0). `signatures/1`
→ `%{reason, signing_date, bytes}` (raw PKCS#7; no signer name from pdfium; unsigned
→ `{:ok, []}`). Both plain marshalling under the lock, no unsafe.

### Codex deep-hardness sweep DONE — CLEAR FOR DISPATCH (commits up to b2584d5, CI green)
Ran the `codex-review-loop` skill, 5 rounds, converged to codex's "CLEAR FOR DISPATCH".
Findings decayed cleanly (memory-safety → DoS → integer-overflow → 1 real bomb).
Fixed (all with tests + new fixtures `huge_page.pdf`, `attachment_bomb.pdf`):
- **R1 Blocker (real heap UB):** draw_image `unsafe PdfBitmap::from_bytes` passed a PACKED
  buffer but pdfium uses a 4-byte-aligned row stride → overread for :gray/:bgr non-aligned
  widths. Fix: repack to `align4(width*bpp)` stride. (Our tests only used aligned widths.)
- **R1 High/Medium:** render dims uncapped (width 2^31 / dpi 1e100) → MAX_RENDER_* caps;
  `pdfium_version/0` ran outside PDFIUM_LOCK → now locked.
- **R2 High×2 (malformed-PDF alloc DoS):** render output derived from page MediaBox was
  unbounded (40000×40000 MediaBox → multi-GB) → `estimated_pixels` area check before
  pdfium allocates (MAX_BITMAP_PIXELS=100MP) + set_maximum_* backstop. image_data decoded
  before bounding → declared-dim check. R2 Med/Low: extract_pages length pre-check;
  draw_image input-dim cap (overflow).
- **R3 High (integer overflow):** append/add_page could cross pdfium-render's u16 page
  ceiling → guards (dest+src ≤ u16::MAX; reject full doc).
- **R4 High (codex REFUTED my pushback with a real bomb):** attachment_data/2 is a
  decompression bomb — 21KB PDF → 20MB decoded via save_to_bytes(). Fix: check
  `attachment.len()` (cheap null-buffer call) > MAX_ATTACHMENT_BYTES=100MB before decode.
Pushbacks codex ACCEPTED: image_raw_data/signatures/list-collectors are proportional-to-
input (not amplification) — no caps; documented the untrusted-input stance (in-process VM,
use OS limits + process isolation) in the moduledoc. Page-count u16 truncation (>65535-page
docs) accepted as a pdfium-render limitation (handle is pub(crate); ops stay in-bounds) —
documented on page_count/1.

Threat model confirmed clean: no pdfium call outside the lock, no uncontained panic-under-
lock, no orphaned-object segfault path, no overflow/OOB/UB in the unsafe block or size math,
no uncapped/undocumented amplifying allocation. Review transcripts: /tmp/codex_review_r{1..5}.txt
(not committed). 150 tests.

### Annotation authoring DONE (commit a183d7d, CI green, 159 tests)
Shipped: `add_text_annotation/5` (sticky note), `add_free_text_annotation/5`,
`add_square_annotation/4`, `add_link_annotation/5`, `delete_annotation/3`. New
"Annotating" hexdocs group, `examples/annotate.exs`, design doc at
`docs/plans/2026-06-25-annotation-authoring-design.md`.
- **Markup family DROPPED from 0.3 (user decision):** highlight/underline/strikeout/
  squiggly attach + read back correctly but pdfium's own renderer won't show them
  without an explicit `/AP` it doesn't auto-generate (verified: no render-delta even
  after save/reopen; Square renders directly). Synthesizing the AP = re-opening the
  page-object-on-annotation crash surface. Deferred.
- **FreeText text color unavailable:** `FPDFAnnot_SetFontColor` is gated behind
  pdfium-render `pdfium_7350`/`pdfium_future`; our `pdfium_latest` = `pdfium_7543`,
  features are non-cumulative, so it's off. Text renders black; documented to use
  `draw_text/5` for color.
- **create_*_annotation attaches immediately** (FPDFPage_CreateAnnot) so the orphan-
  build-then-drop crash class does NOT apply to annotations (unlike page objects).
- **Formatter version skew bit twice:** local Elixir 1.20 vs CI 1.18 disagree on
  line-length wrapping near 98 chars. Keep code lines < 98 or pre-wrap long
  @specs/calls to the explicit multi-line form (both accept it). `mix format
  --check-formatted` passing locally does NOT guarantee CI passes.

### Remaining
Form-filling explicitly NOT a priority. Markup-annotation family deferred (see above).
All v0.3 work is on main, unreleased — a **0.3.0 Hex release still needs a fresh
go-ahead to tag/publish** (the user is asking about release prep as of 2026-06-25).

### Latent note (still open, low priority)
- **`set_dynamic_lib_dir/1` is silent if pdfium is already initialized.** It just
  `.set()`s a `OnceLock` and never checks `PDFIUM`. Fine for test_helper (runs
  first), but when it grows a real return, consider checking `PDFIUM.get().is_some()`
  and returning e.g. `:already_initialized` so a mis-ordered caller can tell.
- Running examples in **dev** needs libpdfium located: `PDFIUM_DYNAMIC_LIB_PATH=$PWD/priv/pdfium
  EXPDFIUM_BUILD=1 mix run examples/forms.exs` (the OS-env fallback; `mix test`
  wires this via test_helper). Beware: a plain `mix compile` (no `EXPDFIUM_BUILD`)
  swaps dev `_build` back to the *downloaded precompiled* artifact, so force a
  rebuild with `EXPDFIUM_BUILD=1 mix compile --force` before running examples.

The goal that kicked this off: be able to add the lib as a mix dependency and
`mix deps.get` it on this machine (macOS arm64, **OTP 29**) with the NIF
downloaded precompiled — no Rust toolchain, no separately-installed pdfium. The
old C++ project (`../pdfium`) can do this only via a path dep + a pre-built
`priv/`; it has no published OTP-29 artifact. ExPdfium fixes that structurally.

---

## Why this rewrite (don't re-litigate)

The old `jtippett/pdfium` (a fork of `gmile/pdfium`, at
`/Users/james/Desktop/elixir/pdfium`) is a hand-rolled **C++/Fine NIF** with:
Dagger for Linux + bash for macOS (two divergent build paths that have already
drifted), a hand-maintained `builds.json`, **per-OTP artifacts** (NIF 2.17 *and*
2.18), a full-OTP download just for `erl_nif.h`, and a `stable`-branch-merge
release trigger requiring a GitHub App token.

The decision (user, 2026-06-24): re-implement on the **ex_bashkit pattern** —
Rust + `rustler_precompiled` + tag-driven release — which the user ran
successfully on `/Users/james/Desktop/lib/ex_bashkit`. Net simplifications:
- **One uniform build matrix** (no Dagger/bash split).
- **No per-OTP artifacts**: NIF ABI is backward-compatible, so one artifact built
  against rustler's NIF version (2.15) loads on OTP 27/28/29+.
- **No `builds.json`/OTP-download dance**: rustler_precompiled handles target
  selection; only the pdfium binary tag is pinned.
- **A mature binding** (`pdfium-render`) → text extraction, metadata, forms for
  free instead of hand-written C++.

---

## Environment & layout

- **This repo:** `/Users/james/Desktop/elixir/ex_pdfium` (git, branch `main`).
- **GitHub:** not created yet → `https://github.com/jtippett/ex_pdfium` (plan).
- **The old project (reference + parity target):** `../pdfium`
  (`/Users/james/Desktop/elixir/pdfium`). Its 4-fn API is the Phase 1–2 parity
  bar: `load_document`, `close_document`, `get_page_count`, `get_page_bitmap`
  (DPI → RGBA bytes + w/h). Test PDF: `../pdfium/custom/test.pdf` (2 pages).
- **The proven template — ExBashkit:** `/Users/james/Desktop/lib/ex_bashkit`
  (Rust + rustler_precompiled, shipped). Copy its `native.ex`, `release.yml`,
  `ci.yml`, `scripts/release.exs`, `justfile`, and the PORTING/HANDOFF/UPDATE doc
  trio shapes. **The async/tokio + push-effect machinery does NOT port** —
  pdfium-render is synchronous with no callbacks.
- **pdfium binaries:** https://github.com/bblanchon/pdfium-binaries/releases —
  old pin was `chromium/7506` (carry forward). Static `.a` for shipping, dynamic
  `.{dylib,so}` for dev.
- **Toolchain here:** Elixir 1.20.1 / OTP 29 (ERTS 17.0.2), Rust stable, macOS
  arm64, zsh. `wget`/`jq`/`curl`/`g++` all present.

**Verify the build first thing (after Phase 0 lands a real NIF):**
```bash
cd /Users/james/Desktop/elixir/ex_pdfium
EXPDFIUM_BUILD=1 mix test
```
(First build is slow — pdfium-render + a static pdfium.)

---

## The working loop (this is what produced clean ex_bashkit phases)

Per phase: **TDD** (failing test first) → implement (Rust NIF + Elixir API,
marshal-only) → **full gate** (`EXPDFIUM_BUILD=1 mix test`, `mix format
--check-formatted`, `cargo fmt --check`, `cargo clippy -- -D warnings`, `mix
compile --warnings-as-errors`) → dispatch the **`superpowers:code-reviewer`**
subagent against the diff (apply `receiving-code-review` rigor — it earned its
keep every phase on ex_bashkit) → fold fixes → commit → push → watch CI green.
Each phase also gets a README section, a CHANGELOG entry, and an `examples/*.exs`.

---

## Key decisions & facts (the crux — internalize before coding)

- **Bundle the dynamic libpdfium; dynamic-bind everywhere.** (UPDATED — see the
  TL;DR.) Static linking turned out infeasible (no bblanchon `.a`). The shipped
  per-target tarball carries the NIF **and** the dynamic `libpdfium`; rustler_
  precompiled extracts both into `priv/native/` and the NIF self-locates the lib
  via `dladdr`. Dev/test uses the same dynamic binding, just pointed at
  `priv/pdfium` via `set_dynamic_lib_dir/1`. PORTING §2a's static recommendation
  is superseded.
- **pdfium is NOT thread-safe.** Enable pdfium-render's **`thread_safe`** feature
  AND construct the `Pdfium` **once** in a `OnceLock` → `&'static`. All
  pdfium-touching NIFs are **`DirtyCpu`** (no tokio — synchronous, CPU-heavy).
- **Lifetimes:** `PdfDocument<'a>` borrows from `Pdfium`. A `'static` Pdfium makes
  `PdfDocument<'static>` storable in `ResourceArc<Mutex<…>>`. Don't store
  `PdfPage` — fetch/render/drop per call. Document GC destructor closes the doc
  (fixes the old manual-`close_document` leak); `close/1` is optional early
  release via `Mutex<Option<…>>`. Fallback if lifetimes fight: store bytes,
  re-open per call. See PORTING §2c.
- **Pin `pdfium-render` exactly** (`=0.8.x`) — `cargo add` first to get the real
  latest, then pin. Carry the bblanchon pdfium tag pin (`chromium/7506`) forward.
- **No per-OTP artifacts.** rustler 0.38 → `nif-2.15` artifact names in
  `release.yml`; that one artifact loads on all newer OTPs. Keep `nif-2.15` in
  sync with rustler and re-verify at release time.
- **The checksum file starts empty** and is regenerated from the released
  artifacts (`mix rustler_precompiled.download ExPdfium.Native --all --print`,
  with `EXPDFIUM_BUILD=1` to dodge the compile chicken-and-egg). See
  UPDATE_PROCEDURE.
- **Never `hex.publish` or push tags without an explicit, fresh go-ahead.** The
  `release.yml` `hex` environment gates publish behind a manual approval — keep it.

---

## Open questions for the user (raise when relevant)

- **pdfium-render 0.8.37 vs 0.9.x:** pinned 0.8.37 for Phase 0 (latest 0.8, what
  `cargo add` resolved, matches the scaffold's `=0.8.x` plan). 0.9.x reworks the
  binding API; bump deliberately later if its features (e.g. newer pdfium
  versions) are wanted.
- **pdfium tag 7506 → 7543:** the docs said "carry 7506 forward," but 7543 is
  required to match pdfium-render 0.8.37's bound API. Flagging the change; if you
  specifically need 7506, we'd instead pin pdfium-render's `pdfium_7350` feature.

- **Static artifact size:** a static pdfium baked per target is multi-MB ×
  N targets. Acceptable? (Alternative: a custom tarball bundling a dynamic
  `libpdfium` beside the NIF + a runtime path resolver — more moving parts.)
- **Target matrix:** mirror ex_bashkit's 4 (aarch64/x86_64 × apple-darwin +
  unknown-linux-gnu)? Add `x86_64-unknown-linux-musl` (the old project shipped
  musl)? musl + static pdfium + C++ stdlib is the fiddliest combo — decide before
  Phase 0's release matrix.
- **API naming:** keep the old names (`load_document`/`get_page_bitmap`) for
  drop-in compatibility, or adopt cleaner ones (`open`/`render_page`)? This plan
  assumes the latter; confirm if drop-in parity matters.
- **pdfium tag cadence:** port the old project's weekly "update to latest
  libpdfium" bot, or bump manually? (UPDATE_PROCEDURE covers manual.)
