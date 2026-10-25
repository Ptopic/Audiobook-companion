from __future__ import annotations

import html
import posixpath
import re
import uuid
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from xml.etree import ElementTree as ET

from bs4 import BeautifulSoup, NavigableString, Tag

NS = {
    "container": "urn:oasis:names:tc:opendocument:xmlns:container",
    "opf": "http://www.idpf.org/2007/opf",
}
DC_NS = "http://purl.org/dc/elements/1.1/"
NCX_NS = "http://www.daisy.org/z3986/2005/ncx/"


class EpubError(ValueError):
    pass


@dataclass
class Chunk:
    id: str
    text: str


@dataclass
class Chapter:
    id: str
    title: str
    href: str
    media_type: str
    text: str
    chunks: list[Chunk] = field(default_factory=list)
    include: bool = True


@dataclass
class Book:
    id: str
    source_path: Path
    rootfile: str
    opf_dir: str
    title: str
    author: str | None
    cover_href: str | None
    cover_media_type: str | None
    chapters: list[Chapter]


def safe_extract_member(name: str) -> None:
    if name.startswith("/") or "\\" in name:
        raise EpubError(f"Unsafe EPUB member path: {name}")
    normalized = posixpath.normpath(name)
    if normalized == ".." or normalized.startswith("../"):
        raise EpubError(f"Unsafe EPUB member path: {name}")


def validate_epub(path: Path) -> None:
    with zipfile.ZipFile(path) as zf:
        names = set(zf.namelist())
        for name in names:
            safe_extract_member(name)


def parse_epub(path: Path, book_id: str | None = None) -> Book:
    validate_epub(path)
    with zipfile.ZipFile(path) as zf:
        container = ET.fromstring(zf.read("META-INF/container.xml"))
        rootfile_el = container.find(".//container:rootfile", NS)
        if rootfile_el is None or not rootfile_el.attrib.get("full-path"):
            raise EpubError("EPUB container is missing rootfile")
        rootfile = rootfile_el.attrib["full-path"]
        opf_dir = posixpath.dirname(rootfile)
        opf = ET.fromstring(zf.read(rootfile))
        metadata_title = opf.find(f".//{{{DC_NS}}}title")
        title = _clean_text(metadata_title.text) if metadata_title is not None else "Untitled"
        title = title or "Untitled"
        creators = [_clean_text(node.text) for node in opf.findall(f".//{{{DC_NS}}}creator")]
        author = ", ".join(_display_author(value) for value in creators if value) or None
        manifest = {
            item.attrib["id"]: item.attrib
            for item in opf.findall(".//opf:manifest/opf:item", NS)
            if "id" in item.attrib and "href" in item.attrib
        }
        cover_href, cover_media_type = _find_cover(opf, manifest, zf, opf_dir)
        toc_titles = _toc_titles(opf, manifest, zf, opf_dir)
        chapters: list[Chapter] = []
        for itemref in opf.findall(".//opf:spine/opf:itemref", NS):
            item = manifest.get(itemref.attrib.get("idref", ""))
            if not item:
                continue
            media_type = item.get("media-type", "")
            if media_type not in {"application/xhtml+xml", "text/html"}:
                continue
            href = item["href"]
            member = posixpath.normpath(posixpath.join(opf_dir, href))
            soup = BeautifulSoup(zf.read(member), "xml")
            for unwanted in soup.find_all(["script", "style", "nav"]):
                unwanted.decompose()
            chunks = extract_readable_chunks(soup)
            raw_text = " ".join(chunk.text for chunk in chunks) if chunks else soup.get_text(" ", strip=True)
            text = " ".join(raw_text.split())
            if not text:
                continue
            heading = soup.find(re.compile("^h[1-6]$"))
            heading_title = _clean_text(heading.get_text(" ", strip=True)) if heading else ""
            chapter_title = heading_title or toc_titles.get(_normalized_href(href)) or _fallback_chapter_title(href)
            cid = item.get("id") or f"chapter-{len(chapters) + 1}"
            chapters.append(Chapter(id=cid, title=chapter_title, href=href, media_type=media_type, text=text, chunks=chunks or chunk_text(text)))
    return Book(
        id=book_id or uuid.uuid4().hex,
        source_path=path,
        rootfile=rootfile,
        opf_dir=opf_dir,
        title=title,
        author=author,
        cover_href=cover_href,
        cover_media_type=cover_media_type,
        chapters=chapters,
    )


