from __future__ import annotations

import hashlib
import json
import posixpath
import re
import shutil
import sqlite3
import threading
import time
import zipfile
from pathlib import Path

from .audio import cache_key, concat_wavs, synthesize, wav_duration
from .epub import Book, apply_replacements, make_smil, parse_epub, wrap_chapter_xhtml, add_media_overlays_to_opf
from .package import PACKAGE_VERSION, export_audiobook_package


DATA_DIR = Path(__file__).resolve().parent.parent / "data"
UPLOAD_DIR = DATA_DIR / "uploads"
CACHE_DIR = DATA_DIR / "cache"
JOB_DIR = DATA_DIR / "jobs"
DB_PATH = DATA_DIR / "app.sqlite3"
_SAFE_JOB_ID = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")


class JobStore:
    def __init__(self) -> None:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        JOB_DIR.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._init_db()

    def _init_db(self) -> None:
        with sqlite3.connect(DB_PATH) as db:
            db.execute("create table if not exists books (id text primary key, title text, path text, manifest text)")
            db.execute("create table if not exists jobs (id text primary key, book_id text, status text, config text, progress real, message text, artifacts text)")
            db.commit()

    def save_upload(self, filename: str, content: bytes) -> Book:
        book_id = hashlib.sha256(content).hexdigest()[:16]
        dest = UPLOAD_DIR / f"{book_id}.epub"
        dest.write_bytes(content)
        book = parse_epub(dest, book_id)
        with sqlite3.connect(DB_PATH) as db:
            db.execute(
                "insert or replace into books values (?, ?, ?, ?)",
                (book.id, book.title, str(dest), json.dumps(book_to_manifest(book))),
            )
            db.commit()
        return book

    def get_book(self, book_id: str) -> Book:
        with sqlite3.connect(DB_PATH) as db:
            row = db.execute("select path from books where id=?", (book_id,)).fetchone()
        if not row:
            raise KeyError(book_id)
        return parse_epub(Path(row[0]), book_id)

    def list_books(self) -> list[dict]:
        with sqlite3.connect(DB_PATH) as db:
            rows = db.execute("select id,title,path,manifest from books order by rowid desc").fetchall()
        books = []
        for book_id, title, path, manifest_raw in rows:
            try:
                books.append(book_to_manifest(parse_epub(Path(path), book_id)))
            except Exception:
                stored = json.loads(manifest_raw)
                stored.setdefault("title", title)
                books.append(stored)
        return books

    def delete_book(self, book_id: str) -> None:
        with self._lock, sqlite3.connect(DB_PATH) as db:
            row = db.execute("select path from books where id=?", (book_id,)).fetchone()
            if not row:
                raise KeyError(book_id)
            job_rows = db.execute("select id,artifacts from jobs where book_id=?", (book_id,)).fetchall()
            db.execute("delete from jobs where book_id=?", (book_id,))
            db.execute("delete from books where id=?", (book_id,))
            db.commit()
        Path(row[0]).unlink(missing_ok=True)
        for job_id, artifacts_raw in job_rows:
            shutil.rmtree(JOB_DIR / job_id, ignore_errors=True)
            try:
                artifacts = json.loads(artifacts_raw)
            except json.JSONDecodeError:
                artifacts = {}
            export_path = artifacts.get("export_epub")
            if export_path:
                Path(export_path).unlink(missing_ok=True)

    def delete_completed_audiobook(self, job_id: str) -> dict:
        if not _SAFE_JOB_ID.fullmatch(job_id):
            raise ValueError("Invalid audiobook ID")
        with self._lock, sqlite3.connect(DB_PATH) as db:
            row = db.execute("select book_id,status from jobs where id=?", (job_id,)).fetchone()
            if not row or row[1] != "done":
                raise KeyError(job_id)
            count = self._delete_completed_jobs(db, row[0])
        return {"id": job_id, "book_id": row[0], "deleted_jobs": count}

    def delete_completed_jobs_for_book(self, book_id: str) -> int:
        if not _SAFE_JOB_ID.fullmatch(book_id):
            raise ValueError("Invalid book ID")
        with self._lock, sqlite3.connect(DB_PATH) as db:
            return self._delete_completed_jobs(db, book_id)

    def _delete_completed_jobs(self, db: sqlite3.Connection, book_id: str) -> int:
        completed = db.execute(
            "select id from jobs where book_id=? and status='done'", (book_id,)
        ).fetchall()
        for (completed_id,) in completed:
            if not _SAFE_JOB_ID.fullmatch(completed_id):
                raise ValueError("Invalid stored job ID")
            path = JOB_DIR / completed_id
            if path.exists():
                shutil.rmtree(path)
        db.execute("delete from jobs where book_id=? and status='done'", (book_id,))
        return len(completed)

    def create_job(self, book_id: str, config: dict) -> str:
        job_id = hashlib.sha256(f"{book_id}:{json.dumps(config, sort_keys=True)}:{time.time()}".encode()).hexdigest()[:16]
        with sqlite3.connect(DB_PATH) as db:
            db.execute("insert into jobs values (?, ?, ?, ?, ?, ?, ?)", (job_id, book_id, "queued", json.dumps(config), 0.0, "", "{}"))
            db.commit()
        return job_id

    def update_job(self, job_id: str, **values) -> None:
        allowed = {"status", "progress", "message", "artifacts"}
        fields = [k for k in values if k in allowed]
        if not fields:
            return
        with self._lock, sqlite3.connect(DB_PATH) as db:
            db.execute(
                f"update jobs set {', '.join(f'{f}=?' for f in fields)} where id=?",
                [json.dumps(values[f]) if f == "artifacts" else values[f] for f in fields] + [job_id],
            )
            db.commit()

    def get_job(self, job_id: str) -> dict:
        with sqlite3.connect(DB_PATH) as db:
            row = db.execute("select id,book_id,status,config,progress,message,artifacts from jobs where id=?", (job_id,)).fetchone()
        if not row:
            raise KeyError(job_id)
        return {"id": row[0], "book_id": row[1], "status": row[2], "config": json.loads(row[3]), "progress": row[4], "message": row[5], "artifacts": json.loads(row[6])}

    def list_jobs(self, book_id: str | None = None) -> list[dict]:
        with sqlite3.connect(DB_PATH) as db:
            if book_id:
                rows = db.execute("select id,book_id,status,config,progress,message,artifacts from jobs where book_id=? order by rowid desc", (book_id,)).fetchall()
            else:
                rows = db.execute("select id,book_id,status,config,progress,message,artifacts from jobs order by rowid desc").fetchall()
        return [
            {"id": r[0], "book_id": r[1], "status": r[2], "config": json.loads(r[3]), "progress": r[4], "message": r[5], "artifacts": json.loads(r[6])}
            for r in rows
        ]

    def resume_job(self, job_id: str) -> None:
        job = self.get_job(job_id)
        if job["status"] != "done":
            self.update_job(job_id, status="queued", message="Queued for resume")

    def cancel_job(self, job_id: str) -> None:
        self.update_job(job_id, status="cancelled", message="Cancelled by user")

    def is_cancelled(self, job_id: str) -> bool:
        return self.get_job(job_id)["status"] == "cancelled"


