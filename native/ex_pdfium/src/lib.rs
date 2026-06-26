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
        grayscale,
        annotations,
        form_fields,
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
        // document-level properties: page mode (:none reuses the existing atom)
        outline,
        thumbnails,
        fullscreen,
        optional_content,
        attachments,
        unset,
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
        attachment_too_large,
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
        // image & object extraction: object types (:text/:path reuse existing atoms)
        image,
        shading,
        form,
        unsupported,
        // image bitmap formats (:bgra/:rgba reuse existing atoms)
        gray,
        bgr,
        bgrx,
        // image extraction errors
        not_an_image,
        object_not_found,
        image_failed,
        image_too_large,
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
        // document creation
        unknown_font,
        bad_image_data,
        unsupported_image_format,
        draw_failed,
        // annotation authoring
        annotate_failed,
        annotation_not_found,
        // flatten
        flatten_failed,
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
    // Bind/initialize pdfium under the global lock like every other pdfium touch,
    // so the one-time `FPDF_InitLibrary` can't race a concurrent first call.
    let _lock = pdfium_lock();
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

// Upper bounds so a caller can't drive pdfium into an absurd (or integer-
// overflowing) bitmap allocation inside the BEAM. Generous: 30k px covers any
// real render; 3000 DPI / 100x scale are far beyond practical use.
const MAX_RENDER_DIMENSION: i32 = 30_000;
const MAX_RENDER_DPI: f64 = 3_000.0;
const MAX_RENDER_SCALE: f64 = 100.0;

// Cap the pixel count of any bitmap pdfium allocates in-process — a render output,
// a decoded image (image_data/3) — so a hostile page (huge MediaBox) or malformed
// image XObject can't drive a multi-GB allocation. 100 MP RGBA is ~400 MB.
const MAX_BITMAP_PIXELS: i64 = 100_000_000;

