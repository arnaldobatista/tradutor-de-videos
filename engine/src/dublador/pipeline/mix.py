"""Mixa o fundo original com a voz dublada e exporta m4a."""
from __future__ import annotations

import logging
import subprocess
from pathlib import Path

import numpy as np
import pyloudnorm
import soundfile as sf
import soxr

from .download import PipelineError

log = logging.getLogger(__name__)

DEFAULT_LUFS = -18.0
HOP_S = 0.05              # passo do envelope de nível da voz original
SILENCE_DB = -60.0
YOUTUBE_LUFS = -14.0      # o YouTube abaixa vídeos mais altos que isso; o dublado segue a mesma regra
PEAK = 0.97


def _loudness(audio: np.ndarray, rate: int) -> float | None:
    if len(audio) < rate:  # o medidor precisa de pelo menos 400 ms; abaixo de 1 s não é confiável
        return None
    try:
        value = pyloudnorm.Meter(rate).integrated_loudness(audio)
    except ValueError:
        return None
    return float(value) if np.isfinite(value) else None


def _stereo(mono: np.ndarray) -> np.ndarray:
    return np.repeat(mono[:, None], 2, axis=1)


def rms_envelope(mono: np.ndarray, rate: int, hop_s: float = HOP_S) -> np.ndarray:
    """Nível RMS em dBFS a cada `hop_s`. Serve para comparar a dinâmica da voz original com a dublada."""
    hop = max(1, int(rate * hop_s))
    count = len(mono) // hop
    if count == 0:
        return np.zeros(0, dtype=np.float32)
    frames = mono[: count * hop].astype(np.float64).reshape(count, hop)
    rms = np.sqrt(np.mean(frames ** 2, axis=1))
    return (20 * np.log10(rms + 1e-9)).astype(np.float32)


def speech_level(env_db: np.ndarray) -> float | None:
    """Nível médio (dB) dos trechos com fala de um envelope; None se não houver fala suficiente."""
    env = env_db[env_db > SILENCE_DB]
    if len(env) < 3:
        return None
    voiced = env[env >= env.max() - 25.0]
    return float(10 * np.log10(np.mean(10 ** (voiced / 10))))


def analyze_voice(vocals_path: Path) -> tuple[dict, np.ndarray]:
    """Volume da voz original (LUFS, medido em estéreo) e o envelope dela, para a dublada seguir a mesma dinâmica."""
    original, rate = sf.read(vocals_path, dtype="float32", always_2d=True)
    level = _loudness(original, rate)
    lufs = float(np.clip(level, -28.0, -12.0)) if level is not None else DEFAULT_LUFS
    return {"voz_lufs": round(lufs, 2), "hop_s": HOP_S}, rms_envelope(original.mean(axis=1), rate)


def _envelope(voice: np.ndarray, rate: int) -> np.ndarray:
    """Presença de voz entre 0 e 1, com ataque rápido e soltura lenta, para o ducking não bombear."""
    hop = int(rate * 0.02)
    frames = np.abs(voice[: len(voice) // hop * hop]).reshape(-1, hop).max(axis=1)
    active = (frames > 10 ** (-45 / 20)).astype(np.float32)
    smooth = np.empty_like(active)
    level = 0.0
    for i, value in enumerate(active):
        level += (value - level) * (0.5 if value > level else 0.07)
        smooth[i] = level
    return np.repeat(smooth, hop)


def mix_arrays(background: np.ndarray, target: float, voice: np.ndarray, rate: int, duck_db: float) -> tuple[np.ndarray, dict]:
    """`background` estéreo (N, 2) e `voice` mono (N,) na mesma taxa. Devolve a mix estéreo e as medições."""
    length = max(len(background), len(voice))
    if len(background) < length:
        background = np.pad(background, ((0, length - len(background)), (0, 0)))
    if len(voice) < length:
        voice = np.pad(voice, (0, length - len(voice)))

    # A voz dublada é mono no centro dos dois canais: medir já em estéreo, como a original foi medida,
    # senão ela sai 3 dB mais alta do que a original.
    current = _loudness(_stereo(voice), rate)
    if current is not None:
        voice = voice * 10 ** ((target - current) / 20)
    achieved = _loudness(_stereo(voice), rate)
    background_level = _loudness(background, rate)

    if duck_db < 0:
        envelope = _envelope(voice, rate)
        envelope = np.pad(envelope, (0, length - len(envelope)))
        background = background * (1.0 - envelope * (1.0 - 10 ** (duck_db / 20)))[:, None]

    mixed = background + voice[:, None]
    mix_level = _loudness(mixed, rate)
    if mix_level is not None and mix_level > YOUTUBE_LUFS:
        mixed = mixed * 10 ** ((YOUTUBE_LUFS - mix_level) / 20)
        mix_level = YOUTUBE_LUFS
    peak = float(np.max(np.abs(mixed))) if length else 0.0
    if peak > PEAK:
        mixed = mixed * (PEAK / peak)
    info = {
        "lufs_voz_original": round(target, 1),
        "lufs_voz_dublada": round(achieved, 1) if achieved is not None else None,
        "lufs_fundo": round(background_level, 1) if background_level is not None else None,
        "lufs_mix": round(mix_level, 1) if mix_level is not None else None,
        "pico": round(min(peak, PEAK), 3),
    }
    return mixed, info


def mix(
    background_path: Path,
    target: float,
    voice_track: np.ndarray,
    voice_rate: int,
    output: Path,
    duck_db: float,
) -> dict:
    background, rate = sf.read(background_path, dtype="float32", always_2d=True)
    voice = soxr.resample(voice_track, voice_rate, rate).astype(np.float32) if voice_rate != rate else voice_track
    mixed, info = mix_arrays(background, target, voice, rate, duck_db)

    wav = output.with_suffix(".mix.wav")
    sf.write(wav, mixed, rate, subtype="PCM_16")
    proc = subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", str(wav), "-c:a", "aac", "-b:a", "160k",
         "-movflags", "+faststart", str(output)],
        capture_output=True, text=True,
    )
    wav.unlink(missing_ok=True)
    if proc.returncode != 0:
        raise PipelineError(f"ffmpeg falhou ao exportar o áudio final: {proc.stderr.strip()[-300:]}")
    info["duracao_mix_s"] = round(len(mixed) / rate, 1)
    return info
