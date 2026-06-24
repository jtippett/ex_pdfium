//! ExPdfium NIF — a thin, faithful bridge to pdfium via `pdfium-render`.
//!
//! Phase 0 wires up the global pdfium instance and a single load-proof NIF
//! (`pdfium_version`). Document/page NIFs land in later phases (see PORTING.md).
//! This encodes the load-bearing decisions from PORTING.md §2.
//!
//! Three rules drive everything here:
//!   1. pdfium is NOT thread-safe and the BEAM calls dirty NIFs from many OS
//!      threads -> one global Pdfium instance, and every pdfium call serialized
//!      through `PDFIUM_LOCK`. (The `sync`/`thread_safe` feature does NOT
//!      serialize data calls — see `PDFIUM_LOCK`; we keep `sync` only for its
//!      `Send + Sync`, so the instance can live in a `static`.)
//!   2. `PdfDocument<'a>` borrows from `Pdfium`. A `'static` Pdfium (OnceLock)
//!      makes `PdfDocument<'static>` storable in a ResourceArc.
//!   3. pdfium work is synchronous and CPU-heavy -> every NIF is DirtyCpu.
//!      (No tokio — unlike ex_bashkit.)

// pdfium-touching code must never panic: a panic while our global `PDFIUM_LOCK`
// (below) is held would poison it. We do recover from poison (see `pdfium_lock`),
// but no-panic is the primary discipline. So forbid `unwrap`/`expect`; map errors
// to atoms instead. The one exception is one-time library init, where failure to
// load pdfium at all is genuinely fatal — that `expect` is allowed on `pdfium()`.
#![deny(clippy::unwrap_used, clippy::expect_used)]

use std::sync::{Mutex, OnceLock};

use pdfium_render::prelude::*;
use rustler::{Atom, Binary, ResourceArc, Term};

mod atoms {
    rustler::atoms! {
        ok,
        path,
        binary,
        bad_source,
        // open/load errors, mapped from PdfiumError (we map, we don't invent)
        password_error,
        invalid_pdf,
        file_error,
        unsupported_security,
        enoent,
        io_error,
        open_failed,
        // resource state
        document_closed,
        lock_poisoned,
    }
}

// ── The single global pdfium instance ───────────────────────────────────────
//
// `'static` so documents can borrow it and live in resources. Initialized once;
// every NIF goes through `pdfium()`.
static PDFIUM: OnceLock<Pdfium> = OnceLock::new();

// Serializes EVERY pdfium operation. pdfium is not thread-safe, and — contrary to
// what its name suggests — pdfium-render's `thread_safe`/`sync` feature only
// brackets library Init/Destroy under a mutex; individual data calls
// (load/page-count/render/close) run with NO lock. Since the BEAM calls our dirty
// NIFs from a pool of OS threads, WE must serialize. Every pdfium-touching path
// (including document close/drop) goes through this lock. The `sync` feature's
// `unsafe impl Send + Sync` for Pdfium/PdfDocument is sound precisely because of
// this discipline: access is effectively single-threaded.
static PDFIUM_LOCK: Mutex<()> = Mutex::new(());

// Dev/test only: the directory holding a dynamic libpdfium, supplied from Elixir
// via `set_dynamic_lib_dir/1` before the first pdfium call. We CANNOT read this
// from an env var set with `System.put_env`: that updates Erlang's internal env
// table but not the C `getenv` a NIF sees, so a function argument is the only
// reliable Elixir->NIF channel. (An OS-level PDFIUM_DYNAMIC_LIB_PATH, set before
// the BEAM boots, still works and is honored as a fallback.)
#[cfg(not(feature = "static"))]
static DYNAMIC_LIB_DIR: OnceLock<String> = OnceLock::new();

// Production discovery: locate the directory of THIS loaded NIF via `dladdr` on a
// symbol we own, so we can pick up a libpdfium shipped *beside* it. The release
// tarball bundles the dynamic libpdfium next to the NIF (rustler_precompiled
// extracts the whole archive into priv/native), so no Elixir wiring or env var is
// needed in production — the NIF finds its own sibling.
#[cfg(all(not(feature = "static"), unix))]
fn nif_sibling_dir() -> Option<String> {
    use std::ffi::CStr;
    let mut info: libc::Dl_info = unsafe { std::mem::zeroed() };
    let addr = std::ptr::addr_of!(PDFIUM) as *const libc::c_void;
    if unsafe { libc::dladdr(addr, &mut info) } == 0 || info.dli_fname.is_null() {
        return None;
    }
    let path = unsafe { CStr::from_ptr(info.dli_fname) }.to_str().ok()?;
    let dir = std::path::Path::new(path).parent()?.to_str()?.to_string();
    // Only claim this dir if a libpdfium is actually bundled here; otherwise
    // return None so the caller falls through to the system loader (e.g. a
    // from-source consumer build, which doesn't bundle libpdfium).
    if std::path::Path::new(&Pdfium::pdfium_platform_library_name_at_path(&dir)).exists() {
        Some(dir)
    } else {
        None
    }
}

