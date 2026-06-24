# Point the dynamic (dev) pdfium binding at a downloaded libpdfium if present.
# `just fetch-pdfium` populates priv/pdfium. Phase 0 wires this up for real.
dev_lib = Path.join([File.cwd!(), "priv", "pdfium"])
if File.dir?(dev_lib), do: System.put_env("PDFIUM_DYNAMIC_LIB_PATH", dev_lib)

ExUnit.start()
