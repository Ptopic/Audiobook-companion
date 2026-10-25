from __future__ import annotations

import hashlib
import math
import wave
from pathlib import Path
from typing import Any

SAMPLE_RATE = 22_050
ENGINE_VERSION = "sine-v1"
KOKORO_MODEL = "mlx-community/Kokoro-82M-bf16"
KOKORO_VERSION = "mlx-audio-0.5.7:mlx-community/Kokoro-82M-bf16"
_KOKORO_MODEL_INSTANCE: Any | None = None


class TtsError(RuntimeError):
    pass


def cache_key(text: str, voice: str, speed: float, engine: str, replacements_hash: str) -> str:
    model_version = KOKORO_VERSION if engine == "kokoro" else ENGINE_VERSION
    payload = "\n".join([engine, model_version, voice, f"{speed:.3f}", replacements_hash, normalize_text(text)])
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def normalize_text(text: str) -> str:
    return " ".join(text.split())


def write_sine_wav(path: Path, text: str, speed: float = 1.0) -> float:
    path.parent.mkdir(parents=True, exist_ok=True)
    words = max(1, len(normalize_text(text).split()))
    duration = max(0.35, words * 0.20 / max(speed, 0.2))
    frames = int(duration * SAMPLE_RATE)
    freq = 330.0 + (len(text) % 120)
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        data = bytearray()
        for i in range(frames):
            envelope = min(1.0, i / 800) * min(1.0, (frames - i) / 800)
            sample = int(9000 * envelope * math.sin(2 * math.pi * freq * i / SAMPLE_RATE))
            data.extend(sample.to_bytes(2, "little", signed=True))
        wf.writeframes(bytes(data))
    return wav_duration(path)


def wav_duration(path: Path) -> float:
    with wave.open(str(path), "rb") as wf:
        return wf.getnframes() / float(wf.getframerate())


def concat_wavs(parts: list[Path], dest: Path) -> float:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if not parts:
        write_sine_wav(dest, "silence")
        return wav_duration(dest)
    with wave.open(str(parts[0]), "rb") as first:
        params = first.getparams()
        frames = [first.readframes(first.getnframes())]
    for part in parts[1:]:
        with wave.open(str(part), "rb") as wf:
            if wf.getparams()[:3] != params[:3]:
                raise TtsError(f"WAV parameter mismatch for {part}")
            frames.append(wf.readframes(wf.getnframes()))
    with wave.open(str(dest), "wb") as out:
        out.setparams(params)
        for chunk in frames:
            out.writeframes(chunk)
    return wav_duration(dest)


def synthesize(text: str, path: Path, engine: str, voice: str, speed: float) -> float:
    if engine == "sine":
        return write_sine_wav(path, text, speed)
    if engine == "kokoro":
        return synthesize_kokoro(text, path, voice, speed)
    raise TtsError(f"Unknown TTS engine: {engine}")


def synthesize_kokoro(text: str, path: Path, voice: str, speed: float) -> float:
    global _KOKORO_MODEL_INSTANCE
    try:
        import numpy as np  # type: ignore
        from mlx_audio.audio_io import write as audio_write  # type: ignore
        from mlx_audio.tts.utils import load_model  # type: ignore
    except Exception as exc:  # pragma: no cover - depends on optional MLX install
        raise TtsError("Kokoro requires mlx-audio==0.5.7 and misaki installed in this virtualenv") from exc
    if _KOKORO_MODEL_INSTANCE is None:
        _KOKORO_MODEL_INSTANCE = load_model(KOKORO_MODEL)
    model = _KOKORO_MODEL_INSTANCE
    chunks = []
    sample_rate = int(getattr(model, "sample_rate", SAMPLE_RATE) or SAMPLE_RATE)
    for result in model.generate(text, voice=voice or "af_heart", speed=speed, lang_code="a"):
        audio = getattr(result, "audio", result)
        chunks.append(np.asarray(audio, dtype=np.float32).reshape(-1))
        sample_rate = int(getattr(result, "sample_rate", sample_rate) or sample_rate)
    if not chunks:
        raise TtsError("Kokoro generated no audio")
    audio = np.concatenate(chunks)
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        audio_write(path, audio, sample_rate, format="wav")
    except Exception as exc:
        raise TtsError(f"Could not write Kokoro WAV output: {exc}") from exc
    return wav_duration(path)
