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
        // text + search
        text_failed,
        empty_query,
        search_failed,
        // metadata keys
        title,
        author,
        subject,
        keywords,
        creator,
        producer,
        creation_date,
        modification_date,
        // permission keys
        print_high_quality,
        print_low_quality,
        assemble,
        modify_content,
        extract_text_and_graphics,
        fill_form_fields,
        create_form_fields,
        annotate,
        // structure & navigation
        attachment_not_found,
        attachment_failed,
        // forms: form technology (FPDF_GetFormType)
        none,
        acrobat,
        xfa_full,
        xfa_foreground,
        // form field types
        text,
        checkbox,
        radio_button,
        combo_box,
        list_box,
        push_button,
        signature,
        unknown,
        // annotation types (PDF /Subtype)
        link,
        free_text,
        line,
        square,
        circle,
        polygon,
        polyline,
        highlight,
        underline,
        squiggly,
        strikeout,
        stamp,
        caret,
        ink,
        popup,
        file_attachment,
        sound,
        movie,
        widget,
        screen,
        printer_mark,
        trap_net,
        watermark,
        three_d,
        rich_media,
        xfa_widget,
        redacted,
        // write: page assembly & save
        same_document,
        empty_selection,
        cannot_delete_all_pages,
        bad_rotation,
        save_failed,
        create_failed,
        copy_failed,
        append_failed,
        delete_failed,
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

// ── Text & search ────────────────────────────────────────────────────────────

// (left, bottom, right, top) in PDF points; origin is the page's bottom-left.
type Rect = (f64, f64, f64, f64);

fn rect_of(b: &PdfRect) -> Rect {
    (
        b.left().value as f64,
        b.bottom().value as f64,
        b.right().value as f64,
        b.top().value as f64,
    )
}

fn page_index_u16(page_index: u32) -> Result<u16, Atom> {
    page_index
        .try_into()
        .map_err(|_| atoms::page_out_of_bounds())
}

/// Phase 3: plain text of one page.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_extract_text(
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
) -> Result<String, Atom> {
    let index = page_index_u16(page_index)?;
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let page = document
            .pages()
            .get(index)
            .map_err(|_| atoms::page_out_of_bounds())?;
        let text = page.text().map_err(|_| atoms::text_failed())?;
        Ok(text.all())
    })
}

/// Phase 3: plain text of the whole document (pages joined by a form feed).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_extract_text_all(doc: ResourceArc<DocumentResource>) -> Result<String, Atom> {
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let mut out = String::new();
        for (i, page) in document.pages().iter().enumerate() {
            if i > 0 {
                out.push('\u{0c}'); // form feed between pages
            }
            let text = page.text().map_err(|_| atoms::text_failed())?;
            out.push_str(&text.all());
        }
        Ok(out)
    })
}

/// Phase 3: text runs with per-segment bounds.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_text_segments(
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
) -> Result<Vec<(String, Rect)>, Atom> {
    let index = page_index_u16(page_index)?;
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let page = document
            .pages()
            .get(index)
            .map_err(|_| atoms::page_out_of_bounds())?;
        let text = page.text().map_err(|_| atoms::text_failed())?;
        let segments = text
            .segments()
            .iter()
            .map(|seg| (seg.text(), rect_of(&seg.bounds())))
            .collect();
        Ok(segments)
    })
}

/// Phase 3: search a page. Each match carries its text and the bounding rects of
/// the segments it spans (a match can wrap across lines).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_search_text(
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
    query: String,
    match_case: bool,
    whole_word: bool,
) -> Result<Vec<(String, Vec<Rect>)>, Atom> {
    let index = page_index_u16(page_index)?;
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let page = document
            .pages()
            .get(index)
            .map_err(|_| atoms::page_out_of_bounds())?;
        let text = page.text().map_err(|_| atoms::text_failed())?;

        let options = PdfSearchOptions::new()
            .match_case(match_case)
            .match_whole_word(whole_word);
        let search = text.search(&query, &options).map_err(|e| match e {
            PdfiumError::TextSearchTargetIsEmpty => atoms::empty_query(),
            _ => atoms::search_failed(),
        })?;

        let matches = search
            .iter(PdfSearchDirection::SearchForward)
            .map(|segments| {
                let mut matched = String::new();
                let mut rects = Vec::new();
                for seg in segments.iter() {
                    matched.push_str(&seg.text());
                    rects.push(rect_of(&seg.bounds()));
                }
                (matched, rects)
            })
            .collect();
        Ok(matches)
    })
}

