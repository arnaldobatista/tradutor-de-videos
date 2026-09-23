"""Descobre onde as frases terminam numa transcrição automática sem pontuação (LLM local)."""
from __future__ import annotations

import json
import logging
import re
import urllib.error
from difflib import SequenceMatcher
from typing import Callable

from ..config import Settings
from . import translate
from .download import PipelineError

log = logging.getLogger(__name__)

CHUNK_WORDS = 130
MIN_MATCH = 0.8
# Reticências são hesitação no meio da frase ("they have really... really long trunks"), não fim dela.
_SENTENCE_END = re.compile(r"(?<![.…])[.!?][\"')\]]*$")
_CLAUSE_END = re.compile(r"(?:[,;:]|\.{2,}|…)[\"')\]]*$")

_SYSTEM = (
    "You restore punctuation in automatic speech transcripts. Return exactly the same words in the same "
    "order, adding only punctuation marks and capitalization. Never add, remove, translate, fix or reorder "
    "words. The excerpt may start or end in the middle of a sentence: do not force a period at the end."
)
_SCHEMA = {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}


def _norm(token: str) -> str:
    return re.sub(r"[^\w]", "", token.lower())


def already_punctuated(words: list[str]) -> bool:
    ends = sum(1 for w in words if _SENTENCE_END.search(w))
    return len(words) > 0 and ends >= len(words) / 45


def breaks_from_text(words: list[str]) -> tuple[set[int], set[int]]:
    """Fins de frase e de oração a partir da pontuação que já existe nas palavras."""
    sentence = {i for i, w in enumerate(words) if _SENTENCE_END.search(w)}
    clause = {i for i, w in enumerate(words) if _CLAUSE_END.search(w)}
    return sentence, clause


def _punctuate_chunk(settings: Settings, model: str, language: str, words: list[str]) -> list[str] | None:
    payload = {
        "model": model,
        "stream": False,
        "think": False,
        "format": _SCHEMA,
        "options": {"temperature": 0.0, "num_ctx": 8192},
        "messages": [
            {"role": "system", "content": _SYSTEM},
            {"role": "user", "content": f"Language: {language or 'unknown'}\nTranscript:\n{' '.join(words)}"},
        ],
    }
    try:
        reply = translate._request(f"{settings.ollama_url}/api/chat", payload)
    except urllib.error.HTTPError as exc:
        if exc.code != 400:
            raise
        payload.pop("think")
        reply = translate._request(f"{settings.ollama_url}/api/chat", payload)
    text = json.loads(reply.get("message", {}).get("content", "")).get("text", "")
    return text.split() or None


def find_breaks(
    words: list[str],
    language: str,
    settings: Settings,
    progress: Callable[[float], None] | None = None,
    cancelled: Callable[[], bool] | None = None,
) -> tuple[set[int], set[int]]:
    """Índices de palavra que fecham frase e que fecham oração (vírgula). Vazio se o LLM não ajudar."""
    if already_punctuated(words):
        return breaks_from_text(words)
    model = translate.pick_model(settings)
    sentence: set[int] = set()
    clause: set[int] = set()
    start = 0
    while start < len(words):
        if cancelled and cancelled():
            raise PipelineError("cancelado")
        chunk = words[start:start + CHUNK_WORDS]
        last_break = None
        try:
            tokens = _punctuate_chunk(settings, model, language, chunk)
        except (urllib.error.URLError, OSError, ValueError, KeyError, TypeError) as exc:
            log.warning("pontuação falhou no trecho %d: %s", start, exc)
            tokens = None
        if tokens:
            a, b = [_norm(w) for w in chunk], [_norm(t) for t in tokens]
            matcher = SequenceMatcher(None, a, b, autojunk=False)
            if matcher.ratio() >= MIN_MATCH:
                to_original: dict[int, int] = {}
                for block in matcher.get_matching_blocks():
                    for k in range(block.size):
                        to_original[block.b + k] = block.a + k
                for j, token in enumerate(tokens):
                    if j not in to_original:
                        continue
                    index = start + to_original[j]
                    if _SENTENCE_END.search(token):
                        sentence.add(index)
                        last_break = index
                    elif _CLAUSE_END.search(token):
                        clause.add(index)
            else:
                log.warning("pontuação descartada no trecho %d (texto alterado demais)", start)
        is_last = start + CHUNK_WORDS >= len(words)
        if is_last:
            break
        # O trecho quase sempre termina no meio de uma frase: o próximo recomeça logo depois da última frase fechada.
        if last_break is not None and last_break + 1 - start >= CHUNK_WORDS // 3:
            sentence = {i for i in sentence if i <= last_break}
            clause = {i for i in clause if i <= last_break}
            start = last_break + 1
        else:
            start += CHUNK_WORDS
        if progress:
            progress(min(1.0, start / len(words)))
    sentence.discard(len(words) - 1)
    return sentence, clause
