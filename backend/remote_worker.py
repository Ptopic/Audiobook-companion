from __future__ import annotations

import argparse
import fcntl
import json
import logging
import os
import threading
import time
from pathlib import Path
from typing import Callable
from urllib.error import HTTPError
from urllib.parse import quote, urljoin, urlparse
from urllib.request import Request, urlopen

from . import jobs
from .cloud import S3Config, upload_package
from .epub import EpubError


LOG = logging.getLogger(__name__)
DEFAULT_BASE_URL = "https://books.petartopic.com"
MAX_EPUB_BYTES = 75 * 1024 * 1024


class LeaseLost(Exception):
    pass


class RemoteClient:
    def __init__(self, base_url: str, token: str) -> None:
        if not token:
            raise ValueError("AUDIOBOOK_REMOTE_TOKEN is required")
        self.base_url = base_url.rstrip("/")
        self.token = token

    def _request(self, method: str, path: str, lease: str | None = None, payload: dict | None = None) -> bytes | None:
        url = urljoin(self.base_url + "/", path.lstrip("/"))
        if urlparse(url).netloc != urlparse(self.base_url).netloc:
            raise ValueError("Remote URL must stay on the configured host")
        headers = {"Authorization": f"Bearer {self.token}", "User-Agent": "KindleAudioBooksMacWorker/1.0"}
        if lease:
            headers["X-Remote-Lease"] = lease
        body = None
        if payload is not None:
            headers["Content-Type"] = "application/json"
            body = json.dumps(payload).encode("utf-8")
        request = Request(url, data=body, headers=headers, method=method)
        try:
            with urlopen(request, timeout=30) as response:
                if response.status == 204:
                    return None
                if path.endswith("/epub"):
                    content = response.read(MAX_EPUB_BYTES + 1)
                    if len(content) > MAX_EPUB_BYTES:
                        raise ValueError("Remote EPUB exceeds 75 MB")
                    return content
                return response.read()
        except HTTPError as exc:
            if exc.code == 409:
                raise LeaseLost("Remote worker lease expired or was reassigned") from exc
            raise

    def claim(self) -> dict | None:
        content = self._request("POST", "/api/remote/worker/claim")
        return json.loads(content) if content is not None else None

    def epub(self, remote_id: str, lease: str) -> bytes:
        content = self._request("GET", f"/api/remote/worker/jobs/{quote(remote_id, safe='')}/epub", lease)
        assert content is not None
        return content

    def progress(self, remote_id: str, lease: str, payload: dict) -> dict:
        content = self._request("POST", f"/api/remote/worker/jobs/{quote(remote_id, safe='')}/progress", lease, payload)
        assert content is not None
        return json.loads(content)