// Cap a decoded embedded-file size (attachment_data/2). Embedded files are stored
// compressed, so a small PDF can decode to a far larger file (a "zip bomb"); bound
// the absolute decoded size while still allowing genuinely large attachments.
const MAX_ATTACHMENT_BYTES: usize = 100_000_000;

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

    // Reject absurd/overflowing sizes (also catches non-finite via the `<=`,
    // which is false for NaN/inf). Combined with `is_positive`, this bounds every
    // value reaching pdfium.
    fn is_within_limits(&self) -> bool {
        match self {
            Sizing::Dpi(d) => *d <= MAX_RENDER_DPI,
            Sizing::Scale(s) => *s <= MAX_RENDER_SCALE,
            Sizing::Size { width, height } => {
                width.is_none_or(|w| w <= MAX_RENDER_DIMENSION)
                    && height.is_none_or(|h| h <= MAX_RENDER_DIMENSION)
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
    grayscale: bool,
    annotations: bool,
    form_fields: bool,
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
        if !sizing.is_positive() || !sizing.is_within_limits() {
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

        // Toggles. pdfium renders annotations and form data by default, so those
        // default to true; grayscale defaults to false.
        let grayscale = opt_bool(opts, atoms::grayscale())?.unwrap_or(false);
        let annotations = opt_bool(opts, atoms::annotations())?.unwrap_or(true);
        let form_fields = opt_bool(opts, atoms::form_fields())?.unwrap_or(true);

        Ok(RenderOpts {
            sizing,
            format,
            background,
            grayscale,
            annotations,
            form_fields,
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

        // Cap the FINAL bitmap dimensions too: requested sizing is bounded above,
        // but pdfium otherwise derives the output size from the page's MediaBox /
        // aspect ratio, so a hostile page (e.g. a 40000x40000 MediaBox) could still
        // drive a huge allocation. set_maximum_* scales the output down to fit.
        config
            .use_grayscale_rendering(self.grayscale)
            .render_annotations(self.annotations)
            .render_form_data(self.form_fields)
            .set_maximum_width(MAX_RENDER_DIMENSION)
            .set_maximum_height(MAX_RENDER_DIMENSION)
    }

    fn format_atom(&self) -> Atom {
        match self.format {
            Format::Rgba => atoms::rgba(),
            Format::Bgra => atoms::bgra(),
        }
    }

    // Estimate the output bitmap's pixel area for a page of the given size (in
    // points), so we can reject an oversized render BEFORE pdfium allocates the
    // bitmap (a hostile MediaBox or aspect ratio can otherwise derive a huge size,
    // which on an overcommit system could OOM the whole VM). Mirrors `to_config`'s
    // sizing; `set_maximum_*` there is a backstop for any estimation error.
    fn estimated_pixels(&self, page_w: f64, page_h: f64) -> f64 {
        let (w, h) = match &self.sizing {
            Sizing::Dpi(d) => (page_w * d / 72.0, page_h * d / 72.0),
            Sizing::Scale(s) => (page_w * s, page_h * s),
            Sizing::Size {
                width: Some(w),
                height: Some(h),
            } => (f64::from(*w), f64::from(*h)),
            Sizing::Size {
                width: Some(w),
                height: None,
            } => {
                let ratio = if page_w > 0.0 { page_h / page_w } else { 1.0 };
                (f64::from(*w), f64::from(*w) * ratio)
            }
            Sizing::Size {
                width: None,
                height: Some(h),
            } => {
                let ratio = if page_h > 0.0 { page_w / page_h } else { 1.0 };
                (f64::from(*h) * ratio, f64::from(*h))
            }
            Sizing::Size {
                width: None,
                height: None,
            } => (page_w, page_h),
        };
        w.max(0.0) * h.max(0.0)
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

fn opt_bool(opts: Term, key: Atom) -> Result<Option<bool>, Atom> {
    match opts.map_get(key) {
        Err(_) => Ok(None),
        Ok(t) => t
            .decode::<bool>()
            .map(Some)
            .map_err(|_| atoms::bad_option()),
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

        // Reject an oversized render before pdfium allocates the bitmap, so a
        // hostile page size can't drive a multi-GB allocation in-process.
        if render.estimated_pixels(page.width().value as f64, page.height().value as f64)
            > MAX_BITMAP_PIXELS as f64
        {
            return Err(atoms::render_failed());
        }

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

// Best-effort font style for one glyph: (font_name, weight, bold?, italic?,
// serif?, fixed_pitch?). Weight is the numeric font weight (None when pdfium
// reports none). The booleans derive from the PDF FontDescriptor /Flags, which
// pdfium itself documents as unreliable for non-embedded (built-in) fonts — so
// `font_name` is the most trustworthy signal here.
type CharStyle = (String, Option<u32>, bool, bool, bool, bool);

// (char, bounds, font_size, origin, style): one entry per glyph in content-stream
// order. `bounds` is the loose (advance-cell) box, or None when pdfium reports
// none; `font_size` is the scaled font size in points; `origin` is the glyph's
// pen position `(x, y)` where `y` is the text baseline; `style` is present only
// when style extraction was requested (it costs several extra FFI calls/glyph).
type TextChar = (
    String,
    Option<Rect>,
    f32,
    Option<(f64, f64)>,
    Option<CharStyle>,
);

// Map pdfium-render's PdfFontWeight enum to its numeric weight (100..=900, or the
// raw value for out-of-range weights). pdfium-render exposes no numeric accessor.
fn weight_value(w: Option<pdfium_render::prelude::PdfFontWeight>) -> Option<u32> {
    use pdfium_render::prelude::PdfFontWeight::*;
    w.map(|w| match w {
        Weight100 => 100,
        Weight200 => 200,
        Weight300 => 300,
        Weight400Normal => 400,
        Weight500 => 500,
        Weight600 => 600,
        Weight700Bold => 700,
        Weight800 => 800,
        Weight900 => 900,
        Custom(n) => n,
    })
}

/// Char-level text extraction: every glyph on a page, in content-stream order.
/// When `with_style` is true each glyph also carries best-effort font style; this
/// adds several `FPDFText_GetFontInfo`/weight FFI calls per glyph, so it is opt-in.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_text_chars(
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
    with_style: bool,
) -> Result<Vec<TextChar>, Atom> {
    let index = page_index_u16(page_index)?;
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let page = document
            .pages()
            .get(index)
            .map_err(|_| atoms::page_out_of_bounds())?;
        let text = page.text().map_err(|_| atoms::text_failed())?;
        let chars = text
            .chars()
            .iter()
            .map(|ch| {
                let s = ch.unicode_char().map(|c| c.to_string()).unwrap_or_default();
                // loose_bounds = the glyph advance cell (stable per-line height,
                // closest to pdfminer's LTChar bbox); fall back to tight if loose errors.
                let bounds = ch
                    .loose_bounds()
                    .or_else(|_| ch.tight_bounds())
                    .ok()
                    .map(|r| rect_of(&r));
                // The pen origin: x is the start of the advance cell, y is the text
                // baseline — the canonical anchor for clustering glyphs into lines.
                let origin = ch
                    .origin()
                    .ok()
                    .map(|(x, y)| (x.value as f64, y.value as f64));
                let style = if with_style {
                    let weight = weight_value(ch.font_weight());
                    let bold = weight.is_some_and(|w| w >= 700) || ch.font_is_bold_reenforced();
                    Some((
                        ch.font_name(),
                        weight,
                        bold,
                        ch.font_is_italic(),
                        ch.font_is_serif(),
                        ch.font_is_fixed_pitch(),
                    ))
                } else {
                    None
                };
                (s, bounds, ch.scaled_font_size().value, origin, style)
            })
            .collect();
        Ok(chars)
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

// PDF version string ("1.7", "2.0"), or None if the file declares none.
fn version_string(v: PdfDocumentVersion) -> Option<String> {
    let s = match v {
        PdfDocumentVersion::Pdf1_0 => "1.0",
        PdfDocumentVersion::Pdf1_1 => "1.1",
        PdfDocumentVersion::Pdf1_2 => "1.2",
        PdfDocumentVersion::Pdf1_3 => "1.3",
        PdfDocumentVersion::Pdf1_4 => "1.4",
        PdfDocumentVersion::Pdf1_5 => "1.5",
        PdfDocumentVersion::Pdf1_6 => "1.6",
        PdfDocumentVersion::Pdf1_7 => "1.7",
        PdfDocumentVersion::Pdf2_0 => "2.0",
        // A two-digit raw version pdfium-render doesn't have a named variant for
        // (e.g. 21 -> "2.1"); format it so future versions still come through.
        PdfDocumentVersion::Other(v) if v > 0 => return Some(format!("{}.{}", v / 10, v % 10)),
        PdfDocumentVersion::Other(_) | PdfDocumentVersion::Unset => return None,
    };
    Some(s.to_string())
}

// How the document asks viewers to present it on open (the catalog /PageMode).
fn page_mode_atom(m: PdfPageMode) -> Atom {
    match m {
        PdfPageMode::None => atoms::none(),
        PdfPageMode::ShowDocumentOutline => atoms::outline(),
        PdfPageMode::ShowPageThumbnails => atoms::thumbnails(),
        PdfPageMode::Fullscreen => atoms::fullscreen(),
        PdfPageMode::ShowContentGroupPanel => atoms::optional_content(),
        PdfPageMode::ShowAttachmentsPanel => atoms::attachments(),
        PdfPageMode::UnsetOrUnknown => atoms::unset(),
    }
}

// (info-dict pairs, version, page_count, page_mode). The info pairs hold only the
// /Info tags that are present (Elixir fills absent ones with nil); version /
// page_count / page_mode are always-present document-level properties.
type DocumentMetadata = (Vec<(Atom, String)>, Option<String>, u32, Atom);

/// Phase 4 (+ comprehensive doc properties): the /Info dictionary plus the PDF
/// version, page count, and page mode.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_metadata(doc: ResourceArc<DocumentResource>) -> Result<DocumentMetadata, Atom> {
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

        let version = version_string(document.version());
        let page_count = u32::from(document.pages().len());
        let page_mode = page_mode_atom(document.pages().page_mode());
        Ok((pairs, version, page_count, page_mode))
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
        // `len()` reads the decoded size via a null-buffer call WITHOUT allocating;
        // reject an oversized (or maliciously compressed) embedded file before
        // `save_to_bytes` decodes it into memory.
        if attachment.len() > MAX_ATTACHMENT_BYTES {
            return Err(atoms::attachment_too_large());
        }
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

// ── Image & object extraction ────────────────────────────────────────────────

fn object_type_atom(t: PdfPageObjectType) -> Atom {
    match t {
        PdfPageObjectType::Text => atoms::text(),
        PdfPageObjectType::Path => atoms::path(),
        PdfPageObjectType::Image => atoms::image(),
        PdfPageObjectType::Shading => atoms::shading(),
        PdfPageObjectType::XObjectForm => atoms::form(),
        PdfPageObjectType::Unsupported => atoms::unsupported(),
    }
}

fn bitmap_format_atom(f: PdfBitmapFormat) -> Atom {
    match f {
        PdfBitmapFormat::Gray => atoms::gray(),
        PdfBitmapFormat::BGR => atoms::bgr(),
        PdfBitmapFormat::BGRx => atoms::bgrx(),
        PdfBitmapFormat::BGRA => atoms::bgra(),
        // pdfium only returns the four formats above; the remaining variant is a
        // deprecated misspelled alias of BGRx. Treat anything else as BGRx.
        _ => atoms::bgrx(),
    }
}

// A page object's transformation matrix (a, b, c, d, e, f) — the PDF `cm`
// transform mapping the object's space onto the page. For an image, it maps the
// unit square to the placement, so a caller can recover scale/rotation/flip
// deterministically (orient an extracted stream without re-rendering).
type Matrix6 = (f64, f64, f64, f64, f64, f64);

// The object's transformation matrix, or None if pdfium cannot report it.
fn matrix_of(obj: &PdfPageObject) -> Option<Matrix6> {
    obj.matrix().ok().map(|m| {
        (
            m.a() as f64,
            m.b() as f64,
            m.c() as f64,
            m.d() as f64,
            m.e() as f64,
            m.f() as f64,
        )
    })
}

// (index, type, bounds, matrix): `index` is the object's 0-based position in the
// page's object list — pass it to image_data/3 / image_raw_data/3.
type PageObject = (usize, Atom, Option<Rect>, Option<Matrix6>);

/// Image & object extraction: every object on a 0-indexed page, in page order.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_page_objects(
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
) -> Result<Vec<PageObject>, Atom> {
    let index = page_index_u16(page_index)?;
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let page = document
            .pages()
            .get(index)
            .map_err(|_| atoms::page_out_of_bounds())?;
        let objects = page
            .objects()
            .iter()
            .enumerate()
            .map(|(i, obj)| {
                let bounds = obj.bounds().ok().map(|q| rect_of(&q.to_rect()));
                (
                    i,
                    object_type_atom(obj.object_type()),
                    bounds,
                    matrix_of(&obj),
                )
            })
            .collect();
        Ok(objects)
    })
}

// (index, width, height, bits_per_pixel, filters, bounds, matrix). width/height
// are the image's intrinsic pixel size; `filters` are the PDF stream filter
// names; `matrix` is the placement transform (see `Matrix6`).
type ImageInfo = (
    usize,
    u32,
    u32,
    u32,
    Vec<String>,
    Option<Rect>,
    Option<Matrix6>,
);

/// Image & object extraction: image objects on a page, with how they're stored.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_images(
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
) -> Result<Vec<ImageInfo>, Atom> {
    let index = page_index_u16(page_index)?;
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let page = document
            .pages()
            .get(index)
            .map_err(|_| atoms::page_out_of_bounds())?;
        let images = page
            .objects()
            .iter()
            .enumerate()
            .filter_map(|(i, obj)| {
                let img = obj.as_image_object()?;
                let width = img.width().ok().and_then(|p| u32::try_from(p).ok())?;
                let height = img.height().ok().and_then(|p| u32::try_from(p).ok())?;
                let bpp = img.bits_per_pixel().map(u32::from).unwrap_or(0);
                let filters = img.filters().iter().map(|f| f.name().to_string()).collect();
                let bounds = obj.bounds().ok().map(|q| rect_of(&q.to_rect()));
                Some((i, width, height, bpp, filters, bounds, matrix_of(&obj)))
            })
            .collect();
        Ok(images)
    })
}

/// Image & object extraction: decoded pixels of the image at `object_index`,
/// as a 4-/3-/1-channel bitmap (format reports the native channel order).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_image_data(
    env: Env<'_>,
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
    object_index: u32,
) -> Result<(Binary<'_>, u32, u32, u32, Atom), Atom> {
    let index = page_index_u16(page_index)?;
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let page = document
            .pages()
            .get(index)
            .map_err(|_| atoms::page_out_of_bounds())?;
        // `object` is owned here so the `img` borrow stays valid for the call.
        let object = page
            .objects()
            .get(object_index as usize)
            .map_err(|_| atoms::object_not_found())?;
        let img = object.as_image_object().ok_or_else(atoms::not_an_image)?;

        // Bound the decode by the image's DECLARED pixel size (cheap metadata read)
        // before get_raw_bitmap allocates: a malformed XObject claiming e.g.
        // 100000x100000 would otherwise make pdfium allocate a huge bitmap in-process.
        let declared_w = i64::from(img.width().map_err(|_| atoms::image_failed())?);
        let declared_h = i64::from(img.height().map_err(|_| atoms::image_failed())?);
        if declared_w.max(0) * declared_h.max(0) > MAX_BITMAP_PIXELS {
            return Err(atoms::image_too_large());
        }

        let bitmap = img.get_raw_bitmap().map_err(|_| atoms::image_failed())?;
        // `get_raw_bitmap` doesn't null-check pdfium's handle; `format()` errors on
        // a null/unknown bitmap, so call it FIRST (before `as_raw_bytes()` reads the
        // buffer) to fail cleanly rather than touch a null buffer. Keep this order.
        let format = bitmap_format_atom(bitmap.format().map_err(|_| atoms::image_failed())?);
        let width = u32::try_from(bitmap.width()).unwrap_or(0);
        let height = u32::try_from(bitmap.height()).unwrap_or(0);
        let bytes = bitmap.as_raw_bytes();
        let stride = if height == 0 {
            0
        } else {
            (bytes.len() / height as usize) as u32
        };

        let mut binary = OwnedBinary::new(bytes.len()).ok_or_else(atoms::alloc_failed)?;
        binary.as_mut_slice().copy_from_slice(&bytes);
        Ok((binary.release(env), width, height, stride, format))
    })
}

