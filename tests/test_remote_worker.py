from __future__ import annotations

import json
from pathlib import Path

import pytest

from backend import jobs, remote_worker
from backend.cloud import S3Config
from tests.fixtures import make_epub


class FakeClient:
    def __init__(self, epub: bytes) -> None:
        self.epub_bytes = epub
        self.claims: list[dict] = []
        self.reports: list[dict] = []
        self.downloads = 0
        self.reject_lease = False

    def claim(self) -> dict | None:
        return self.claims.pop(0) if self.claims else None

    def epub(self, remote_id: str, lease: str) -> bytes:
        self.downloads += 1
        return self.epub_bytes

    def progress(self, remote_id: str, lease: str, payload: dict) -> dict:
        if self.reject_lease:
            raise remote_worker.LeaseLost()
        self.reports.append(payload)
        return payload


def test_remote_client_sends_worker_user_agent(monkeypatch: pytest.MonkeyPatch) -> None:
    seen_headers: dict[str, str] = {}

    class NoJobResponse:
        status = 204

        def __enter__(self) -> "NoJobResponse":
            return self

        def __exit__(self, *_args: object) -> None:
            pass

    def fake_urlopen(request: object, timeout: int) -> NoJobResponse:
        seen_headers.update(dict(request.header_items()))
        return NoJobResponse()

    monkeypatch.setattr(remote_worker, "urlopen", fake_urlopen)
    assert remote_worker.RemoteClient("https://books.example.test", "token").claim() is None
    assert seen_headers["User-agent"] == "KindleAudioBooksMacWorker/1.0"
    assert seen_headers["Authorization"] == "Bearer token"


