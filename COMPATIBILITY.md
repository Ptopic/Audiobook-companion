# Compatibility Notes

Checked against `audiobook.koplugin` source cloned at `/tmp/audiobook.koplugin` and the GitHub release/issue metadata available on 2026-10-01.

- Latest GitHub release observed: `v0.2.11`, published 2026-09-30, asset `audiobook-koplugin-v0.2.11.zip`.
- Source HEAD observed: `f917cb797bef65508fb685e2f65bd296b3f591d3`.
- README describes synchronized word highlighting, page turns, Bluetooth, Storyteller compatibility, and EPUB 3 Media Overlay work in progress:
  - `https://github.com/stradichenko/audiobook.koplugin`
  - `https://github.com/stradichenko/audiobook.koplugin/releases/tag/v0.2.11`
- The plugin detects `.smil` files in the EPUB zip, loads media overlays in OPF spine order, and groups timing entries by resolved audio path.
- The exporter emits one WAV per chapter and SMIL clip offsets that restart per chapter audio file.
- OPF manifest additions are self-closing `<item .../>` entries because the plugin parser expects that shape.
- SMIL entries use `<par><text src="chapter.xhtml#id"/><audio src="audio.wav" clipBegin="0.000s" clipEnd="1.250s"/></par>`.
- SMIL `text` and `audio` `src` values must resolve relative to the SMIL file path. Because this app stores SMIL under `media-overlays/` and audio under `audio/`, generated SMIL uses paths like `../Text/part0007.xhtml#kaud-0001` and `../audio/x_chapter2.wav`.
- Highlighting granularity is paragraph/heading chunk level in this MVP. It does not generate or label estimated word timings as exact.
- Kindle-side playback is still unverified. The plugin notes Kindle GStreamer limitations where raw PCM WAV is the safest synced audio format; MP3 should not be treated as verified synced Kindle compatibility.
- Issue #64 was a closed aligned/enriched audiobook highlighting/page-turn bug, which is evidence that this path exists but not evidence that this app's output works on your Kindle:
  - `https://github.com/stradichenko/audiobook.koplugin/issues/64`
