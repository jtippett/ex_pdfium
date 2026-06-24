# Point the dynamic (dev) pdfium binding at a downloaded libpdfium if present.
# `just fetch-pdfium` populates priv/pdfium. We hand the path to the NIF via a
# function argument, NOT an env var: System.put_env (os:putenv) updates Erlang's
# env table but does not reach the C getenv that a NIF's std::env::var reads.
dev_lib = Path.join([File.cwd!(), "priv", "pdfium"])

if Path.wildcard(Path.join(dev_lib, "libpdfium*")) != [],
  do: ExPdfium.Native.set_dynamic_lib_dir(dev_lib)

ExUnit.start()
