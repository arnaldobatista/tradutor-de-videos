"""Orquestra o pipeline de um vídeo, com cache por etapa e progresso."""
from __future__ import annotations

import json
import logging
import shutil
import threading
import time
from pathlib import Path
from typing import Callable

import numpy as np
import soundfile as sf

from ..config import CACHE_DIR, Settings
from . import fit, mix, punctuate, segment, separate, translate, tts
from .download import PipelineError, VideoSource, fetch_source

log = logging.getLogger(__name__)

# (etapa, peso no progresso total). A separação roda em paralelo com legendas e voz.
STAGES = (("download", 0.05), ("legendas", 0.15), ("separacao", 0.35), ("voz", 0.37), ("mixagem", 0.08))
STAGE_LABELS = {
    "download": "Baixando o áudio",
    "legendas": "Preparando as falas",
    "separacao": "Removendo a voz original",
    "voz": "Gerando a voz em português",
    "mixagem": "Mixando",
}
SEPARATION_SPEED = 6.0  # htdemucs no M1 Max processa ~6x mais rápido que tempo real
# Sobe quando a mixagem muda de um jeito que vale refazer dublagens já em cache.
MIX_VERSION = 2

ProgressFn = Callable[[str, float], None]


def video_dir(video_id: str) -> Path:
    return CACHE_DIR / video_id


def output_path(video_id: str, settings: Settings) -> Path:
    return video_dir(video_id) / f"dub.{settings.target_lang}.{settings.voice}.m4a"


def _load(path: Path) -> list[segment.Utterance]:
    return [segment.Utterance(**row) for row in json.loads(path.read_text())]


def _save(path: Path, utterances: list[segment.Utterance]) -> None:
    path.write_text(json.dumps([u.to_dict() for u in utterances], ensure_ascii=False, indent=1))


def _sentences(words: list[segment.Word], language: str, settings: Settings, duration: float,
               progress: Callable[[float], None], cancelled: Callable[[], bool],
               portuguese: bool = False) -> list[segment.Utterance] | None:
    """Falas por frase completa; None quando não há tempo por palavra ou o LLM local não ajuda."""
    if len(words) < 8:
        return None
    texts = [w.text for w in words]
    if not punctuate.already_punctuated(texts) and not (settings.ollama_assist and translate.available_models(settings)):
        return None
    try:
        sentence_breaks, clause_breaks = punctuate.find_breaks(
            texts, language, settings, lambda f: progress(0.35 * f), cancelled)
    except PipelineError:
        raise
    except Exception as exc:  # noqa: BLE001 - pontuar é melhoria: sem ela vale o agrupamento por pausas
        log.warning("não consegui pontuar a transcrição: %s", exc)
        return None
    if len(sentence_breaks) < len(words) / 120:
        return None
    return segment.build_sentence_utterances(words, sentence_breaks, clause_breaks, duration, portuguese)


def _build_utterances(source: VideoSource, settings: Settings, workdir: Path, duration: float,
                      report: dict, progress: Callable[[float], None], cancelled: Callable[[], bool]) -> list[segment.Utterance]:
    subs = source.subs
    if subs.original_lang == "pt" and not subs.portuguese:
        raise PipelineError("O vídeo já está em português.")

    lines: list[segment.Line] = []
    words: list[segment.Word] = []
    if subs.original:
        lines, words = segment.parse_json3(subs.original)
    pt_lines = segment.parse_json3(subs.portuguese)[0] if subs.portuguese else []

    if pt_lines:
        report["traducao"] = "legenda manual em português" if subs.portuguese_is_manual else "faixa traduzida do YouTube"
        cached = workdir / "falas.youtube.json"
        if cached.exists():
            return _load(cached)
        utterances = _sentences(segment.words_from_lines(pt_lines), "pt", settings, duration,
                                progress, cancelled, portuguese=True)
        if not utterances:
            utterances = segment.build_utterances(pt_lines, [w.start for w in words], duration, text_is_portuguese=True)
        report["falas_enxugadas"] = translate.condense(utterances, settings, lambda f: progress(0.35 + 0.65 * f))
        _save(cached, utterances)
        return utterances

    if not lines:
        raise PipelineError("Este vídeo não tem legendas (nem automáticas). Ainda não dá para dublar sem legenda.")
    if settings.translator != "ollama" and not settings.ollama_fallback:
        raise PipelineError("O YouTube negou a faixa traduzida e a tradução local (Ollama) está desligada.")
    if settings.translator == "youtube":
        if subs.portuguese_error:
            report["aviso"] = f"O YouTube negou a faixa traduzida ({subs.portuguese_error}); usei a tradução local."
        elif not subs.portuguese_listed:
            report["aviso"] = "Este vídeo não tem faixa em português no YouTube; usei a tradução local."

    cached = workdir / "falas.ollama.json"
    if cached.exists():
        report["traducao"] = "Ollama (cache)"
        return _load(cached)
    # Legenda manual não traz tempo por palavra, mas também corta frases no meio: interpola e monta por frase.
    utterances = _sentences(words or segment.words_from_lines(lines), subs.original_lang, settings, duration,
                            progress, cancelled)
    if not utterances:
        utterances = segment.build_utterances(lines, [w.start for w in words], duration, text_is_portuguese=False)
    model = translate.translate(utterances, settings, source.info.get("title") or "",
                                lambda f: progress(0.35 + 0.5 * f), cancelled)
    utterances = [u for u in utterances if u.text]
    report["falas_enxugadas"] = translate.condense(utterances, settings, lambda f: progress(0.85 + 0.15 * f))
    report["traducao"] = f"Ollama ({model})"
    _save(cached, utterances)
    return utterances


