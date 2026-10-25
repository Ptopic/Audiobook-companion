from __future__ import annotations

import hashlib
import hmac
import json
import math
import os
import secrets
import sqlite3
import time
import zipfile
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator
from xml.etree.ElementTree import ParseError

from fastapi import APIRouter, Depends, File, Header, HTTPException, UploadFile
from fastapi.responses import FileResponse, Response
from pydantic import BaseModel, Field

from . import jobs
from .epub import EpubError, parse_epub, safe_extract_member

MAX_UPLOAD = 75 * 1024 * 1024
MAX_EXPANDED = 250 * 1024 * 1024
LEASE_SECONDS = 600
VOICES = {"af_heart", "af_bella", "af_nicole", "af_sarah", "am_adam", "am_michael", "bf_emma", "bm_george"}


def _authenticate(authorization: str | None = Header(default=None)) -> None:
    token = os.environ.get("AUDIOBOOK_REMOTE_TOKEN")
    if not token:
        raise HTTPException(503, "Remote service is not configured")
    if not authorization or not authorization.startswith("Bearer ") or not hmac.compare_digest(authorization[7:], token):
        raise HTTPException(401, "Invalid remote token", headers={"WWW-Authenticate": "Bearer"})


def authenticate_when_configured(authorization: str | None = Header(default=None)) -> None:
    if os.environ.get("AUDIOBOOK_REMOTE_TOKEN"):
        _authenticate(authorization)


router = APIRouter(prefix="/api/remote", dependencies=[Depends(_authenticate)])


def _paths() -> tuple[Path, Path]:
    root = jobs.DATA_DIR / "remote"
    root.mkdir(parents=True, exist_ok=True)
    uploads = root / "uploads"
    uploads.mkdir(parents=True, exist_ok=True)
    return root / "queue.sqlite3", uploads


@contextmanager
def _db() -> Iterator[sqlite3.Connection]:
    db_path, _ = _paths()
    db = sqlite3.connect(db_path, timeout=30)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA busy_timeout=30000")
    db.execute("""CREATE TABLE IF NOT EXISTS books (
        id TEXT PRIMARY KEY, title TEXT NOT NULL, author TEXT, path TEXT NOT NULL,
        chapters TEXT NOT NULL, created_at REAL NOT NULL
    )""")
    db.execute("""CREATE TABLE IF NOT EXISTS jobs (
        id TEXT PRIMARY KEY, book_id TEXT NOT NULL, status TEXT NOT NULL,
        config TEXT NOT NULL, progress REAL NOT NULL, message TEXT NOT NULL,
        manifest_url TEXT, lease_token TEXT, lease_until REAL,
        created_at REAL NOT NULL, updated_at REAL NOT NULL
    )""")
    db.commit()
    try:
        with db:
            yield db
    finally:
        db.close()


def _summary(db: sqlite3.Connection, row: sqlite3.Row) -> dict:
    book = db.execute("SELECT title,author FROM books WHERE id=?", (row["book_id"],)).fetchone()
    return {
        "id": row["id"], "book_id": row["book_id"],
        "title": book["title"] if book else "Untitled",
        "author": book["author"] if book else None,
        "status": row["status"], "progress": row["progress"],
        "message": row["message"], "manifest_url": row["manifest_url"],
        "config": json.loads(row["config"]),
        "created_at": row["created_at"], "updated_at": row["updated_at"],
    }


def _book(db: sqlite3.Connection, book_id: str) -> sqlite3.Row:
    row = db.execute("SELECT * FROM books WHERE id=?", (book_id,)).fetchone()
    if row is None:
        raise HTTPException(404, "Book not found")
    return row


def _job(db: sqlite3.Connection, job_id: str) -> sqlite3.Row:
    row = db.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
    if row is None:
        raise HTTPException(404, "Job not found")
    return row