def _clean_text(value: str | None) -> str:
    return " ".join((value or "").split())


def _display_author(value: str) -> str:
    """Turn the common EPUB form `Family, Given` into a natural display name."""
    parts = [part.strip() for part in value.split(",")]
    if len(parts) == 2 and all(parts) and not re.search(r"\b(jr|sr|ii|iii|iv)\.?$", parts[1], re.I):
        return f"{parts[1]} {parts[0]}"
    return value


def _normalized_href(value: str) -> str:
    return posixpath.normpath(value.split("#", 1)[0]).lstrip("./")


def _fallback_chapter_title(href: str) -> str:
    stem = Path(_normalized_href(href)).stem
    words = re.sub(r"[_-]+", " ", stem)
    words = re.sub(r"(?i)^part0*", "Part ", words)
    return _clean_text(words).title() or "Chapter"


def _toc_titles(opf: ET.Element, manifest: dict[str, dict], zf: zipfile.ZipFile, opf_dir: str) -> dict[str, str]:
    titles: dict[str, str] = {}
    nav_item = next((item for item in manifest.values() if "nav" in item.get("properties", "").split()), None)
    if nav_item:
        member = posixpath.normpath(posixpath.join(opf_dir, nav_item["href"]))
        if member in zf.namelist():
            soup = BeautifulSoup(zf.read(member), "xml")
            nav = soup.find("nav", attrs={"epub:type": "toc"}) or soup.find("nav")
            if nav:
                for anchor in nav.find_all("a", href=True):
                    label = _clean_text(anchor.get_text(" ", strip=True))
                    target = _normalized_href(posixpath.join(posixpath.dirname(nav_item["href"]), anchor["href"]))
                    if label:
                        titles[target] = _chapter_label(label)

    spine = opf.find(".//opf:spine", NS)
    ncx_id = spine.attrib.get("toc") if spine is not None else None
    ncx_item = manifest.get(ncx_id or "") or next(
        (item for item in manifest.values() if item.get("media-type") == "application/x-dtbncx+xml"),
        None,
    )
    if ncx_item:
        member = posixpath.normpath(posixpath.join(opf_dir, ncx_item["href"]))
        if member in zf.namelist():
            ncx = ET.fromstring(zf.read(member))
            for point in ncx.findall(f".//{{{NCX_NS}}}navPoint"):
                content = point.find(f"{{{NCX_NS}}}content")
                label = point.find(f"{{{NCX_NS}}}navLabel/{{{NCX_NS}}}text")
                if content is None or label is None or not content.attrib.get("src"):
                    continue
                target = _normalized_href(posixpath.join(posixpath.dirname(ncx_item["href"]), content.attrib["src"]))
                text = _clean_text(label.text)
                if text:
                    titles.setdefault(target, _chapter_label(text))
    return titles


def _chapter_label(label: str) -> str:
    return f"Chapter {label}" if label.isdigit() else label


def _find_cover(
    opf: ET.Element,
    manifest: dict[str, dict],
    zf: zipfile.ZipFile,
    opf_dir: str,
) -> tuple[str | None, str | None]:
    cover_id = None
    for meta in opf.findall(".//opf:metadata/opf:meta", NS):
        if meta.attrib.get("name", "").lower() == "cover":
            cover_id = meta.attrib.get("content")
            break
    item = manifest.get(cover_id or "")
    if item is None:
        item = next((entry for entry in manifest.values() if "cover-image" in entry.get("properties", "").split()), None)
    if item is None:
        item = next(
            (entry for entry in manifest.values() if entry.get("media-type", "").startswith("image/") and "cover" in entry.get("href", "").lower()),
            None,
        )
    if item is None:
        return None, None
    href = item["href"]
    member = posixpath.normpath(posixpath.join(opf_dir, href))
    if member not in zf.namelist():
        return None, None
    return href, item.get("media-type") or "application/octet-stream"


def chunk_text(text: str) -> list[Chunk]:
    pieces = [p.strip() for p in re.split(r"(?<=[.!?])\s+|\n{2,}", text) if p.strip()]
    if not pieces:
        pieces = [text]
    return [Chunk(id=f"kaud-{i + 1:04d}", text=p) for i, p in enumerate(pieces)]