/// Image & object extraction: the original, still-encoded stream of the image at
/// `object_index` (e.g. the raw JPEG bytes for a DCTDecode image).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_image_raw_data(
    env: Env<'_>,
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
    object_index: u32,
) -> Result<Binary<'_>, Atom> {
    let index = page_index_u16(page_index)?;
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let page = document
            .pages()
            .get(index)
            .map_err(|_| atoms::page_out_of_bounds())?;
        let object = page
            .objects()
            .get(object_index as usize)
            .map_err(|_| atoms::object_not_found())?;
        let img = object.as_image_object().ok_or_else(atoms::not_an_image)?;

        let bytes = img
            .get_raw_image_data()
            .map_err(|_| atoms::image_failed())?;
        let mut binary = OwnedBinary::new(bytes.len()).ok_or_else(atoms::alloc_failed)?;
        binary.as_mut_slice().copy_from_slice(&bytes);
        Ok(binary.release(env))
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
        // Page indices are u16 in pdfium-render; refuse a merge that would exceed
        // that ceiling rather than overflow the page-index cache (u32 sum avoids
        // overflowing the check itself).
        if u32::from(dest_doc.pages().len()) + u32::from(src_doc.pages().len())
            > u32::from(u16::MAX)
        {
            return Err(atoms::page_out_of_bounds());
        }
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
    // A PDF can hold at most u16::MAX pages, and the dest index is a u16. Reject an
    // oversized selection up front rather than copying tens of thousands of pages
    // into a huge partial document only to fail at the u16 conversion below.
    if indices.len() > u16::MAX as usize {
        return Err(atoms::page_out_of_bounds());
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

// ── Document creation: pages, text, shapes, images ───────────────────────────

fn color_of(c: (u8, u8, u8, u8)) -> PdfColor {
    PdfColor::new(c.0, c.1, c.2, c.3)
}

// A stroke width must be a finite, non-negative number of points. (A negative
// width already fails gracefully inside pdfium-render's path constructor — see
// the codex-review note — but we reject it up front for a clear `:bad_option`
// and to keep a non-finite value from ever reaching pdfium.)
fn valid_stroke_width(width: f64) -> bool {
    width.is_finite() && width >= 0.0
}

// Map a Standard-14 font name to its built-in. Unknown -> None (-> :unknown_font).
fn font_builtin(name: &str) -> Option<PdfFontBuiltin> {
    Some(match name {
        "helvetica" => PdfFontBuiltin::Helvetica,
        "helvetica_bold" => PdfFontBuiltin::HelveticaBold,
        "helvetica_oblique" => PdfFontBuiltin::HelveticaOblique,
        "helvetica_bold_oblique" => PdfFontBuiltin::HelveticaBoldOblique,
        "times_roman" => PdfFontBuiltin::TimesRoman,
        "times_bold" => PdfFontBuiltin::TimesBold,
        "times_italic" => PdfFontBuiltin::TimesItalic,
        "times_bold_italic" => PdfFontBuiltin::TimesBoldItalic,
        "courier" => PdfFontBuiltin::Courier,
        "courier_bold" => PdfFontBuiltin::CourierBold,
        "courier_oblique" => PdfFontBuiltin::CourierOblique,
        "courier_bold_oblique" => PdfFontBuiltin::CourierBoldOblique,
        "symbol" => PdfFontBuiltin::Symbol,
        "zapf_dingbats" => PdfFontBuiltin::ZapfDingbats,
        _ => return None,
    })
}

// pdfium bitmaps are BGR-ordered. Map a Bitmap format to (pdfium format, swap_rb):
// an :rgba/:rgbx buffer needs R and B swapped to become BGRA/BGRx.
fn image_format(name: &str) -> Option<(PdfBitmapFormat, bool)> {
    Some(match name {
        "bgra" => (PdfBitmapFormat::BGRA, false),
        "rgba" => (PdfBitmapFormat::BGRA, true),
        "bgrx" => (PdfBitmapFormat::BGRx, false),
        "rgbx" => (PdfBitmapFormat::BGRx, true),
        "bgr" => (PdfBitmapFormat::BGR, false),
        "gray" => (PdfBitmapFormat::Gray, false),
        _ => return None,
    })
}

fn bytes_per_pixel(f: PdfBitmapFormat) -> usize {
    match f {
        PdfBitmapFormat::Gray => 1,
        PdfBitmapFormat::BGR => 3,
        _ => 4,
    }
}

// Validate a page index before we build any object. Drawing builds the object
// first (it needs the document), then adds it to the page; if the page were
// missing, the orphaned, never-added object would be dropped — which pdfium does
// not handle cleanly. So check the page exists up front.
fn check_page(document: &PdfDocument, page_index: u16) -> Result<(), Atom> {
    if page_index < document.pages().len() {
        Ok(())
    } else {
        Err(atoms::page_out_of_bounds())
    }
}

// Add a freshly-built object to a page and commit the page content. Takes the
// page by immutable document borrow (the object also borrows the document
// immutably, so the two coexist; the mutation goes through the page handle).
fn add_to_page(
    document: &PdfDocument,
    page_index: u16,
    object: PdfPageObject,
) -> Result<Atom, Atom> {
    let mut page = document
        .pages()
        .get(page_index)
        .map_err(|_| atoms::page_out_of_bounds())?;
    page.objects_mut()
        .add_object(object)
        .map_err(|_| atoms::draw_failed())?;
    page.regenerate_content()
        .map_err(|_| atoms::draw_failed())?;
    Ok(atoms::ok())
}

// Attach a freshly-built object to a page, THEN style it. Adding first makes the
// object page-owned, so any fallible styling that follows (set_fill_color,
// translate, set_bitmap, …) can't drop an orphaned, never-added object — which
// crashes pdfium. (The returned object is page-owned, so dropping it is a no-op.)
// Used for objects whose styling happens after construction (text, images);
// shapes carry their styling in the constructor and use `add_to_page`.
fn attach_then_style(
    document: &PdfDocument,
    page_index: u16,
    object: PdfPageObject,
    style: impl FnOnce(&mut PdfPageObject) -> Result<(), Atom>,
) -> Result<Atom, Atom> {
    let mut page = document
        .pages()
        .get(page_index)
        .map_err(|_| atoms::page_out_of_bounds())?;
    let mut added = page
        .objects_mut()
        .add_object(object)
        .map_err(|_| atoms::draw_failed())?;
    style(&mut added)?;
    drop(added); // release the borrow (no-op for a page-owned object) before regen
    page.regenerate_content()
        .map_err(|_| atoms::draw_failed())?;
    Ok(atoms::ok())
}

/// Document creation: a new, empty in-memory document.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_new() -> Result<ResourceArc<DocumentResource>, Atom> {
    with_pdfium(|pdfium| {
        let doc = pdfium
            .create_new_pdf()
            .map_err(|_| atoms::create_failed())?;
        Ok(ResourceArc::new(DocumentResource {
            doc: Mutex::new(Some(doc)),
        }))
    })
}

