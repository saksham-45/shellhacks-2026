"""Create disposable 16 kHz PCM fixtures for the spike."""
from __future__ import annotations

import math
import shutil
import subprocess
import tempfile
import wave
from pathlib import Path

RATE = 16_000


def _resample_mono(raw: bytes, source_rate: int, channels: int) -> bytes:
    import array
    samples = array.array("h")
    samples.frombytes(raw)
    if channels > 1:
        samples = array.array("h", samples[::channels])
    if source_rate == RATE:
        return samples.tobytes()
    output_len = max(1, int(len(samples) * RATE / source_rate))
    out = array.array("h")
    for i in range(output_len):
        src = min(len(samples) - 1, int(i * source_rate / RATE))
        out.append(samples[src])
    return out.tobytes()


def _synthesize(command: str, phrase: str, destination: Path) -> bool:
    with tempfile.TemporaryDirectory() as tmp:
        wav_path = Path(tmp) / "spoken.wav"
        if command == "espeak-ng":
            args = [command, "-w", str(wav_path), "-s", "145", phrase]
        else:
            args = [command, "-w", str(wav_path), phrase]
        try:
            subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            with wave.open(str(wav_path), "rb") as wav:
                raw = wav.readframes(wav.getnframes())
                pcm = _resample_mono(raw, wav.getframerate(), wav.getnchannels())
            destination.write_bytes(pcm)
            return True
        except (OSError, subprocess.SubprocessError, EOFError, wave.Error, ValueError):
            return False


def _tone_clip(path: Path) -> None:
    frames = bytearray()
    for i in range(int(RATE * 0.6)):
        sample = int(0.18 * 32767 * math.sin(2 * math.pi * 440 * i / RATE))
        frames += int(sample).to_bytes(2, "little", signed=True)
    frames += b"\x00\x00" * int(RATE * 0.8)
    path.write_bytes(bytes(frames))


def ensure_clips(directory: str | Path) -> dict[str, object]:
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    commands = [("espeak-ng", "english"), ("pico2wave", "spanish")]
    phrases = {
        "english": "When is trash day?",
        "spanish": "¿Cuándo pasa la basura?",
    }
    source = "speech"
    for command, name in commands:
        path = directory / f"{name}.pcm"
        if not (shutil.which(command) and _synthesize(command, phrases[name], path)):
            _tone_clip(path)
            source = "tone+silence"
    return {"source": source, "sample_rate": RATE, "channels": 1, "bits": 16}
