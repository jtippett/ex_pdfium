# ExPdfium v0.3 — Write Tools: Page Assembly + Save (design)

**Date:** 2026-06-25
**Status:** approved, implementing
**Scope:** the first write phase of v0.3. Reopens the write/edit scope that was
deliberately out of scope through v0.2 (the read-only toolkit).

## Why now

v0.2 shipped the complete **read** surface (open/count/render/text/metadata/
geometry/permissions/structure/forms+annotations read). The native pdfium engine
is already loaded and pdfium-render exposes a rich, faithful **write** surface;
exposing it idiomatically is the natural next step. v0.3 *starts* filling in write
tools, beginning with the highest-utility, most self-contained area.

## Decisions (locked)

1. **First phase = page assembly + save.** Merge, split/extract, delete, reorder,
   rotate, and save. Chosen over form-filling / annotation-authoring / new-doc
   creation because it is the canonical PDF-write use case, is self-contained, and
   forces a clean **save foundation** that every later write feature reuses.
2. **Mutation return convention = `{:ok, doc}` (chainable).** pdfium mutates the
   open document *in place* (a stateful native resource). In-place mutators return
   `{:ok, doc}` with the **same handle**, so they thread uniformly through `with`/
   pipelines. Ops that genuinely produce a **new** document return `{:ok, new_doc}`.
   (`{:ok, doc}` is for uniform piping, not a claim of a new value — documented.)

## Public API (phase 1)

```elixir
# Save — full snapshot (FPDF_SaveAsCopy); does NOT close or alter doc.
ExPdfium.save_to_bytes(doc)        # => {:ok, binary} | {:error, reason}
ExPdfium.save_to_file(doc, path)   # => :ok | {:error, reason}

# In-place mutation — return {:ok, doc} (same handle).
ExPdfium.append(doc, source)       # copy ALL of source's pages onto the end of doc (merge)
ExPdfium.delete_pages(doc, 3)      # delete one page index…
ExPdfium.delete_pages(doc, 2..4)   # …or an inclusive range
ExPdfium.rotate_page(doc, 0, 90)   # absolute rotation: 0 | 90 | 180 | 270

# Constructive — produce a NEW document, return {:ok, new_doc}.
ExPdfium.extract_pages(source, [0, 2, 5])  # new doc with those pages, in order, dups ok
```

Names follow pdfium-render (`append`, `save_to_bytes/file`) to keep the mapping
faithful; `delete_pages`/`extract_pages`/`rotate_page` are the idiomatic Elixir
spellings. `extract_pages` is the split/subset primitive (split = a few calls).

**Deferred to later 0.3.x (YAGNI now):** `insert_pages` (merge into the middle at
an index), relative rotation, `tile_into_new_document` (n-up), `new/0` blank-doc
creation (lands with the new-doc-creation area). `append` + `extract_pages` already
cover merge and split.

## pdfium-render mapping (faithful, no vendored logic)

- Save: `PdfDocument::save_to_bytes()` / `save_to_file(path)` (both via
  `save_to_writer`, a full `FPDF_SaveAsCopy`).
- `append`: `document.pages_mut().append(&source)` (copies source's whole page range).
- `delete_pages`: `pages_mut().delete_page_at_index(i)` / `delete_page_range(Range)`.
- `rotate_page`: `pages_mut().get(i)?.set_rotation(PdfPageRenderRotation)` (stored as
  page metadata; no content regeneration needed).
- `extract_pages`: `pdfium().create_new_pdf()` → loop
  `dest.pages_mut().copy_page_from_document(&source, idx, dest_count)` per requested
  index → wrap in a fresh `DocumentResource` (reuses the GC/cleanup-thread close).

## Architecture / safety

- Write NIFs mirror read NIFs exactly but take `.as_mut()` on the
  `Mutex<Option<PdfDocument>>` guard instead of `.as_ref()`. pdfium-render's
  mutators take `&mut PdfDocument`, which the mutex hands us under `PDFIUM_LOCK`.
  **No change to the locking model** — `PDFIUM_LOCK` already serializes every op, so
  concurrent writes (or a write racing a render) queue rather than corrupt. Logical
  semantics are last-write-wins (documented).
- **Two-document ops** (`append`, `extract_pages`): because `PDFIUM_LOCK` is global,
  holding it means no other thread holds any per-doc mutex, so locking both per-doc
  mutexes inside it cannot deadlock. **Aliasing hazard:** `append(doc, doc)` would
  lock one mutex twice (std `Mutex` is non-reentrant) and Rust can't alias `&mut`+`&`
  to one object — detect identical `ResourceArc`s up front and return
  `{:error, :same_document}`.
- Index validation against `page_count` happens **before** mutating, so a bad index
  fails cleanly (`:page_out_of_bounds`) with no half-applied edit.

## Errors (mapped, not invented)

`:document_closed`, `:page_out_of_bounds`, `:bad_rotation` (degrees ∉ {0,90,180,270}),
`:same_document`, and save failures → `:save_failed` / `:io_error` / `:enoent`.

## Testing — round-trip is the core technique

Every write is verified by `save_to_bytes` → `ExPdfium.open(bytes)` → assert with the
trusted read API. Fixtures: `text.pdf` (2 pages, distinct text per page), `sample.pdf`.
- append `text`+`sample` → reopen → `page_count == 4`, pages 0–1 text preserved.
- extract `[1,0]` from `text` → reopen → page order swapped (proves order + selection).
- delete `0` → reopen → count drops, remaining text is the old page 1.
- rotate 0 by 90 → reopen → `page_info(doc,0).rotation == 90`.
- error paths: closed doc, OOB index/range, bad degrees, `append(doc,doc)`.
- concurrency: parallel extract/save on a shared doc stays correct.

## Docs & release

- Reframe `@moduledoc`/README from "does not create, edit, or save" → a read **+
  write** toolkit (page assembly today; forms/annotation authoring in later 0.3.x).
- New README "Writing — page assembly" section, `examples/assembly.exs`, CHANGELOG
  entry, `@doc group: :writing` in the docs sidebar, PORTING.md scope note updated.
- Working loop per phase (TDD → full gate → code-reviewer → commit → push → CI).
  **0.3.0 = page assembly + save.** Forms-filling and annotation-authoring are
  later phases (0.3.1+/0.4), each gated by an explicit go-ahead. No tag/publish
  without a fresh go-ahead.
