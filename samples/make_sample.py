from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from backend.jobs import JobStore, run_job  # noqa: E402
from tests.fixtures import make_epub  # noqa: E402


def main() -> None:
    source = ROOT / "samples" / "fixture.epub"
    make_epub(source)
    store = JobStore()
    book = store.save_upload("fixture.epub", source.read_bytes())
    job_id = store.create_job(
        book.id,
        {
            "engine": "sine",
            "voice": "af_heart",
            "speed": 1.0,
            "include_chapters": [chapter.id for chapter in book.chapters],
            "replacements": {},
        },
    )
    run_job(store, job_id)
    job = store.get_job(job_id)
    if job["status"] != "done":
        raise SystemExit(f"Sample generation failed: {job['message']}")
    print(f"Sample EPUB: {source}")
    print(f"Aligned export: {job['artifacts']['export_epub']}")
    for chapter_id, artifact in job["artifacts"]["chapters"].items():
        print(f"Audio {chapter_id}: {artifact['audio']}")


if __name__ == "__main__":
    main()