// ── Metadata, geometry & permissions ─────────────────────────────────────────

/// Phase 4: document info dictionary. Returns only the tags that are present, as
/// `(key, value)` pairs; the Elixir side fills absent keys with nil.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_metadata(doc: ResourceArc<DocumentResource>) -> Result<Vec<(Atom, String)>, Atom> {
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let md = document.metadata();

        let mut pairs = Vec::new();
        for (key, tag) in [
            (atoms::title(), PdfDocumentMetadataTagType::Title),
            (atoms::author(), PdfDocumentMetadataTagType::Author),
            (atoms::subject(), PdfDocumentMetadataTagType::Subject),
            (atoms::keywords(), PdfDocumentMetadataTagType::Keywords),
            (atoms::creator(), PdfDocumentMetadataTagType::Creator),
            (atoms::producer(), PdfDocumentMetadataTagType::Producer),
            (
                atoms::creation_date(),
                PdfDocumentMetadataTagType::CreationDate,
            ),
            (
                atoms::modification_date(),
                PdfDocumentMetadataTagType::ModificationDate,
            ),
        ] {
            if let Some(t) = md.get(tag) {
                pairs.push((key, t.value().to_string()));
            }
        }
        Ok(pairs)
    })
}

// (media, crop, bleed, trim, art) — each nil if the box is undefined.
type PageBoxes = (
    Option<Rect>,
    Option<Rect>,
    Option<Rect>,
    Option<Rect>,
    Option<Rect>,
);

/// Phase 4: page size (points), rotation (degrees), label, and boundary boxes.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_page_info(
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
) -> Result<(f64, f64, i64, Option<String>, PageBoxes), Atom> {
    let index = page_index_u16(page_index)?;
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let page = document
            .pages()
            .get(index)
            .map_err(|_| atoms::page_out_of_bounds())?;

        let width = page.width().value as f64;
        let height = page.height().value as f64;
        let rotation = match page.rotation() {
            Ok(PdfPageRenderRotation::Degrees90) => 90,
            Ok(PdfPageRenderRotation::Degrees180) => 180,
            Ok(PdfPageRenderRotation::Degrees270) => 270,
            _ => 0,
        };
        let label = page.label().map(|s| s.to_string());

        let b = page.boundaries();
        let boxes = (
            b.media().ok().map(|x| rect_of(&x.bounds)),
            b.crop().ok().map(|x| rect_of(&x.bounds)),
            b.bleed().ok().map(|x| rect_of(&x.bounds)),
            b.trim().ok().map(|x| rect_of(&x.bounds)),
            b.art().ok().map(|x| rect_of(&x.bounds)),
        );

        Ok((width, height, rotation, label, boxes))
    })
}

/// Phase 4: document permissions, as `(key, bool)` pairs. An undeterminable
/// permission (unknown security handler) is reported as `false`.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_permissions(doc: ResourceArc<DocumentResource>) -> Result<Vec<(Atom, bool)>, Atom> {
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let p = document.permissions();

        // pdfium-render can only read permissions for security-handler revisions
        // 2-4; revision 5/6 (AES-256 / PDF 2.0) makes every `can_*` return Err.
        // Probe once and surface that rather than reporting a misleading all-false
        // set from a security-relevant API. (All `can_*` share this check, so on
        // success the `unwrap_or(false)` below can't actually error.)
        let print_high_quality = p
            .can_print_high_quality()
            .map_err(|_| atoms::unsupported_security())?;
        Ok(vec![
            (atoms::print_high_quality(), print_high_quality),
            (
                atoms::print_low_quality(),
                p.can_print_only_low_quality().unwrap_or(false),
            ),
            (
                atoms::assemble(),
                p.can_assemble_document().unwrap_or(false),
            ),
            (
                atoms::modify_content(),
                p.can_modify_document_content().unwrap_or(false),
            ),
            (
                atoms::extract_text_and_graphics(),
                p.can_extract_text_and_graphics().unwrap_or(false),
            ),
            (
                atoms::fill_form_fields(),
                p.can_fill_existing_interactive_form_fields()
                    .unwrap_or(false),
            ),
            (
                atoms::create_form_fields(),
                p.can_create_new_interactive_form_fields().unwrap_or(false),
            ),
            (
                atoms::annotate(),
                p.can_add_or_modify_text_annotations().unwrap_or(false),
            ),
        ])
    })
}

