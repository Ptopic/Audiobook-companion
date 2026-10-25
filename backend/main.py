from __future__ import annotations

from pathlib import Path

from fastapi import BackgroundTasks, Depends, FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from .audio import cache_key, synthesize
from .epub import EpubError
from .cloud import S3Config, catalog_items, delete_catalog_audiobook, get_catalog_audiobook, upload_package, valid_catalog_id
from .jobs import CACHE_DIR, JobStore, book_to_manifest, ensure_audiobook_package, run_job
from .package import manifest_for_api
from .remote import authenticate_when_configured, router as remote_router

BASE = Path(__file__).resolve().parent.parent
store = JobStore()
app = FastAPI(title="Kindle Audio Books", docs_url="/api/docs", redoc_url=None)


class GenerateRequest(BaseModel):
    engine: str = "kokoro"
    voice: str = "af_heart"
    speed: float = 1.0
    include_chapters: list[str] | None = None
    replacements: dict[str, str] = {}


class PreviewRequest(BaseModel):
    text: str
    engine: str = "kokoro"
    voice: str = "af_heart"
    speed: float = 1.0


@app.get("/api/health")
def health() -> dict:
    return {"ok": True, "host": "127.0.0.1", "network": "local-only"}


@app.get("/api/voices")
def voices() -> dict:
    return {
        "engines": [
            {
                "id": "kokoro",
                "name": "Kokoro MLX",
                "offline": True,
                "model": "mlx-community/Kokoro-82M-bf16",
                "voices": ["af_heart", "af_bella", "af_nicole", "af_sarah", "am_adam", "am_michael", "bf_emma", "bm_george"],
            },
            {"id": "sine", "name": "Sine test tone (not speech)", "offline": True, "voices": ["test_tone"]},
        ],
        "kindle_playback_verified": False,
    }


@app.post("/api/books", dependencies=[Depends(authenticate_when_configured)])
async def upload_book(file: UploadFile = File(...)) -> dict:
    if not file.filename.lower().endswith(".epub"):
        raise HTTPException(400, "Upload a .epub file")
    content = await file.read()
    try:
        book = store.save_upload(file.filename, content)
    except EpubError as exc:
        raise HTTPException(400, str(exc)) from exc
    return book_to_manifest(book)


@app.get("/api/books")
def list_books() -> list[dict]:
    return store.list_books()


@app.get("/api/books/{book_id}")
def get_book(book_id: str) -> dict:
    try:
        return book_to_manifest(store.get_book(book_id))
    except KeyError as exc:
        raise HTTPException(404, "Book not found") from exc


@app.delete("/api/books/{book_id}", dependencies=[Depends(authenticate_when_configured)])
def delete_book(book_id: str) -> dict:
    try:
        store.delete_book(book_id)
    except KeyError as exc:
        raise HTTPException(404, "Book not found") from exc
    return {"ok": True}


@app.post("/api/books/{book_id}/jobs", dependencies=[Depends(authenticate_when_configured)])
def create_job(book_id: str, req: GenerateRequest, background: BackgroundTasks) -> dict:
    try:
        store.get_book(book_id)
    except KeyError as exc:
        raise HTTPException(404, "Book not found") from exc
    if req.engine not in {"sine", "kokoro"}:
        raise HTTPException(400, "Engine must be sine or kokoro")
    if not 0.4 <= req.speed <= 2.5:
        raise HTTPException(400, "Speed must be between 0.4 and 2.5")
    if req.include_chapters is not None and len(req.include_chapters) == 0:
        raise HTTPException(400, "Select at least one chapter to generate")
    job_id = store.create_job(book_id, req.model_dump())
    background.add_task(run_job, store, job_id)
    return {"job_id": job_id}