/// Document creation: add a blank page sized in points. `at` < 0 appends; otherwise
/// the page is inserted at that 0-based index.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_add_page(
    doc: ResourceArc<DocumentResource>,
    width: f64,
    height: f64,
    at: i64,
) -> Result<Atom, Atom> {
    with_pdfium(|_| {
        let mut guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_mut().ok_or_else(atoms::document_closed)?;
        // u16 page-index ceiling: refuse to add a page to an already-full document.
        if document.pages().len() == u16::MAX {
            return Err(atoms::page_out_of_bounds());
        }
        let size = PdfPagePaperSize::from_points(
            PdfPoints::new(width as f32),
            PdfPoints::new(height as f32),
        );
        if at < 0 {
            document
                .pages_mut()
                .create_page_at_end(size)
                .map_err(|_| atoms::create_failed())?;
        } else {
            let idx = u16::try_from(at).map_err(|_| atoms::page_out_of_bounds())?;
            document
                .pages_mut()
                .create_page_at_index(size, idx)
                .map_err(|_| atoms::page_out_of_bounds())?;
        }
        Ok(atoms::ok())
    })
}

/// Document creation: draw text at `(x, y)` (PDF points, bottom-left origin).
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn document_draw_text(
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
    x: f64,
    y: f64,
    text: String,
    font: String,
    size: f64,
    color: (u8, u8, u8, u8),
) -> Result<Atom, Atom> {
    let index = page_index_u16(page_index)?;
    let builtin = font_builtin(&font).ok_or_else(atoms::unknown_font)?;
    with_pdfium(|_| {
        let mut guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_mut().ok_or_else(atoms::document_closed)?;
        check_page(document, index)?;
        let token = document.fonts_mut().new_built_in(builtin);
        let object = PdfPageTextObject::new(&*document, text, token, PdfPoints::new(size as f32))
            .map_err(|_| atoms::draw_failed())?;
        attach_then_style(document, index, object.into(), |obj| {
            obj.set_fill_color(color_of(color))
                .map_err(|_| atoms::draw_failed())?;
            obj.translate(PdfPoints::new(x as f32), PdfPoints::new(y as f32))
                .map_err(|_| atoms::draw_failed())
        })
    })
}