def _validate_zip(path: Path) -> None:
    try:
        with zipfile.ZipFile(path) as zf:
            infos = zf.infolist()
            if not infos or len(infos) > 1000:
                raise EpubError("EPUB has too many or no members")
            expanded = 0
            for info in infos:
                safe_extract_member(info.filename)
                if info.flag_bits & 1:
                    raise EpubError("Encrypted EPUB members are not supported")
                if info.file_size > 20 * 1024 * 1024:
                    raise EpubError("EPUB member exceeds size limit")
                expanded += info.file_size
                if expanded > MAX_EXPANDED or (info.file_size > 1024 * 1024 and info.file_size > 200 * max(info.compress_size, 1)):
                    raise EpubError("EPUB expands beyond size limit")
            if zf.testzip() is not None:
                raise EpubError("EPUB contains a damaged member")
    except (zipfile.BadZipFile, OSError, RuntimeError) as exc:
        raise EpubError("Invalid EPUB archive") from exc


class QueueRequest(BaseModel):
    include_chapters: list[str]
    voice: str = "af_heart"
    speed: float = 1.0
    replacements: dict[str, str] = Field(default_factory=dict)


class ProgressRequest(BaseModel):
    status: str
    progress: float
    message: str = ""
    manifest_url: str | None = None


@router.post("/books")
async def upload_book(file: UploadFile = File(...)) -> dict:
    if not file.filename or not file.filename.lower().endswith(".epub"):
        raise HTTPException(400, "Upload a .epub file")
    _, uploads = _paths()
    temp = uploads / f".{secrets.token_hex(16)}.tmp"
    digest = hashlib.sha256()
    size = 0
    try:
        with temp.open("wb") as out:
            while chunk := await file.read(1024 * 1024):
                size += len(chunk)
                if size > MAX_UPLOAD:
                    raise HTTPException(413, "EPUB exceeds 75 MB limit")
                digest.update(chunk)
                out.write(chunk)
        if size == 0:
            raise HTTPException(400, "Empty EPUB")
        _validate_zip(temp)
        book_id = digest.hexdigest()[:16]
        book = parse_epub(temp, book_id)
        if not book.chapters:
            raise EpubError("EPUB has no readable chapters")
        chapters = [
            {"id": c.id, "title": c.title, "preview": c.text[:240], "word_count": len(c.text.split())}
            for c in book.chapters
        ]
        if len({c["id"] for c in chapters}) != len(chapters):
            raise EpubError("EPUB has duplicate chapter IDs")
        dest = uploads / f"{book_id}.epub"
        temp.replace(dest)
        with _db() as db:
            db.execute(
                "INSERT OR REPLACE INTO books VALUES (?,?,?,?,?,?)",
                (book_id, book.title, book.author, str(dest), json.dumps(chapters), time.time()),
            )
        return {"id": book_id, "title": book.title, "author": book.author, "chapters": chapters}
    except EpubError as exc:
        raise HTTPException(400, str(exc)) from exc
    except (KeyError, ValueError, ParseError, zipfile.BadZipFile) as exc:
        raise HTTPException(400, "Malformed EPUB") from exc
    finally:
        temp.unlink(missing_ok=True)


@router.post("/books/{book_id}/jobs")
def create_job(book_id: str, req: QueueRequest) -> dict:
    if not req.include_chapters or len(req.include_chapters) != len(set(req.include_chapters)):
        raise HTTPException(400, "Select at least one unique chapter")
    if req.voice not in VOICES:
        raise HTTPException(400, "Unknown voice")
    if not math.isfinite(req.speed) or not 0.4 <= req.speed <= 2.5:
        raise HTTPException(400, "Speed must be between 0.4 and 2.5")
    if len(req.replacements) > 100 or any(len(k) > 200 or len(v) > 200 or not k for k, v in req.replacements.items()):
        raise HTTPException(400, "Invalid replacements")
    with _db() as db:
        book = _book(db, book_id)
        chapter_ids = {c["id"] for c in json.loads(book["chapters"])}
        if not set(req.include_chapters) <= chapter_ids:
            raise HTTPException(400, "Unknown chapter ID")
        job_id = secrets.token_hex(12)
        now = time.time()
        config = req.model_dump()
        db.execute(
            "INSERT INTO jobs VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (job_id, book_id, "queued", json.dumps(config), 0.0, "Queued", None, None, None, now, now),
        )
    return {"job_id": job_id}