@app.post("/api/preview", dependencies=[Depends(authenticate_when_configured)])
def preview(req: PreviewRequest) -> FileResponse:
    if req.engine not in {"sine", "kokoro"}:
        raise HTTPException(400, "Engine must be sine or kokoro")
    if not 0.4 <= req.speed <= 2.5:
        raise HTTPException(400, "Speed must be between 0.4 and 2.5")
    text = " ".join(req.text.split())[:600] or "Preview"
    key = cache_key(text, req.voice, req.speed, req.engine, "preview")
    path = CACHE_DIR / f"preview-{key}.wav"
    if not path.exists():
        try:
            synthesize(text, path, req.engine, req.voice, req.speed)
        except Exception as exc:
            raise HTTPException(400, str(exc)) from exc
    return FileResponse(path, media_type="audio/wav")


@app.get("/api/jobs/{job_id}")
def get_job(job_id: str) -> dict:
    try:
        return store.get_job(job_id)
    except KeyError as exc:
        raise HTTPException(404, "Job not found") from exc


@app.get("/api/jobs")
def list_jobs(book_id: str | None = None) -> list[dict]:
    return store.list_jobs(book_id)


@app.post("/api/jobs/{job_id}/resume", dependencies=[Depends(authenticate_when_configured)])
def resume_job(job_id: str, background: BackgroundTasks) -> dict:
    try:
        store.resume_job(job_id)
    except KeyError as exc:
        raise HTTPException(404, "Job not found") from exc
    background.add_task(run_job, store, job_id)
    return {"ok": True}


@app.post("/api/jobs/{job_id}/cancel", dependencies=[Depends(authenticate_when_configured)])
def cancel_job(job_id: str) -> dict:
    store.cancel_job(job_id)
    return {"ok": True}


@app.get("/api/jobs/{job_id}/audio/{chapter_id}")
def chapter_audio(job_id: str, chapter_id: str) -> FileResponse:
    job = store.get_job(job_id)
    chapter = job["artifacts"].get("chapters", {}).get(chapter_id)
    if not chapter:
        raise HTTPException(404, "Audio not ready")
    return FileResponse(chapter["audio"], media_type="audio/wav")


@app.get("/api/jobs/{job_id}/export")
def export(job_id: str) -> FileResponse:
    job = store.get_job(job_id)
    path = job["artifacts"].get("export_epub")
    if not path:
        raise HTTPException(404, "Export not ready")
    return FileResponse(path, filename=Path(path).name, media_type="application/epub+zip")


@app.get("/api/audiobooks")
def list_audiobooks() -> list[dict]:
    items_by_book: dict[str, dict] = {}
    for job in store.list_jobs():
        if job["status"] != "done":
            continue
        try:
            packaged = ensure_audiobook_package(store, job["id"])
            book = store.get_book(packaged["book_id"])
        except Exception:
            continue
        artifacts = packaged["artifacts"]
        manifest = manifest_for_api(Path(artifacts["package_manifest"]), packaged["id"])
        chapters = [
            {"id": chapter["id"], "duration": chapter.get("duration", 0)}
            for chapter in manifest.get("chapters", [])
        ]
        if book.id not in items_by_book:
            items_by_book[book.id] = {
                "id": packaged["id"],
                "book_id": book.id,
                "title": book.title,
                "author": book.author,
                "cover_url": manifest.get("cover_url"),
                "duration": sum(float(chapter["duration"]) for chapter in chapters),
                "chapters": chapters,
                "manifest_url": f"/api/audiobooks/{packaged['id']}/manifest",
                "package_url": f"/api/audiobooks/{packaged['id']}/package",
                "s3": artifacts.get("s3"),
            }
    config = S3Config.from_env()
    if config:
        for item in catalog_items(config):
            book_id = item.get("book_id")
            if book_id:
                items_by_book[book_id] = item
    return list(items_by_book.values())