def extract_readable_chunks(soup: BeautifulSoup) -> list[Chunk]:
    """Return block-level chunks in document order without rebuilding XHTML."""
    body = soup.find("body")
    root = body or soup
    blocks: list[Tag] = []
    for tag in root.find_all(["h1", "h2", "h3", "h4", "h5", "h6", "p", "li", "blockquote"], recursive=True):
        if tag.find_parent(["script", "style", "nav"]):
            continue
        text = " ".join(tag.get_text(" ", strip=True).split())
        if text:
            blocks.append(tag)
    return [Chunk(id=f"kaud-{i + 1:04d}", text=" ".join(tag.get_text(" ", strip=True).split())) for i, tag in enumerate(blocks)]


def apply_replacements(text: str, replacements: dict[str, str]) -> str:
    result = text
    for src, dest in replacements.items():
        if src:
            result = result.replace(src, dest)
    return result


def wrap_chapter_xhtml(original: bytes, chunks: list[Chunk]) -> bytes:
    soup = BeautifulSoup(original, "xml")
    for unwanted in soup.find_all(["script", "style"]):
        unwanted.decompose()
    body = soup.find("body")
    if body is None:
        return original
    blocks = [
        tag for tag in body.find_all(["h1", "h2", "h3", "h4", "h5", "h6", "p", "li", "blockquote"], recursive=True)
        if " ".join(tag.get_text(" ", strip=True).split())
    ]
    for tag, chunk in zip(blocks, chunks):
        if tag.find(id=chunk.id):
            continue
        span = soup.new_tag("span", id=chunk.id)
        children = list(tag.contents)
        for child in children:
            span.append(child.extract())
        tag.append(span)
    return str(soup).encode("utf-8")


def make_smil(chapter_href: str, audio_href: str, timings: list[dict]) -> bytes:
    lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0">', "<body><seq>"]
    for timing in timings:
        lines.append(
            '<par><text src="{text}#{frag}"/><audio src="{audio}" clipBegin="{begin:.3f}s" clipEnd="{end:.3f}s"/></par>'.format(
                text=html.escape(chapter_href, quote=True),
                frag=html.escape(timing["id"], quote=True),
                audio=html.escape(audio_href, quote=True),
                begin=timing["begin"],
                end=timing["end"],
            )
        )
    lines.append("</seq></body></smil>")
    return "\n".join(lines).encode("utf-8")


def add_media_overlays_to_opf(opf_bytes: bytes, overlays: dict[str, dict], total_duration: float) -> bytes:
    text = opf_bytes.decode("utf-8")
    for item_id, overlay in overlays.items():
        pattern = re.compile(r'<item\b(?=[^>]*\bid="' + re.escape(item_id) + r'")[^>]*/?>')
        text = pattern.sub(lambda m: _ensure_item_attr(m.group(0), "media-overlay", overlay["smil_id"]), text, count=1)
    manifest_items = []
    for overlay in overlays.values():
        manifest_items.append(f'<item id="{overlay["smil_id"]}" href="{overlay["smil_href"]}" media-type="application/smil+xml"/>')
        manifest_items.append(f'<item id="{overlay["audio_id"]}" href="{overlay["audio_href"]}" media-type="audio/wav"/>')
    text = text.replace("</manifest>", "\n" + "\n".join(manifest_items) + "\n</manifest>")
    if "media:active-class" not in text:
        text = text.replace("</metadata>", f'\n<meta property="media:active-class">kaud-active</meta>\n<meta property="media:duration">{total_duration:.3f}s</meta>\n</metadata>')
    return text.encode("utf-8")


def _ensure_attr(tag_start: str, name: str, value: str) -> str:
    if re.search(r"\b" + re.escape(name) + r"\s*=", tag_start):
        return re.sub(r'\b' + re.escape(name) + r'\s*=\s*"[^"]*"', f'{name}="{value}"', tag_start)
    return f'{tag_start} {name}="{value}"'


def _ensure_item_attr(item_tag: str, name: str, value: str) -> str:
    stripped = item_tag.rstrip()
    self_closing = stripped.endswith("/>")
    end = "/>" if self_closing else ">"
    tag_start = re.sub(r"\s*/?>\s*$", "", item_tag)
    return _ensure_attr(tag_start, name, value) + end
