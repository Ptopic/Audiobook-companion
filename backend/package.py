from __future__ import annotations

import json
import posixpath
import shutil
import subprocess
import time
import zipfile
from pathlib import Path
from typing import Any

from .audio import wav_duration
from .epub import Book

PACKAGE_VERSION = "iphone-audiobook-v2"


def export_audiobook_package(book: Book, job: dict, dest: Path) -> dict[str, str]:
    artifacts = job.get("artifacts") or {}
    chapters = artifacts.get("chapters") or {}
    dest.mkdir(parents=True, exist_ok=True)
    audio_dir = dest / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)
    cover_file = _copy_cover(book, dest)
    chapter_by_id = {c.id: c for c in book.chapters}
    packaged_chapters = []
    for chapter_id, artifact in chapters.items():
        chapter = chapter_by_id.get(chapter_id)
        if not chapter:
            continue
        source = Path(artifact["audio"])
        audio_name = f"{chapter_id}.m4a" if _ffmpeg_path() else f"{chapter_id}.wav"
        audio_dest = audio_dir / audio_name
        _copy_or_convert_audio(source, audio_dest)
        segments = [
            {
                "id": t["id"],
                "text": t.get("text", ""),
                "start": round(float(t["begin"]), 3),
                "end": round(float(t["end"]), 3),
            }
            for t in artifact.get("timings", [])
        ]
        duration = segments[-1]["end"] if segments else round(wav_duration(audio_dest), 3)
        packaged_chapters.append(
            {
                "id": chapter.id,
                "title": chapter.title,
                "href": chapter.href,
                "duration": duration,
                "audio_file": f"audio/{audio_name}",
                "audio_path": f"audio/{audio_name}",
                "segments": segments,
            }
        )
    manifest = {
        "schema": PACKAGE_VERSION,
        "generator_version": PACKAGE_VERSION,
        "id": book.id,
        "job_id": job["id"],
        "title": book.title,
        "author": book.author,
        "cover_file": cover_file,
        "created_at": int(time.time()),
        "generator": {
            "engine": job.get("config", {}).get("engine", "unknown"),
            "voice": job.get("config", {}).get("voice", "unknown"),
            "speed": job.get("config", {}).get("speed", 1.0),
        },
        "chapters": packaged_chapters,
    }
    manifest_path = dest / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
    zip_path = dest.with_suffix(".zip")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(dest.rglob("*")):
            if path.is_file():
                zf.write(path, path.relative_to(dest).as_posix())
    return {
        "package_dir": str(dest),
        "package_manifest": str(manifest_path),
        "package_zip": str(zip_path),
    }


def _copy_cover(book: Book, dest: Path) -> str | None:
    if not book.cover_href:
        return None
    member = posixpath.normpath(posixpath.join(book.opf_dir, book.cover_href))
    suffix = Path(book.cover_href).suffix.lower() or _cover_suffix(book.cover_media_type)
    cover_name = f"cover{suffix}"
    with zipfile.ZipFile(book.source_path) as zf:
        if member not in zf.namelist():
            return None
        (dest / cover_name).write_bytes(zf.read(member))
    return cover_name


def _cover_suffix(media_type: str | None) -> str:
    return {
        "image/jpeg": ".jpg",
        "image/png": ".png",
        "image/webp": ".webp",
        "image/gif": ".gif",
        "image/svg+xml": ".svg",
    }.get(media_type or "", ".jpg")


def manifest_for_api(manifest_path: Path, job_id: str, base_url: str = "") -> dict[str, Any]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    base = base_url.rstrip("/")
    for chapter in manifest.get("chapters", []):
        chapter["audio_url"] = f"{base}/api/audiobooks/{job_id}/audio/{chapter['id']}"
    if manifest.get("cover_file"):
        manifest["cover_url"] = f"{base}/api/audiobooks/{job_id}/cover"
    return manifest


def _copy_or_convert_audio(source: Path, dest: Path) -> None:
    if dest.exists() and dest.stat().st_mtime >= source.stat().st_mtime:
        return
    if dest.suffix == ".m4a":
        ffmpeg = _ffmpeg_path()
        if ffmpeg:
            subprocess.run(
                [
                    ffmpeg,
                    "-y",
                    "-i",
                    str(source),
                    "-vn",
                    "-c:a",
                    "aac",
                    "-b:a",
                    "96k",
                    "-movflags",
                    "+faststart",
                    str(dest),
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            return
    shutil.copyfile(source, dest)


def _ffmpeg_path() -> str | None:
    return shutil.which("ffmpeg")
