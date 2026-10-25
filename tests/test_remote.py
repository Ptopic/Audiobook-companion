from __future__ import annotations

import sqlite3
import time
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from backend import jobs
from backend.main import app
from tests.fixtures import make_epub


@pytest.fixture
def remote(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(jobs, "DATA_DIR", tmp_path / "data")
    monkeypatch.setenv("AUDIOBOOK_REMOTE_TOKEN", "secret-test-token")
    client = TestClient(app)
    headers = {"Authorization": "Bearer secret-test-token"}
    return client, headers, tmp_path


def _upload(client: TestClient, headers: dict, tmp_path: Path) -> dict:
    epub = make_epub(tmp_path / "book.epub")
    with epub.open("rb") as fh:
        response = client.post("/api/remote/books", files={"file": ("book.epub", fh, "application/epub+zip")}, headers=headers)
    assert response.status_code == 200, response.text
    return response.json()


def _queue(client: TestClient, headers: dict, book_id: str) -> str:
    response = client.post(
        f"/api/remote/books/{book_id}/jobs",
        json={"include_chapters": ["c2", "c1"], "voice": "af_heart", "speed": 1.2},
        headers=headers,
    )
    assert response.status_code == 200, response.text
    return response.json()["job_id"]


def test_authentication_fails_closed(remote, monkeypatch: pytest.MonkeyPatch):
    client, headers, _ = remote
    assert client.get("/api/remote/jobs").status_code == 401
    assert client.get("/api/remote/jobs", headers={"Authorization": "Bearer wrong"}).status_code == 401
    monkeypatch.delenv("AUDIOBOOK_REMOTE_TOKEN")
    assert client.get("/api/remote/jobs", headers=headers).status_code == 503
    assert client.post("/api/remote/worker/claim", headers=headers).status_code == 503


def test_legacy_mutations_require_token_only_in_remote_mode(remote, monkeypatch: pytest.MonkeyPatch):
    client, headers, _ = remote
    mutations = [
        ("post", "/api/books", {"files": {"file": ("bad.txt", b"x")}}),
        ("delete", "/api/books/missing", {}),
        ("post", "/api/books/missing/jobs", {"json": {"engine": "invalid"}}),
        ("post", "/api/preview", {"json": {"text": "Hello", "engine": "invalid"}}),
        ("post", "/api/jobs/missing/resume", {}),
        ("post", "/api/jobs/missing/cancel", {}),
        ("post", "/api/audiobooks/missing/upload-s3", {}),
    ]
    for method, path, kwargs in mutations:
        call = getattr(client, method)
        assert call(path, **kwargs).status_code == 401, path
        assert call(path, headers={"Authorization": "Bearer wrong"}, **kwargs).status_code == 401, path
        assert call(path, headers=headers, **kwargs).status_code != 401, path
    assert client.get("/api/audiobooks/missing/manifest").status_code == 404
    monkeypatch.delenv("AUDIOBOOK_REMOTE_TOKEN")
    for method, path, kwargs in mutations:
        assert getattr(client, method)(path, **kwargs).status_code != 401, path


def test_upload_spine_order_and_queue_validation(remote):
    client, headers, tmp_path = remote
    book = _upload(client, headers, tmp_path)
    assert book["title"] == "Fixture Book"
    assert book["author"] == "Alex Writer"
    assert [chapter["id"] for chapter in book["chapters"]] == ["c1", "c2"]
    assert [chapter["title"] for chapter in book["chapters"]] == ["One", "Two"]
    assert book["chapters"][0]["word_count"] > 0
    assert "bad()" not in book["chapters"][0]["preview"]
    url = f"/api/remote/books/{book['id']}/jobs"
    for payload in (
        {"include_chapters": []},
        {"include_chapters": ["missing"]},
        {"include_chapters": ["c1", "c1"]},
        {"include_chapters": ["c1"], "voice": "invalid"},
        {"include_chapters": ["c1"], "speed": 3.0},
    ):
        assert client.post(url, json=payload, headers=headers).status_code == 400
    job_id = _queue(client, headers, book["id"])
    job = client.get(f"/api/remote/jobs/{job_id}", headers=headers).json()
    assert job["book_id"] == book["id"]
    assert job["status"] == "queued"
    assert job["config"]["include_chapters"] == ["c2", "c1"]
    assert [item["id"] for item in client.get("/api/remote/jobs", headers=headers).json()] == [job_id]


def test_claim_epub_progress_and_stale_recovery(remote):
    client, headers, tmp_path = remote
    book = _upload(client, headers, tmp_path)
    first_id = _queue(client, headers, book["id"])
    claimed = client.post("/api/remote/worker/claim", headers=headers).json()
    assert claimed["id"] == first_id
    assert claimed["status"] == "running"
    assert claimed["config"]["voice"] == "af_heart"
    lease_headers = {**headers, "X-Remote-Lease": claimed["lease_token"]}
    assert client.post("/api/remote/worker/claim", headers=headers).status_code == 204
    assert client.get(claimed["epub_url"], headers=headers).status_code == 409
    epub_response = client.get(claimed["epub_url"], headers=lease_headers)
    assert epub_response.status_code == 200
    assert epub_response.content == (tmp_path / "book.epub").read_bytes()
    progress_url = f"/api/remote/worker/jobs/{first_id}/progress"
    response = client.post(progress_url, json={"status": "running", "progress": 0.5, "message": "Chapter 1"}, headers=lease_headers)
    assert response.status_code == 200
    assert response.json()["progress"] == 0.5
    assert client.post(progress_url, json={"status": "done", "progress": 1.0, "message": "Ready", "manifest_url": "http://bad.test/manifest.json"}, headers=lease_headers).status_code == 400
    response = client.post(progress_url, json={"status": "done", "progress": 1.0, "message": "Ready", "manifest_url": "https://cdn.test/manifest.json"}, headers=lease_headers)
    assert response.status_code == 200
    assert response.json()["manifest_url"] == "https://cdn.test/manifest.json"
    assert client.post(progress_url, json={"status": "running", "progress": 1.0}, headers=lease_headers).status_code == 409

    second_id = _queue(client, headers, book["id"])
    old_claim = client.post("/api/remote/worker/claim", headers=headers).json()
    assert old_claim["id"] == second_id
    old_headers = {**headers, "X-Remote-Lease": old_claim["lease_token"]}
    assert client.post(f"/api/remote/worker/jobs/{second_id}/progress", json={"status": "running", "progress": 0.3}, headers=old_headers).status_code == 200
    db_path = jobs.DATA_DIR / "remote" / "queue.sqlite3"
    with sqlite3.connect(db_path) as db:
        db.execute("UPDATE jobs SET lease_until=? WHERE id=?", (time.time() - 1, second_id))
    new_claim = client.post("/api/remote/worker/claim", headers=headers).json()
    assert new_claim["id"] == second_id
    assert new_claim["progress"] == 0
    assert new_claim["lease_token"] != old_claim["lease_token"]
    assert client.post(f"/api/remote/worker/jobs/{second_id}/progress", json={"status": "done", "progress": 1.0}, headers={**headers, "X-Remote-Lease": old_claim["lease_token"]}).status_code == 409


def test_claim_is_atomic(remote):
    client, headers, tmp_path = remote
    book = _upload(client, headers, tmp_path)
    job_id = _queue(client, headers, book["id"])
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: client.post("/api/remote/worker/claim", headers=headers), range(2)))
    assert sorted(response.status_code for response in results) == [200, 204]
    assert next(response.json() for response in results if response.status_code == 200)["id"] == job_id


