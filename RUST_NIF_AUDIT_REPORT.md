# ExPdfium Rust NIF Security & Correctness Audit

Audit date: 2026-07-15  
Audited revision: `d84c3bb` (`main`, tagged `v0.4.3`) plus the changes described here  
Audit mode: hostile-input, failure-oriented, source-built NIF

## Outcome

The complete BEAM → Rustler → `pdfium-render` → pdfium surface was mapped and
reviewed. Confirmed defects were fixed rather than left as review notes. The most
important reproduced defect was an embedded-NUL path that panicked inside the
pinned `pdfium-render` dynamic bindings; the URI variant also poisoned the
document mutex and made the resource unusable. The regression family now covers
passwords, search strings, authored text, annotations, resource reuse, absence of
partial mutation, invalid numeric geometry, direct native option terms, date
parsing, export parity, scheduler classification, checksums, targets, ABI, Cargo
features, upstream asset digests, and immutable workflow action references.

No unresolved, reproducible Rust panic, BEAM scheduler misclassification, silent
security-default substitution, or release-manifest mismatch remains in the
audited source tree. The existing `v0.4.3` release binaries are an important
exception: they predate these source changes and require a new release before
users of precompiled artifacts receive the hardening (see Residual Risk R1).

## Baseline and product profile

- Initial worktree change: only the untracked owner-supplied
  `RUST_NIF_AUDIT_STARTFILE.md`; it was preserved.
- Baseline revision: `d84c3bb` (`Release 0.4.3`).
- Baseline source-built tests: 207 passing.
- Toolchains observed: Elixir 1.20.2, OTP 29, Rust/Cargo 1.97.
- Supported Elixir: `~> 1.17`; Rust MSRV: 1.82.
- Rustler: 0.38 / NIF ABI 2.15.
- Rust dependency: exact `pdfium-render = 0.8.37`, default features disabled,
  `pdfium_latest` (`pdfium_7543`) enabled; wrapper default enables `sync`.
- Runtime pdfium: bblanchon immutable `chromium/7543` release, dynamically
  bundled beside each NIF.
- Precompiled targets: Apple and Linux GNU on both aarch64 and x86_64.

## Executable architecture map

### Boundary and scheduling

`ExPdfium` owns public normalization and result structs; `ExPdfium.Native` owns
45 stubs with an exactly matching set of 45 Rust exports. Every export is now
`DirtyCpu`, including one-time configuration. Public file opens use `File.read/1`
before the binary enters the CPU-dirty parser, and public file saves use
`File.write/2` after native serialization. No filesystem operation remains in a
CPU-dirty NIF.

| Surface | Native exports | Boundary shape |
|---|---:|---|
| Diagnostics/configuration | 2 | version/error; dynamic library directory |
| Document lifecycle | 3 | binary+password → resource; count; close |
| Rendering | 1 | resource+page+map → owned bitmap binary/metadata |
| Text/search | 5 | resource/page/options → strings, glyphs, rects, matches |
| Metadata/geometry/permissions | 3 | resource/page → maps/flags via tuples |
| Structure/navigation | 4 | bookmarks, links, attachment metadata/data |
| Forms/annotation reading | 3 | form type, widgets, page annotations |
| Page objects/images | 4 | object metadata, decoded/raw image bytes |
| Page assembly/save | 5 | save, append, extract, delete, rotate |
| New document/drawing | 7 | create, add page, text/path/image objects |
| Annotation authoring | 5 | add four types; delete by index |
| Flatten/signatures | 3 | flatten page/document; signature data |

The public Elixir module adds pure helpers such as thumbnails, matrix/rotation
composition, bitmap conversion, date parsing, file writing, and text repair. It
does not add another native execution path.

### Ownership, locking, and cleanup

```text
BEAM caller
  -> DirtyCpu NIF
     -> process-wide PDFIUM_LOCK
        -> per-document Mutex<Option<PdfDocument<'static>>>
           -> short-lived PdfPage / object / annotation handles

Resource GC Drop
  -> unbounded std channel (one message per dropped document)
     -> dedicated named cleanup thread
        -> PDFIUM_LOCK
           -> FPDF_CloseDocument
```

- `PDFIUM` is a `OnceLock<Result<Pdfium, ()>>`; initialization success or failure
  is cached once. A missing/incompatible library returns
  `:pdfium_init_failed`, not a Rust panic.
- All pdfium calls, including explicit close and GC close, serialize under
  `PDFIUM_LOCK`. Lock order is global lock before document lock.
- The per-document `Option` makes close idempotent and prevents use after close.
- Page handles are never stored in BEAM resources.
- Cleanup-thread creation uses fallible `thread::Builder::spawn`; document
  construction returns `:cleanup_failed` if the worker cannot be created.
