"""Sintetiza cada fala e encaixa no tempo da fala original."""
from __future__ import annotations

import hashlib
import logging
import os
import subprocess
import threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from statistics import median
from typing import Callable

import numpy as np

from ..config import Settings
from .download import PipelineError
from .segment import Utterance
from .translate import CHARS_PER_SECOND
from .mix import HOP_S, rms_envelope, speech_level
from .tts import TTSEngine, prepare_text

log = logging.getLogger(__name__)

MARGIN_S = 0.12           # respiro antes da próxima fala
GAP_S = 0.08              # distância mínima entre duas falas dubladas
SPEED_GAIN = 0.65         # pedir speed=1.3 ao Kokoro encurta ~1.2x: o ganho real é ~65% do pedido
MAX_BASE_SPEED = 1.25     # ritmo-base do vídeo inteiro, para a voz não ficar alternando lento/rápido
MAX_STRETCH = 1.15        # compressão extra (atempo) depois de esgotar o speed do TTS
MAX_DELAY_S = 1.2         # a dublagem nunca termina mais que isso depois da janela da fala
MAX_TOTAL_SPEED = 1.75    # acima disso a fala fica ininteligível: melhor cortar o fim
TOLERANCE = 1.04
WORKERS = 3
DYN_MIN_DB, DYN_MAX_DB = -8.0, 6.0   # quanto uma fala pode se afastar do nível médio para seguir a original
DYN_TRUST_DB = 12.0                  # janela original fora disso em relação à mediana = legenda desalinhada


@dataclass
class Placed:
    utterance: Utterance
    audio: np.ndarray
    at: float             # instante em que a fala dublada entra
    speed: float          # aceleração efetiva aplicada
    delay: float          # atraso em relação à fala original


def _requested(effective: float) -> float:
    return min(2.0, 1.0 + (effective - 1.0) / SPEED_GAIN)


def _atempo(audio: np.ndarray, sample_rate: int, factor: float) -> np.ndarray:
    proc = subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-f", "f32le", "-ar", str(sample_rate), "-ac", "1", "-i", "pipe:0",
         "-filter:a", f"atempo={factor:.4f}", "-f", "f32le", "pipe:1"],
        input=audio.astype(np.float32).tobytes(), capture_output=True,
    )
    if proc.returncode != 0 or not proc.stdout:
        log.warning("atempo falhou, mantendo áudio sem compressão: %s", proc.stderr.decode()[-200:])
        return audio
    return np.frombuffer(proc.stdout, dtype=np.float32).copy()


