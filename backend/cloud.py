from __future__ import annotations

import json
import os
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


_SAFE_ID = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")


def valid_catalog_id(value: str) -> bool:
    return bool(_SAFE_ID.fullmatch(value))


@dataclass(frozen=True)
class S3Config:
    bucket: str
    prefix: str = "audiobooks"
    public_base_url: str | None = None
    endpoint_url: str | None = None

    @classmethod
    def from_env(cls) -> "S3Config | None":
        bucket = os.getenv("S3_BUCKET") or os.getenv("AUDIOBOOK_S3_BUCKET") or os.getenv("S3_BUCKET_NAME")
        if not bucket:
            return None
        return cls(
            bucket=bucket,
            prefix=(os.getenv("S3_PREFIX") or os.getenv("AUDIOBOOK_S3_PREFIX") or "audiobooks").strip("/"),
            public_base_url=(
                os.getenv("S3_PUBLIC_BASE_URL")
                or os.getenv("AUDIOBOOK_S3_PUBLIC_BASE_URL")
                or os.getenv("S3_PUBLIC_URL_PREFIX")
            ),
            endpoint_url=os.getenv("S3_ENDPOINT") or os.getenv("AUDIOBOOK_S3_ENDPOINT"),
        )

    def url_for(self, key: str) -> str | None:
        if not self.public_base_url:
            return None
        return f"{self.public_base_url.rstrip('/')}/{key}"


def upload_package(package_dir: Path, manifest: dict[str, Any], config: S3Config) -> dict[str, Any]:
    if not config.public_base_url:
        raise RuntimeError("Set S3_PUBLIC_BASE_URL or AUDIOBOOK_S3_PUBLIC_BASE_URL to an HTTPS base URL for iPhone streaming")
    try:
        import boto3  # type: ignore
    except Exception as exc:  # pragma: no cover - optional dependency
        raise RuntimeError("Install boto3 to upload audiobook packages to S3") from exc

    s3 = boto3.client("s3", endpoint_url=config.endpoint_url)
    book_id = manifest["id"]
    job_id = manifest["job_id"]
    root_key = f"{config.prefix}/{book_id}/{job_id}"
    uploaded = []
    remote_manifest = json.loads(json.dumps(manifest))
    cover_file = remote_manifest.get("cover_file")
    if cover_file:
        cover_key = f"{root_key}/{cover_file}"
        cover_path = package_dir / cover_file
        s3.upload_file(str(cover_path), config.bucket, cover_key, ExtraArgs={"ContentType": _content_type(cover_path)})
        remote_manifest["cover_url"] = config.url_for(cover_key) or f"s3://{config.bucket}/{cover_key}"
        uploaded.append(cover_key)
    for chapter in remote_manifest.get("chapters", []):
        audio_file = chapter["audio_file"]
        key = f"{root_key}/{audio_file}"
        local_path = package_dir / audio_file
        s3.upload_file(str(local_path), config.bucket, key, ExtraArgs={"ContentType": _content_type(local_path)})
        chapter["audio_url"] = config.url_for(key) or f"s3://{config.bucket}/{key}"
        uploaded.append(key)
    manifest_key = f"{root_key}/manifest.json"
    body = json.dumps(remote_manifest, indent=2, ensure_ascii=False).encode("utf-8")
    s3.put_object(Bucket=config.bucket, Key=manifest_key, Body=body, ContentType="application/json; charset=utf-8")
    uploaded.append(manifest_key)
    catalog_key = _update_catalog(s3, config, remote_manifest, manifest_key)
    uploaded.append(catalog_key)
    return {
        "bucket": config.bucket,
        "prefix": root_key,
        "manifest_key": manifest_key,
        "manifest_url": config.url_for(manifest_key) or f"s3://{config.bucket}/{manifest_key}",
        "catalog_key": catalog_key,
        "catalog_url": config.url_for(catalog_key) or f"s3://{config.bucket}/{catalog_key}",
        "uploaded": uploaded,
    }


def catalog_items(config: S3Config) -> list[dict[str, Any]]:
    """Return the shared S3 catalog, or an empty list when it is unavailable."""
    try:
        import boto3  # type: ignore
    except Exception:  # pragma: no cover - optional dependency
        return []
    try:
        catalog = _read_catalog(boto3.client("s3", endpoint_url=config.endpoint_url), config)
    except Exception:
        return []
    items = catalog.get("audiobooks")
    return items if isinstance(items, list) else []


def get_catalog_audiobook(config: S3Config, audiobook_id: str) -> dict[str, Any] | None:
    if not valid_catalog_id(audiobook_id) or not _valid_prefix(config.prefix):
        raise ValueError("Invalid audiobook ID or S3 prefix")
    try:
        import boto3  # type: ignore
    except Exception as exc:  # pragma: no cover - optional dependency
        raise RuntimeError("Install boto3 to delete S3 audiobooks") from exc
    catalog = _read_catalog(boto3.client("s3", endpoint_url=config.endpoint_url), config)
    _, item = _catalog_match(catalog, audiobook_id)
    return item


