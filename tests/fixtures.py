from __future__ import annotations

import zipfile
from pathlib import Path


def make_epub(path: Path, encryption_marker: bool = False) -> Path:
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        zf.writestr("META-INF/container.xml", """<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""")
        if encryption_marker:
            zf.writestr("META-INF/encryption.xml", "<encryption/>")
        zf.writestr("OEBPS/content.opf", """<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Fixture Book</dc:title><dc:creator>Writer, Alex</dc:creator><meta name="cover" content="cover-image"/></metadata>
<manifest>
<item id="c1" href="chap1.xhtml" media-type="application/xhtml+xml"/>
<item id="c2" href="chap2.xhtml" media-type="application/xhtml+xml"/>
<item id="cover-image" href="images/cover.jpg" media-type="image/jpeg"/>
</manifest>
<spine><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>""")
        zf.writestr("OEBPS/chap1.xhtml", """<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><body><h1>One</h1><p>Hello world. Second sentence.</p><script>bad()</script></body></html>""")
        zf.writestr("OEBPS/chap2.xhtml", """<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><body><h1>Two</h1><p>Final chapter text.</p></body></html>""")
        zf.writestr("OEBPS/images/cover.jpg", b"fixture-cover")
    return path
