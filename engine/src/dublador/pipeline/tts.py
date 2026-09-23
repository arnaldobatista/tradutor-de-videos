"""TTS local. Hoje só Kokoro (ONNX); qualquer motor novo implementa a mesma interface."""
from __future__ import annotations

import logging
import re
import threading
import urllib.request
from typing import Protocol

import numpy as np

from ..config import KOKORO_BASE_URL, KOKORO_FILES, MODELS_DIR

log = logging.getLogger(__name__)

_EMOJI = re.compile("[\U0001F000-\U0001FAFF☀-➿️]")


class TTSEngine(Protocol):
    sample_rate: int

    def synthesize(self, text: str, voice: str, speed: float) -> np.ndarray:
        """Áudio mono float32 em `sample_rate`."""


def prepare_text(text: str) -> str:
    text = _EMOJI.sub("", text).replace("&", " e ").replace("%", " por cento")
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    if text and text[-1] not in ".!?…":
        text += "."
    return text


def ensure_kokoro_files() -> None:
    MODELS_DIR.mkdir(parents=True, exist_ok=True)
    for name in KOKORO_FILES:
        target = MODELS_DIR / name
        if target.exists() and target.stat().st_size > 0:
            continue
        log.info("baixando modelo de voz %s", name)
        partial = target.with_suffix(target.suffix + ".part")
        urllib.request.urlretrieve(f"{KOKORO_BASE_URL}/{name}", partial)
        partial.rename(target)


class KokoroEngine:
    sample_rate = 24000

    def __init__(self) -> None:
        self._kokoro = None
        self._load_lock = threading.Lock()
        # O espeak-ng (fonemização) não é thread-safe; a inferência ONNX é.
        self._phonemize_lock = threading.Lock()

    def _model(self):
        with self._load_lock:
            if self._kokoro is None:
                from kokoro_onnx import Kokoro

                ensure_kokoro_files()
                self._kokoro = Kokoro(str(MODELS_DIR / KOKORO_FILES[0]), str(MODELS_DIR / KOKORO_FILES[1]))
                # O phonemizer avisa a cada frase em que a contagem de palavras muda; é inofensivo e polui o log.
                logging.getLogger("phonemizer").setLevel(logging.ERROR)
            return self._kokoro

    def synthesize(self, text: str, voice: str, speed: float) -> np.ndarray:
        kokoro = self._model()
        text = prepare_text(text)
        if not text:
            return np.zeros(0, dtype=np.float32)
        with self._phonemize_lock:
            phonemes = kokoro.tokenizer.phonemize(text, "pt-br")
        speed = float(min(2.0, max(0.5, speed)))
        samples, _ = kokoro.create(phonemes, voice=voice, speed=speed, is_phonemes=True)
        return np.asarray(samples, dtype=np.float32)


_engine: KokoroEngine | None = None


def get_engine() -> KokoroEngine:
    global _engine
    if _engine is None:
        _engine = KokoroEngine()
    return _engine