def delete_catalog_audiobook(
    config: S3Config, audiobook_id: str, expected_book_id: str | None = None,
) -> dict[str, Any] | None:
    """Delete one catalog entry and only the objects under its exact package prefix."""
    if not valid_catalog_id(audiobook_id) or not _valid_prefix(config.prefix):
        raise ValueError("Invalid audiobook ID or S3 prefix")
    try:
        import boto3  # type: ignore
    except Exception as exc:  # pragma: no cover - optional dependency
        raise RuntimeError("Install boto3 to delete S3 audiobooks") from exc

    s3 = boto3.client("s3", endpoint_url=config.endpoint_url)
    catalog = _read_catalog(s3, config)
    items, item = _catalog_match(catalog, audiobook_id)
    if item is None:
        return None
    book_id = item["book_id"]
    if expected_book_id is not None and book_id != expected_book_id:
        raise ValueError("Audiobook catalog entry changed")
    root_key = f"{config.prefix}/{book_id}/{audiobook_id}/"

    # Finish listing before mutating S3 so a listing failure cannot leave an
    # unexamined page of objects behind.
    keys: list[str] = []
    token: str | None = None
    seen_tokens: set[str] = set()
    while True:
        args: dict[str, Any] = {"Bucket": config.bucket, "Prefix": root_key}
        if token:
            args["ContinuationToken"] = token
        response = s3.list_objects_v2(**args)
        for obj in response.get("Contents", []):
            key = obj.get("Key")
            if not isinstance(key, str) or not key.startswith(root_key):
                raise ValueError("S3 returned an object outside the audiobook prefix")
            keys.append(key)
        if not response.get("IsTruncated"):
            break
        token = response.get("NextContinuationToken")
        if not isinstance(token, str) or not token or token in seen_tokens:
            raise RuntimeError("S3 object listing did not advance")
        seen_tokens.add(token)

    for start in range(0, len(keys), 1000):
        response = s3.delete_objects(
            Bucket=config.bucket,
            Delete={"Objects": [{"Key": key} for key in keys[start:start + 1000]], "Quiet": True},
        )
        if response.get("Errors"):
            raise RuntimeError("S3 could not delete every audiobook object")

    catalog["audiobooks"] = [entry for entry in items if entry is not item]
    catalog["updated_at"] = int(time.time())
    s3.put_object(
        Bucket=config.bucket,
        Key=_catalog_key(config),
        Body=json.dumps(catalog, indent=2, ensure_ascii=False).encode("utf-8"),
        ContentType="application/json; charset=utf-8",
    )
    return item


def _catalog_match(catalog: dict[str, Any], audiobook_id: str) -> tuple[list[dict[str, Any]], dict[str, Any] | None]:
    items = catalog.get("audiobooks", [])
    if not isinstance(items, list) or any(not isinstance(item, dict) for item in items):
        raise ValueError("Invalid S3 audiobook catalog")
    matches = [item for item in items if item.get("id") == audiobook_id]
    if not matches:
        return items, None
    if len(matches) != 1:
        raise ValueError("Duplicate audiobook ID in S3 catalog")
    item = matches[0]
    book_id = item.get("book_id")
    if not isinstance(book_id, str) or not valid_catalog_id(book_id):
        raise ValueError("Invalid book ID in S3 catalog")
    return items, item


def _valid_prefix(prefix: str) -> bool:
    return bool(prefix) and all(valid_catalog_id(part) for part in prefix.split("/"))


def _update_catalog(s3: Any, config: S3Config, manifest: dict[str, Any], manifest_key: str) -> str:
    catalog = _read_catalog(s3, config)
    chapters = [
        {"id": chapter["id"], "duration": float(chapter.get("duration", 0))}
        for chapter in manifest.get("chapters", [])
    ]
    uploaded_at = int(time.time())
    entry = {
        "id": manifest["job_id"],
        "book_id": manifest["id"],
        "title": manifest.get("title") or "Untitled",
        "author": manifest.get("author"),
        "cover_url": manifest.get("cover_url"),
        "duration": sum(chapter["duration"] for chapter in chapters),
        "chapters": chapters,
        "manifest_url": config.url_for(manifest_key) or f"s3://{config.bucket}/{manifest_key}",
        "package_url": None,
        "uploaded_at": uploaded_at,
    }
    existing = catalog.get("audiobooks")
    items = existing if isinstance(existing, list) else []
    items = [item for item in items if item.get("book_id") != entry["book_id"]]
    items.append(entry)
    items.sort(key=lambda item: int(item.get("uploaded_at", 0)), reverse=True)
    catalog = {
        "schema": "audiobook-catalog-v1",
        "updated_at": uploaded_at,
        "audiobooks": items,
    }
    key = _catalog_key(config)
    s3.put_object(
        Bucket=config.bucket,
        Key=key,
        Body=json.dumps(catalog, indent=2, ensure_ascii=False).encode("utf-8"),
        ContentType="application/json; charset=utf-8",
    )
    return key


def _read_catalog(s3: Any, config: S3Config) -> dict[str, Any]:
    try:
        response = s3.get_object(Bucket=config.bucket, Key=_catalog_key(config))
    except Exception as exc:
        error = getattr(exc, "response", {}).get("Error", {})
        if error.get("Code") in {"NoSuchKey", "404", "NotFound"}:
            return {}
        # Lightweight test doubles and some S3-compatible providers use
        # FileNotFoundError for a missing object.
        if isinstance(exc, (FileNotFoundError, KeyError)):
            return {}
        raise
    body = response["Body"].read()
    value = json.loads(body)
    return value if isinstance(value, dict) else {}


def _catalog_key(config: S3Config) -> str:
    return f"{config.prefix}/catalog.json"


def _content_type(path: Path) -> str:
    if path.suffix == ".m4a":
        return "audio/mp4"
    if path.suffix == ".wav":
        return "audio/wav"
    if path.suffix.lower() in {".jpg", ".jpeg"}:
        return "image/jpeg"
    if path.suffix.lower() == ".png":
        return "image/png"
    if path.suffix.lower() == ".webp":
        return "image/webp"
    if path.suffix.lower() == ".gif":
        return "image/gif"
    if path.suffix.lower() == ".svg":
        return "image/svg+xml"
    return "application/octet-stream"
