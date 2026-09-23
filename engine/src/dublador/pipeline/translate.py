"""LLM local via Ollama: traduz quando o YouTube não entrega a faixa em português e enxuga falas que não cabem no tempo."""
from __future__ import annotations

import json
import logging
import re
import urllib.error
import urllib.request
from typing import Callable

from ..config import Settings
from .download import PipelineError
from .segment import Utterance

log = logging.getLogger(__name__)

BATCH = 8
CHARS_PER_SECOND = 16.0   # ritmo medido do Kokoro pt-BR em velocidade 1.0
CONDENSE_ABOVE = 1.25     # só enxuga o que exigiria acelerar a voz além disso

_TRANSLATE_SYSTEM = (
    "Você é tradutor de dublagem. Traduza cada fala para português do Brasil falado e natural. "
    "A fala dublada precisa caber no mesmo tempo da original: seja conciso e respeite max_chars, "
    "cortando redundâncias e muletas, nunca o sentido. As falas vêm de legenda automática, sem pontuação "
    "e às vezes cortadas no meio da frase: restaure a pontuação e traduza só o trecho de cada id, "
    "sem puxar conteúdo das falas vizinhas. Mantenha nomes próprios, marcas e termos técnicos consagrados; "
    "todo o resto tem que sair em português, inclusive repetições e hesitações (nada de palavra solta em inglês). "
    "Use registro neutro: só use palavrão se o original tiver. Não comente nem explique."
)
_CONDENSE_SYSTEM = (
    "Você adapta falas de dublagem em português do Brasil. Reescreva cada fala para caber em max_chars, "
    "mantendo a ideia principal, o tom e os termos técnicos. Corte redundâncias, exemplos secundários e muletas. "
    "Não comente nem explique."
)


def _schema(count: int) -> dict:
    return {
        "type": "object",
        "properties": {
            "falas": {
                "type": "array",
                "minItems": count,
                "maxItems": count,
                "items": {
                    "type": "object",
                    "properties": {"id": {"type": "integer"}, "pt": {"type": "string"}},
                    "required": ["id", "pt"],
                },
            }
        },
        "required": ["falas"],
    }


def _request(url: str, payload: dict | None = None, timeout: float = 600.0) -> dict:
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read())


def _score(name: str) -> int:
    n = name.lower()
    score = 0
    if any(family in n for family in ("qwen", "gemma", "llama", "mistral", "aya", "phi", "granite", "deepseek")):
        score += 3
    if any(tag in n for tag in ("thinking", "reason", "-r1", ":r1")):
        score -= 5  # raciocínio longo: lento demais para traduzir fala a fala
    if "coder" in n or "code" in n:
        score -= 1
    if "instruct" in n:
        score += 1
    size = re.search(r"(\d+(?:\.\d+)?)b\b", n)
    if size:
        billions = float(size.group(1))
        score += 2 if 12 <= billions <= 40 else 1 if 7 <= billions < 12 else 0
    return score


def available_models(settings: Settings) -> list[str]:
    try:
        tags = _request(f"{settings.ollama_url}/api/tags", timeout=4.0)
    except (urllib.error.URLError, OSError, ValueError):
        return []
    return [m["name"] for m in tags.get("models", [])]


def pick_model(settings: Settings) -> str:
    if settings.ollama_model:
        return settings.ollama_model
    names = available_models(settings)
    if not names:
        raise PipelineError("O Ollama não está respondendo em 127.0.0.1:11434 ou não tem modelos instalados.")
    return max(names, key=_score)


def budget_chars(utterance: Utterance) -> int:
    return max(20, int((utterance.window_end - utterance.start) * CHARS_PER_SECOND))


def _chat(settings: Settings, model: str, system: str, user: str, count: int) -> dict[int, str]:
    payload = {
        "model": model,
        "stream": False,
        "think": False,
        "format": _schema(count),
        "options": {"temperature": 0.2, "num_ctx": 8192},
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
    }
    try:
        reply = _request(f"{settings.ollama_url}/api/chat", payload)
    except urllib.error.HTTPError as exc:
        if exc.code != 400:
            raise
        payload.pop("think")  # modelos sem modo de raciocínio recusam o campo
        reply = _request(f"{settings.ollama_url}/api/chat", payload)
    parsed = json.loads(reply.get("message", {}).get("content", ""))
    result: dict[int, str] = {}
    for row in parsed.get("falas", []):
        if isinstance(row, dict) and isinstance(row.get("pt"), str) and row["pt"].strip():
            result[int(row["id"])] = re.sub(r"\s+", " ", row["pt"]).strip()
    return result


