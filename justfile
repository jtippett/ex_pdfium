# Project commands. Run `just --list` to see them all.

# Interactive release: pick patch/minor/major, roll the CHANGELOG, tag & push.
release:
    elixir scripts/release.exs

# Run the test suite (builds the NIF locally; dynamic pdfium binding).
test:
    EXPDFIUM_BUILD=1 mix test

# Format Elixir + Rust.
fmt:
    mix format
    cd native/ex_pdfium && cargo fmt

# Download a dynamic libpdfium for local dev/test into priv/pdfium (set the tag).
fetch-pdfium tag="chromium/7506":
    scripts/fetch-pdfium-dev.sh {{tag}}
