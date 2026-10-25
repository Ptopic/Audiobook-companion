# Kindle Audio Books

A FastAPI audiobook generator plus a small iPhone SwiftUI listener. It turns a readable EPUB into local narration, exports an iPhone-friendly audiobook package, and still keeps the older EPUB 3 Media Overlay export for KOReader experiments.

No paid TTS APIs or telemetry are used. The server binds to `127.0.0.1` by default. S3 upload is optional and only runs when you trigger it with S3 environment variables configured.

## Run

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python -m backend
```

Open <http://127.0.0.1:8765>.

## Tests

With the Python environment above active:

```bash
pip install -r requirements-test.txt
python -m pytest tests -q
```

## Recommended Architecture

- Generate audiobooks on the FastAPI backend.
- Package each completed job as `manifest.json` plus chapter audio under `data/jobs/<job_id>/iphone-package/`.
- Optionally upload that package to S3/CDN.
- Listen in the iPhone app while reading separately on Kindle.

Kokoro MLX is Apple Silicon/macOS-specific. A Linux VPS such as `petarvps` can host the FastAPI catalog and S3 upload path, but it cannot run `mlx-audio` unless that VPS is Apple Silicon macOS. For Linux VPS generation, add a non-MLX Kokoro backend, ONNX/PyTorch TTS, or generate on the Mac and sync packages to the VPS/S3.

## Engines

- `kokoro`: default local text-to-speech engine using `mlx-audio==0.5.7` and `mlx-community/Kokoro-82M-bf16`.
- `sine`: deterministic local WAV test tone only. It is useful for export/debug checks, but it is not speech.

Kokoro also needs `espeak-ng` available on macOS for the English frontend:

```bash
brew install espeak-ng
```

The first Kokoro preview/generation may download the Kokoro model, voice files, and a small spaCy English model. After those files are cached locally, narration runs offline.

## Workflow

1. Upload an EPUB.
2. Review spine-ordered chapters and select only the sections you want narrated. New uploads start with all chapters deselected.
3. Choose engine, voice, speed, and optional pronunciation replacements.
4. Generate locally. Jobs persist in `data/app.sqlite3`; generated audio and exports live under `data/jobs`.
5. Play generated chapters in the browser.
6. Download the iPhone package ZIP, open the manifest, or upload the package to S3.
7. The aligned EPUB export remains available as a legacy Kindle experiment.

The iPhone package is now the primary output. Kindle physical playback is not the recommended path because device audio playback proved unreliable.

## iPhone App

Open the Xcode project:

```bash
open ios/AudiobookCompanion/AudiobookCompanion.xcodeproj
```

Run the `AudiobookCompanion` scheme. The app:

- lists completed packages from `/api/audiobooks`
- loads each package manifest
- streams chapter `.m4a` or `.wav` audio with `AVPlayer`
- supports play/pause and speed changes
- shows the current paragraph/segment text
- lets you tap a segment to seek and start playback there
- enables iOS background audio mode

For the iOS simulator, `http://127.0.0.1:8765/` works. For a physical iPhone, use a URL the phone can reach, such as your Mac LAN IP or an HTTPS VPS/CDN URL.

## S3 Upload

Install dependencies, then set environment variables before starting the server:

```bash
export AUDIOBOOK_S3_BUCKET="your-private-bucket"
export AUDIOBOOK_S3_PREFIX="audiobooks"
export AUDIOBOOK_S3_PUBLIC_BASE_URL="https://your-cdn.example.com"
python -m backend
```

The public base URL must be HTTPS and must resolve to the uploaded S3 keys, otherwise the iPhone app cannot stream the audio. AWS credentials should come from the normal AWS environment, profile, or instance role; never put credentials in this repo.

Each upload also updates `<prefix>/catalog.json`. The catalog contains one entry per stable EPUB `book_id`, so uploading the same book again replaces its prior catalog entry while leaving its old assets untouched. `/api/audiobooks` merges this shared catalog with local completed jobs, allowing the iPhone app to discover books generated and uploaded from another machine.

The iPhone player's **Delete Audiobook** menu calls an authenticated `DELETE /api/audiobooks/{id}` endpoint. It removes the selected audiobook's S3 package/catalog entry and completed VPS-local audio versions for that book, but preserves the uploaded source EPUB and unfinished jobs. The app confirms before deleting and only removes the Library card after the server succeeds.

## Remote Mac Narration Worker

