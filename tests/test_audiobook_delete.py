from __future__ import annotations

import json
import sys
import types
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

import backend.jobs as jobs
import backend.main as main
from tests.fixtures import make_epub


@pytest.fixture
def isolated_store(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> jobs.JobStore:
    data = tmp_path / "data"
    monkeypatch.setattr(jobs, "DATA_DIR", data)
    monkeypatch.setattr(jobs, "UPLOAD_DIR", data / "uploads")
    monkeypatch.setattr(jobs, "CACHE_DIR", data / "cache")
    monkeypatch.setattr(jobs, "JOB_DIR", data / "jobs")
    monkeypatch.setattr(jobs, "DB_PATH", data / "app.sqlite3")
    for name in ("S3_BUCKET", "AUDIOBOOK_S3_BUCKET", "S3_BUCKET_NAME"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.delenv("AUDIOBOOK_REMOTE_TOKEN", raising=False)
    store = jobs.JobStore()
    monkeypatch.setattr(main, "store", store)
    return store


def test_delete_local_audiobook_removes_completed_versions_only(
    tmp_path: Path, isolated_store: jobs.JobStore,
):
    store = isolated_store
    epub = make_epub(tmp_path / "book.epub")
    book = store.save_upload("book.epub", epub.read_bytes())
    completed = [store.create_job(book.id, {}) for _ in range(2)]
    pending = store.create_job(book.id, {})
    other = store.create_job("another-book", {})
    for job_id in completed + [pending, other]:
        path = jobs.JOB_DIR / job_id
        path.mkdir()
        (path / "artifact.txt").write_text("keep or delete")
    for job_id in completed:
        store.update_job(job_id, status="done")
    store.update_job(other, status="done")

    response = TestClient(main.app).delete(f"/api/audiobooks/{completed[1]}")
    assert response.status_code == 200
    assert response.json() == {"ok": True, "id": completed[1]}
    for job_id in completed:
        with pytest.raises(KeyError):
            store.get_job(job_id)
        assert not (jobs.JOB_DIR / job_id).exists()
    assert store.get_job(pending)["status"] == "queued"
    assert store.get_job(other)["status"] == "done"
    assert (jobs.JOB_DIR / pending / "artifact.txt").exists()
    assert (jobs.JOB_DIR / other / "artifact.txt").exists()
    assert (jobs.UPLOAD_DIR / f"{book.id}.epub").exists()
    assert store.get_book(book.id).id == book.id


class FakeS3:
    def __init__(self, objects: dict[str, bytes]):
        self.objects = objects
        self.deleted: list[str] = []
        self.fail_delete = False

    def get_object(self, Bucket: str, Key: str) -> dict:
        if Key not in self.objects:
            raise FileNotFoundError(Key)
        return {"Body": types.SimpleNamespace(read=lambda: self.objects[Key])}

    def put_object(self, **kwargs) -> None:
        self.objects[kwargs["Key"]] = kwargs["Body"]

    def list_objects_v2(self, **kwargs) -> dict:
        keys = sorted(key for key in self.objects if key.startswith(kwargs["Prefix"]))
        offset = int(kwargs.get("ContinuationToken", "0"))
        page = keys[offset:offset + 1]
        next_offset = offset + len(page)
        response = {"Contents": [{"Key": key} for key in page], "IsTruncated": next_offset < len(keys)}
        if response["IsTruncated"]:
            response["NextContinuationToken"] = str(next_offset)
        return response

    def delete_objects(self, **kwargs) -> dict:
        if self.fail_delete:
            return {"Errors": [{"Key": kwargs["Delete"]["Objects"][0]["Key"], "Code": "AccessDenied"}]}
        for item in kwargs["Delete"]["Objects"]:
            self.deleted.append(item["Key"])
            self.objects.pop(item["Key"], None)
        return {"Errors": []}


def test_delete_s3_audiobook_uses_exact_prefix_and_all_pages(
    monkeypatch: pytest.MonkeyPatch, isolated_store: jobs.JobStore,
):
    book_id = "book123"
    audio_id = "job123"
    root = f"audiobooks/{book_id}/{audio_id}/"
    catalog_key = "audiobooks/catalog.json"
    entry = {"id": audio_id, "book_id": book_id, "title": "Selected"}
    other_entry = {"id": "otherjob", "book_id": "otherbook", "title": "Other"}
    objects = {
        catalog_key: json.dumps({"schema": "audiobook-catalog-v1", "audiobooks": [entry, other_entry]}).encode(),
        root + "manifest.json": b"{}",
        root + "cover.jpg": b"cover",
        root + "audio/one.m4a": b"one",
        f"audiobooks/{book_id}/{audio_id}-old/manifest.json": b"older version",
        "audiobooks/otherbook/otherjob/manifest.json": b"other book",
    }
    fake = FakeS3(objects)
    monkeypatch.setitem(sys.modules, "boto3", types.SimpleNamespace(client=lambda *args, **kwargs: fake))
    monkeypatch.setenv("S3_BUCKET", "bucket")
    client = TestClient(main.app)

    response = client.delete(f"/api/audiobooks/{audio_id}")
    assert response.status_code == 200
    assert sorted(fake.deleted) == sorted([root + "manifest.json", root + "cover.jpg", root + "audio/one.m4a"])
    assert objects[f"audiobooks/{book_id}/{audio_id}-old/manifest.json"] == b"older version"
    assert objects["audiobooks/otherbook/otherjob/manifest.json"] == b"other book"
    assert json.loads(objects[catalog_key])["audiobooks"] == [other_entry]
    assert client.delete(f"/api/audiobooks/{audio_id}").status_code == 404


def test_delete_s3_failure_keeps_catalog_for_retry(
    monkeypatch: pytest.MonkeyPatch, isolated_store: jobs.JobStore,
):
    entry = {"id": "job123", "book_id": "book123"}
    catalog_key = "audiobooks/catalog.json"
    objects = {
        catalog_key: json.dumps({"audiobooks": [entry]}).encode(),
        "audiobooks/book123/job123/manifest.json": b"{}",
    }
    fake = FakeS3(objects)
    fake.fail_delete = True
    monkeypatch.setitem(sys.modules, "boto3", types.SimpleNamespace(client=lambda *args, **kwargs: fake))
    monkeypatch.setenv("S3_BUCKET", "bucket")

    response = TestClient(main.app).delete("/api/audiobooks/job123")
    assert response.status_code == 502
    assert json.loads(objects[catalog_key])["audiobooks"] == [entry]
    assert "audiobooks/book123/job123/manifest.json" in objects


def test_delete_shared_s3_and_local_id(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, isolated_store: jobs.JobStore,
):
    store = isolated_store
    epub = make_epub(tmp_path / "book.epub")
    book = store.save_upload("book.epub", epub.read_bytes())
    job_id = store.create_job(book.id, {})
    store.update_job(job_id, status="done")
    (jobs.JOB_DIR / job_id).mkdir()
    (jobs.JOB_DIR / job_id / "package.zip").write_bytes(b"package")
    catalog_key = "audiobooks/catalog.json"
    manifest_key = f"audiobooks/{book.id}/{job_id}/manifest.json"
    objects = {
        catalog_key: json.dumps({"audiobooks": [{"id": job_id, "book_id": book.id}]}).encode(),
        manifest_key: b"{}",
    }
    fake = FakeS3(objects)
    monkeypatch.setitem(sys.modules, "boto3", types.SimpleNamespace(client=lambda *args, **kwargs: fake))
    monkeypatch.setenv("S3_BUCKET", "bucket")

    response = TestClient(main.app).delete(f"/api/audiobooks/{job_id}")
    assert response.status_code == 200
    assert manifest_key not in objects
    assert json.loads(objects[catalog_key])["audiobooks"] == []
    with pytest.raises(KeyError):
        store.get_job(job_id)
    assert not (jobs.JOB_DIR / job_id).exists()
    assert (jobs.UPLOAD_DIR / f"{book.id}.epub").exists()


def test_delete_remote_id_removes_same_book_local_jobs_and_can_retry(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, isolated_store: jobs.JobStore,
):
    store = isolated_store
    epub = make_epub(tmp_path / "book.epub")
    book = store.save_upload("book.epub", epub.read_bytes())
    completed = [store.create_job(book.id, {}) for _ in range(2)]
    pending = store.create_job(book.id, {})
    unrelated = store.create_job("another-book", {})
    for job_id in completed + [pending, unrelated]:
        (jobs.JOB_DIR / job_id).mkdir()
    for job_id in completed + [unrelated]:
        store.update_job(job_id, status="done")

    remote_id = "remote123"
    assert remote_id not in completed
    catalog_key = "audiobooks/catalog.json"
    manifest_key = f"audiobooks/{book.id}/{remote_id}/manifest.json"
    entry = {"id": remote_id, "book_id": book.id}
    objects = {
        catalog_key: json.dumps({"audiobooks": [entry]}).encode(),
        manifest_key: b"{}",
    }
    fake = FakeS3(objects)
    monkeypatch.setitem(sys.modules, "boto3", types.SimpleNamespace(client=lambda *args, **kwargs: fake))
    monkeypatch.setenv("S3_BUCKET", "bucket")
    client = TestClient(main.app)

    def fail_local_delete(path: Path) -> None:
        raise OSError("disk error")

    with monkeypatch.context() as patch:
        patch.setattr(jobs.shutil, "rmtree", fail_local_delete)
        assert client.delete(f"/api/audiobooks/{remote_id}").status_code == 500
    assert json.loads(objects[catalog_key])["audiobooks"] == [entry]
    assert manifest_key in objects
    assert all(store.get_job(job_id)["status"] == "done" for job_id in completed)

    fake.fail_delete = True
    assert client.delete(f"/api/audiobooks/{remote_id}").status_code == 502
    assert json.loads(objects[catalog_key])["audiobooks"] == [entry]
    for job_id in completed:
        with pytest.raises(KeyError):
            store.get_job(job_id)
        assert not (jobs.JOB_DIR / job_id).exists()

    fake.fail_delete = False
    assert client.delete(f"/api/audiobooks/{remote_id}").status_code == 200
    assert json.loads(objects[catalog_key])["audiobooks"] == []
    assert manifest_key not in objects
    assert store.get_job(pending)["status"] == "queued"
    assert store.get_job(unrelated)["status"] == "done"
    assert (jobs.JOB_DIR / pending).exists()
    assert (jobs.JOB_DIR / unrelated).exists()
    assert (jobs.UPLOAD_DIR / f"{book.id}.epub").exists()


def test_delete_requires_token_and_rejects_missing_or_unsafe_id(
    monkeypatch: pytest.MonkeyPatch, isolated_store: jobs.JobStore,
):
    monkeypatch.setenv("AUDIOBOOK_REMOTE_TOKEN", "secret")
    client = TestClient(main.app)
    assert client.delete("/api/audiobooks/missing").status_code == 401
    assert client.delete("/api/audiobooks/missing", headers={"Authorization": "Bearer wrong"}).status_code == 401
    headers = {"Authorization": "Bearer secret"}
    assert client.delete("/api/audiobooks/missing", headers=headers).status_code == 404
    assert client.delete("/api/audiobooks/bad.id", headers=headers).status_code == 400