- There are no callbacks into BEAM, async request tables, monitors, timers,
  network sockets, subprocesses, deserializers, random sources, or snapshots.
  Host capability use is limited to dynamic-library discovery/loading and the
  explicit Elixir filesystem APIs.

### Release and package chain

```text
PDFIUM_TAG + PDFIUM_SHA256SUMS
  -> CI/source tests and four-target release build
     -> NIF + verified libpdfium in each tar.gz
        -> GitHub release
           -> rustler_precompiled checksum manifest
              -> Hex package (source + checksums; no bundled binary in package)
```

Third-party Actions are pinned to full commit IDs. Workflow-wide permissions are
read-only; only the release upload job receives `contents: write`. The four
current `v0.4.3` artifacts were downloaded, SHA-256 verified by
`rustler_precompiled`, and inspected to contain exactly the target NIF plus the
platform `libpdfium` sibling.

## Finding ledger

| ID | Severity | Surface and evidence | Disposition, fix, and regression proof |
|---|---|---|---|
| F1 | Medium | Embedded NUL in an encrypted-document password reached `CString::new(...).unwrap()` in `pdfium-render` 0.8.37 and reproduced `:nif_panicked`. | Fixed with pre-lock `:invalid_string` validation. Test proves the error and a subsequent correct encrypted open/count. |
| F2 | Medium | Embedded NUL URI reproduced the same upstream panic while holding the document mutex; the next call returned `:lock_poisoned`. UTF-16 text/search helpers silently truncated at NUL. | Fixed across passwords, queries, authored text/free text, and URIs. Tests prove caller/VM survival, empty annotations/objects after failure, valid reuse, and no truncated success. |
| F3 | Medium | Path opens performed `std::fs::read()` inside a `DirtyCpu` NIF; a slow/FIFO filesystem could occupy a dirty CPU scheduler. | Public path reads moved to BEAM `File.read/1`; native parser accepts only bytes. Direct native-path regression proves fail-closed behavior and public reuse. |
| F4 | Medium | Page/drawing/annotation/image `f64` values narrowed to `f32` without finite/range checks; huge values became infinities. Placed images capped each dimension but allowed a 900 MP staging allocation. | All numeric crossings validate finite `f32` representability; positive sizes/radii are enforced. Image pixel area, checked arithmetic, and `try_reserve_exact()` bound/fail allocation. Tests prove no page/object side effect and later reuse. |
| F5 | Medium | Page objects were attached before fallible styling/regeneration, and annotations were attached before fallible property writes. Error could therefore mean partial mutation. | Object changes stage with manual content regeneration and remove the new object on styling/regeneration failure. Annotation operations record the insertion index and delete on any construction/property error. Tests cover absence after validation failures; code-path review covers upstream failure rollback. |
| F6 | Medium | Render/image bitmap dimensions used `unwrap_or(0)` and then returned success; image enumeration silently omitted unreadable images and substituted bit depth 0; unknown bitmap enums defaulted to BGRx. | Positive dimensions, pixel area, byte divisibility, minimum stride, and integer conversions now fail explicitly. Image enumeration propagates `:image_failed`; bitmap enum matching is exhaustive, including the deprecated alias. |
| F7 | Medium | Seven permission probes used `unwrap_or(false)` after one probe; checkbox/radio checked state also defaulted errors to false; page rotation defaulted any error to 0. | Every security permission propagates `:unsupported_security`; form state returns `:form_failed`; rotation/dimensions return `:page_info_failed`. Attachment lengths now cross as `u64`, avoiding 32-bit truncation. |
| F8 | Low | A direct native render call with a non-map options term made every `map_get` look absent and silently rendered defaults. | The boundary now rejects non-maps with `:bad_option`; regression proves resource reuse. |
| F9 | Low | `parse_pdf_date/1` was not end-anchored and accepted trailing garbage; timezone hour/minute ranges and incomplete signs were accepted. | Regex is end-anchored, signed offsets require an hour, and hour/minute ranges are checked. Regression family covers garbage, incomplete sign, +24 hours, and 60 minutes. |
| F10 | Medium | Dynamic pdfium binding used `expect()`, producing `:nif_panicked` when the bundled library was missing/incompatible. `thread::spawn()` could also panic during GC cleanup initialization. | Initialization is a cached explicit result; cleanup construction is fallible and checked before resource creation. A disposable BEAM subprocess verified `{:error, :pdfium_init_failed}`. |
| F11 | High (release correctness) | The checked-in manifest named only v0.1.0 artifacts while the package/version/release was v0.4.3. The loader fails closed when the expected basename is absent. | Manifest regenerated from the existing four v0.4.3 assets. Tests bind current Mix version, four targets, NIF 2.15, native stubs, Rust exports, and release target matrix together. A production-env default precompiled load returned `"pdfium loaded"`. |
| F12 | High (supply chain) | CI/release downloaded upstream `libpdfium` archives without checking content; third-party Actions used movable tags; all release jobs inherited write permission. | Added authoritative SHA-256 pins for the immutable upstream release, verification before extraction, full-SHA action pins, and job-level least privilege. The developer fetch path was executed successfully with verification. |
| F13 | Low | README and maintenance docs claimed read-only/static packaging, old `~> 0.1`, and old PDFium pins despite the executable product. | README, update procedure, script comments, changelog, and historical-document banners now distinguish the current dynamic write-capable product from archived design history. |

