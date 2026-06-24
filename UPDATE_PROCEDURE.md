# ExPdfium Update & Release Procedure

Two things drift over time and need a deliberate procedure:

1. **`pdfium-render`** (the Rust crate) — pinned exactly in `Cargo.toml`.
2. **pdfium itself** (the bblanchon binary) — pinned by tag (`LIBPDFIUM_TAG` /
   the version your `release.yml` downloads).

And one thing must happen in a **specific order** every release: regenerating the
precompiled-NIF checksum file. That's the part everyone gets wrong; it's last.

---

## Part A — Bumping pdfium-render

`pdfium-render` is on crates.io, so track **released versions**, not a git ref.

1. Check the latest:
   ```bash
   cargo search pdfium-render        # or https://crates.io/crates/pdfium-render
   grep 'pdfium-render' native/ex_pdfium/Cargo.toml
   ```
2. Read its CHANGELOG / release notes for breaking changes to the APIs we use
   (open/load, `pages()`, `render_*`, text extraction, error types).
3. Bump and pin exactly:
   ```toml
   pdfium-render = "=0.<new>.<patch>"
   ```
   ```bash
   cd native/ex_pdfium && cargo update -p pdfium-render
   cd ../.. && EXPDFIUM_BUILD=1 mix test
   ```
4. Fix any signature/type drift (most likely: error enum variants, builder/render
   config). **Map** changes — never re-implement behavior Elixir-side.

---

## Part B — Bumping the pdfium binary (bblanchon)

The shipped NIF links a **static** pdfium; dev/test loads a **dynamic** one. Both
come from https://github.com/bblanchon/pdfium-binaries/releases.

- The pinned tag (carry forward from the old project: `chromium/7506`) lives in
  `release.yml` (and a `LIBPDFIUM_TAG` file if you keep one for the dev download
  script).
- To bump: pick a newer `chromium/NNNN` tag, update the download URLs + recorded
  sha256s, rebuild, run the full suite, render `../pdfium/custom/test.pdf` and
  confirm output is byte-identical (or visually identical) to the prior build.
- **Security:** if upstream pdfium fixes a parsing/sandbox CVE, bump promptly.
- Optionally port the old project's weekly bot
  (`.github/workflows/update-libpdfium.yaml`) that opens a PR on a new tag.

> Keep the static (shipping) and dynamic (dev) pdfium on the **same tag** so dev
> behavior matches what users get.

---

## Part C — Cutting an ExPdfium release (order matters)

This is the precompiled-NIF dance. Use `just release` (`scripts/release.exs`) for
steps 1–3; the rest is the workflow + the checksum regen.

1. **Bump the version.** `just release` shows current vs published, asks
   patch/minor/major, rolls the CHANGELOG `[Unreleased]` section, then (on
   confirm) commits, tags `vX.Y.Z`, and pushes — which triggers `release.yml`.
   - Semver against **our** API, not pdfium-render's. Big additive features are
     minor `0.x` bumps.
2. **Wait for `release.yml`'s build matrix to finish.** Confirm the GitHub
   release has **one artifact per target** (4 by default; 5 if musl is added).
3. **Regenerate the checksum file from the released artifacts:**
   ```bash
   EXPDFIUM_BUILD=1 mix rustler_precompiled.download ExPdfium.Native --all --print
   ```
   - `EXPDFIUM_BUILD=1` forces a local build so compiling `native.ex` doesn't try
     to download a NIF whose checksum doesn't exist yet (the chicken-and-egg).
   - This writes `checksum-Elixir.ExPdfium.Native.exs`. Commit + push it.
4. **Publish to Hex.** The `publish` job in `release.yml` does this from CI,
   **gated by the `hex` environment** (a required-reviewer approval pauses it so
   you eyeball the release first). It regenerates checksums in the CI workspace
   before `mix hex.publish` so the package tarball carries them.
   - If publishing manually instead: `mix hex.publish` after step 3. This is the
     irreversible outward step — needs your Hex auth and a fresh go-ahead.

### Verify the whole point afterwards
On a clean machine (or a fresh `_build`/`deps`) with **no Rust toolchain and no
pdfium installed**, on **OTP 29**:
```elixir
# mix.exs
{:ex_pdfium, "~> 0.1"}
```
```bash
mix deps.get && mix compile     # downloads the precompiled NIF, no build
```
If that loads and renders a page, the release is good.

---

## Release ordering, at a glance

```
bump version + CHANGELOG  →  tag vX.Y.Z  →  release.yml builds N artifacts
   →  GitHub release created  →  regen + commit checksum file
   →  hex.publish (gated by `hex` env approval)  →  verify clean install on OTP 29
```

The checksum file is **always** generated *after* the artifacts exist. Never hand-
edit it; never publish before it's regenerated.
