//! ExPdfium NIF — a thin, faithful bridge to pdfium via `pdfium-render`.
//!
//! SCAFFOLD. This encodes the load-bearing decisions from PORTING.md §2; the
//! bodies are sketches to be filled in per phase. It will not compile until
//! `cargo add pdfium-render` brings the crate and the APIs are matched against
//! the pinned version's docs.
//!
//! Three rules drive everything here:
//!   1. pdfium is NOT thread-safe and the BEAM calls dirty NIFs from many OS
//!      threads -> one global, `thread_safe`-feature Pdfium instance.
//!   2. `PdfDocument<'a>` borrows from `Pdfium`. A `'static` Pdfium (OnceLock)
//!      makes `PdfDocument<'static>` storable in a ResourceArc.
//!   3. pdfium work is synchronous and CPU-heavy -> every NIF is DirtyCpu.
//!      (No tokio — unlike ex_bashkit.)

use std::sync::{Mutex, OnceLock};

use pdfium_render::prelude::*;
use rustler::{Error, NifResult, ResourceArc};

// ── The single global pdfium instance ───────────────────────────────────────
//
// `'static` so documents can borrow it and live in resources. Initialized once;
// every NIF goes through `pdfium()`.
static PDFIUM: OnceLock<Pdfium> = OnceLock::new();

fn pdfium() -> &'static Pdfium {
    PDFIUM.get_or_init(|| {
        // Shipping build: linked statically into this .so.
        #[cfg(feature = "static")]
        let bindings = Pdfium::bind_to_statically_linked_library()
            .expect("statically linked pdfium failed to bind");

        // Dev/test build: load a dynamic libpdfium. Prefer an explicit path
        // (set in test_helper / the dev download script), fall back to the
        // system library.
        #[cfg(not(feature = "static"))]
        let bindings = match std::env::var("PDFIUM_DYNAMIC_LIB_PATH") {
            Ok(dir) => Pdfium::bind_to_library(Pdfium::pdfium_platform_library_name_at_path(&dir))
                .or_else(|_| Pdfium::bind_to_system_library())
                .expect("could not load a dynamic libpdfium (set PDFIUM_DYNAMIC_LIB_PATH)"),
            Err(_) => {
                Pdfium::bind_to_system_library().expect("no libpdfium found (set PDFIUM_DYNAMIC_LIB_PATH)")
            }
        };

        Pdfium::new(bindings)
    })
}

// ── Document resource ───────────────────────────────────────────────────────
//
// `Mutex<Option<…>>`: the Option lets `document_close` release early (take it);
// the Mutex serializes multi-step ops on one document (belt-and-suspenders over
// the `thread_safe` feature). Drop closes the document — no manual-close leak.
struct DocumentResource {
    doc: Mutex<Option<PdfDocument<'static>>>,
}

#[rustler::resource_impl]
impl rustler::Resource for DocumentResource {}

// ── NIFs ─────────────────────────────────────────────────────────────────────

/// Phase 0: prove pdfium links & initializes.
#[rustler::nif(schedule = "DirtyCpu")]
fn pdfium_version() -> String {
    // Placeholder — pdfium-render exposes a version/bindings handle; return
    // something that only succeeds if the library actually loaded.
    let _ = pdfium();
    "pdfium loaded".to_string()
}

/// Phase 1: open from {:path, p} | {:binary, bytes}, optional password.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_open(
    _source: rustler::Term,
    _password: Option<String>,
) -> NifResult<ResourceArc<DocumentResource>> {
    // TODO(Phase 1): decode `source`, call pdfium().load_pdf_from_file /
    // load_pdf_from_byte_slice (or _vec for an owned buffer), map PdfiumError.
    let _ = pdfium();
    Err(Error::Atom("not_implemented"))
}

/// Phase 1: explicit early close. Idempotent.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_close(doc: ResourceArc<DocumentResource>) -> rustler::Atom {
    let _ = doc.doc.lock().map(|mut g| g.take());
    rustler::types::atom::ok()
}

/// Phase 1: page count.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_page_count(_doc: ResourceArc<DocumentResource>) -> NifResult<u16> {
    // TODO(Phase 1): lock, ensure Some, doc.pages().len().
    Err(Error::Atom("not_implemented"))
}

/// Phase 2: render a 0-indexed page -> (data, width, height, stride, format).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_render_page(
    _doc: ResourceArc<DocumentResource>,
    _page_index: u16,
    _opts: rustler::Term,
) -> NifResult<(rustler::Binary<'static>, u32, u32, u32, rustler::Atom)> {
    // TODO(Phase 2): lock; fetch page (don't store it); build a PdfRenderConfig
    // from opts (dpi/scale/width/height); render to a bitmap; copy bytes into an
    // OwnedBinary; return with width/height/stride and the format atom.
    Err(Error::Atom("not_implemented"))
}

rustler::init!("Elixir.ExPdfium.Native");