def book_to_manifest(book: Book) -> dict:
    return {
        "id": book.id,
        "title": book.title,
        "author": book.author,
        "has_cover": book.cover_href is not None,
        "chapters": [{"id": c.id, "title": c.title, "href": c.href, "text": c.text, "chunks": [{"id": x.id, "text": x.text} for x in c.chunks]} for c in book.chapters],
    }


def run_job(store: JobStore, job_id: str) -> None:
    job = store.get_job(job_id)
    book = store.get_book(job["book_id"])
    config = job["config"]
    engine = config.get("engine", "sine")
    voice = config.get("voice", "af_heart")
    speed = float(config.get("speed", 1.0))
    if config.get("include_chapters") is None:
        include = {c.id for c in book.chapters}
    else:
        include = set(config.get("include_chapters") or [])
    replacements = config.get("replacements") or {}
    replacements_hash = hashlib.sha256(json.dumps(replacements, sort_keys=True).encode()).hexdigest()
    work = JOB_DIR / job_id
    audio_dir = work / "audio"
    work.mkdir(parents=True, exist_ok=True)
    store.update_job(job_id, status="running", message="Generating audio")
    selected = [c for c in book.chapters if c.id in include]
    artifacts = {"chapters": {}, "export_epub": None}
    total_steps = max(1, sum(len(c.chunks) for c in selected))
    done = 0
    try:
        for chapter in selected:
            if store.is_cancelled(job_id):
                return
            chunk_paths: list[Path] = []
            timings = []
            cursor = 0.0
            for chunk in chapter.chunks:
                narration = apply_replacements(chunk.text, replacements)
                key = cache_key(narration, voice, speed, engine, replacements_hash)
                cached = CACHE_DIR / f"{key}.wav"
                if not cached.exists():
                    synthesize(narration, cached, engine, voice, speed)
                duration = wav_duration(cached)
                local_chunk = audio_dir / chapter.id / f"{chunk.id}.wav"
                local_chunk.parent.mkdir(parents=True, exist_ok=True)
                if not local_chunk.exists():
                    shutil.copyfile(cached, local_chunk)
                chunk_paths.append(local_chunk)
                timings.append({"id": chunk.id, "begin": cursor, "end": cursor + duration, "text": chunk.text})
                cursor += duration
                done += 1
                store.update_job(job_id, progress=done / total_steps)
            chapter_wav = audio_dir / f"{chapter.id}.wav"
            concat_wavs(chunk_paths, chapter_wav)
            artifacts["chapters"][chapter.id] = {"audio": str(chapter_wav), "timings": timings}
        export_path = export_media_overlay_epub(book, artifacts, work / f"{book.id}-aligned.epub")
        artifacts["export_epub"] = str(export_path)
        artifacts.update(export_audiobook_package(book, {**job, "artifacts": artifacts}, work / "iphone-package"))
        store.update_job(job_id, status="done", progress=1.0, message="Done. iPhone audiobook package ready.", artifacts=artifacts)
    except Exception as exc:
        store.update_job(job_id, status="failed", message=str(exc), artifacts=artifacts)