/// Document creation: draw a rectangle. `fill`/`stroke` are `(r,g,b,a)` or absent.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn document_draw_rectangle(
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
    left: f64,
    bottom: f64,
    right: f64,
    top: f64,
    fill: Option<(u8, u8, u8, u8)>,
    stroke: Option<(u8, u8, u8, u8)>,
    stroke_width: f64,
) -> Result<Atom, Atom> {
    let index = page_index_u16(page_index)?;
    if stroke.is_some() && !valid_stroke_width(stroke_width) {
        return Err(atoms::bad_option());
    }
    with_pdfium(|_| {
        let mut guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_mut().ok_or_else(atoms::document_closed)?;
        check_page(document, index)?;
        let rect = PdfRect::new_from_values(bottom as f32, left as f32, top as f32, right as f32);
        let object = PdfPagePathObject::new_rect(
            &*document,
            rect,
            stroke.map(color_of),
            stroke.map(|_| PdfPoints::new(stroke_width as f32)),
            fill.map(color_of),
        )
        .map_err(|_| atoms::draw_failed())?;
        add_to_page(document, index, object.into())
    })
}

/// Document creation: draw a straight line (always stroked).
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn document_draw_line(
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    stroke: (u8, u8, u8, u8),
    stroke_width: f64,
) -> Result<Atom, Atom> {
    let index = page_index_u16(page_index)?;
    if !valid_stroke_width(stroke_width) {
        return Err(atoms::bad_option());
    }
    with_pdfium(|_| {
        let mut guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_mut().ok_or_else(atoms::document_closed)?;
        check_page(document, index)?;
        let object = PdfPagePathObject::new_line(
            &*document,
            PdfPoints::new(x1 as f32),
            PdfPoints::new(y1 as f32),
            PdfPoints::new(x2 as f32),
            PdfPoints::new(y2 as f32),
            color_of(stroke),
            PdfPoints::new(stroke_width as f32),
        )
        .map_err(|_| atoms::draw_failed())?;
        add_to_page(document, index, object.into())
    })
}