#[cfg(all(not(feature = "static"), not(unix)))]
fn nif_sibling_dir() -> Option<String> {
    None
}

// One-time init: a failure to load pdfium at all is fatal, so `expect` here is
// intentional (and runs before any pdfium call could hold the `sync` mutex).
#[allow(clippy::expect_used)]
fn pdfium() -> &'static Pdfium {
    PDFIUM.get_or_init(|| {
        // Optional static link (user-supplied libpdfium.a via the `static`
        // feature; NOT the shipped path — release bundles a dynamic libpdfium).
        #[cfg(feature = "static")]
        let bindings = Pdfium::bind_to_statically_linked_library()
            .expect("statically linked pdfium failed to bind");

        // Dynamic binding. Resolution order:
        //   1. dir handed in from Elixir via set_dynamic_lib_dir/1 (dev/test),
        //   2. an OS-level PDFIUM_DYNAMIC_LIB_PATH (set before the BEAM boots),
        //   3. the NIF's own directory (production: libpdfium bundled beside it),
        //   4. the system loader's search path.
        #[cfg(not(feature = "static"))]
        let bindings = {
            let dir = DYNAMIC_LIB_DIR
                .get()
                .cloned()
                .or_else(|| std::env::var("PDFIUM_DYNAMIC_LIB_PATH").ok())
                .or_else(nif_sibling_dir);
            let bound = match dir {
                // A resolved dir is a libpdfium we were told about or that ships
                // beside us; if it won't load, fail loudly rather than silently
                // binding the pinned API against an unrelated system pdfium.
                Some(dir) => {
                    Pdfium::bind_to_library(Pdfium::pdfium_platform_library_name_at_path(&dir))
                }
                None => Pdfium::bind_to_system_library(),
            };
            bound.expect(
                "could not load libpdfium (bundled lib missing? else set \
                 ExPdfium.Native.set_dynamic_lib_dir/1 or install pdfium)",
            )
        };

        Pdfium::new(bindings)
    })
}

/// Acquire the global pdfium lock. `PDFIUM_LOCK` guards only `()`, so a poisoned
/// lock carries no corrupted data — recover the guard and keep serializing rather
/// than failing open (an unserialized pdfium call would be UB) or failing closed
/// (bricking the library). Poisoning should not happen anyway: pdfium-touching
/// code never panics (see the crate-level `deny`).
fn pdfium_lock() -> std::sync::MutexGuard<'static, ()> {
    PDFIUM_LOCK
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
}

