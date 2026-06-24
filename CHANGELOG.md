# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html) (against *our* API,
not pdfium-render's).

## [Unreleased]

### Added
- Initial scaffold: project structure, `rustler_precompiled` config, tag-driven
  release pipeline, and the porting plan (`PORTING.md`).
- Phase 0 (toolchain): `ExPdfium.pdfium_version/0`, a load-proof NIF that binds
  and initializes pdfium. Pinned `pdfium-render = "=0.8.37"`. The dev/test build
  binds pdfium dynamically; the libpdfium directory is passed to the NIF via
  `ExPdfium.Native.set_dynamic_lib_dir/1` (env vars set with `System.put_env`
  don't reach a NIF).

### Changed
- pdfium-render must be built with the `sync` feature (not just `thread_safe`):
  only `sync` adds the `Send + Sync` impls that let the single global `Pdfium`
  live in a `static`. `release.yml` updated accordingly.
- Pinned pdfium binary tag bumped `chromium/7506` → `chromium/7543` to match the
  pdfium API version pdfium-render 0.8.37 binds (`pdfium_latest`).
- Shipping strategy: the precompiled NIF binds pdfium **dynamically** and bundles
  the dynamic `libpdfium` inside each per-target tarball (rustler_precompiled
  extracts it next to the NIF; the NIF self-locates it via `dladdr`). bblanchon
  ships no static `libpdfium.a`, so static linking isn't used. The optional
  `static`/`libcpp`/`libstdcpp` features remain for a user-supplied `.a`.
