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
use rustler::{Atom, Binary, Env, OwnedBinary, ResourceArc, Term};

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
        // render: option keys
        dpi,
        scale,
        width,
        height,
        format,
        background,
        // render: option values
        rgba,
        bgra,
        white,
        transparent,
        // render: errors
        page_out_of_bounds,
        render_failed,
        unsupported_format,
        unsupported_background,
        bad_option,
        alloc_failed,
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

// Closing a document (`FPDF_CloseDocument`) is a pdfium call, so it must run
// under `PDFIUM_LOCK`. A GC-driven `Drop` runs on a *normal* BEAM scheduler,
// where blocking on a lock that a long render holds would stall the scheduler
// past its budget. So `Drop` hands the document to this dedicated cleanup thread,
// which closes it under the lock off-scheduler. `PdfDocument` is `Send` (the
// `sync` feature), so moving it across the channel is sound.
static CLEANUP: OnceLock<Mutex<std::sync::mpsc::Sender<PdfDocument<'static>>>> = OnceLock::new();

fn cleanup_sender() -> &'static Mutex<std::sync::mpsc::Sender<PdfDocument<'static>>> {
    CLEANUP.get_or_init(|| {
        let (tx, rx) = std::sync::mpsc::channel::<PdfDocument<'static>>();
        std::thread::spawn(move || {
            // Blocks until a document arrives; ends when all senders drop (never,
            // in practice — the static `Sender` lives for the process lifetime).
            for document in rx {
                let _lock = pdfium_lock();
                drop(document); // FPDF_CloseDocument, serialized under the lock
            }
        });
        Mutex::new(tx)
    })
}

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
    // GC path. Closing is a pdfium call that must run under `PDFIUM_LOCK`, but this
    // `Drop` runs on a normal BEAM scheduler — so hand the document to the cleanup
    // thread, which closes it under the lock off-scheduler. The common path takes
    // no pdfium lock here, so it can't stall the scheduler. If `close/1` already
    // took the document, there's nothing to do.
    fn drop(&mut self) {
        let slot = self
            .doc
            .get_mut()
            .unwrap_or_else(|poison| poison.into_inner());
        let Some(document) = slot.take() else {
            return;
        };
        // The common path takes no pdfium lock. The fallbacks below DO take
        // `pdfium_lock()`; they're only reachable if the cleanup thread is gone,
        // and they must not run on a thread already holding `PDFIUM_LOCK` (the
        // non-reentrant std Mutex would self-deadlock). No NIF drops a doc's last
        // ref while inside `with_pdfium`, so today that can't happen.
        match cleanup_sender().lock() {
            Ok(tx) => {
                // On send error (cleanup thread gone — shouldn't happen) the
                // SendError owns the document; close it inline under the lock.
                if let Err(returned) = tx.send(document) {
                    let _lock = pdfium_lock();
                    drop(returned.0);
                }
            }
            Err(_) => {
                let _lock = pdfium_lock();
                drop(document);
            }
        }
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

// ── Rendering ────────────────────────────────────────────────────────────────

enum Format {
    Rgba,
    Bgra,
}

enum Sizing {
    Dpi(f64),
    Scale(f64),
    Size {
        width: Option<i32>,
        height: Option<i32>,
    },
}

impl Sizing {
    fn is_positive(&self) -> bool {
        match self {
            Sizing::Dpi(d) => *d > 0.0,
            Sizing::Scale(s) => *s > 0.0,
            Sizing::Size { width, height } => {
                width.is_none_or(|w| w > 0) && height.is_none_or(|h| h > 0)
            }
        }
    }
}

enum Background {
    White,
    Transparent,
}

struct RenderOpts {
    sizing: Sizing,
    format: Format,
    background: Background,
}

impl RenderOpts {
    // Parse the opts map. Sizing precedence: width/height -> scale -> dpi (72).
    // A present-but-wrong-typed or non-positive option is an error, not a silent
    // fallback to the default.
    fn from_term(opts: Term) -> Result<Self, Atom> {
        let width = opt_i32(opts, atoms::width())?;
        let height = opt_i32(opts, atoms::height())?;
        let scale = opt_f64(opts, atoms::scale())?;
        let dpi = opt_f64(opts, atoms::dpi())?;

        let sizing = if width.is_some() || height.is_some() {
            Sizing::Size { width, height }
        } else if let Some(scale) = scale {
            Sizing::Scale(scale)
        } else {
            Sizing::Dpi(dpi.unwrap_or(72.0))
        };
        if !sizing.is_positive() {
            return Err(atoms::bad_option());
        }

        let format = match opt_atom(opts, atoms::format())? {
            None => Format::Rgba,
            Some(f) if f == atoms::rgba() => Format::Rgba,
            Some(f) if f == atoms::bgra() => Format::Bgra,
            Some(_) => return Err(atoms::unsupported_format()),
        };

        let background = match opt_atom(opts, atoms::background())? {
            None => Background::White,
            Some(b) if b == atoms::white() => Background::White,
            Some(b) if b == atoms::transparent() => Background::Transparent,
            Some(_) => return Err(atoms::unsupported_background()),
        };

        Ok(RenderOpts {
            sizing,
            format,
            background,
        })
    }

    fn to_config(&self) -> PdfRenderConfig {
        // Native pixel order is BGRA; asking pdfium to reverse it yields RGBA with
        // no post-conversion. The config clears to white by default.
        let mut config =
            PdfRenderConfig::new().set_reverse_byte_order(matches!(self.format, Format::Rgba));

        config = match &self.sizing {
            // pdfium's scale 1.0 == 72 DPI (1 point -> 1 pixel).
            Sizing::Dpi(dpi) => config.scale_page_by_factor((dpi / 72.0) as f32),
            Sizing::Scale(scale) => config.scale_page_by_factor(*scale as f32),
            Sizing::Size {
                width: Some(w),
                height: Some(h),
            } => config.set_target_size(*w, *h),
            Sizing::Size {
                width: Some(w),
                height: None,
            } => config.set_target_width(*w),
            Sizing::Size {
                width: None,
                height: Some(h),
            } => config.set_target_height(*h),
            Sizing::Size {
                width: None,
                height: None,
            } => config,
        };

        if matches!(self.background, Background::Transparent) {
            config = config.set_clear_color(PdfColor::new(0, 0, 0, 0));
        }

        config
    }

    fn format_atom(&self) -> Atom {
        match self.format {
            Format::Rgba => atoms::rgba(),
            Format::Bgra => atoms::bgra(),
        }
    }
}

// Optional opts: `Ok(None)` if the key is absent, `Ok(Some(v))` if present and
// valid, `Err(:bad_option)` if present but the wrong type / out of range. (A
// missing key makes `map_get` return `Err`, which we treat as absent.)
fn opt_f64(opts: Term, key: Atom) -> Result<Option<f64>, Atom> {
    match opts.map_get(key) {
        Err(_) => Ok(None),
        // Accept an Elixir integer or float.
        Ok(t) => t
            .decode::<f64>()
            .ok()
            .or_else(|| t.decode::<i64>().ok().map(|i| i as f64))
            .map(Some)
            .ok_or_else(atoms::bad_option),
    }
}

fn opt_i32(opts: Term, key: Atom) -> Result<Option<i32>, Atom> {
    match opts.map_get(key) {
        Err(_) => Ok(None),
        Ok(t) => t
            .decode::<i64>()
            .ok()
            .and_then(|i| i32::try_from(i).ok())
            .map(Some)
            .ok_or_else(atoms::bad_option),
    }
}

fn opt_atom(opts: Term, key: Atom) -> Result<Option<Atom>, Atom> {
    match opts.map_get(key) {
        Err(_) => Ok(None),
        Ok(t) => t
            .decode::<Atom>()
            .map(Some)
            .map_err(|_| atoms::bad_option()),
    }
}

/// Phase 2: render a 0-indexed page to a 4-channel bitmap.
/// Returns `{:ok, {data, width, height, stride, format}}`. The page is fetched,
/// rendered, and dropped within the call (never stored).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_render_page<'a>(
    env: Env<'a>,
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
    opts: Term<'a>,
) -> Result<(Binary<'a>, u32, u32, u32, Atom), Atom> {
    let render = RenderOpts::from_term(opts)?;
    let index: u16 = page_index
        .try_into()
        .map_err(|_| atoms::page_out_of_bounds())?;

    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;

        let page = document
            .pages()
            .get(index)
            .map_err(|_| atoms::page_out_of_bounds())?;

        let bitmap = page
            .render_with_config(&render.to_config())
            .map_err(|_| atoms::render_failed())?;

        let width = u32::try_from(bitmap.width()).unwrap_or(0);
        let height = u32::try_from(bitmap.height()).unwrap_or(0);
        let bytes = bitmap.as_raw_bytes();
        // Derive stride from the actual buffer rather than assuming width*4 —
        // pdfium can pad rows for some formats. (Ours is 4-channel, so this is
        // width*4 in practice, but we don't bake that assumption in.)
        let stride = if height == 0 {
            0
        } else {
            (bytes.len() / height as usize) as u32
        };

        let mut binary = OwnedBinary::new(bytes.len()).ok_or_else(atoms::alloc_failed)?;
        binary.as_mut_slice().copy_from_slice(&bytes);

        Ok((
            binary.release(env),
            width,
            height,
            stride,
            render.format_atom(),
        ))
    })
}

rustler::init!("Elixir.ExPdfium.Native");