// ── Structure & navigation ───────────────────────────────────────────────────

// A bookmark/outline node. NifMap encodes it as %{title:, page:, children:}.
#[derive(rustler::NifMap)]
struct Bookmark {
    title: String,
    page: Option<u32>,
    children: Vec<Bookmark>,
}

// Bound the outline walk so a malicious/cyclic bookmark graph can't blow the
// stack or memory (pdfium-render's own iterator guards against cycles too).
const MAX_OUTLINE_DEPTH: usize = 64;
const MAX_OUTLINE_NODES: usize = 50_000;

fn build_bookmark(bookmark: &PdfBookmark, depth: usize, budget: &mut usize) -> Bookmark {
    let title = bookmark.title().unwrap_or_default();
    let page = bookmark
        .destination()
        .and_then(|d| d.page_index().ok())
        .map(u32::from);

    let mut children = Vec::new();
    if depth < MAX_OUTLINE_DEPTH {
        let mut child = bookmark.first_child();
        while let Some(node) = child {
            if *budget == 0 {
                break;
            }
            *budget -= 1;
            children.push(build_bookmark(&node, depth + 1, budget));
            child = node.next_sibling();
        }
    }

    Bookmark {
        title,
        page,
        children,
    }
}

/// Phase 5: the document outline (bookmarks) as a nested tree.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_outline(doc: ResourceArc<DocumentResource>) -> Result<Vec<Bookmark>, Atom> {
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;

        let mut budget = MAX_OUTLINE_NODES;
        let mut top = Vec::new();
        let mut node = document.bookmarks().root();
        while let Some(bookmark) = node {
            if budget == 0 {
                break;
            }
            budget -= 1;
            top.push(build_bookmark(&bookmark, 0, &mut budget));
            node = bookmark.next_sibling();
        }
        Ok(top)
    })
}

// (bounds, uri, page): `uri` for a web link, `page` for an internal destination.
type Link = (Option<Rect>, Option<String>, Option<u32>);

/// Phase 5: links on a page. `uri` for a web link, `page` for an internal
/// destination (0-indexed); both may be nil.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_links(doc: ResourceArc<DocumentResource>, page_index: u32) -> Result<Vec<Link>, Atom> {
    let index = page_index_u16(page_index)?;
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let page = document
            .pages()
            .get(index)
            .map_err(|_| atoms::page_out_of_bounds())?;

        let links = page
            .links()
            .iter()
            .map(|link| {
                let bounds = link.rect().ok().map(|r| rect_of(&r));
                let uri = link
                    .action()
                    .and_then(|a| a.as_uri_action().and_then(|u| u.uri().ok()));
                let dest_page = link
                    .destination()
                    .and_then(|d| d.page_index().ok())
                    .map(u32::from);
                (bounds, uri, dest_page)
            })
            .collect();
        Ok(links)
    })
}

/// Phase 5: list embedded files as `(name, size)` pairs.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_attachments(doc: ResourceArc<DocumentResource>) -> Result<Vec<(String, u32)>, Atom> {
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let list = document
            .attachments()
            .iter()
            .map(|a| (a.name(), a.len() as u32))
            .collect();
        Ok(list)
    })
}

/// Phase 5: extract one embedded file's bytes.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_attachment_data<'a>(
    env: Env<'a>,
    doc: ResourceArc<DocumentResource>,
    index: u32,
) -> Result<Binary<'a>, Atom> {
    let index: u16 = index
        .try_into()
        .map_err(|_| atoms::attachment_not_found())?;
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let attachment = document
            .attachments()
            .get(index)
            .map_err(|_| atoms::attachment_not_found())?;
        let bytes = attachment
            .save_to_bytes()
            .map_err(|_| atoms::attachment_failed())?;

        let mut binary = OwnedBinary::new(bytes.len()).ok_or_else(atoms::alloc_failed)?;
        binary.as_mut_slice().copy_from_slice(&bytes);
        Ok(binary.release(env))
    })
}

// ── Forms & annotations (read) ───────────────────────────────────────────────

fn form_type_atom(t: PdfFormType) -> Atom {
    match t {
        PdfFormType::None => atoms::none(),
        PdfFormType::Acrobat => atoms::acrobat(),
        PdfFormType::XfaFull => atoms::xfa_full(),
        PdfFormType::XfaForeground => atoms::xfa_foreground(),
    }
}