/// Document creation: draw a circle of `radius` centered at `(cx, cy)`.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn document_draw_circle(
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
    cx: f64,
    cy: f64,
    radius: f64,
    fill: Option<(u8, u8, u8, u8)>,
    stroke: Option<(u8, u8, u8, u8)>,
    stroke_width: f64,
) -> Result<Atom, Atom> {
    let index = page_index_u16(page_index)?;
    if stroke.is_some() && !valid_stroke_width(stroke_width) {
        return Err(atoms::bad_option());
    }
    with_pdfium(|_| {
        let mut guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_mut().ok_or_else(atoms::document_closed)?;
        check_page(document, index)?;
        let object = PdfPagePathObject::new_circle_at(
            &*document,
            PdfPoints::new(cx as f32),
            PdfPoints::new(cy as f32),
            PdfPoints::new(radius as f32),
            stroke.map(color_of),
            stroke.map(|_| PdfPoints::new(stroke_width as f32)),
            fill.map(color_of),
        )
        .map_err(|_| atoms::draw_failed())?;
        add_to_page(document, index, object.into())
    })
}

/// Document creation: place a decoded bitmap, scaled into the `[left,bottom,
/// right,top]` rectangle. pdfium is BGR-ordered; an :rgba/:rgbx buffer is R/B
/// swapped here so any `ExPdfium.Bitmap` works.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn document_draw_image(
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
    data: Binary,
    img_width: u32,
    img_height: u32,
    format: String,
    left: f64,
    bottom: f64,
    right: f64,
    top: f64,
) -> Result<Atom, Atom> {
    let index = page_index_u16(page_index)?;
    let (pdf_format, swap_rb) =
        image_format(&format).ok_or_else(atoms::unsupported_image_format)?;
    if img_width == 0 || img_height == 0 {
        return Err(atoms::bad_image_data());
    }
    // Cap input dimensions: keeps the size math (packed_row * height, stride *
    // height) far from usize overflow and bounds the allocation. 30000 px per side
    // is already enormous for a placed image.
    if img_width > MAX_RENDER_DIMENSION as u32 || img_height > MAX_RENDER_DIMENSION as u32 {
        return Err(atoms::bad_image_data());
    }
    let packed_row = img_width as usize * bytes_per_pixel(pdf_format);
    if data.len() != packed_row * img_height as usize {
        return Err(atoms::bad_image_data());
    }
    // pdfium lays bitmap rows out with a 4-byte-aligned stride; repack the packed
    // input into a buffer with that stride so pdfium never reads past it. (The
    // padding is only non-trivial for the 1-/3-byte :gray / :bgr formats; 4-byte
    // formats are already aligned, so this is a straight copy for them.)
    let stride = (packed_row + 3) & !3;
    let mut buffer = vec![0u8; stride * img_height as usize];
    for (y, src_row) in data.as_slice().chunks_exact(packed_row).enumerate() {
        buffer[y * stride..y * stride + packed_row].copy_from_slice(src_row);
    }
    if swap_rb {
        // RGBA/RGBX -> BGRA/BGRx: swap the red and blue bytes of each pixel. These
        // are 4-byte formats, so stride == packed_row (no padding within a row).
        for pixel in buffer.chunks_exact_mut(4) {
            pixel.swap(0, 2);
        }
    }

    with_pdfium(|_| {
        let mut guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_mut().ok_or_else(atoms::document_closed)?;
        check_page(document, index)?;
        let width = i32::try_from(img_width).map_err(|_| atoms::bad_image_data())?;
        let height = i32::try_from(img_height).map_err(|_| atoms::bad_image_data())?;
        // SAFETY: `buffer` is exactly `stride * height` bytes with pdfium's
        // 4-byte-aligned row stride (built above), matching what pdfium reads, and
        // it outlives the bitmap; set_bitmap copies the pixels out before drop.
        let bitmap = unsafe {
            PdfBitmap::from_bytes(width, height, pdf_format, &mut buffer, document.bindings())
        }
        .map_err(|_| atoms::image_failed())?;

        let object = PdfPageImageObject::new(&*document).map_err(|_| atoms::draw_failed())?;
        attach_then_style(document, index, object.into(), |obj| {
            obj.as_image_object_mut()
                .ok_or_else(atoms::draw_failed)?
                .set_bitmap(&bitmap)
                .map_err(|_| atoms::draw_failed())?;
            // A fresh image object is a unit square at the origin; scale to the
            // target size then translate to its bottom-left corner.
            obj.scale((right - left) as f32, (top - bottom) as f32)
                .map_err(|_| atoms::draw_failed())?;
            obj.translate(PdfPoints::new(left as f32), PdfPoints::new(bottom as f32))
                .map_err(|_| atoms::draw_failed())
        })
    })
}

