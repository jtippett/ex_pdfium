#!/usr/bin/env bash
# Download a DYNAMIC libpdfium for local dev/test into priv/pdfium/.
# Release archives bundle the same dynamic library beside the NIF.
#
#   scripts/fetch-pdfium-dev.sh [chromium/NNNN]
#
# Keep the tag in sync with release.yml's PDFIUM_TAG and UPDATE_PROCEDURE.md.
set -euo pipefail

TAG="${1:-chromium/8125}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/priv/pdfium"

if [[ "$TAG" != "chromium/8125" ]]; then
  echo "unsupported unverified tag: $TAG (update PDFIUM_SHA256SUMS and the pinned tag first)" >&2
  exit 1
fi

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
expected="$(awk -v asset="$asset" '$2 == asset { print $1 }' "$ROOT/PDFIUM_SHA256SUMS")"
actual="$(shasum -a 256 "$tmp/pdfium.tgz" | awk '{ print $1 }')"
if [[ -z "$expected" || "$actual" != "$expected" ]]; then
  echo "libpdfium checksum mismatch for $asset" >&2
  rm -rf "$tmp"
  exit 1
fi
tar -xzf "$tmp/pdfium.tgz" -C "$tmp" "$lib"
cp "$tmp/$lib" "$DEST/"
rm -rf "$tmp"
echo "Installed $(basename "$lib") -> $DEST/"
echo "Tests pick it up via ExPdfium.Native.set_dynamic_lib_dir/1 (see test/test_helper.exs)."