class RemoteWorker:
    def __init__(self, client: RemoteClient, store: jobs.JobStore, s3: S3Config, state_path: Path) -> None:
        self.client = client
        self.store = store
        self.s3 = s3
        self.state_path = state_path
        self._state_lock = threading.RLock()
        self.state: dict[str, dict] = self._load_state()
        self._reconcile_local_jobs()

    def _load_state(self) -> dict[str, dict]:
        if not self.state_path.exists():
            return {}
        value = json.loads(self.state_path.read_text(encoding="utf-8"))
        if not isinstance(value, dict):
            raise ValueError("Remote worker state must be a JSON object")
        return value

    def _save_state(self) -> None:
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        temp = self.state_path.with_suffix(".tmp")
        descriptor = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as out:
            json.dump(self.state, out, indent=2)
            out.flush()
            os.fsync(out.fileno())
        temp.replace(self.state_path)
        os.chmod(self.state_path, 0o600)

    def _reconcile_local_jobs(self) -> None:
        # A crash between create_job and writing state still leaves this marker in SQLite.
        for local in self.store.list_jobs():
            remote_id = local["config"].get("remote_job_id")
            if remote_id and remote_id not in self.state:
                self.state[remote_id] = {"local_job_id": local["id"], "phase": "active", "progress": 0.0}
                self._save_state()

    def _set(self, remote_id: str, **fields: object) -> None:
        with self._state_lock:
            self.state.setdefault(remote_id, {}).update(fields)
            self._save_state()

    def _report(self, remote_id: str, status: str, progress: float, message: str, manifest_url: str | None = None) -> None:
        with self._state_lock:
            record = self.state[remote_id]
            lease = record.get("lease_token")
            if not lease:
                raise LeaseLost("No active worker lease")
            progress = max(progress, float(record.get("progress", 0.0)))
            payload = {"status": status, "progress": min(progress, 1.0), "message": message}
            if manifest_url:
                payload["manifest_url"] = manifest_url
            try:
                response = self.client.progress(remote_id, lease, payload)
            except LeaseLost:
                self._set(remote_id, lease_token=None)
                raise
            self._set(remote_id, progress=max(progress, float(response.get("progress", progress))))

    def _claim(self, claim: dict) -> str:
        remote_id = claim["id"]
        current = self.state.get(remote_id, {})
        claimed_progress = float(claim.get("progress", 0.0))
        local_failed = False
        if current.get("local_job_id"):
            try:
                local_failed = self.store.get_job(current["local_job_id"])["status"] == "failed"
            except KeyError:
                pass
        self._set(
            remote_id,
            local_job_id=current.get("local_job_id"),
            lease_token=claim["lease_token"],
            phase="active",
            progress=claimed_progress if local_failed or current.get("phase") == "failed" else max(float(current.get("progress", 0.0)), claimed_progress),
            config=claim["config"],
        )
        return remote_id

    def _local_job(self, remote_id: str) -> str:
        record = self.state[remote_id]
        local_id = record.get("local_job_id")
        if local_id:
            try:
                self.store.get_job(local_id)
                return local_id
            except KeyError:
                pass
        epub = self.client.epub(remote_id, record["lease_token"])
        book = self.store.save_upload(f"{remote_id}.epub", epub)
        config = record["config"]
        local_config = {
            "engine": "kokoro",
            "voice": config.get("voice", "af_heart"),
            "speed": config.get("speed", 1.0),
            "include_chapters": config["include_chapters"],
            "replacements": config.get("replacements") or {},
            "remote_job_id": remote_id,
        }
        local_id = self.store.create_job(book.id, local_config)
        self._set(remote_id, local_job_id=local_id)
        return local_id

    def _with_heartbeat(self, remote_id: str, local_id: str, action: Callable[[], None]) -> None:
        stop = threading.Event()
        lost = threading.Event()

        def heartbeat() -> None:
            while not stop.wait(30):
                local = self.store.get_job(local_id)
                try:
                    self._report(remote_id, "running", min(float(local["progress"]) * 0.9, 0.9), local["message"] or "Narrating")
                except LeaseLost:
                    lost.set()
                    return
                except Exception:
                    LOG.exception("Heartbeat failed for %s; will retry", remote_id)

        monitor = threading.Thread(target=heartbeat, daemon=True)
        monitor.start()
        try:
            action()
        finally:
            stop.set()
            monitor.join(timeout=35)
        if lost.is_set():
            raise LeaseLost("Lease lost during job processing")

    def _process(self, remote_id: str) -> None:
        record = self.state[remote_id]
        local_id = record.get("local_job_id")
        local = self.store.get_job(local_id) if local_id else None
        progress = min(float(local["progress"]) * 0.9, 0.9) if local and local["status"] != "failed" else 0.0
        self._report(remote_id, "running", progress, "Mac worker active")
        try:
            local_id = self._local_job(remote_id)
        except (EpubError, KeyError, ValueError) as exc:
            self._report(remote_id, "failed", progress, f"Cannot prepare EPUB: {exc}")
            self._set(remote_id, phase="failed", lease_token=None)
            return
        local = self.store.get_job(local_id)
        if local["status"] != "done":
            def narrate() -> None:
                self.store.resume_job(local_id)
                jobs.run_job(self.store, local_id)

            self._with_heartbeat(remote_id, local_id, narrate)
            local = self.store.get_job(local_id)
            if local["status"] != "done":
                self._report(remote_id, "failed", min(float(local["progress"]) * 0.9, 0.9), local["message"] or "Narration did not finish")
                self._set(remote_id, phase="failed", lease_token=None)
                return
        manifest_url = self.state[remote_id].get("manifest_url")
        if not manifest_url:
            self._report(remote_id, "running", 0.95, "Uploading audiobook package")
            manifest_path = Path(local["artifacts"]["package_manifest"])
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            upload: dict = {}

            def upload_action() -> None:
                nonlocal upload
                upload = upload_package(Path(local["artifacts"]["package_dir"]), manifest, self.s3)

            try:
                self._with_heartbeat(remote_id, local_id, upload_action)
            except LeaseLost:
                raise
            except Exception:
                self._report(remote_id, "running", 0.95, "Upload failed; retrying")
                raise
            manifest_url = upload["manifest_url"]
            self._set(remote_id, manifest_url=manifest_url)
        self._report(remote_id, "done", 1.0, "Audiobook ready", manifest_url)
        self._set(remote_id, phase="done", lease_token=None)

    def run_once(self) -> bool:
        active = next((remote_id for remote_id, record in self.state.items() if record.get("phase") == "active" and record.get("lease_token")), None)
        if active is None:
            claim = self.client.claim()
            if claim is None:
                return False
            active = self._claim(claim)
        try:
            self._process(active)
        except LeaseLost:
            LOG.warning("Lease lost for %s; waiting for a new claim", active)
            self._set(active, lease_token=None)
        except Exception:
            LOG.exception("Remote job %s failed; local state retained for retry", active)
        return True


def main() -> None:
    parser = argparse.ArgumentParser(description="Narrate queued remote EPUB jobs on this Mac")
    parser.add_argument("--poll-seconds", type=float, default=30.0)
    args = parser.parse_args()
    if args.poll_seconds < 5:
        parser.error("--poll-seconds must be at least 5")
    token = os.getenv("AUDIOBOOK_REMOTE_TOKEN")
    if not token:
        parser.error("Set AUDIOBOOK_REMOTE_TOKEN")
    s3 = S3Config.from_env()
    if not s3 or not s3.public_base_url or not s3.public_base_url.startswith("https://"):
        parser.error("Set S3_BUCKET and an HTTPS S3_PUBLIC_BASE_URL")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    lock_path = jobs.DATA_DIR / "remote-worker.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("Another remote worker is already running")
        worker = RemoteWorker(RemoteClient(os.getenv("AUDIOBOOK_REMOTE_BASE_URL", DEFAULT_BASE_URL), token), jobs.JobStore(), s3, jobs.DATA_DIR / "remote-worker.json")
        LOG.info("Polling %s", worker.client.base_url)
        while True:
            try:
                worker.run_once()
            except Exception:
                LOG.exception("Polling failed; retrying")
            time.sleep(args.poll_seconds)


if __name__ == "__main__":
    main()
