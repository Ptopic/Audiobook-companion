# Evidence

This file is updated by the implementer with commands run, results, artifacts, and limitations.

## Implemented

- FastAPI app bound by default to `127.0.0.1:8765`.
- EPUB marker files such as `META-INF/rights.xml` and `META-INF/encryption.xml` are ignored when content is otherwise readable; the app does not remove DRM or decrypt unreadable content.
- EPUB spine parsing through `META-INF/container.xml` and OPF manifest/spine.
- Plain text chapter UI with include/exclude toggles.
- Voice/speed preview endpoint and player.
- Local Kokoro MLX speech generation using `mlx-audio==0.5.7` and `mlx-community/Kokoro-82M-bf16`.
- Sine test tone remains available for export/debug checks, but it is not speech.
- New uploads start with all chapters deselected, so generation only runs for explicitly selected chapters.
- Persistent jobs in SQLite with resume-friendly cache reuse and cancel status.
- WAV chapter playback and EPUB 3 Media Overlay export.
- iPhone audiobook package export with `manifest.json`, chapter audio, segment timestamps, ZIP download, and local catalog APIs.
- Optional environment-driven S3 upload using `boto3`; credentials are not stored in the app.
- SwiftUI iPhone app under `ios/AudiobookCompanion` with catalog loading, AVPlayer playback, speed controls, current segment display, tap-to-seek, and background audio mode.
- Paragraph/heading-level XHTML span IDs for media overlay references, preserving original chapter structure instead of rebuilding chapter bodies from plain text.
- Book deletion endpoint and UI control for removing local uploads/jobs.
- Tests for fixture parsing, readable marker-file EPUBs, generation/cache, export references, and timestamps.
- Tests for iPhone package manifest/ZIP contents, segment monotonicity, and S3 configuration behavior.

## Commands

- `.venv/bin/python -m pytest -q`
  - Result after marker-file upload patch: `3 passed in 0.06s`
- `.venv/bin/python samples/make_sample.py`
  - Result: generated `samples/fixture.epub`
  - Result: generated aligned export `data/jobs/1884500460fde39b/7ffbdd9f32eaf32f-aligned.epub`
  - Result: generated sample WAV files:
    - `data/jobs/1884500460fde39b/audio/c1.wav`
    - `data/jobs/1884500460fde39b/audio/c2.wav`
- `.venv/bin/python - <<'PY' ...`
  - Result: checked `data/jobs/1884500460fde39b/7ffbdd9f32eaf32f-aligned.epub`
  - Result: SMIL files found: `OEBPS/media-overlays/c1.smil`, `OEBPS/media-overlays/c2.smil`
  - Result: every SMIL text/audio reference resolved; timestamps were monotonic and within WAV duration.
- `command -v epubcheck`
  - Result: no output; `epubcheck` is not installed, so EPUBCheck validation was skipped.
- `.venv/bin/python -m backend`
  - Result: Uvicorn bound to `http://127.0.0.1:8765`
- `curl -sS http://127.0.0.1:8765/api/health`
  - Result: `{"ok":true,"host":"127.0.0.1","network":"local-only"}`
- `.venv/bin/python -m pip install mlx-audio==0.5.7 misaki==0.7.4 num2words==0.5.14 phonemizer==3.4.0 spacy==3.8.16`
  - Result: Kokoro MLX dependencies installed in the project virtualenv.
- `brew install espeak-ng`
  - Result: `espeak-ng` installed for Kokoro English phonemization.
- `.venv/bin/python - <<'PY' ...`
  - Result: direct Kokoro smoke generated `data/cache/kokoro-smoke.wav`, duration `2.8s`, size `134444` bytes.
- `.venv/bin/python -m pytest -q`
  - Result after Kokoro/default-selection patch: `4 passed, 1 warning in 0.33s`
- `curl -sS -X POST http://127.0.0.1:8765/api/preview ... -o /tmp/kokoro-preview.wav`
  - Result: API preview generated a Kokoro WAV: 16-bit mono, 24000 Hz, duration `5.075s`.
- User device test reported KOReader plugin action **Play aligned audiobook from here** but then **no audio found**.
  - Root cause found in generated EPUB package: OPF source items had invalid syntax like `/ media-overlay="..."`, and SMIL files referenced `audio/*.wav` relative to `media-overlays/` instead of `../audio/*.wav`.
  - Fix: OPF `media-overlay` attributes are now inserted before any self-closing slash, and SMIL text/audio references are relative to the SMIL file directory.
  - Existing completed exports were repackaged in place.
  - Verification: `.venv/bin/python -m pytest -q` returned `4 passed, 1 warning in 0.41s`; inspected repackaged EPUBs and confirmed SMIL text/audio references normalize to real zip members.
- Pivoted primary playback to iPhone app because Kindle audio playback was unreliable.
  - `.venv/bin/python -m pytest -q`
    - Result: `6 passed, 1 warning in 0.53s`.
  - XcodeBuildMCP `build_sim`
    - Result: `SUCCEEDED` for `ios/AudiobookCompanion/AudiobookCompanion.xcodeproj`, scheme `AudiobookCompanion`, simulator `MyMind iPhone 17`, no warnings.
  - Repackaged completed jobs into iPhone packages.
    - Example: `data/jobs/643055b4a8bb3953/iphone-package.zip`, size `23109127` bytes.
  - `GET /api/audiobooks`
    - Result: returned completed package catalog entries including A Killer's Wife.
  - `GET /api/audiobooks/643055b4a8bb3953/manifest`
    - Result: returned `iphone-audiobook-v1`, title `A Killer’s Wife`, 4 chapters, and segment/audio URLs.
  - `GET /api/audiobooks/643055b4a8bb3953/audio/x_chapter2` with a range request
    - Result: served `.m4a` audio bytes.

## Generated Artifacts

- Local virtualenv: `.venv/`
- App state database: `data/app.sqlite3`
- Sample source EPUB: `samples/fixture.epub`
- Sample aligned EPUB: `data/jobs/1884500460fde39b/7ffbdd9f32eaf32f-aligned.epub`
- Example iPhone package ZIP: `data/jobs/643055b4a8bb3953/iphone-package.zip`
- iOS app project: `ios/AudiobookCompanion/AudiobookCompanion.xcodeproj`
- Sample chapter WAV files: `data/jobs/1884500460fde39b/audio/*.wav`

## Limitations

- Chunk timing is paragraph/heading level for this MVP, not word level.
- The app does not invent word timings.
- Kokoro first-run setup needs internet for package/model/voice downloads; after that it uses cached local files.
- Kindle physical playback remains unverified until tested on a device.
- Kokoro MLX generation is Apple Silicon/macOS-specific; Linux VPS generation needs a different local TTS backend.
- S3 streaming in the iPhone app needs HTTPS URLs via `AUDIOBOOK_S3_PUBLIC_BASE_URL` or another reachable HTTPS catalog/audio host.
- iPhone app currently streams; offline chapter downloads are not implemented yet.
