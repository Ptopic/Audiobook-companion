from __future__ import annotations

import json
import posixpath
import sqlite3
import sys
import types
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

import pytest
from fastapi.testclient import TestClient

from backend.audio import wav_duration
from backend.cloud import S3Config, catalog_items, upload_package
from backend.epub import parse_epub
from backend.package import manifest_for_api
from backend.jobs import JobStore, run_job
from backend.main import app
from tests.fixtures import make_epub


def test_parse_spine_order_and_plain_text(tmp_path: Path):
    epub = make_epub(tmp_path / "book.epub")
    book = parse_epub(epub, "book")
    assert [c.title for c in book.chapters] == ["One", "Two"]
    assert book.author == "Alex Writer"
    assert book.cover_href == "images/cover.jpg"
    assert "bad()" not in book.chapters[0].text
    assert [chunk.text for chunk in book.chapters[0].chunks] == ["One", "Hello world. Second sentence."]


def test_ignores_encryption_marker_when_content_is_readable(tmp_path: Path):
    epub = make_epub(tmp_path / "marked.epub", encryption_marker=True)
    book = parse_epub(epub)
    assert book.title == "Fixture Book"
    assert [c.title for c in book.chapters] == ["One", "Two"]


def test_empty_chapter_selection_is_rejected(tmp_path: Path):
    client = TestClient(app)
    epub = make_epub(tmp_path / "empty-selection.epub")
    with epub.open("rb") as fh:
        upload = client.post("/api/books", files={"file": ("empty-selection.epub", fh, "application/epub+zip")})
    assert upload.status_code == 200
    book_id = upload.json()["id"]
    res = client.post(f"/api/books/{book_id}/jobs", json={"include_chapters": []})
    assert res.status_code == 400
    assert "Select at least one chapter" in res.text
    client.delete(f"/api/books/{book_id}")


