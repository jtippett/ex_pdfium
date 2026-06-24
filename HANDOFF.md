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

### Carry into Phase 1 (from the Phase 0 code review)
- **Never panic inside a pdfium call.** `thread_safe`/`sync` route every FFI call
  through a process-global `Mutex` (`PdfiumThreadMarshall`) that pdfium-render
  `.unwrap()`s. A panic *inside* a marshalled call poisons that mutex and wedges
  ALL subsequent pdfium calls process-wide. Phase 0's `.expect()`s are safe only
  because they run in `OnceLock::get_or_init`, before any marshalled call. Phase 1
  rule: map `PdfiumError` → `{:error, _}`; do not panic inside a pdfium call.
- **`set_dynamic_lib_dir/1` is silent if pdfium is already initialized.** It just
  `.set()`s a `OnceLock` and never checks `PDFIUM`. Fine for test_helper (runs
  first), but when it grows a real return, consider checking `PDFIUM.get().is_some()`
  and returning e.g. `:already_initialized` so a mis-ordered caller can tell.

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