The public service at `https://books.petartopic.com` can queue selected EPUB chapters. Narration still runs on an Apple Silicon Mac with Kokoro MLX. On the Mac, from this repository:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
brew install espeak-ng ffmpeg
export AUDIOBOOK_REMOTE_TOKEN="shared-worker-token"
export AUDIOBOOK_REMOTE_BASE_URL="https://books.petartopic.com"
export AUDIOBOOK_S3_BUCKET="your-bucket"
export AUDIOBOOK_S3_PREFIX="audiobooks"
export AUDIOBOOK_S3_PUBLIC_BASE_URL="https://your-cdn.example.com"
python -m backend.remote_worker
```

Set AWS credentials through a profile or the usual `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and optional `AWS_SESSION_TOKEN`. For S3-compatible storage, also set `AUDIOBOOK_S3_ENDPOINT`. The public HTTPS base URL must serve the uploaded keys; the completed remote job links directly to its uploaded `manifest.json`. Keep the remote token and S3 credentials out of this repository.

The worker polls every 30 seconds (`--poll-seconds` can increase this), holds one job at a time, and sends progress every 30 seconds during narration to renew its remote lease. Its remote-to-local mapping is in `data/remote-worker.json`, and the local SQLite jobs and audio cache survive restarts. Run only one worker process per Mac/repository; a lock file prevents a second instance. If S3 or the network fails after narration, restart the worker to retry the upload and completion report without synthesizing the finished local job again. If narration fails, use Retry in the iPhone app: the worker reclaims the same remote job, resumes its local job, and reuses completed audio chunks. Persistent failures can be inspected in the local job data and worker logs.

Kokoro speech uses local inference and no paid API. The first run may download model files; afterward speech generation can work offline, but claiming jobs, renewing the lease, and uploading packages require network access. Keep the Mac awake and connected while processing a job. A lease that expires during a long outage can be reassigned by the VPS.

To start the worker automatically at Mac login, add `AUDIOBOOK_REMOTE_TOKEN=...` to the project `.env` using the same secret configured for `AUDIOBOOK_REMOTE_TOKEN` on the VPS. The existing `.env` can supply the S3 settings above. Then run:

```bash
bash scripts/install-remote-worker.sh
```

The installer copies `backend/`, `.venv/`, `.env`, and the worker runner to `~/Library/Application Support/KindleAudioBooks/worker/`, then starts a per-user LaunchAgent from that directory. This keeps launchd clear of macOS Desktop privacy restrictions. The staged `.env` is private (`0600`), and the token is neither written to the plist nor printed. The original project and its `data/` directory stay in place; the staged worker has its own `data/` for jobs and cached audio. Rerun the installer after changing code, dependencies, or `.env`.

LaunchAgent logs are in `~/Library/Application Support/KindleAudioBooks/worker/data/remote-worker.stdout.log` and `remote-worker.stderr.log`. To stop automatic startup, run `launchctl bootout "gui/$(id -u)/com.petartopic.kindle-audio-books.remote-worker"` and remove `~/Library/LaunchAgents/com.petartopic.kindle-audio-books.remote-worker.plist`.

## Storage and Offline Use

- Uploaded books: `data/uploads/`
- Reusable chunk cache: `data/cache/`
- Jobs, chapter WAVs, and exports: `data/jobs/`
- iPhone packages: `data/jobs/<job_id>/iphone-package/` and `data/jobs/<job_id>/iphone-package.zip`
- App database: `data/app.sqlite3`

After Python packages, `espeak-ng`, and Kokoro model files are installed, generation uses local files only. The EPUB content is parsed as untrusted ZIP/XML; embedded scripts and remote resources are not executed or fetched. Marker files such as `META-INF/encryption.xml` are ignored when the content is otherwise readable; the app does not remove DRM or decrypt unreadable content. Use **Delete book data** in the app to remove a book upload and its jobs.

## Kindle Transfer Test

This path is legacy/experimental. Prefer the iPhone app for listening.

1. Install the `audiobook-koplugin-v0.2.11.zip` release from `audiobook.koplugin`, not GitHub’s source ZIP.
2. Copy the exported `*-aligned.epub` to the Kindle documents folder.
3. Start KOReader, pair Bluetooth headphones in Kindle settings, then open the exported EPUB.
4. Use **Play aligned audiobook from here** or **Play aligned/enriched audiobook**.
5. Confirm audio leaves the Kindle over Bluetooth, highlighting follows paragraph/heading chunks, and pages advance.
6. Report whether playback works; until then the app shows Kindle playback as unverified.

## Sample

Regenerate the local sample with:

```bash
.venv/bin/python samples/make_sample.py
```

The current sample export is `data/jobs/1884500460fde39b/7ffbdd9f32eaf32f-aligned.epub`. Existing completed jobs have iPhone packages under `data/jobs/<job_id>/iphone-package.zip`.