fn form_field_type_atom(t: PdfFormFieldType) -> Atom {
    match t {
        PdfFormFieldType::Text => atoms::text(),
        PdfFormFieldType::Checkbox => atoms::checkbox(),
        PdfFormFieldType::RadioButton => atoms::radio_button(),
        PdfFormFieldType::ComboBox => atoms::combo_box(),
        PdfFormFieldType::ListBox => atoms::list_box(),
        PdfFormFieldType::PushButton => atoms::push_button(),
        PdfFormFieldType::Signature => atoms::signature(),
        PdfFormFieldType::Unknown => atoms::unknown(),
    }
}

fn annotation_type_atom(t: PdfPageAnnotationType) -> Atom {
    match t {
        PdfPageAnnotationType::Text => atoms::text(),
        PdfPageAnnotationType::Link => atoms::link(),
        PdfPageAnnotationType::FreeText => atoms::free_text(),
        PdfPageAnnotationType::Line => atoms::line(),
        PdfPageAnnotationType::Square => atoms::square(),
        PdfPageAnnotationType::Circle => atoms::circle(),
        PdfPageAnnotationType::Polygon => atoms::polygon(),
        PdfPageAnnotationType::Polyline => atoms::polyline(),
        PdfPageAnnotationType::Highlight => atoms::highlight(),
        PdfPageAnnotationType::Underline => atoms::underline(),
        PdfPageAnnotationType::Squiggly => atoms::squiggly(),
        PdfPageAnnotationType::Strikeout => atoms::strikeout(),
        PdfPageAnnotationType::Stamp => atoms::stamp(),
        PdfPageAnnotationType::Caret => atoms::caret(),
        PdfPageAnnotationType::Ink => atoms::ink(),
        PdfPageAnnotationType::Popup => atoms::popup(),
        PdfPageAnnotationType::FileAttachment => atoms::file_attachment(),
        PdfPageAnnotationType::Sound => atoms::sound(),
        PdfPageAnnotationType::Movie => atoms::movie(),
        PdfPageAnnotationType::Widget => atoms::widget(),
        PdfPageAnnotationType::Screen => atoms::screen(),
        PdfPageAnnotationType::PrinterMark => atoms::printer_mark(),
        PdfPageAnnotationType::TrapNet => atoms::trap_net(),
        PdfPageAnnotationType::Watermark => atoms::watermark(),
        PdfPageAnnotationType::ThreeD => atoms::three_d(),
        PdfPageAnnotationType::RichMedia => atoms::rich_media(),
        PdfPageAnnotationType::XfaWidget => atoms::xfa_widget(),
        PdfPageAnnotationType::Redacted => atoms::redacted(),
        PdfPageAnnotationType::Unknown => atoms::unknown(),
    }
}

/// Phase 6: which interactive-form technology the document uses
/// (`:none` | `:acrobat` | `:xfa_full` | `:xfa_foreground`). pdfium-render only
/// surfaces a form (and its type) when one is present and non-empty, so an
/// absent or empty form reports `:none`.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_form_type(doc: ResourceArc<DocumentResource>) -> Result<Atom, Atom> {
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let t = match document.form() {
            Some(form) => form_type_atom(form.form_type()),
            None => atoms::none(),
        };
        Ok(t)
    })
}

// (type, bounds, contents, name, hidden, printed). `type` is the PDF /Subtype;
// `name` is the annotation's own /NM, not a form field name.
type Annotation = (
    Atom,
    Option<Rect>,
    Option<String>,
    Option<String>,
    bool,
    bool,
);

/// Phase 6: annotations on a 0-indexed page, in page order. Widget annotations
/// (form fields) are included alongside markup annotations.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_annotations(
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
) -> Result<Vec<Annotation>, Atom> {
    let index = page_index_u16(page_index)?;
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let page = document
            .pages()
            .get(index)
            .map_err(|_| atoms::page_out_of_bounds())?;
        let annotations = page
            .annotations()
            .iter()
            .map(|a| {
                (
                    annotation_type_atom(a.annotation_type()),
                    a.bounds().ok().map(|r| rect_of(&r)),
                    a.contents(),
                    a.name(),
                    a.is_hidden(),
                    a.is_printed(),
                )
            })
            .collect();
        Ok(annotations)
    })
}

