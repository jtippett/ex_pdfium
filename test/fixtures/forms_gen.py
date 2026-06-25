#!/usr/bin/env python3
"""Generate a hand-built PDF with an AcroForm + markup annotations for Phase 6.

Regenerate the committed fixture with `python3 test/fixtures/forms_gen.py`
(it overwrites test/fixtures/forms.pdf in place; commit both together).

We can't rely on reportlab/pypdf here, so we assemble the file object-by-object
and compute the xref table from real byte offsets. The document has:

  * An AcroForm (so pdfium reports form_type = :acrobat) with:
      - a filled text field   (full_name = "Ada Lovelace")
      - an empty text field   (comments, no /V)
      - a checked checkbox    (subscribe = Yes)
      - a radio group         (plan: "pro" checked, "basic" off)
  * Two markup annotations not tied to a form:
      - a Text (sticky note) annotation with /Contents
      - a Highlight annotation with /Contents

Checkboxes/radios need an /AP /N appearance subdictionary whose non-Off key
names the "on" state, otherwise pdfium's FPDFAnnot_IsChecked can't resolve the
checked state. We include minimal form-XObject appearance streams for that.
"""

objs = {}


def add(num, body):
    objs[num] = body


# 1: Catalog with AcroForm. /Fields lists the *field* objects (the text fields,
# the checkbox, and the radio parent — not the individual radio kid widgets).
add(1, b"<< /Type /Catalog /Pages 2 0 R "
       b"/AcroForm << /Fields [4 0 R 5 0 R 6 0 R 7 0 R] /NeedAppearances true >> >>")

# 2: Pages
add(2, b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>")

# 3: Page. /Annots holds every widget (text x2, checkbox, 2 radio kids) plus the
# two markup annotations.
add(3, b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
       b"/Resources << /Font << /F1 14 0 R >> >> /Contents 15 0 R "
       b"/Annots [4 0 R 5 0 R 6 0 R 8 0 R 9 0 R 12 0 R 13 0 R] >>")

# 4: filled text field (widget + field merged)
add(4, b"<< /Type /Annot /Subtype /Widget /FT /Tx /T (full_name) "
       b"/V (Ada Lovelace) /Rect [100 700 400 720] /F 4 /DA (/F1 12 Tf 0 g) >>")

# 5: empty text field
add(5, b"<< /Type /Annot /Subtype /Widget /FT /Tx /T (comments) "
       b"/Rect [100 650 400 670] /F 4 /DA (/F1 12 Tf 0 g) >>")

# 6: checkbox, checked. On-state "Yes" named via /AP /N.
add(6, b"<< /Type /Annot /Subtype /Widget /FT /Btn /T (subscribe) "
       b"/V /Yes /AS /Yes /Rect [100 610 120 630] /F 4 "
       b"/AP << /N << /Yes 10 0 R /Off 11 0 R >> >> >>")

# 7: radio group parent field. Ff 49152 = Radio (32768) + NoToggleToOff (16384).
add(7, b"<< /FT /Btn /Ff 49152 /T (plan) /V /pro /Kids [8 0 R 9 0 R] >>")

# 8: radio kid "pro" (checked)
add(8, b"<< /Type /Annot /Subtype /Widget /Parent 7 0 R /AS /pro "
       b"/Rect [100 560 120 580] /F 4 "
       b"/AP << /N << /pro 10 0 R /Off 11 0 R >> >> >>")

# 9: radio kid "basic" (off)
add(9, b"<< /Type /Annot /Subtype /Widget /Parent 7 0 R /AS /Off "
       b"/Rect [200 560 220 580] /F 4 "
       b"/AP << /N << /basic 10 0 R /Off 11 0 R >> >> >>")

# 10 / 11: shared minimal appearance XObjects (on / off). Content is irrelevant
# to value reading; they just have to exist so the on-state key resolves.
ap_on = b"q 0 0 20 20 re f Q"
ap_off = b"q 1 1 18 18 re S Q"
add(10, b"<< /Type /XObject /Subtype /Form /BBox [0 0 20 20] /Resources << >> "
        b"/Length %d >>\nstream\n%s\nendstream" % (len(ap_on), ap_on))
add(11, b"<< /Type /XObject /Subtype /Form /BBox [0 0 20 20] /Resources << >> "
        b"/Length %d >>\nstream\n%s\nendstream" % (len(ap_off), ap_off))

# 12: Text (sticky note) markup annotation
add(12, b"<< /Type /Annot /Subtype /Text /Rect [500 700 520 720] "
        b"/Contents (A reviewer note) /T (Reviewer) /NM (note-1) >>")

# 13: Highlight markup annotation
add(13, b"<< /Type /Annot /Subtype /Highlight /Rect [100 500 300 515] "
        b"/QuadPoints [100 515 300 515 100 500 300 500] "
        b"/Contents (Important passage) /NM (hl-1) >>")

# 14: font
add(14, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")

# 15: page content stream
content = b"BT /F1 18 Tf 72 750 Td (Form & annotation sample) Tj ET"
add(15, b"<< /Length %d >>\nstream\n%s\nendstream" % (len(content), content))


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


path = "/Users/james/Desktop/elixir/ex_pdfium/test/fixtures/forms.pdf"
with open(path, "wb") as f:
    f.write(build())
print("wrote", path)