@router.get("/jobs")
def list_jobs() -> list[dict]:
    with _db() as db:
        rows = db.execute("SELECT * FROM jobs ORDER BY created_at DESC").fetchall()
        return [_summary(db, row) for row in rows]


@router.get("/jobs/{job_id}")
def get_job(job_id: str) -> dict:
    with _db() as db:
        return _summary(db, _job(db, job_id))


@router.post("/jobs/{job_id}/retry")
def retry_job(job_id: str) -> dict:
    with _db() as db:
        db.execute("BEGIN IMMEDIATE")
        row = _job(db, job_id)
        if row["status"] != "failed":
            raise HTTPException(409, "Only failed jobs can be retried")
        db.execute(
            "UPDATE jobs SET status='queued', progress=0, message='Queued for retry', "
            "manifest_url=NULL, lease_token=NULL, lease_until=NULL, updated_at=? WHERE id=?",
            (time.time(), job_id),
        )
        return _summary(db, _job(db, job_id))


@router.post("/worker/claim")
def claim_job():
    with _db() as db:
        db.execute("BEGIN IMMEDIATE")
        now = time.time()
        row = db.execute(
            "SELECT * FROM jobs WHERE status='queued' OR (status='running' AND lease_until<?) ORDER BY created_at LIMIT 1",
            (now,),
        ).fetchone()
        if row is None:
            return Response(status_code=204)
        lease_token = secrets.token_hex(24)
        db.execute(
            "UPDATE jobs SET status='running', progress=?, message='Claimed by worker', manifest_url=NULL, lease_token=?, lease_until=?, updated_at=? WHERE id=?",
            (0.0 if row["status"] == "running" else row["progress"], lease_token, now + LEASE_SECONDS, now, row["id"]),
        )
        claimed = _job(db, row["id"])
        return {**_summary(db, claimed), "epub_url": f"/api/remote/worker/jobs/{row['id']}/epub", "lease_token": lease_token}


def _leased_job(db: sqlite3.Connection, job_id: str, lease: str | None) -> sqlite3.Row:
    row = _job(db, job_id)
    if row["status"] != "running" or not lease or not row["lease_token"] or not hmac.compare_digest(lease, row["lease_token"]) or (row["lease_until"] or 0) < time.time():
        raise HTTPException(409, "Worker lease is no longer valid")
    return row


@router.get("/worker/jobs/{job_id}/epub")
def worker_epub(job_id: str, x_remote_lease: str | None = Header(default=None)) -> FileResponse:
    with _db() as db:
        row = _leased_job(db, job_id, x_remote_lease)
        book = _book(db, row["book_id"])
        path = Path(book["path"])
    if not path.is_file():
        raise HTTPException(404, "EPUB not found")
    return FileResponse(path, filename=f"{row['book_id']}.epub", media_type="application/epub+zip")


@router.post("/worker/jobs/{job_id}/progress")
def worker_progress(job_id: str, req: ProgressRequest, x_remote_lease: str | None = Header(default=None)) -> dict:
    if req.status not in {"running", "done", "failed"}:
        raise HTTPException(400, "Invalid status")
    if not math.isfinite(req.progress) or not 0 <= req.progress <= 1:
        raise HTTPException(400, "Progress must be between 0 and 1")
    if req.manifest_url is not None and not req.manifest_url.startswith("https://"):
        raise HTTPException(400, "Manifest URL must use HTTPS")
    with _db() as db:
        db.execute("BEGIN IMMEDIATE")
        row = _leased_job(db, job_id, x_remote_lease)
        if req.progress < row["progress"]:
            raise HTTPException(400, "Progress cannot decrease")
        now = time.time()
        db.execute(
            "UPDATE jobs SET status=?,progress=?,message=?,manifest_url=?,lease_until=?,lease_token=?,updated_at=? WHERE id=?",
            (
                req.status, req.progress, req.message[:1000], req.manifest_url or row["manifest_url"],
                now + LEASE_SECONDS if req.status == "running" else None,
                x_remote_lease if req.status == "running" else None,
                now, job_id,
            ),
        )
        return _summary(db, _job(db, job_id))