// (name, type, value, checked, read_only, required, (page, bounds)). The page +
// bounds are nested to stay within rustler's 7-element tuple limit.
type FormField = (
    Option<String>,
    Atom,
    Option<String>,
    Option<bool>,
    bool,
    bool,
    (u32, Option<Rect>),
);

// Read a field's value the way pdfium-render models each type: text/combo/list
// expose a string value; checkbox/radio expose an on-state name plus a checked
// flag. We surface both rather than coercing a checkbox down to a string.
// Push-button/signature/unknown carry no readable value.
//
// `is_checked()` can Err for a checkbox/radio whose state pdfium can't resolve;
// we deliberately treat that as `false` (an unreadable toggle is reported as
// not-checked rather than failing the whole field listing). `group_value()` for
// these is the group's *selected* on-state, identical across the group's option
// widgets — the per-option export name is not exposed by pdfium-render.
fn form_field_value(
    field: &PdfFormField,
    field_type: PdfFormFieldType,
) -> (Option<String>, Option<bool>) {
    match field_type {
        PdfFormFieldType::Text => (field.as_text_field().and_then(|f| f.value()), None),
        PdfFormFieldType::ComboBox => (field.as_combo_box_field().and_then(|f| f.value()), None),
        PdfFormFieldType::ListBox => (field.as_list_box_field().and_then(|f| f.value()), None),
        PdfFormFieldType::Checkbox => match field.as_checkbox_field() {
            Some(f) => (f.group_value(), Some(f.is_checked().unwrap_or(false))),
            None => (None, None),
        },
        PdfFormFieldType::RadioButton => match field.as_radio_button_field() {
            Some(f) => (f.group_value(), Some(f.is_checked().unwrap_or(false))),
            None => (None, None),
        },
        PdfFormFieldType::PushButton | PdfFormFieldType::Signature | PdfFormFieldType::Unknown => {
            (None, None)
        }
    }
}

/// Phase 6: AcroForm fields, one entry per widget annotation, across all pages.
/// A checkbox or radio group shares its name across its option widgets, so it
/// surfaces as one entry per option (distinguished by `value` / `checked`).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_form_fields(doc: ResourceArc<DocumentResource>) -> Result<Vec<FormField>, Atom> {
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;

        let mut fields = Vec::new();
        for (page_index, page) in document.pages().iter().enumerate() {
            let page_index = u32::try_from(page_index).unwrap_or(0);
            for annotation in page.annotations().iter() {
                let Some(field) = annotation.as_form_field() else {
                    continue;
                };
                let field_type = field.field_type();
                let (value, checked) = form_field_value(field, field_type);
                let bounds = annotation.bounds().ok().map(|r| rect_of(&r));
                fields.push((
                    field.name(),
                    form_field_type_atom(field_type),
                    value,
                    checked,
                    field.is_read_only(),
                    field.is_required(),
                    (page_index, bounds),
                ));
            }
        }
        Ok(fields)
    })
}

// ── Writing: page assembly & save (v0.3) ─────────────────────────────────────
//
// Write NIFs serialize through `PDFIUM_LOCK` exactly like the read NIFs. Where a
// pdfium-render mutator needs `&mut PdfDocument` (e.g. `pages_mut().append`) we
// take `.as_mut()` on the `Mutex<Option<…>>` guard; the others mutate through an
// owned `PdfPage` / document FFI handle and so only need `.as_ref()`. The lock
// already serializes every pdfium op, so a write can't race a render or another
// write — they queue (last-write-wins).

/// v0.3: serialize the (possibly edited) document to PDF bytes. A full save
/// (`FPDF_SaveAsCopy`); it does not close or alter the document.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_save(env: Env<'_>, doc: ResourceArc<DocumentResource>) -> Result<Binary<'_>, Atom> {
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let bytes = document.save_to_bytes().map_err(|_| atoms::save_failed())?;

        let mut binary = OwnedBinary::new(bytes.len()).ok_or_else(atoms::alloc_failed)?;
        binary.as_mut_slice().copy_from_slice(&bytes);
        Ok(binary.release(env))
    })
}