// ── Annotation authoring ─────────────────────────────────────────────────────
//
// pdfium-render's `create_*_annotation` calls `FPDFPage_CreateAnnot`, which
// attaches the annotation to the page immediately and then sets properties on the
// attached handle — so there is no detached, never-added annotation to drop. The
// orphan-build-then-drop crash class that affects page *objects* (see
// `attach_then_style`) does not arise here.

// Build a PdfRect from the (left, bottom, right, top) the Elixir side passes.
fn annot_rect(l: f64, b: f64, r: f64, t: f64) -> PdfRect {
    PdfRect::new_from_values(b as f32, l as f32, t as f32, r as f32)
}

/// Annotation authoring: a text (sticky-note) annotation at `(x, y)`.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_add_text_annotation(
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
    x: f64,
    y: f64,
    text: String,
    color: (u8, u8, u8, u8),
) -> Result<Atom, Atom> {
    let index = page_index_u16(page_index)?;
    with_pdfium(|_| {
        let mut guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_mut().ok_or_else(atoms::document_closed)?;
        let mut page = document
            .pages()
            .get(index)
            .map_err(|_| atoms::page_out_of_bounds())?;
        let mut annotation = page
            .annotations_mut()
            .create_text_annotation(&text)
            .map_err(|_| atoms::annotate_failed())?;
        annotation
            .set_position(PdfPoints::new(x as f32), PdfPoints::new(y as f32))
            .map_err(|_| atoms::annotate_failed())?;
        annotation
            .set_fill_color(color_of(color))
            .map_err(|_| atoms::annotate_failed())?;
        Ok(atoms::ok())
    })
}

/// Annotation authoring: a free-text (visible text box) annotation in `bounds`.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn document_add_free_text_annotation(
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
    l: f64,
    b: f64,
    r: f64,
    t: f64,
    text: String,
    fill: Option<(u8, u8, u8, u8)>,
    stroke: Option<(u8, u8, u8, u8)>,
) -> Result<Atom, Atom> {
    let index = page_index_u16(page_index)?;
    with_pdfium(|_| {
        let mut guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_mut().ok_or_else(atoms::document_closed)?;
        let mut page = document
            .pages()
            .get(index)
            .map_err(|_| atoms::page_out_of_bounds())?;
        let mut annotation = page
            .annotations_mut()
            .create_free_text_annotation(&text)
            .map_err(|_| atoms::annotate_failed())?;
        annotation
            .set_bounds(annot_rect(l, b, r, t))
            .map_err(|_| atoms::annotate_failed())?;
        if let Some(c) = fill {
            annotation
                .set_fill_color(color_of(c))
                .map_err(|_| atoms::annotate_failed())?;
        }
        if let Some(c) = stroke {
            annotation
                .set_stroke_color(color_of(c))
                .map_err(|_| atoms::annotate_failed())?;
        }
        Ok(atoms::ok())
    })
}