def test_failed_job_can_retry_without_reupload(remote):
    client, headers, tmp_path = remote
    book = _upload(client, headers, tmp_path)
    job_id = _queue(client, headers, book["id"])
    retry_url = f"/api/remote/jobs/{job_id}/retry"
    assert client.post(retry_url, headers=headers).status_code == 409
    assert client.post("/api/remote/jobs/missing/retry", headers=headers).status_code == 404
    claimed = client.post("/api/remote/worker/claim", headers=headers).json()
    worker_headers = {**headers, "X-Remote-Lease": claimed["lease_token"]}
    failed = client.post(
        f"/api/remote/worker/jobs/{job_id}/progress",
        json={"status": "failed", "progress": 0.4, "message": "S3 upload failed"},
        headers=worker_headers,
    )
    assert failed.status_code == 200
    assert failed.json()["status"] == "failed"
    assert client.post(retry_url).status_code == 401
    retried = client.post(retry_url, headers=headers)
    assert retried.status_code == 200
    assert retried.json()["id"] == job_id
    assert retried.json()["status"] == "queued"
    assert retried.json()["progress"] == 0
    assert retried.json()["manifest_url"] is None
    assert client.post(retry_url, headers=headers).status_code == 409
    reclaimed = client.post("/api/remote/worker/claim", headers=headers).json()
    assert reclaimed["id"] == job_id
    assert reclaimed["lease_token"] != claimed["lease_token"]
    assert client.post(
        f"/api/remote/worker/jobs/{job_id}/progress",
        json={"status": "running", "progress": 0.1},
        headers=worker_headers,
    ).status_code == 409


def test_bad_epub_is_rejected(remote):
    client, headers, tmp_path = remote
    response = client.post("/api/remote/books", files={"file": ("bad.epub", b"not a zip", "application/epub+zip")}, headers=headers)
    assert response.status_code == 400
    bad = tmp_path / "bomb.epub"
    with zipfile.ZipFile(bad, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("huge.txt", b"x" * (21 * 1024 * 1024))
    with bad.open("rb") as fh:
        response = client.post("/api/remote/books", files={"file": ("bomb.epub", fh, "application/epub+zip")}, headers=headers)
    assert response.status_code == 400
    malformed = tmp_path / "malformed.epub"
    with zipfile.ZipFile(malformed, "w") as zf:
        zf.writestr("META-INF/container.xml", "<invalid")
    with malformed.open("rb") as fh:
        response = client.post("/api/remote/books", files={"file": ("malformed.epub", fh, "application/epub+zip")}, headers=headers)
    assert response.status_code == 400