@pytest.fixture
def isolated_jobs(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> jobs.JobStore:
    monkeypatch.setattr(jobs, "DATA_DIR", tmp_path / "data")
    monkeypatch.setattr(jobs, "UPLOAD_DIR", tmp_path / "data" / "uploads")
    monkeypatch.setattr(jobs, "CACHE_DIR", tmp_path / "data" / "cache")
    monkeypatch.setattr(jobs, "JOB_DIR", tmp_path / "data" / "jobs")
    monkeypatch.setattr(jobs, "DB_PATH", tmp_path / "data" / "app.sqlite3")
    return jobs.JobStore()


@pytest.mark.parametrize("fail_first_upload", [False, True])
def test_claim_narrate_upload_and_resume_without_duplicate(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, isolated_jobs: jobs.JobStore, fail_first_upload: bool) -> None:
    client = FakeClient(make_epub(tmp_path / "source.epub").read_bytes())
    claim = {
        "id": "remote-1", "book_id": "remote-book", "lease_token": "lease-1", "progress": 0.0,
        "config": {"voice": "bf_emma", "speed": 1.2, "include_chapters": ["c1"], "replacements": {"A": "B"}},
    }
    client.claims.append(claim)
    state_path = tmp_path / "data" / "remote-worker.json"
    s3 = S3Config("bucket", public_base_url="https://cdn.example.test")
    run_count = 0
    upload_count = 0

    def fake_run(store: jobs.JobStore, local_id: str) -> None:
        nonlocal run_count
        run_count += 1
        local = store.get_job(local_id)
        assert local["config"]["engine"] == "kokoro"
        assert local["config"]["include_chapters"] == ["c1"]
        assert local["config"]["voice"] == "bf_emma"
        package = tmp_path / "package"
        package.mkdir(exist_ok=True)
        manifest = package / "manifest.json"
        manifest.write_text(json.dumps({"id": local["book_id"], "job_id": local_id, "chapters": []}))
        store.update_job(local_id, status="done", progress=1.0, artifacts={"package_dir": str(package), "package_manifest": str(manifest)})

    def fake_upload(package: Path, manifest: dict, config: S3Config) -> dict:
        nonlocal upload_count
        upload_count += 1
        assert config.bucket == "bucket"
        if fail_first_upload and upload_count == 1:
            raise OSError("temporary S3 failure")
        return {"manifest_url": "https://cdn.example.test/manifest.json"}

    monkeypatch.setattr(remote_worker.jobs, "run_job", fake_run)
    monkeypatch.setattr(remote_worker, "upload_package", fake_upload)
    worker = remote_worker.RemoteWorker(client, isolated_jobs, s3, state_path)
    assert worker.run_once()
    if fail_first_upload:
        assert worker.state["remote-1"].get("manifest_url") is None
        assert client.reports[-1]["message"] == "Upload failed; retrying"
        assert worker.run_once()
    assert run_count == 1
    assert upload_count == 1 + int(fail_first_upload)
    assert client.downloads == 1
    assert client.reports[-1] == {"status": "done", "progress": 1.0, "message": "Audiobook ready", "manifest_url": "https://cdn.example.test/manifest.json"}
    local_id = worker.state["remote-1"]["local_job_id"]

    restarted = remote_worker.RemoteWorker(client, isolated_jobs, s3, state_path)
    client.claims.append({**claim, "lease_token": "lease-2", "progress": 0.95})
    assert restarted.run_once()
    assert restarted.state["remote-1"]["local_job_id"] == local_id
    assert run_count == 1
    assert upload_count == 1 + int(fail_first_upload)
    assert client.downloads == 1


def test_expired_lease_waits_for_reclaim(tmp_path: Path, isolated_jobs: jobs.JobStore) -> None:
    client = FakeClient(make_epub(tmp_path / "source.epub").read_bytes())
    client.claims.append({"id": "remote-2", "lease_token": "expired", "progress": 0.0, "config": {"include_chapters": ["c1"]}})
    client.reject_lease = True
    state_path = tmp_path / "data" / "remote-worker.json"
    worker = remote_worker.RemoteWorker(client, isolated_jobs, S3Config("bucket", public_base_url="https://cdn.example.test"), state_path)
    assert worker.run_once()
    assert worker.state["remote-2"]["lease_token"] is None
    assert client.downloads == 0
    assert not worker.run_once()


def test_failed_narration_reuses_local_job_after_remote_retry(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, isolated_jobs: jobs.JobStore) -> None:
    client = FakeClient(make_epub(tmp_path / "source.epub").read_bytes())
    claim = {"id": "remote-retry", "lease_token": "first-lease", "progress": 0.0, "config": {"include_chapters": ["c1"]}}
    client.claims.append(claim)
    s3 = S3Config("bucket", public_base_url="https://cdn.example.test")
    worker = remote_worker.RemoteWorker(client, isolated_jobs, s3, tmp_path / "data" / "remote-worker.json")
    local_ids: list[str] = []
    uploaded: list[str] = []

    def fake_run(store: jobs.JobStore, local_id: str) -> None:
        local_ids.append(local_id)
        if len(local_ids) == 1:
            store.update_job(local_id, status="failed", progress=0.5, message="Temporary synthesis error")
            return
        assert store.get_job(local_id)["status"] == "queued"
        package = tmp_path / "package"
        package.mkdir(exist_ok=True)
        manifest = package / "manifest.json"
        manifest.write_text(json.dumps({"id": "book", "job_id": local_id, "chapters": []}))
        store.update_job(local_id, status="done", progress=1.0, artifacts={"package_dir": str(package), "package_manifest": str(manifest)})

    def fake_upload(package: Path, manifest: dict, config: S3Config) -> dict:
        uploaded.append(manifest["job_id"])
        return {"manifest_url": "https://cdn.example.test/manifest.json"}

    monkeypatch.setattr(remote_worker.jobs, "run_job", fake_run)
    monkeypatch.setattr(remote_worker, "upload_package", fake_upload)
    assert worker.run_once()
    assert client.reports[-1]["status"] == "failed"
    assert worker.state["remote-retry"]["phase"] == "failed"
    assert uploaded == []

    client.claims.append({**claim, "lease_token": "retry-lease"})
    report_count = len(client.reports)
    assert worker.run_once()
    assert client.reports[report_count]["progress"] == 0.0
    assert local_ids == [local_ids[0], local_ids[0]]
    assert client.downloads == 1
    assert uploaded == [local_ids[0]]
    assert client.reports[-1]["status"] == "done"
