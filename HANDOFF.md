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

**Scaffold stage. Nothing is implemented yet.** This folder is the runway: the
plan, the release machinery, and skeleton stubs are in place so the port can be
"kicked off" by working PORTING.md's phases in order. **Phase 0 (prove the
static-link + precompiled-release path with a trivial NIF) has not been done —
start there.**

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

- **Static-link pdfium for the shipped NIF; dynamic-bind for dev/test.** Static
  (`pdfium-render` `static` feature + `PDFIUM_STATIC_LIB_PATH`) gives one
  self-contained `.so` per target — the only mode that fits rustler_precompiled's
  single-artifact model. Dev/test keeps the default dynamic binding (compiles
  with no pdfium present; loads a downloaded `libpdfium` at runtime) for a fast
  inner loop. See PORTING §2a — **the central decision.**
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
