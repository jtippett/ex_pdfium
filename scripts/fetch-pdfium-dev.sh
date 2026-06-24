#!/usr/bin/env bash
# Download a DYNAMIC libpdfium for local dev/test into priv/pdfium/.
# The shipped NIF links pdfium statically; this is only for the dev inner loop.
#
#   scripts/fetch-pdfium-dev.sh [chromium/NNNN]
#
# Keep the tag in sync with release.yml's PDFIUM_TAG and UPDATE_PROCEDURE.md.
set -euo pipefail

TAG="${1:-chromium/7543}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/priv/pdfium"

os="$(uname -s)"; arch="$(uname -m)"
case "$os-$arch" in
  Darwin-arm64)  asset="pdfium-mac-arm64.tgz"; lib="lib/libpdfium.dylib" ;;
  Darwin-x86_64) asset="pdfium-mac-x64.tgz";   lib="lib/libpdfium.dylib" ;;
  Linux-aarch64) asset="pdfium-linux-arm64.tgz"; lib="lib/libpdfium.so" ;;
  Linux-x86_64)  asset="pdfium-linux-x64.tgz";   lib="lib/libpdfium.so" ;;
  *) echo "unsupported host: $os-$arch" >&2; exit 1 ;;
esac

url="https://github.com/bblanchon/pdfium-binaries/releases/download/${TAG/\//%2F}/${asset}"
echo "Downloading $asset ($TAG) ..."
mkdir -p "$DEST"
tmp="$(mktemp -d)"
curl -fsSL "$url" -o "$tmp/pdfium.tgz"
tar -xzf "$tmp/pdfium.tgz" -C "$tmp" "$lib"
cp "$tmp/$lib" "$DEST/"
rm -rf "$tmp"
echo "Installed $(basename "$lib") -> $DEST/"
echo "Tests pick it up via ExPdfium.Native.set_dynamic_lib_dir/1 (see test/test_helper.exs)."
