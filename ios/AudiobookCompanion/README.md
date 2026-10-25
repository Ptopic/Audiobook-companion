# Audiobook Companion iOS App

Small SwiftUI client for the FastAPI audiobook catalog.

## Run In Xcode

1. Open `AudiobookCompanion.xcodeproj` in Xcode.
2. Pick the `AudiobookCompanion` scheme and an iPhone simulator or device.
3. The default server URL is `https://books.petartopic.com/`.

## Install On iPhone

This project reuses the same install workflow shape as the My Mind iOS app.

Direct build, install, and launch on the first available paired iPhone:

```bash
cd /Users/petartopic/Desktop/Petar/kindle-audio-books/ios/AudiobookCompanion
./scripts/run-device.sh
```

If more than one iPhone is available, pass the device UDID:

```bash
DEVICE_ID=00008150-000E55010243C01C ./scripts/run-device.sh
```

Build and publish an Ad Hoc OTA install page:

```bash
cd /Users/petartopic/Desktop/Petar/kindle-audio-books/ios/AudiobookCompanion
./scripts/build-and-publish-ota.sh
```

The OTA files are written to the same Mission Control public directory pattern as My Mind:

```text
/Users/petartopic/Desktop/Petar/get-stuff-done/apps/mission-control-app/ui/public/my-mind/ota/audiobook-companion/latest/
```

Current OTA install page:

```text
https://frontend.petartopic.com/my-mind/ota/audiobook-companion/latest/
```

To publish directly to the current `ptopic-kb` VPS static OTA folder:

```bash
VPS_OTA_TARGET="petarvps:/home/petar/projects/ptopic-kb/backend/.mind-storage/ota/audiobook-companion/latest" \
  ./scripts/publish-ota.sh
```

For OTA export, automatic signing is attempted with team `RFRVD795TK`. If Apple requires a named Ad Hoc provisioning profile, create one for `com.petar.audiobookcompanion`, then run:

```bash
PROVISIONING_PROFILE_NAME="Audiobook Companion Ad Hoc" ./scripts/build-and-publish-ota.sh
```

`EXPORT_METHOD=development ./scripts/build-adhoc-ipa.sh` is not a reliable fallback on this machine: Xcode export failed with "No Accounts" and a managed provisioning profile error. The current IPA was packaged from a valid signed development archive. Installation on a physical iPhone has not yet been verified.

## Create Audiobook

1. Open Settings and save the `AUDIOBOOK_REMOTE_TOKEN` value once. The app stores it in iOS Keychain and sends it only to the authenticated remote endpoints.
2. Open Create, choose an EPUB from iPhone Files or iCloud Drive, and wait for its chapters to load in book order. All chapters start unchecked; select the ones to narrate.
3. Choose a Kokoro voice and narration speed, then tap Create audiobook. The job is queued on the server.
4. Watch job status and progress in Create. Failed jobs show a Retry button. When a job is done, open Library and refresh to play the generated audiobook.

## Current MVP

- Lists completed audiobook packages from `/api/audiobooks`.
- Uploads EPUBs, queues remote narration jobs, and shows progress in Create.
- Loads `manifest.json`.
- Streams chapter audio with `AVPlayer`.
- Supports play/pause and speed selection.
- Deletes a generated audiobook from the player's top-right menu after confirmation; server storage and the Library entry are removed, while the uploaded source EPUB remains available for regeneration.
- Displays current segment text.
- Lets you tap a segment to seek and start playback there.
- Opens the original EPUB chapter from the player’s Read control, preserving the source HTML, images, and embedded styles while audio plays. The reader has measured in-chapter pages, page-turn controls, and a table of contents for chapter navigation; its play button starts or pauses audio for the displayed chapter. The Transcript tab remains available for segment seeking.
- Reader chapters require the authenticated `/api/remote/books/{book_id}/reader/{chapter_id}` endpoint and the remote token in Settings. If the endpoint is unavailable, the reader shows a retryable error without affecting audio playback.
- Enables iOS background audio mode.
- Publishes book, chapter, author, cover, elapsed time, and playback rate to iOS Now Playing.
- Accepts system and headset play/pause, 15-second skip, and position seeking commands. Headset next/previous track commands also move 15 seconds.
- Keeps the player alive when you return to Library, pauses when headphones disconnect, and resumes after a system interruption only when iOS recommends it and playback was active beforehand.

Device playback checklist (hardware behavior not yet verified): lock the phone while playing; test Lock Screen and Control Center play/pause, both 15-second skips, and scrubbing; change speed in the app and check time progression; test AirPods play/pause and next/previous gestures; try an incoming call and headphone disconnect; return Home and reopen the same book; open a second book and verify the first book's checkpoint and metadata do not carry over.

Run the playback policy regression tests with `swift test --package-path ios/AudiobookCompanion` from the repository root.

Offline downloads are the next natural step; this MVP streams from the backend or S3/CDN URLs.

## Edit Tool Test

This note was added to verify that README edits work normally.
This second line was added with an explicit patch tool call.
This third line was added with another explicit Edit tool call.
This fourth line was added with another explicit patch tool call.