@app.delete("/api/audiobooks/{audiobook_id}", dependencies=[Depends(authenticate_when_configured)])
def delete_audiobook(audiobook_id: str) -> dict:
    if not valid_catalog_id(audiobook_id):
        raise HTTPException(400, "Invalid audiobook ID")
    remote = None
    config = S3Config.from_env()
    if config:
        try:
            remote = get_catalog_audiobook(config, audiobook_id)
        except ValueError as exc:
            raise HTTPException(400, str(exc)) from exc
        except Exception as exc:
            raise HTTPException(502, "Could not read S3 audiobook catalog") from exc

    try:
        if remote:
            store.delete_completed_jobs_for_book(remote["book_id"])
        else:
            store.delete_completed_audiobook(audiobook_id)
    except KeyError as exc:
        raise HTTPException(404, "Audiobook not found") from exc
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    except OSError as exc:
        raise HTTPException(500, "Could not remove local audiobook files") from exc

    if remote:
        try:
            delete_catalog_audiobook(config, audiobook_id, expected_book_id=remote["book_id"])
        except ValueError as exc:
            raise HTTPException(409, str(exc)) from exc
        except Exception as exc:
            raise HTTPException(502, "Could not delete S3 audiobook") from exc
    return {"ok": True, "id": audiobook_id}


@app.get("/api/audiobooks/{job_id}/manifest")
def audiobook_manifest(job_id: str) -> JSONResponse:
    try:
        job = ensure_audiobook_package(store, job_id)
    except KeyError as exc:
        raise HTTPException(404, "Audiobook not found") from exc
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    manifest = manifest_for_api(Path(job["artifacts"]["package_manifest"]), job_id)
    return JSONResponse(manifest)


@app.get("/api/audiobooks/{job_id}/audio/{chapter_id}")
def audiobook_audio(job_id: str, chapter_id: str) -> FileResponse:
    try:
        job = ensure_audiobook_package(store, job_id)
    except KeyError as exc:
        raise HTTPException(404, "Audiobook not found") from exc
    manifest = manifest_for_api(Path(job["artifacts"]["package_manifest"]), job_id)
    chapter = next((c for c in manifest.get("chapters", []) if c["id"] == chapter_id), None)
    if not chapter:
        raise HTTPException(404, "Chapter not found")
    path = Path(job["artifacts"]["package_dir"]) / chapter["audio_file"]
    media_type = "audio/mp4" if path.suffix == ".m4a" else "audio/wav"
    return FileResponse(path, media_type=media_type)


@app.get("/api/audiobooks/{job_id}/cover")
def audiobook_cover(job_id: str) -> FileResponse:
    try:
        job = ensure_audiobook_package(store, job_id)
    except KeyError as exc:
        raise HTTPException(404, "Audiobook not found") from exc
    manifest = manifest_for_api(Path(job["artifacts"]["package_manifest"]), job_id)
    cover_file = manifest.get("cover_file")
    if not cover_file:
        raise HTTPException(404, "Cover not found")
    path = Path(job["artifacts"]["package_dir"]) / cover_file
    media_types = {
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".png": "image/png",
        ".webp": "image/webp",
        ".gif": "image/gif",
        ".svg": "image/svg+xml",
    }
    return FileResponse(path, media_type=media_types.get(path.suffix.lower(), "application/octet-stream"))


@app.get("/api/audiobooks/{job_id}/package")
def audiobook_package(job_id: str) -> FileResponse:
    try:
        job = ensure_audiobook_package(store, job_id)
    except KeyError as exc:
        raise HTTPException(404, "Audiobook not found") from exc
    path = Path(job["artifacts"]["package_zip"])
    return FileResponse(path, filename=path.name, media_type="application/zip")


@app.post("/api/audiobooks/{job_id}/upload-s3", dependencies=[Depends(authenticate_when_configured)])
def upload_audiobook_to_s3(job_id: str) -> dict:
    config = S3Config.from_env()
    if not config:
        raise HTTPException(400, "Set S3_BUCKET or AUDIOBOOK_S3_BUCKET before uploading")
    try:
        job = ensure_audiobook_package(store, job_id)
    except KeyError as exc:
        raise HTTPException(404, "Audiobook not found") from exc
    manifest = manifest_for_api(Path(job["artifacts"]["package_manifest"]), job_id)
    try:
        result = upload_package(Path(job["artifacts"]["package_dir"]), manifest, config)
    except Exception as exc:
        raise HTTPException(400, str(exc)) from exc
    artifacts = job["artifacts"]
    artifacts["s3"] = result
    store.update_job(job_id, artifacts=artifacts)
    return result


app.include_router(remote_router)
app.mount("/", StaticFiles(directory=BASE / "static", html=True), name="static")