def export_media_overlay_epub(book: Book, artifacts: dict, dest: Path) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    overlays: dict[str, dict] = {}
    total_duration = 0.0
    chapter_by_id = {c.id: c for c in book.chapters}
    with zipfile.ZipFile(book.source_path) as src, zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as out:
        names = set(src.namelist())
        if "mimetype" in names:
            out.writestr("mimetype", src.read("mimetype"), compress_type=zipfile.ZIP_STORED)
        for name in src.namelist():
            if name == "mimetype":
                continue
            data = src.read(name)
            chapter = next((c for c in book.chapters if _member_for(book, c.href) == name and c.id in artifacts["chapters"]), None)
            if chapter:
                data = wrap_chapter_xhtml(data, chapter.chunks)
            if name == book.rootfile:
                continue
            out.writestr(name, data)
        for cid, ch_artifact in artifacts["chapters"].items():
            chapter = chapter_by_id[cid]
            smil_href = f"media-overlays/{cid}.smil"
            audio_href = f"audio/{cid}.wav"
            smil_chapter_href = _relative_href(smil_href, chapter.href)
            smil_audio_href = _relative_href(smil_href, audio_href)
            smil_member = _member_for(book, smil_href)
            audio_member = _member_for(book, audio_href)
            smil = make_smil(smil_chapter_href, smil_audio_href, ch_artifact["timings"])
            out.writestr(smil_member, smil)
            out.write(ch_artifact["audio"], audio_member)
            total_duration += ch_artifact["timings"][-1]["end"] if ch_artifact["timings"] else 0.0
            overlays[chapter.id] = {"smil_id": f"kaud-smil-{cid}", "smil_href": smil_href, "audio_id": f"kaud-audio-{cid}", "audio_href": audio_href}
        opf = add_media_overlays_to_opf(src.read(book.rootfile), overlays, total_duration)
        out.writestr(book.rootfile, opf)
    return dest


def _member_for(book: Book, href: str) -> str:
    return str(Path(posixpath.normpath(posixpath.join(book.opf_dir, href)))).replace("\\", "/")


def _relative_href(from_href: str, target_href: str) -> str:
    base = posixpath.dirname(from_href)
    if not base:
        return target_href
    return posixpath.relpath(target_href, start=base)


def ensure_audiobook_package(store: JobStore, job_id: str) -> dict:
    job = store.get_job(job_id)
    if job["status"] != "done":
        raise ValueError("Job is not done")
    artifacts = job.get("artifacts") or {}
    if artifacts.get("package_manifest") and artifacts.get("package_zip"):
        manifest_path = Path(artifacts["package_manifest"])
        if manifest_path.exists() and Path(artifacts["package_zip"]).exists():
            try:
                if json.loads(manifest_path.read_text(encoding="utf-8")).get("schema") == PACKAGE_VERSION:
                    return job
            except (OSError, json.JSONDecodeError):
                pass
    book = store.get_book(job["book_id"])
    artifacts.update(export_audiobook_package(book, job, JOB_DIR / job_id / "iphone-package"))
    store.update_job(job_id, artifacts=artifacts)
    job["artifacts"] = artifacts
    return job