def test_generate_sine_cache_and_export(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    import backend.jobs as jobs

    monkeypatch.setattr(jobs, "DATA_DIR", tmp_path / "data")
    monkeypatch.setattr(jobs, "UPLOAD_DIR", tmp_path / "data" / "uploads")
    monkeypatch.setattr(jobs, "CACHE_DIR", tmp_path / "data" / "cache")
    monkeypatch.setattr(jobs, "JOB_DIR", tmp_path / "data" / "jobs")
    monkeypatch.setattr(jobs, "DB_PATH", tmp_path / "data" / "app.sqlite3")
    store = JobStore()
    content = make_epub(tmp_path / "book.epub").read_bytes()
    book = store.save_upload("book.epub", content)
    job_id = store.create_job(book.id, {"engine": "sine", "voice": "af_heart", "speed": 1.0, "include_chapters": ["c1"], "replacements": {}})
    run_job(store, job_id)
    job = store.get_job(job_id)
    assert job["status"] == "done"
    audio = Path(job["artifacts"]["chapters"]["c1"]["audio"])
    assert audio.exists()
    timings = job["artifacts"]["chapters"]["c1"]["timings"]
    assert timings[0]["begin"] == 0
    assert all(a["end"] <= b["begin"] for a, b in zip(timings, timings[1:]))
    assert timings[-1]["end"] <= wav_duration(audio) + 0.02
    cache_files = list((tmp_path / "data" / "cache").glob("*.wav"))
    mtimes = {p.name: p.stat().st_mtime for p in cache_files}
    second = store.create_job(book.id, {"engine": "sine", "voice": "af_heart", "speed": 1.0, "include_chapters": ["c1"], "replacements": {}})
    run_job(store, second)
    assert store.list_jobs(book.id)[0]["id"] == second
    store.cancel_job(second)
    assert store.get_job(second)["status"] == "cancelled"
    store.resume_job(second)
    assert store.get_job(second)["status"] == "queued"
    run_job(store, second)
    assert store.get_job(second)["status"] == "done"
    assert mtimes == {p.name: p.stat().st_mtime for p in cache_files}
    export = Path(store.get_job(second)["artifacts"]["export_epub"])
    assert export.exists()
    packaged = store.get_job(second)["artifacts"]
    package_manifest = Path(packaged["package_manifest"])
    package_zip = Path(packaged["package_zip"])
    assert package_manifest.exists()
    assert package_zip.exists()
    manifest = manifest_for_api(package_manifest, second)
    assert manifest["schema"] == "iphone-audiobook-v2"
    assert manifest["generator_version"] == "iphone-audiobook-v2"
    assert manifest["title"] == "Fixture Book"
    assert manifest["author"] == "Alex Writer"
    assert manifest["cover_file"] == "cover.jpg"
    assert manifest["cover_url"] == f"/api/audiobooks/{second}/cover"
    assert manifest["chapters"][0]["audio_url"] == f"/api/audiobooks/{second}/audio/c1"
    assert manifest["chapters"][0]["audio_path"] == manifest["chapters"][0]["audio_file"]
    assert manifest["chapters"][0]["segments"][0]["start"] == 0
    assert all(a["end"] <= b["start"] for a, b in zip(manifest["chapters"][0]["segments"], manifest["chapters"][0]["segments"][1:]))
    with zipfile.ZipFile(package_zip) as zf:
        package_names = set(zf.namelist())
        assert "manifest.json" in package_names
        assert "cover.jpg" in package_names
        assert manifest["chapters"][0]["audio_file"] in package_names
    with zipfile.ZipFile(export) as zf:
        names = set(zf.namelist())
        assert "OEBPS/media-overlays/c1.smil" in names
        assert "OEBPS/audio/c1.wav" in names
        opf = zf.read("OEBPS/content.opf").decode()
        assert 'media-overlay="kaud-smil-c1"' in opf
        assert "/ media-overlay=" not in opf
        ET.fromstring(opf)
        assert '<item id="c1" href="chap1.xhtml" media-type="application/xhtml+xml" media-overlay="kaud-smil-c1"/>' in opf
        assert '<item id="kaud-smil-c1" href="media-overlays/c1.smil" media-type="application/smil+xml"/>' in opf
        smil = zf.read("OEBPS/media-overlays/c1.smil").decode()
        assert 'text src="../chap1.xhtml#kaud-0001"' in smil
        assert 'audio src="../audio/c1.wav"' in smil
        chapter = zf.read("OEBPS/chap1.xhtml").decode()
        assert "<h1><span id=\"kaud-0001\">One</span></h1>" in chapter
        for src in ["../chap1.xhtml", "../audio/c1.wav"]:
            normalized = posixpath.normpath(posixpath.join("OEBPS/media-overlays", src))
            assert normalized in names
    store.delete_book(book.id)
    assert not (tmp_path / "data" / "uploads" / f"{book.id}.epub").exists()


def test_s3_config_is_optional(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.delenv("S3_BUCKET", raising=False)
    monkeypatch.delenv("AUDIOBOOK_S3_BUCKET", raising=False)
    monkeypatch.delenv("S3_ENDPOINT", raising=False)
    monkeypatch.delenv("AUDIOBOOK_S3_ENDPOINT", raising=False)
    assert S3Config.from_env() is None
    monkeypatch.setenv("AUDIOBOOK_S3_BUCKET", "bucket")
    monkeypatch.setenv("AUDIOBOOK_S3_PREFIX", "private/books")
    monkeypatch.setenv("AUDIOBOOK_S3_PUBLIC_BASE_URL", "https://cdn.example.test/root")
    config = S3Config.from_env()
    assert config is not None
    assert config.bucket == "bucket"
    assert config.prefix == "private/books"
    assert config.endpoint_url is None
    assert config.url_for("private/books/book/manifest.json") == "https://cdn.example.test/root/private/books/book/manifest.json"


def test_s3_upload_requires_https_base_url(tmp_path: Path):
    manifest = {"id": "book", "job_id": "job", "chapters": []}
    with pytest.raises(RuntimeError, match="PUBLIC_BASE_URL"):
        upload_package(tmp_path, manifest, S3Config(bucket="bucket"))


def test_s3_upload_includes_cover_and_metadata(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    (tmp_path / "cover.jpg").write_bytes(b"cover")
    (tmp_path / "audio").mkdir()
    (tmp_path / "audio" / "c1.m4a").write_bytes(b"audio")
    calls: list[tuple] = []
    objects: dict[str, bytes] = {}

    class FakeS3:
        def upload_file(self, path, bucket, key, ExtraArgs):
            calls.append(("upload", path, bucket, key, ExtraArgs))

        def put_object(self, **kwargs):
            calls.append(("put", kwargs))
            objects[kwargs["Key"]] = kwargs["Body"]

        def get_object(self, Bucket, Key):
            if Key not in objects:
                raise FileNotFoundError(Key)
            return {"Body": types.SimpleNamespace(read=lambda: objects[Key])}

    fake_s3 = FakeS3()
    monkeypatch.setitem(sys.modules, "boto3", types.SimpleNamespace(client=lambda *args, **kwargs: fake_s3))
    manifest = {
        "id": "book",
        "job_id": "job",
        "title": "Real Title",
        "author": "Real Author",
        "cover_file": "cover.jpg",
        "chapters": [{"id": "c1", "audio_file": "audio/c1.m4a"}],
    }
    result = upload_package(
        tmp_path,
        manifest,
        S3Config(bucket="bucket", public_base_url="https://cdn.example.test"),
    )
    put = next(call[1] for call in calls if call[0] == "put" and call[1]["Key"].endswith("/manifest.json"))
    remote = json.loads(put["Body"])
    assert remote["title"] == "Real Title"
    assert remote["author"] == "Real Author"
    assert remote["cover_url"] == "https://cdn.example.test/audiobooks/book/job/cover.jpg"
    assert remote["chapters"][0]["audio_url"] == "https://cdn.example.test/audiobooks/book/job/audio/c1.m4a"
    assert "audiobooks/book/job/cover.jpg" in result["uploaded"]
    assert result["catalog_key"] == "audiobooks/catalog.json"
    catalog = json.loads(objects[result["catalog_key"]])
    assert catalog["schema"] == "audiobook-catalog-v1"
    assert len(catalog["audiobooks"]) == 1
    assert catalog["audiobooks"][0]["book_id"] == "book"
    assert catalog["audiobooks"][0]["id"] == "job"
    assert catalog["audiobooks"][0]["manifest_url"] == "https://cdn.example.test/audiobooks/book/job/manifest.json"
    assert catalog_items(S3Config(bucket="bucket", public_base_url="https://cdn.example.test")) == catalog["audiobooks"]
    cover_upload = next(call for call in calls if call[0] == "upload" and call[3].endswith("cover.jpg"))
    assert cover_upload[4]["ContentType"] == "image/jpeg"

    replacement = dict(manifest, job_id="new-job", title="Updated Title")
    upload_package(
        tmp_path,
        replacement,
        S3Config(bucket="bucket", public_base_url="https://cdn.example.test"),
    )
    catalog = json.loads(objects[result["catalog_key"]])
    assert len(catalog["audiobooks"]) == 1
    assert catalog["audiobooks"][0]["id"] == "new-job"
    assert catalog["audiobooks"][0]["title"] == "Updated Title"