/// Run `f` with exclusive access to pdfium, serialized across all threads (see
/// `PDFIUM_LOCK`). `f` returns a tagged result so callers map errors to atoms.
fn with_pdfium<R>(f: impl FnOnce(&'static Pdfium) -> Result<R, Atom>) -> Result<R, Atom> {
    let _lock = pdfium_lock();
    f(pdfium())
}

// ── NIFs ─────────────────────────────────────────────────────────────────────

/// Phase 0: prove pdfium links & initializes.
///
/// Touching `pdfium()` binds the library (eagerly resolving every FPDF symbol)
/// and runs `FPDF_InitLibrary` once — so returning at all means pdfium loaded.
/// pdfium exposes no build-version string through its public C API, so we return
/// a stable load-confirmation marker rather than inventing one.
#[rustler::nif(schedule = "DirtyCpu")]
fn pdfium_version() -> String {
    let _ = pdfium();
    "pdfium loaded".to_string()
}

/// Dev/test only: point the dynamic binding at a directory containing libpdfium,
/// before the first pdfium call. No-op on the statically-linked (shipped) build,
/// and a no-op if pdfium has already been initialized.
#[rustler::nif]
fn set_dynamic_lib_dir(dir: String) -> rustler::Atom {
    #[cfg(not(feature = "static"))]
    let _ = DYNAMIC_LIB_DIR.set(dir);
    #[cfg(feature = "static")]
    let _ = dir;
    atoms::ok()
}

// ── Document resource ────────────────────────────────────────────────────────
//
// `Mutex<Option<…>>`: the Option lets `document_close` release the document
// early (take it); the Mutex serializes multi-step ops on one document. The
// `'static` Pdfium (above) makes `PdfDocument<'static>` storable here, and the
// `sync` feature provides its `Send + Sync`. Dropping the resource on GC drops
// the document, which closes it in pdfium — so there's no manual-close leak.
struct DocumentResource {
    doc: Mutex<Option<PdfDocument<'static>>>,
}

#[rustler::resource_impl]
impl rustler::Resource for DocumentResource {}

impl Drop for DocumentResource {
    // GC path: dropping the PdfDocument calls FPDF_CloseDocument, a pdfium call,
    // so serialize it under the global lock. If `close/1` already took the
    // document, this is a no-op.
    //
    // INVARIANT: this must never run on a thread already holding `PDFIUM_LOCK`
    // (the std Mutex is non-reentrant → self-deadlock). It can't today: a NIF
    // holds its `ResourceArc` for the whole call, so a doc can't reach refcount 0
    // mid-call. A future NIF that drops the last ref to a doc *inside* a
    // `with_pdfium`/`pdfium_lock` section would break this.
    fn drop(&mut self) {
        let _pdfium_lock = pdfium_lock();
        let slot = self
            .doc
            .get_mut()
            .unwrap_or_else(|poison| poison.into_inner());
        drop(slot.take());
    }
}

// What `document_open` was handed. Either way we end up with an owned Vec and
// load via `load_pdf_from_byte_vec`, which gives the document ownership of its
// buffer and ties its lifetime only to the `'static` Pdfium — exactly what a
// `'static` resource needs.
enum Source {
    Path(String),
    Bytes(Vec<u8>),
}

fn io_error_atom(err: &std::io::Error) -> Atom {
    match err.kind() {
        std::io::ErrorKind::NotFound => atoms::enoent(),
        _ => atoms::io_error(),
    }
}

// Map a PdfiumError to a friendly atom. We MAP pdfium's semantics; we never
// invent our own.
fn open_error_atom(err: &PdfiumError) -> Atom {
    match err {
        PdfiumError::IoError(e) => io_error_atom(e),
        PdfiumError::PdfiumLibraryInternalError(internal) => match internal {
            // pdfium reports the same error for a missing OR an incorrect password.
            PdfiumInternalError::PasswordError => atoms::password_error(),
            PdfiumInternalError::FormatError => atoms::invalid_pdf(),
            PdfiumInternalError::FileError => atoms::file_error(),
            PdfiumInternalError::SecurityError => atoms::unsupported_security(),
            _ => atoms::open_failed(),
        },
        _ => atoms::open_failed(),
    }
}

/// Phase 1: open from `{:path, p}` | `{:binary, bytes}`, optional password.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_open(
    source: Term,
    password: Option<String>,
) -> Result<ResourceArc<DocumentResource>, Atom> {
    // Read the file outside the pdfium lock — file IO needn't be serialized.
    let bytes = match decode_source(source)? {
        Source::Bytes(bytes) => bytes,
        Source::Path(path) => std::fs::read(&path).map_err(|e| io_error_atom(&e))?,
    };

    with_pdfium(|pdfium| {
        let doc = pdfium
            .load_pdf_from_byte_vec(bytes, password.as_deref())
            .map_err(|e| open_error_atom(&e))?;

        Ok(ResourceArc::new(DocumentResource {
            doc: Mutex::new(Some(doc)),
        }))
    })
}

fn decode_source(term: Term) -> Result<Source, Atom> {
    let (tag, value): (Atom, Term) = term.decode().map_err(|_| atoms::bad_source())?;
    if tag == atoms::path() {
        Ok(Source::Path(
            value.decode().map_err(|_| atoms::bad_source())?,
        ))
    } else if tag == atoms::binary() {
        let bytes: Binary = value.decode().map_err(|_| atoms::bad_source())?;
        Ok(Source::Bytes(bytes.as_slice().to_vec()))
    } else {
        Err(atoms::bad_source())
    }
}

/// Phase 1: page count. `{:error, :document_closed}` once the doc is closed.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_page_count(doc: ResourceArc<DocumentResource>) -> Result<u32, Atom> {
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        match guard.as_ref() {
            Some(document) => Ok(u32::from(document.pages().len())),
            None => Err(atoms::document_closed()),
        }
    })
}

/// Phase 1: explicit early close. Idempotent — closing an already-closed
/// document is a no-op. (GC closes it too; this just releases pdfium memory now.)
#[rustler::nif(schedule = "DirtyCpu")]
fn document_close(doc: ResourceArc<DocumentResource>) -> Atom {
    // FPDF_CloseDocument is a pdfium call, so close under the global lock. Hold
    // it across the take so the document drops (closes) while we own pdfium.
    let _pdfium_lock = pdfium_lock();
    let mut slot = doc.doc.lock().unwrap_or_else(|poison| poison.into_inner());
    drop(slot.take());
    atoms::ok()
}

rustler::init!("Elixir.ExPdfium.Native");