def run(
    video_id: str,
    settings: Settings,
    on_progress: ProgressFn | None = None,
    cancelled: Callable[[], bool] | None = None,
    on_info: Callable[[dict], None] | None = None,
) -> tuple[Path, dict]:
    cancelled = cancelled or (lambda: False)
    workdir = video_dir(video_id)
    workdir.mkdir(parents=True, exist_ok=True)
    final = output_path(video_id, settings)
    report: dict = {"video_id": video_id, "voz": settings.voice, "tempos_s": {}}
    weights = dict(STAGES)
    fractions = {name: 0.0 for name in weights}
    progress_lock = threading.Lock()
    current = {"stage": "download"}

    def stage(name: str, foreground: bool = True) -> Callable[[float], None]:
        def update(fraction: float) -> None:
            with progress_lock:
                fractions[name] = max(fractions[name], min(1.0, fraction))
                if foreground:
                    current["stage"] = name
                total = sum(weights[n] * fractions[n] for n in weights)
                label = current["stage"]
            if on_progress:
                on_progress(label, total)

        update(0.0)
        return update

    def check() -> None:
        if cancelled():
            raise PipelineError("cancelado")

    started = time.perf_counter()
    clock = started

    def lap(name: str) -> None:
        nonlocal clock
        now = time.perf_counter()
        report["tempos_s"][name] = round(now - clock, 1)
        clock = now

    background, levels, env_file = workdir / "background.flac", workdir / "levels.json", workdir / "voice_env.npy"
    separated = background.exists() and levels.exists() and env_file.exists()
    source = fetch_source(video_id, workdir, settings, settings.translator == "youtube",
                          need_audio=not separated, progress=stage("download"))
    stage("download")(1.0)
    if on_info:
        on_info(source.info)
    report["titulo"] = source.info.get("title")
    duration = sf.info(background if separated else source.audio_path).duration
    report["duracao_s"] = round(duration, 1)
    lap("download")
    check()

    # A separação (GPU) corre em paralelo com a preparação das falas (LLM) e com o TTS (CPU).
    separation_update = stage("separacao", foreground=False)
    separation: dict = {"error": None, "seconds": 0.0}

    def separate_worker() -> None:
        t0 = time.perf_counter()
        try:
            if not separated:
                vocals_wav, background_wav = workdir / "vocals.wav", workdir / "background.wav"
                separate.separate(source.audio_path, vocals_wav, background_wav, settings.separator_model)
                info, envelope = mix.analyze_voice(vocals_wav)
                levels.write_text(json.dumps(info))
                np.save(env_file, envelope.astype(np.float16))
                data, rate = sf.read(background_wav, dtype="int16", always_2d=True)
                sf.write(background, data, rate, format="FLAC")
                for leftover in (vocals_wav, background_wav, source.audio_path):
                    leftover.unlink(missing_ok=True)
        except Exception as exc:  # noqa: BLE001 - o erro é relançado na thread principal
            separation["error"] = exc
        separation["seconds"] = time.perf_counter() - t0

    def separation_ticker() -> None:
        expected = max(5.0, duration / SEPARATION_SPEED + 8.0)
        t0 = time.perf_counter()
        while worker.is_alive():
            separation_update(min(0.95, (time.perf_counter() - t0) / expected))
            time.sleep(1.0)

    worker = threading.Thread(target=separate_worker, name="separacao", daemon=True)
    worker.start()
    threading.Thread(target=separation_ticker, name="separacao-progresso", daemon=True).start()

    try:
        utterances = _build_utterances(source, settings, workdir, duration, report, stage("legendas"), cancelled)
        stage("legendas")(1.0)
        lap("legendas")
        check()

        engine = tts.get_engine()
        placed, fit_report = fit.synthesize_and_fit(utterances, engine, settings, workdir / "tts", stage("voz"), cancelled)
        report.update(fit_report)
        lap("voz")
    finally:
        with progress_lock:
            current["stage"] = "separacao"
        worker.join()
    if separation["error"]:
        raise separation["error"]
    separation_update(1.0)
    report["tempos_s"]["separacao"] = round(separation["seconds"], 1)
    clock = time.perf_counter()
    check()

    update = stage("mixagem")
    info = json.loads(levels.read_text())
    envelope = np.load(env_file).astype(np.float32)
    gains = fit.utterance_gains(placed, engine.sample_rate, envelope, info.get("hop_s", mix.HOP_S))
    track = fit.render_voice_track(placed, engine.sample_rate, duration, gains)
    target = info["voz_lufs"] + settings.voice_offset_db
    report.update(mix.mix(background, target, track, engine.sample_rate, final, settings.duck_db))
    report["dinamica_db"] = {"min": round(min(gains), 1), "max": round(max(gains), 1),
                             "falas_ajustadas": sum(1 for g in gains if abs(g) > 0.5)}
    report["mix_version"] = MIX_VERSION
    (workdir / "falas.json").write_text(json.dumps(
        [{**p.utterance.to_dict(), "entra_em": round(p.at, 2), "velocidade": round(p.speed, 2),
          "atraso": round(p.delay, 2), "ganho_db": round(g, 1)} for p, g in zip(placed, gains)],
        ensure_ascii=False, indent=1))
    update(1.0)
    lap("mixagem")

    shutil.rmtree(workdir / "tts", ignore_errors=True)  # só serve para retomar um job interrompido
    report["tempo_total_s"] = round(time.perf_counter() - started, 1)
    (workdir / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=1))
    return final, report