def _translate_batch(settings: Settings, model: str, title: str, before: str, after: str,
                     batch: list[Utterance]) -> dict[int, str]:
    items = [{"id": u.id, "texto": u.source_text, "max_chars": budget_chars(u)} for u in batch]
    user = (
        f"Título do vídeo: {title}\n"
        f"Contexto anterior (não traduza): {before or '—'}\n"
        f"Contexto seguinte (não traduza): {after or '—'}\n"
        f"Falas para traduzir:\n{json.dumps(items, ensure_ascii=False)}"
    )
    result = _chat(settings, model, _TRANSLATE_SYSTEM, user, len(batch))
    sources = {u.id: u.source_text for u in batch}
    # Modelos pequenos às vezes despejam o vídeo inteiro numa fala só: isso é descartado.
    return {uid: pt for uid, pt in result.items() if uid in sources and len(pt) <= 2.2 * len(sources[uid]) + 30}


def translate(
    utterances: list[Utterance],
    settings: Settings,
    title: str,
    progress: Callable[[float], None] | None = None,
    cancelled: Callable[[], bool] | None = None,
) -> str:
    """Preenche `text` de cada fala. Devolve o nome do modelo usado."""
    model = pick_model(settings)
    pending = [u for u in utterances if not u.text]
    log.info("traduzindo %d falas com o Ollama (%s)", len(pending), model)
    for offset in range(0, len(pending), BATCH):
        if cancelled and cancelled():
            raise PipelineError("cancelado")
        batch = pending[offset:offset + BATCH]
        before = " ".join(u.source_text for u in pending[max(0, offset - 2):offset])[-400:]
        after = " ".join(u.source_text for u in pending[offset + BATCH:offset + BATCH + 1])[:200]
        translated: dict[int, str] = {}
        try:
            translated = _translate_batch(settings, model, title, before, after, batch)
        except (urllib.error.URLError, OSError) as exc:
            raise PipelineError(f"Falha ao falar com o Ollama: {exc}") from exc
        except (ValueError, KeyError, TypeError) as exc:
            log.warning("resposta inválida do Ollama no lote %d: %s", offset // BATCH, exc)
        for u in batch:
            if u.id not in translated:  # segunda chance: uma fala por vez
                try:
                    translated.update(_translate_batch(settings, model, title, before, after, [u]))
                except Exception as exc:  # noqa: BLE001 - uma fala ruim não pode abortar o vídeo
                    log.warning("fala %d sem tradução: %s", u.id, exc)
            u.text = translated.get(u.id, "")
        if progress:
            progress(0.8 * min(1.0, (offset + len(batch)) / max(1, len(pending))))
    missing = [u.id for u in pending if not u.text]
    if len(missing) > len(pending) * 0.3:
        raise PipelineError(f"O modelo {model} não conseguiu traduzir {len(missing)} de {len(pending)} falas.")
    return model


def condense(
    utterances: list[Utterance],
    settings: Settings,
    progress: Callable[[float], None] | None = None,
) -> int:
    """Enxuga as falas que não cabem na janela nem acelerando. Devolve quantas foram encurtadas."""
    long = [u for u in utterances if u.text and len(u.text) > budget_chars(u) * CONDENSE_ABOVE]
    if not long or not settings.ollama_assist:
        return 0
    try:
        model = pick_model(settings)
    except PipelineError:
        return 0
    shortened = 0
    for offset in range(0, len(long), BATCH):
        batch = long[offset:offset + BATCH]
        items = [{"id": u.id, "fala": u.text, "max_chars": budget_chars(u)} for u in batch]
        try:
            result = _chat(settings, model, _CONDENSE_SYSTEM, json.dumps(items, ensure_ascii=False), len(batch))
        except Exception as exc:  # noqa: BLE001 - enxugar é melhoria opcional; sem ela o encaixe acelera a voz
            log.warning("não consegui enxugar o lote %d: %s", offset // BATCH, exc)
            continue
        for u in batch:
            new = result.get(u.id, "")
            if new and len(new) < len(u.text) and len(new) >= 0.35 * len(u.text):
                u.text = new
                shortened += 1
        if progress:
            progress(0.8 + 0.2 * min(1.0, (offset + len(batch)) / len(long)))
    log.info("%d de %d falas longas foram enxugadas", shortened, len(long))
    return shortened