def _fade(audio: np.ndarray, sample_rate: int) -> np.ndarray:
    n = min(len(audio) // 2, int(sample_rate * 0.008))
    if n > 0:
        ramp = np.linspace(0.0, 1.0, n, dtype=np.float32)
        audio[:n] *= ramp
        audio[-n:] *= ramp[::-1]
    return audio


class _ClipCache:
    def __init__(self, directory: Path, engine: TTSEngine, voice: str) -> None:
        self.directory = directory
        self.engine = engine
        self.voice = voice
        directory.mkdir(parents=True, exist_ok=True)

    def get(self, text: str, speed: float) -> np.ndarray:
        key = hashlib.sha1(f"{self.voice}|{speed:.3f}|{prepare_text(text)}".encode()).hexdigest()[:20]
        path = self.directory / f"{key}.npy"
        if path.exists():
            return np.load(path)
        audio = self.engine.synthesize(text, self.voice, speed)
        # Falas com o mesmo texto caem na mesma chave em threads paralelas: gravar num temporário e
        # renomear garante que ninguém leia um arquivo pela metade.
        partial = self.directory / f"{key}.{threading.get_ident()}.tmp"
        with open(partial, "wb") as handle:
            np.save(handle, audio)
        os.replace(partial, path)
        return audio


def synthesize_and_fit(
    utterances: list[Utterance],
    engine: TTSEngine,
    settings: Settings,
    cache_dir: Path,
    progress: Callable[[float], None] | None = None,
    cancelled: Callable[[], bool] | None = None,
) -> tuple[list[Placed], dict]:
    sr = engine.sample_rate
    todo = [u for u in utterances if u.text.strip()]
    if not todo:
        raise PipelineError("As legendas não têm nenhuma fala para dublar.")
    clips = _ClipCache(cache_dir, engine, settings.voice)
    allowed = {u.id: max(0.4, u.window_end - u.start - MARGIN_S) for u in todo}

    # 1) Ritmo-base do vídeo a partir do tamanho dos textos; cada fala só acelera acima dele se precisar.
    needed = {u.id: (len(prepare_text(u.text)) / CHARS_PER_SECOND) / allowed[u.id] for u in todo}
    base = float(np.clip(median(needed.values()), settings.base_speed, MAX_BASE_SPEED))
    target = {u.id: float(np.clip(max(base, needed[u.id]), base, settings.max_speed)) for u in todo}

    done = 0
    total_steps = len(todo) * 1.25  # a 2ª passada costuma refazer ~25% das falas

    def run(batch: list[tuple[Utterance, float]]) -> dict[int, np.ndarray]:
        nonlocal done
        results: dict[int, np.ndarray] = {}

        def one(item: tuple[Utterance, float]) -> tuple[int, np.ndarray]:
            if cancelled and cancelled():
                raise PipelineError("cancelado")
            utterance, effective = item
            return utterance.id, clips.get(utterance.text, round(_requested(effective), 2))

        with ThreadPoolExecutor(max_workers=WORKERS) as pool:
            for uid, audio in pool.map(one, batch):
                results[uid] = audio
                done += 1
                if progress:
                    progress(min(0.99, done / total_steps))
        return results

    audio = run([(u, target[u.id]) for u in todo])

    # 2) Quem ainda estourou a janela é refeito mais rápido, com a razão medida de verdade.
    retry: list[tuple[Utterance, float]] = []
    for u in todo:
        ratio = (len(audio[u.id]) / sr) / allowed[u.id]
        if ratio > TOLERANCE and target[u.id] < settings.max_speed - 0.01:
            target[u.id] = float(min(settings.max_speed, target[u.id] * ratio * 1.02))
            retry.append((u, target[u.id]))
    if retry:
        total_steps = max(total_steps, done + len(retry))
        audio.update(run(retry))

    # 3) Último recurso: compressão no tempo; o que sobrar vira atraso, absorvido nas pausas seguintes.
    placed: list[Placed] = []
    cursor = 0.0
    truncated = 0
    for u in todo:
        clip = audio[u.id]
        ratio = (len(clip) / sr) / allowed[u.id]
        speed = target[u.id]
        if ratio > TOLERANCE:
            factor = min(MAX_STRETCH, ratio)
            clip = _atempo(clip, sr, factor)
            speed *= factor
        at = max(u.start, cursor)
        room = max(0.3, u.window_end + MAX_DELAY_S - at)
        if len(clip) / sr > room:
            # Teto rígido de atraso: comprime até o limite do inteligível e corta o que ainda sobrar.
            factor = min(MAX_TOTAL_SPEED / speed, (len(clip) / sr) / room)
            if factor > 1.01:
                clip = _atempo(clip, sr, factor)
                speed *= factor
            if len(clip) / sr > room:
                clip = clip[: int(room * sr)]
                truncated += 1
        clip = _fade(clip.copy(), sr)
        placed.append(Placed(utterance=u, audio=clip, at=at, speed=speed, delay=at - u.start))
        cursor = at + len(clip) / sr + GAP_S
    if progress:
        progress(1.0)

    delays = [p.delay for p in placed]
    speeds = [p.speed for p in placed]
    report = {
        "falas": len(placed),
        "ritmo_base": round(base, 2),
        "velocidade_media": round(float(np.mean(speeds)), 2),
        "velocidade_maxima": round(float(np.max(speeds)), 2),
        "falas_aceleradas": sum(1 for s in speeds if s > base + 0.05),
        "falas_atrasadas": sum(1 for d in delays if d > 0.5),
        "atraso_maximo_s": round(float(np.max(delays)), 2),
        "falas_cortadas": truncated,
    }
    return placed, report


def utterance_gains(placed: list[Placed], sample_rate: int, envelope: np.ndarray, hop_s: float = HOP_S) -> list[float]:
    """Ganho por fala (dB) para a dublagem seguir a dinâmica da voz original: sussurro fica sussurro.

    Compara, fala a fala, o nível da voz original na janela dela com o nível do clipe de TTS, ambos
    relativos às suas próprias medianas. O nível global é acertado depois, na mixagem.
    """
    original = [
        speech_level(envelope[int(p.utterance.start / hop_s): int(p.utterance.speech_end / hop_s)]) for p in placed
    ]
    dubbed = [speech_level(rms_envelope(p.audio, sample_rate, hop_s)) for p in placed]
    pairs = [(o, d) for o, d in zip(original, dubbed) if o is not None and d is not None]
    if len(pairs) < 3:
        return [0.0] * len(placed)
    original_ref = median(o for o, _ in pairs)
    dubbed_ref = median(d for _, d in pairs)
    gains: list[float] = []
    for o, d in zip(original, dubbed):
        if o is None or d is None or abs(o - original_ref) > DYN_TRUST_DB:
            gains.append(0.0)
            continue
        gains.append(float(np.clip((o - original_ref) - (d - dubbed_ref), DYN_MIN_DB, DYN_MAX_DB)))
    return gains


def render_voice_track(
    placed: list[Placed], sample_rate: int, duration: float, gains_db: list[float] | None = None
) -> np.ndarray:
    end = max([duration] + [p.at + len(p.audio) / sample_rate for p in placed])
    track = np.zeros(int(end * sample_rate) + 1, dtype=np.float32)
    for index, p in enumerate(placed):
        i = int(p.at * sample_rate)
        gain = 10 ** (gains_db[index] / 20) if gains_db else 1.0
        track[i:i + len(p.audio)] += p.audio * gain
    return track
