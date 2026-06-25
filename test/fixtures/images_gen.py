#!/usr/bin/env python3
"""Generate a hand-built PDF with text, a path, and several embedded images.

Regenerate the committed fixture with `python3 test/fixtures/images_gen.py`
(it overwrites test/fixtures/images.pdf in place; commit both together).

The page's content stream draws, in this order:
  0. a text object   (BT … Tj ET)
  1. a path object   (a filled rectangle)
  2. an RGB image    (4x4 8-bpc DeviceRGB, /FlateDecode)
  3. a grayscale img (4x4 8-bpc DeviceGray, /FlateDecode)
  4. a JPEG image    (16x12 DeviceRGB, /DCTDecode)

The flate images are built with zlib (no PIL); the JPEG is a small real baseline
JPEG embedded as a base64 constant (generated once with ImageMagick), so this
generator stays dependency-free. This exercises decode (get_raw_bitmap → :bgr /
:gray), the still-encoded stream (get_raw_image_data → the original JPEG), filter
reporting, and multi-image index mapping. We compute the xref from real offsets.
"""

import base64
import zlib

# 4x4 RGB raster (48 raw bytes) → /FlateDecode.
rgb_raw = bytes(
    value
    for y in range(4)
    for x in range(4)
    for value in (x * 64, y * 64, (x + y) * 32)
)
rgb_stream = zlib.compress(rgb_raw, 9)

# 4x4 grayscale raster (16 raw bytes) → /FlateDecode.
gray_raw = bytes((x + y * 4) * 16 for y in range(4) for x in range(4))
gray_stream = zlib.compress(gray_raw, 9)

# A small real baseline JPEG (16x12), generated once with:
#   magick -size 16x12 gradient:blue-yellow tiny.jpg
jpeg_stream = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkK"
    "DA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQEBAQEBAQ"
    "EBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wAARCAAMABADAREAAhEBAxEB/8QA"
    "FgABAQEAAAAAAAAAAAAAAAAAAAcJ/8QAHRAAAQIHAAAAAAAAAAAAAAAAAAEGFxhUVaGi0f/EABcBAQEB"
    "AQAAAAAAAAAAAAAAAAAHBQn/xAAhEQABAAoDAAAAAAAAAAAAAAAAAwUUFRYYUVNhY5Gh8P/aAAwDAQAC"
    "EQMRAD8Aj0riW7QvUxu3sy3RgSuJbtBMbt7DowahQ9a9DlOHF6OF1d9yURlR0EPWvQ5TgjhdXfchlR0"
    "P/9k="
)

objs = {}


def add(num, body):
    objs[num] = body


add(1, b"<< /Type /Catalog /Pages 2 0 R >>")
add(2, b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
add(3, b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
       b"/Resources << /Font << /F1 5 0 R >> "
       b"/XObject << /Im0 6 0 R /Im1 7 0 R /Im2 8 0 R >> >> "
       b"/Contents 4 0 R >>")

# Content: text, a filled rectangle (path), then the three images.
content = (
    b"BT /F1 18 Tf 72 750 Td (Embedded image sample) Tj ET\n"
    b"0.8 0.8 0.8 rg 100 100 200 150 re f\n"
    b"q 64 0 0 64 300 400 cm /Im0 Do Q\n"
    b"q 64 0 0 64 380 400 cm /Im1 Do Q\n"
    b"q 96 0 0 72 300 250 cm /Im2 Do Q"
)
add(4, b"<< /Length %d >>\nstream\n%s\nendstream" % (len(content), content))

add(5, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")

add(6, b"<< /Type /XObject /Subtype /Image /Width 4 /Height 4 "
       b"/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode "
       b"/Length %d >>\nstream\n%s\nendstream" % (len(rgb_stream), rgb_stream))

add(7, b"<< /Type /XObject /Subtype /Image /Width 4 /Height 4 "
       b"/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode "
       b"/Length %d >>\nstream\n%s\nendstream" % (len(gray_stream), gray_stream))

add(8, b"<< /Type /XObject /Subtype /Image /Width 16 /Height 12 "
       b"/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode "
       b"/Length %d >>\nstream\n%s\nendstream" % (len(jpeg_stream), jpeg_stream))


def build():
    out = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offsets = {}
    for num in sorted(objs):
        offsets[num] = len(out)
        out += b"%d 0 obj\n" % num
        out += objs[num]
        out += b"\nendobj\n"
    xref_pos = len(out)
    n = max(objs) + 1
    out += b"xref\n0 %d\n" % n
    out += b"0000000000 65535 f \n"
    for num in range(1, n):
        out += b"%010d 00000 n \n" % offsets[num]
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\n" % n
    out += b"startxref\n%d\n%%%%EOF\n" % xref_pos
    return bytes(out)


path = "/Users/james/Desktop/elixir/ex_pdfium/test/fixtures/images.pdf"
with open(path, "wb") as f:
    f.write(build())
print("wrote", path, "(rgb", len(rgb_stream), "gray", len(gray_stream),
      "jpeg", len(jpeg_stream), "bytes)")
