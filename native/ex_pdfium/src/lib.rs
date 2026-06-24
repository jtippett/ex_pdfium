//! ExPdfium NIF — a thin, faithful bridge to pdfium via `pdfium-render`.
//!
//! Phase 0 wires up the global pdfium instance and a single load-proof NIF
//! (`pdfium_version`). Document/page NIFs land in later phases (see PORTING.md).
//! This encodes the load-bearing decisions from PORTING.md §2.
//!
//! Three rules drive everything here:
//!   1. pdfium is NOT thread-safe and the BEAM calls dirty NIFs from many OS
//!      threads -> one global Pdfium instance. The `sync` feature serializes
//!      every call (a mutex) AND makes Pdfium Send+Sync so it can live here in a
//!      `static` (plain `thread_safe` does the former but not the latter).
//!   2. `PdfDocument<'a>` borrows from `Pdfium`. A `'static` Pdfium (OnceLock)
//!      makes `PdfDocument<'static>` storable in a ResourceArc.
//!   3. pdfium work is synchronous and CPU-heavy -> every NIF is DirtyCpu.
//!      (No tokio — unlike ex_bashkit.)

use std::sync::OnceLock;

use pdfium_render::prelude::*;

// ── The single global pdfium instance ───────────────────────────────────────
//
// `'static` so documents can borrow it and live in resources. Initialized once;
// every NIF goes through `pdfium()`.
static PDFIUM: OnceLock<Pdfium> = OnceLock::new();

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
    rustler::types::atom::ok()
}

// Phase 1+ NIFs land in their own phases: document open/close/page_count, then
// render_page. They hang a document off `ResourceArc<Mutex<Option<PdfDocument<
// 'static>>>>` — see PORTING.md §2c for the resource-lifetime design (the `Sync`
// bound on rustler resources is the crux there). Until then, the matching Elixir
// stubs in lib/ex_pdfium/native.ex raise `:nif_not_loaded`.

rustler::init!("Elixir.ExPdfium.Native");