/// v0.3: copy all of `src`'s pages onto the end of `dest` (merge).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_append(
    dest: ResourceArc<DocumentResource>,
    src: ResourceArc<DocumentResource>,
) -> Result<Atom, Atom> {
    // Appending a document to itself would lock one per-doc mutex twice (std
    // Mutex is non-reentrant → self-deadlock) and can't borrow `&mut` + `&` of one
    // document. Reject up front. (Two *distinct* docs can't deadlock here: holding
    // PDFIUM_LOCK means no other thread holds any per-doc mutex.)
    if std::ptr::eq(&*dest, &*src) {
        return Err(atoms::same_document());
    }
    with_pdfium(|_| {
        let mut dest_guard = dest.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let src_guard = src.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let dest_doc = dest_guard.as_mut().ok_or_else(atoms::document_closed)?;
        let src_doc = src_guard.as_ref().ok_or_else(atoms::document_closed)?;
        dest_doc
            .pages_mut()
            .append(src_doc)
            .map_err(|_| atoms::append_failed())?;
        Ok(atoms::ok())
    })
}

/// v0.3: build a NEW document from the given 0-indexed pages of `src`, in the
/// given order (duplicates allowed). All indices are validated before any copy,
/// so a bad index leaves no half-built document.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_extract_pages(
    src: ResourceArc<DocumentResource>,
    indices: Vec<u32>,
) -> Result<ResourceArc<DocumentResource>, Atom> {
    if indices.is_empty() {
        return Err(atoms::empty_selection());
    }
    with_pdfium(|pdfium| {
        let src_guard = src.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let src_doc = src_guard.as_ref().ok_or_else(atoms::document_closed)?;
        let count = u32::from(src_doc.pages().len());
        for &i in &indices {
            if i >= count {
                return Err(atoms::page_out_of_bounds());
            }
        }

        let mut new_doc = pdfium
            .create_new_pdf()
            .map_err(|_| atoms::create_failed())?;
        for (dest_idx, &src_idx) in indices.iter().enumerate() {
            let src_i = u16::try_from(src_idx).map_err(|_| atoms::page_out_of_bounds())?;
            let dest_i = u16::try_from(dest_idx).map_err(|_| atoms::page_out_of_bounds())?;
            new_doc
                .pages_mut()
                .copy_page_from_document(src_doc, src_i, dest_i)
                .map_err(|_| atoms::copy_failed())?;
        }

        Ok(ResourceArc::new(DocumentResource {
            doc: Mutex::new(Some(new_doc)),
        }))
    })
}

/// v0.3: delete the inclusive 0-indexed page range `[from, to]`.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_delete_pages(
    doc: ResourceArc<DocumentResource>,
    from: u32,
    to: u32,
) -> Result<Atom, Atom> {
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let count = u32::from(document.pages().len());
        if from > to || to >= count {
            return Err(atoms::page_out_of_bounds());
        }
        // Refuse to leave a zero-page document (symmetric with extract_pages'
        // empty-selection guard; a 0-page PDF is degenerate and reader-dependent).
        if to - from + 1 >= count {
            return Err(atoms::cannot_delete_all_pages());
        }
        // Delete from the highest index down so the lower indices we still need
        // stay valid as pages are removed. (`PdfPage::delete` is the non-
        // deprecated path; the `PdfPages` range delete is deprecated.)
        for i in (from..=to).rev() {
            let idx = u16::try_from(i).map_err(|_| atoms::page_out_of_bounds())?;
            let page = document
                .pages()
                .get(idx)
                .map_err(|_| atoms::page_out_of_bounds())?;
            page.delete().map_err(|_| atoms::delete_failed())?;
        }
        Ok(atoms::ok())
    })
}

/// v0.3: set a page's absolute rotation. `degrees` must be 0, 90, 180, or 270.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_rotate_page(
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
    degrees: u32,
) -> Result<Atom, Atom> {
    let rotation = match degrees {
        0 => PdfPageRenderRotation::None,
        90 => PdfPageRenderRotation::Degrees90,
        180 => PdfPageRenderRotation::Degrees180,
        270 => PdfPageRenderRotation::Degrees270,
        _ => return Err(atoms::bad_rotation()),
    };
    let index = page_index_u16(page_index)?;
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let mut page = document
            .pages()
            .get(index)
            .map_err(|_| atoms::page_out_of_bounds())?;
        // Rotation is page-dictionary metadata set directly on the page object,
        // so it persists in the document (and a later save) without content
        // regeneration.
        page.set_rotation(rotation);
        Ok(atoms::ok())
    })
}

rustler::init!("Elixir.ExPdfium.Native");