/// Annotation authoring: a square (rectangle) annotation filling `bounds`.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn document_add_square_annotation(
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
    l: f64,
    b: f64,
    r: f64,
    t: f64,
    fill: Option<(u8, u8, u8, u8)>,
    stroke: Option<(u8, u8, u8, u8)>,
) -> Result<Atom, Atom> {
    let index = page_index_u16(page_index)?;
    with_pdfium(|_| {
        let mut guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_mut().ok_or_else(atoms::document_closed)?;
        let mut page = document
            .pages()
            .get(index)
            .map_err(|_| atoms::page_out_of_bounds())?;
        let mut annotation = page
            .annotations_mut()
            .create_square_annotation()
            .map_err(|_| atoms::annotate_failed())?;
        annotation
            .set_bounds(annot_rect(l, b, r, t))
            .map_err(|_| atoms::annotate_failed())?;
        if let Some(c) = fill {
            annotation
                .set_fill_color(color_of(c))
                .map_err(|_| atoms::annotate_failed())?;
        }
        if let Some(c) = stroke {
            annotation
                .set_stroke_color(color_of(c))
                .map_err(|_| atoms::annotate_failed())?;
        }
        Ok(atoms::ok())
    })
}

/// Annotation authoring: a link annotation over `bounds` opening `uri`.
#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn document_add_link_annotation(
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
    l: f64,
    b: f64,
    r: f64,
    t: f64,
    uri: String,
) -> Result<Atom, Atom> {
    let index = page_index_u16(page_index)?;
    with_pdfium(|_| {
        let mut guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_mut().ok_or_else(atoms::document_closed)?;
        let mut page = document
            .pages()
            .get(index)
            .map_err(|_| atoms::page_out_of_bounds())?;
        let mut annotation = page
            .annotations_mut()
            .create_link_annotation(&uri)
            .map_err(|_| atoms::annotate_failed())?;
        annotation
            .set_bounds(annot_rect(l, b, r, t))
            .map_err(|_| atoms::annotate_failed())?;
        Ok(atoms::ok())
    })
}

/// Annotation authoring: delete the annotation at 0-based `annot_index` on a page.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_delete_annotation(
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
    annot_index: u32,
) -> Result<Atom, Atom> {
    let index = page_index_u16(page_index)?;
    let annot_index = usize::try_from(annot_index).map_err(|_| atoms::annotation_not_found())?;
    with_pdfium(|_| {
        let mut guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_mut().ok_or_else(atoms::document_closed)?;
        let mut page = document
            .pages()
            .get(index)
            .map_err(|_| atoms::page_out_of_bounds())?;
        let annotations = page.annotations_mut();
        if annot_index >= annotations.len() {
            return Err(atoms::annotation_not_found());
        }
        // `get` returns a `PdfPageAnnotation<'a>` independent of the transient
        // `&self` borrow, so it can be handed straight to `delete_annotation`
        // (which re-borrows the collection mutably).
        let annotation = annotations
            .get(annot_index)
            .map_err(|_| atoms::annotation_not_found())?;
        annotations
            .delete_annotation(annotation)
            .map_err(|_| atoms::annotate_failed())?;
        Ok(atoms::ok())
    })
}

// ── Flatten & signatures ─────────────────────────────────────────────────────

/// Flatten a single page's annotations and form fields into its content stream
/// (pdfium uses the print appearance). A page with nothing to flatten is a no-op.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_flatten_page(
    doc: ResourceArc<DocumentResource>,
    page_index: u32,
) -> Result<Atom, Atom> {
    let index = page_index_u16(page_index)?;
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let mut page = document
            .pages()
            .get(index)
            .map_err(|_| atoms::page_out_of_bounds())?;
        page.flatten().map_err(|_| atoms::flatten_failed())?;
        Ok(atoms::ok())
    })
}

/// Flatten every page (see `document_flatten_page`).
#[rustler::nif(schedule = "DirtyCpu")]
fn document_flatten(doc: ResourceArc<DocumentResource>) -> Result<Atom, Atom> {
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let count = document.pages().len();
        for i in 0..count {
            let mut page = document
                .pages()
                .get(i)
                .map_err(|_| atoms::page_out_of_bounds())?;
            page.flatten().map_err(|_| atoms::flatten_failed())?;
        }
        Ok(atoms::ok())
    })
}

// (reason, signing_date, contents): the signature's /Reason, /M date string, and
// raw /Contents (PKCS#7) bytes. pdfium exposes no signer name (it lives inside
// the PKCS#7 blob).
type Signature<'a> = (Option<String>, Option<String>, Binary<'a>);

/// Read the document's digital signatures.
#[rustler::nif(schedule = "DirtyCpu")]
fn document_signatures(
    env: Env<'_>,
    doc: ResourceArc<DocumentResource>,
) -> Result<Vec<Signature<'_>>, Atom> {
    with_pdfium(|_| {
        let guard = doc.doc.lock().map_err(|_| atoms::lock_poisoned())?;
        let document = guard.as_ref().ok_or_else(atoms::document_closed)?;
        let mut signatures = Vec::new();
        for signature in document.signatures().iter() {
            let bytes = signature.bytes();
            let mut binary = OwnedBinary::new(bytes.len()).ok_or_else(atoms::alloc_failed)?;
            binary.as_mut_slice().copy_from_slice(&bytes);
            signatures.push((
                signature.reason(),
                signature.signing_date(),
                binary.release(env),
            ));
        }
        Ok(signatures)
    })
}

rustler::init!("Elixir.ExPdfium.Native");
