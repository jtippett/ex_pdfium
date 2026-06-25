#!/usr/bin/env python3
"""Generate a tiny PDF with a "decompression bomb" embedded file, for testing the
attachment_data/2 size cap.

Regenerate with `python3 test/fixtures/attachment_bomb_gen.py` (overwrites
test/fixtures/attachment_bomb.pdf; commit both together).

The embedded file is /FlateDecode over ~105 MB of zero bytes, which zlib RLE-
compresses to ~100 KB. /Params << /Size … >> declares the decoded length, so
pdfium reports a >100 MB attachment from a ~100 KB file — the amplification the
cap exists to stop. Computes a real xref from byte offsets.
"""

import zlib

DECODED_SIZE = 105_000_000  # > the 100 MB cap
stream = zlib.compress(b"\x00" * DECODED_SIZE, 9)

objs = {
    1: b"<< /Type /Catalog /Pages 2 0 R "
       b"/Names << /EmbeddedFiles << /Names [(bomb.bin) 5 0 R] >> >> >>",
    2: b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    3: b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>",
    5: b"<< /Type /Filespec /F (bomb.bin) /EF << /F 6 0 R >> >>",
    6: b"<< /Type /EmbeddedFile /Filter /FlateDecode /Params << /Size %d >> "
       b"/Length %d >>\nstream\n%s\nendstream" % (DECODED_SIZE, len(stream), stream),
}

out = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
off = {}
for n in sorted(objs):
    off[n] = len(out)
    out += b"%d 0 obj\n" % n + objs[n] + b"\nendobj\n"
xref = len(out)
size = max(objs) + 1
out += b"xref\n0 %d\n0000000000 65535 f \n" % size
for n in range(1, size):
    out += (b"%010d 00000 n \n" % off[n]) if n in off else b"0000000000 00000 f \n"
out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (size, xref)

path = "/Users/james/Desktop/elixir/ex_pdfium/test/fixtures/attachment_bomb.pdf"
with open(path, "wb") as f:
    f.write(bytes(out))
print("wrote", path, len(out), "bytes; decoded size", DECODED_SIZE)