## Validation evidence

- `mix format --check-formatted`
- `cargo fmt --check --manifest-path native/ex_pdfium/Cargo.toml`
- `EXPDFIUM_BUILD=1 mix compile --warnings-as-errors`
- `cargo clippy --manifest-path native/ex_pdfium/Cargo.toml --all-targets -- -D warnings`
- `cargo test --manifest-path native/ex_pdfium/Cargo.toml` (crate has no unit tests; boundary behavior is exercised through ExUnit)
- `EXPDFIUM_BUILD=1 mix test` (final count recorded in the handoff response)
- `EXPDFIUM_BUILD=1 mix docs`
- RustSec `cargo audit` against 58 locked Rust dependencies: no advisories
- `mix hex.audit`: no retired/security-advisory packages
- `mix rustler_precompiled.download ExPdfium.Native --all --print`: four current artifacts downloaded and checksummed
- `MIX_ENV=prod mix run --no-start`: default precompiled artifact loaded its bundled pdfium and returned `"pdfium loaded"`
- `mix hex.build --unpack`: package file/dependency metadata inspected; native source, current manifest, and PDFium sums included
- `bash -n` for the fetch script and YAML parsing for both workflows
- Successful verified download/extraction through `scripts/fetch-pdfium-dev.sh`
- Disposable missing-library subprocess: explicit `{:error, :pdfium_init_failed}`

## Residual risk and required owner action

### R1 — a new release is required

The existing `v0.4.3` precompiled binaries were built before this audit. Their
checksums and bundle layout are now correct, and backward compatibility was
smoke-tested, but they do **not** contain the hardened Rust implementation. The
next release must rebuild all four targets from this source, regenerate its
manifest, pass the gated publish workflow, and be runtime-smoke-tested on each
platform. This audit deliberately did not tag, publish, push, or alter external
services.

### R2 — pdfium remains native, in-process code

A genuine memory-safety fault in pdfium can still crash or corrupt the BEAM VM.
The wrapper contains Rust/contract faults but cannot sandbox the C++ engine.
Keep the documented recommendation to process adversarial PDFs in a supervised
OS process/container with memory and CPU limits.

### R3 — upstream bitmap copy contains an unsafe internal assumption

Pinned `pdfium-render`'s `PdfBitmap::as_raw_bytes()` obtains a buffer length from
pdfium's stride × height inside its bindings. ExPdfium now verifies the bitmap
handle format, positive bounded dimensions before the call, and stride/length
relationships after it, but the public upstream API does not expose stride or
the private bitmap handle for a complete pre-copy validation. Track/fix this
upstream when upgrading `pdfium-render`; local validation cannot eliminate a
malicious or buggy pdfium return value before that internal unsafe slice/copy.

### R4 — deliberately proportional outputs

Text, page/object lists, raw image streams, signatures, saves, and similar
results remain proportional to document content. Render/decode/attachment and
outline amplification have explicit caps, but arbitrary global caps on faithful
extraction would change product policy. OS isolation remains the final bound for
untrusted workloads.

### R5 — cleanup catastrophic fallback

If the cleanup worker dies after resource creation or its mutex becomes
poisoned, GC deliberately leaks that document rather than blocking a normal BEAM
scheduler or closing pdfium without serialization. Worker creation failure is
explicit and prevents documents from being constructed; the residual leak path
requires a catastrophic internal thread failure and is not caller-controlled.

### R6 — platform and fuzzing coverage

The hardened source and existing precompiled artifact were executed on macOS
aarch64. The other three release archives were checksum/layout inspected but not
executed locally. No sanitizer/libFuzzer harness was added around the third-party
pdfium parser. The four-target CI build, platform smoke tests, and periodic
corpus/fuzzing against newer pdfium releases remain valuable defense in depth.

### R7 — global serialization is intentional

All pdfium calls serialize process-wide because the pinned engine/binding is not
thread-safe. This prevents races but means one expensive operation delays other
callers. Dirty scheduling protects normal schedulers; workload-level isolation,
timeouts around caller processes, and bounded concurrency should handle service
availability.
