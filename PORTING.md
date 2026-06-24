# ExPdfium Porting Playbook

How to grow this scaffold into a complete, community-grade Elixir wrapper around
[`pdfium`](https://pdfium.googlesource.com/pdfium/) — Google's PDF engine from
Chromium — via the Rust [`pdfium-render`](https://github.com/ajrcarey/pdfium-render)
crate, shipped as a **precompiled NIF** with `rustler_precompiled`.

It distills the lessons from the sibling project **ExBashkit**
(`/Users/james/Desktop/lib/ex_bashkit`), which wraps the `bashkit` Rust crate the
same way and shipped cleanly (Phases 1–9, CI green, precompiled release proven
end-to-end). The release machinery, doc discipline, and working loop transfer
*directly*. What's genuinely different here is **not** the Elixir/Rust bridge —
it's that pdfium is a **C++ library** that must be linked/shipped, and it is
**not thread-safe**. Those two facts are the whole game; everything else is easy.

Read this top-to-bottom once, then work the phases in order. Each phase is
shippable on its own.

> **Why a rewrite at all?** The existing `gmile/pdfium` (forked at
> `jtippett/pdfium`, `/Users/james/Desktop/elixir/pdfium`) is a hand-rolled C++
> NIF (via Fine) with a bespoke build: Dagger for Linux, bash scripts for macOS,
> a hand-maintained `builds.json`, per-OTP artifacts (NIF 2.17 *and* 2.18), a
> whole-OTP download just to get `erl_nif.h`, and a `stable`-branch-merge release
> trigger. It works, but it's heavy to maintain and — as of this writing — has no
> published OTP-29 artifact. This rewrite collapses all of that onto the
> ex_bashkit pattern: one uniform `rustler_precompiled` matrix, tag-driven
> releases, no per-OTP artifacts (NIF ABI is backward-compatible — one artifact
> built against the lowest NIF version loads on all newer OTPs), and a mature
> upstream binding that gives us text extraction and metadata for free.

---

## 0. The shape of the thing

ExPdfium is a thin **Rustler NIF** over the `pdfium-render` crate, distributed as
a **precompiled binary** via `rustler_precompiled` so end users need **no Rust
toolchain and no separately-installed pdfium**. The Elixir side owns the
ergonomics (structs, the public API); the Rust side is a faithful, minimal
bridge.

```
lib/ex_pdfium.ex             # public API: open/1, page_count/1, render_page/3, …
lib/ex_pdfium/native.ex      # RustlerPrecompiled config + NIF stubs
lib/ex_pdfium/document.ex    # %ExPdfium.Document{} — opaque GC'd resource handle
lib/ex_pdfium/bitmap.ex      # %ExPdfium.Bitmap{} — {data, width, height, stride}
native/ex_pdfium/src/lib.rs  # #[rustler::nif] fns + the global Pdfium instance
```

**Golden rule (carried from ExBashkit/ExMonty):** vendor *no* rendering or
parsing logic on the Elixir side. Every semantic — how a page rasterizes, how
text is extracted, what a bitmap's pixel format is — comes from pdfium. We only
marshal data across the boundary. When pdfium-render changes, we should mostly be
updating encodings, not behavior.

---

## 1. Lessons inherited from ExBashkit

These were paid for once already. Honor them.

### The precompiled-NIF release dance (the part everyone gets wrong)
- `lib/ex_pdfium/native.ex` downloads a prebuilt NIF whose checksum must be in
  `checksum-Elixir.ExPdfium.Native.exs`. **That file starts empty and is
  regenerated *after* a release exists.** Full ordering in
  [`UPDATE_PROCEDURE.md`](UPDATE_PROCEDURE.md). The trap:
  1. tag `vX.Y.Z` → `release.yml` builds the NIFs and creates the GitHub release,
  2. **then** `mix rustler_precompiled.download ExPdfium.Native --all --print`
     downloads them and writes the checksum file,
  3. publish to Hex (the workflow does it from CI, gated by the `hex`
     environment) — the package tarball includes the freshly-generated checksums.
- The download/compile step has a **chicken-and-egg**: compiling `native.ex`
  tries to fetch a NIF that isn't published yet. Run anything that compiles the
  app with `EXPDFIUM_BUILD=1` so the local build satisfies compilation, e.g.
  `EXPDFIUM_BUILD=1 mix rustler_precompiled.download ExPdfium.Native --all --print`.
- Keep the NIF ABI version (`nif-2.15`) in `release.yml` artifact names in sync
  with the rustler version. (rustler 0.38 targets NIF 2.15 and is forward-loaded
  on newer OTP — **this is the entire reason we don't build per-OTP artifacts**.)

### Pin exact crate versions, never a moving ref
- `pdfium-render` is on crates.io, so pin `pdfium-render = "=0.8.x"` (exact).
  Bump deliberately via the update procedure. **First real task:** `cargo add
  pdfium-render` to resolve the true latest, then pin it exactly.

### CI gates that catch the common breakage
- `mix format --check-formatted`, `cargo fmt --check`,
  `cargo clippy -- -D warnings`, `mix compile --warnings-as-errors`, `mix test`.
- CI builds the NIF from source (`EXPDFIUM_BUILD=1`) rather than downloading.

### Docs are part of "done"
- Every new public function/field gets a moduledoc + `@spec` + a doctest or test.
  Every new capability gets a README section and a CHANGELOG entry. Doc drift is
  the easiest thing to forget.

### The working loop (this is what produced clean ex_bashkit phases)
Per phase: **TDD** (write the failing test first — `EXPDFIUM_BUILD=1 mix test`)
→ implement (Rust NIF + Elixir API, marshal-only) → **full gate** (`mix test`,
`mix format --check-formatted`, `cargo fmt --check`, `cargo clippy -- -D warnings`,
`mix compile --warnings-as-errors`) → dispatch the **`superpowers:code-reviewer`**
subagent against the diff (on ex_bashkit it caught a real soundness bug every
single phase — take it seriously) → fold fixes → commit → push → watch CI green.
Each phase also gets a README section, a CHANGELOG entry, and an `examples/*.exs`.

---

## 2. What's genuinely different about pdfium (the crux)

ExBashkit's hard part was async + a push-based effect model. **None of that
applies here** — pdfium-render is synchronous and has no callbacks. Our hard part
is entirely different and lives in three places.

### a) Linking & shipping pdfium — THE central decision
pdfium is C++. `pdfium-render` offers three binding modes; the choice dictates
the whole build/release pipeline:

| Mode | What ships | Build needs pdfium? | Fit for precompiled NIF |
|------|-----------|---------------------|-------------------------|
| **Dynamic at runtime** (default) | `pdfium_nif.so` + a separate `libpdfium.{dylib,so}` the NIF loads via a path at load time | No | ⚠️ Poor — `rustler_precompiled` ships a *single* `.so`; a second file needs a custom tarball + a runtime path resolver (this is the rpath pain the old C++ project fought) |
| **Static** (`static` feature + `PDFIUM_STATIC_LIB_PATH`) | one self-contained `pdfium_nif.so` with `libpdfium.a` linked in | **Yes** (a static `libpdfium.a` per target at build time) | ✅ **Best** — one artifact per target, no second file, no rpath surgery |
| System library | nothing — user installs pdfium | No | ✗ Defeats the "no install" goal |

> **Recommendation: static linking.** It's the only mode that produces a single
> self-contained artifact per target, which is exactly what `rustler_precompiled`
> distributes. Cost: each artifact is bigger (libpdfium is multi-MB), the build
> downloads a **static** pdfium per target, and you must link a C++ stdlib
> (pdfium-render's `libstdc++` feature on Linux/gnu, `libc++` on macOS).
>
> **Dev vs ship asymmetry (use it):** keep the *default* (dynamic) binding for
> local dev and `mix test` — pdfium-render then compiles with **no pdfium
> present**, and tests load a `libpdfium` downloaded once to a known path
> (`PDFIUM_DYNAMIC_LIB_PATH` / `Pdfium::bind_to_library/1`). Turn on `static`
> only in `release.yml`'s build matrix. This keeps the inner loop fast and makes
> Phase 0 (below) about proving the static *release* path specifically.

Static `libpdfium.a` (and the dynamic libs for dev) come from
**[bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries/releases)**
— the same source the old project pinned via `LIBPDFIUM_TAG` (`chromium/7506`).
Carry that pin forward; the update bot (UPDATE_PROCEDURE) tracks new tags.

### b) pdfium is NOT thread-safe — the BEAM will call it from many threads
pdfium requires `FPDF_InitLibrary()` once and forbids concurrent calls across
documents from different threads. BEAM **dirty schedulers run on a pool of OS
threads**, so naive NIFs would call pdfium concurrently → UB/crashes.

Two things make this safe; use both:
- **`pdfium-render`'s `thread_safe` feature** wraps every pdfium call in an
  internal mutex. Enable it. This is the analog to ex_bashkit's single shared
  tokio runtime — here it's a single serialized library.
- **Initialize the `Pdfium` instance exactly once**, in a `OnceLock` (or
  `once_cell`), and hand out `&'static` references. Never construct it per call.

Even with `thread_safe`, treat pdfium as a single global resource: all NIFs that
touch it are **`DirtyCpu`** (rendering is CPU-heavy and routinely exceeds the 1ms
budget that would stall a normal scheduler).

### c) Lifetimes — `PdfDocument<'a>` borrows from `Pdfium`
This is the one real Rust-ergonomics puzzle. In pdfium-render, `PdfDocument`,
`PdfPage`, etc. borrow from the `Pdfium`/bindings instance:

```rust
let pdfium = Pdfium::new(...);          // owns the bindings
let doc = pdfium.load_pdf_from_byte_slice(&bytes, None)?;  // doc borrows pdfium
let page = doc.pages().get(0)?;         // page borrows doc
```

You cannot store a borrowing `PdfDocument<'a>` in a `ResourceArc` (rustler
resources are `'static`). Resolve it with **a single `'static` Pdfium**:

- Put the `Pdfium` in a `OnceLock<Pdfium>` → `&'static Pdfium`. Now
  `PdfDocument<'static>` is possible (it borrows the static), and **can** live in
  a `ResourceArc`.
- Wrap the document in `ResourceArc<Mutex<PdfDocument<'static>>>` (the mutex is
  belt-and-suspenders over `thread_safe`, and serializes multi-step ops on one
  doc). Drop = pdfium closes the document → **fixes the old API's manual
  `close_document` leak risk**; expose an explicit `close/1` only as an optional
  early-release that `.take()`s an `Option`.
- Pages are cheap and short-lived: **don't** store `PdfPage` in a resource. Fetch
  the page inside each NIF call from the stored document, render, return data,
  drop. (Mirrors ex_bashkit's "consumes self → `Mutex<Option<T>>`" discipline:
  if an API consumes `self`, store `Option` and `.take()`.)

If the `'static` approach gets awkward for a given API, the fallback is to store
the **document bytes** in the resource and re-open per call — slower but trivially
sound. Prefer the static-Pdfium handle; reach for re-open only if lifetimes fight
you.

### d) Build size & time
A static pdfium is large; release builds are heavier than ex_bashkit's. Lean on
`Swatinem/rust-cache` and cache the downloaded pdfium per target. End users never
pay this — they download the precompiled NIF.

---

## 3. Staged plan

Each phase: implement the NIF(s), add the Elixir API + struct, write tests
(`EXPDFIUM_BUILD=1 mix test`), update README + CHANGELOG + an `examples/*.exs`,
keep CI green. Tag a release when a phase is a meaningful user-facing increment.

### Phase 0 — Toolchain & release pipeline (do this FIRST, before any PDF logic)
The single biggest risk is the static-link + precompiled-release path, so prove
it with a **trivial** NIF before writing real rendering code.

- [ ] `cargo add pdfium-render` in `native/ex_pdfium`; pin the resolved version
      exactly in `Cargo.toml`. Add `rustler = "0.38"`.
- [ ] One trivial NIF that needs pdfium, e.g. `pdfium_version/0` returning the
      pdfium build string (proves the library actually links & initializes).
- [ ] Get `EXPDFIUM_BUILD=1 mix test` green locally with **dynamic** binding (dev
      mode): download a `libpdfium` for this host, point `Pdfium::bind_to_library`
      at it, assert the version call works.
- [ ] Make `release.yml`'s build job: download **static** pdfium per target →
      `PDFIUM_STATIC_LIB_PATH=… cargo build --release --features static,libstdc++`
      (or `libc++` on darwin) → package the single `.so`.
- [ ] Tag `v0.1.0`. Confirm the GitHub release has one artifact per target.
      Regenerate + commit the checksum file. Confirm a clean `mix deps.get` of
      the package on *this* machine (OTP 29) downloads and loads the precompiled
      NIF with **no Rust toolchain and no pdfium installed**. **This is the whole
      point of the rewrite — do not move on until it's proven.**

### Phase 1 — Open documents & page count
- [ ] `ExPdfium.open(path)` and `ExPdfium.open(binary)` → `{:ok, %Document{}}`.
      `%Document{}` wraps `ResourceArc<Mutex<PdfDocument<'static>>>`.
- [ ] `ExPdfium.page_count(doc)` → `{:ok, n}`.
- [ ] Password-protected PDFs: optional `password:` opt → pdfium-render's
      `load_pdf_from_*` password arg. Wrong/missing password → `{:error, …}`.
- [ ] GC destructor closes the document. Optional `ExPdfium.close(doc)` for
      early release (`Mutex<Option<…>>`, idempotent).
- [ ] Errors are mapped from `PdfiumError` to friendly atoms/messages — *map*,
      don't invent semantics.

### Phase 2 — Render a page to a bitmap (parity with the old library)
- [ ] `ExPdfium.render_page(doc, page_index, opts)` →
      `{:ok, %ExPdfium.Bitmap{data, width, height, stride, format}}`.
- [ ] Opts: sizing by `:dpi` (the old API's contract) and/or `:width`/`:height`/
      `:scale`; `:format` (BGRA/RGBA — pdfium is natively BGRA, document the
      choice; the old lib returned 4-channel for `Vix`); optional background/alpha.
- [ ] Document the exact byte layout so consumers (`Vix.Vips.Image.new_from_binary`,
      `Image`) can use it directly — preserve the old README's recipe.
- [ ] Bench a high-DPI render; confirm DirtyCpu (not a normal scheduler).

### Phase 3 — Page geometry & document metadata
- [ ] `page_size/2` (points), page label, rotation; document `metadata/1`
      (title/author/dates), pdfium version. All free from pdfium-render.

### Phase 4 — Text extraction
- [ ] `extract_text(doc, page_index)` and whole-doc text. pdfium-render exposes
      page text + per-character geometry; start with plain text, add bounding
      boxes only if asked. (Capability the old library never had.)

### Phase 5+ (optional, demand-driven)
- [ ] Render straight to PNG (pdfium-render `image` feature) as a convenience.
- [ ] Form fields, annotations, attachments, bookmarks/outline, page
      thumbnails — each its own small phase, behind the same gate. Only build
      what someone asks for; keep the default surface tight.

---

## 4. Definition of done (per phase and overall)

- [ ] NIF stubs in `native.ex` match the `#[rustler::nif]` fns exactly.
- [ ] Public functions have moduledocs, `@spec`s, and doctests/tests.
- [ ] `EXPDFIUM_BUILD=1 mix test` green; `mix format`/`cargo fmt`/`clippy` clean;
      `mix compile --warnings-as-errors` clean.
- [ ] README capability section + CHANGELOG `[Unreleased]` entry + `examples/`.
- [ ] No vendored logic — semantics come from pdfium-render.
- [ ] Documents are GC-closed (no manual-close leak); pdfium is only ever touched
      under the global lock / single instance.

When in doubt, open the ExBashkit repo (`/Users/james/Desktop/lib/ex_bashkit`)
and copy the proven shape — `native.ex`, `release.yml`, `scripts/release.exs`,
the doc trio, and the per-phase loop are all directly transferable.
