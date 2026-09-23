"""yt-dlp: metadados, faixa de áudio original e legendas em json3."""
from __future__ import annotations

import json
import logging
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import yt_dlp
from yt_dlp.utils import DownloadError

from ..config import COOKIES_FILE, Settings

log = logging.getLogger(__name__)

PT_KEYS = ("pt-BR", "pt", "pt-PT")


class PipelineError(Exception):
    """Erro com mensagem pronta para mostrar ao usuário."""


class TranslatedTrackUnavailable(PipelineError):
    pass


@dataclass
class SubtitleChoice:
    """Faixas escolhidas: `original` dá tempos/texto de origem; `portuguese` dá o texto final."""

    original: dict | None = None
    original_lang: str = ""
    original_is_asr: bool = False
    portuguese: dict | None = None
    portuguese_is_manual: bool = False
    portuguese_listed: bool = False   # o YouTube oferece alguma faixa em português para este vídeo
    portuguese_error: str = ""        # por que a faixa oferecida não veio (ex.: HTTP 429)


@dataclass
class VideoSource:
    video_id: str
    info: dict
    audio_path: Path
    subs: SubtitleChoice = field(default_factory=SubtitleChoice)


def video_url(video_id: str) -> str:
    return f"https://www.youtube.com/watch?v={video_id}"


def _ydl_options(settings: Settings, workdir: Path, progress: Callable[[float], None] | None,
                 skip_browser: bool = False) -> dict:
    def hook(status: dict) -> None:
        if progress and status.get("status") == "downloading":
            total = status.get("total_bytes") or status.get("total_bytes_estimate")
            if total:
                progress(min(1.0, status.get("downloaded_bytes", 0) / total))

    options = {
        "format": "bestaudio/best",
        "outtmpl": str(workdir / "source.%(ext)s"),
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "noplaylist": True,
        "retries": 5,
        "progress_hooks": [hook],
        "logger": log,
    }
    if not settings.use_cookies:
        return options
    if settings.cookies_from_browser and not skip_browser:
        browser, _, profile = settings.cookies_from_browser.partition(":")
        options["cookiesfrombrowser"] = (browser.strip().lower(), profile.strip() or None, None, None)
    elif COOKIES_FILE.exists() and COOKIES_FILE.stat().st_size > 0:
        options["cookiefile"] = str(COOKIES_FILE)
    return options


# Resultado da última leitura de cookies pelo navegador: o app mostra isso ao usuário, porque a falha
# (permissão negada pelo macOS) é silenciosa e o motor segue com os cookies da extensão.
browser_cookies = {"ok": None, "error": ""}


def _open_ydl(settings: Settings, workdir: Path, progress: Callable[[float], None] | None) -> yt_dlp.YoutubeDL:
    """Abre o yt-dlp com os cookies do navegador; se o sistema negar o acesso, cai nos cookies da extensão."""
    ydl = yt_dlp.YoutubeDL(_ydl_options(settings, workdir, progress))
    if settings.use_cookies and settings.cookies_from_browser:
        try:
            count = len(list(ydl.cookiejar))  # a leitura é preguiçosa: força agora para o erro aparecer aqui
            log.info("cookies lidos de %s pelo yt-dlp: %d", settings.cookies_from_browser, count)
            browser_cookies.update(ok=True, error="")
        except Exception as exc:  # noqa: BLE001 - Keychain negado, pasta protegida, perfil inexistente...
            log.warning("não consegui ler os cookies de %s (%s); usando os enviados pela extensão",
                        settings.cookies_from_browser, str(exc)[-200:])
            browser_cookies.update(ok=False, error=str(exc)[-120:])
            ydl.close()
            ydl = yt_dlp.YoutubeDL(_ydl_options(settings, workdir, progress, skip_browser=True))
    return ydl


def _json3_url(entries: list[dict] | None) -> str | None:
    for entry in entries or []:
        if entry.get("ext") == "json3":
            return entry.get("url")
    return None


def _choose_tracks(info: dict) -> tuple[dict, dict]:
    """Devolve {papel: (chave, url, ...)} separando faixa original e faixa em português."""
    manual = info.get("subtitles") or {}
    auto = info.get("automatic_captions") or {}
    language = (info.get("language") or "").split("-")[0]

    original: dict = {}
    orig_keys = [k for k in auto if k.endswith("-orig")]
    if orig_keys:
        key = orig_keys[0]
        original = {"key": key, "url": _json3_url(auto[key]), "asr": True, "lang": key.removesuffix("-orig")}
    elif language and any(k.split("-")[0] == language for k in manual):
        key = next(k for k in manual if k.split("-")[0] == language)
        original = {"key": key, "url": _json3_url(manual[key]), "asr": False, "lang": language}
    elif language and language in auto:
        original = {"key": language, "url": _json3_url(auto[language]), "asr": True, "lang": language}
    elif manual:
        key = next((k for k in manual if k.split("-")[0] not in ("pt",) and k != "live_chat"), None)
        if key:
            original = {"key": key, "url": _json3_url(manual[key]), "asr": False, "lang": key.split("-")[0]}
    elif len(auto) == 1:
        key = next(iter(auto))
        original = {"key": key, "url": _json3_url(auto[key]), "asr": True, "lang": key.split("-")[0]}

    portuguese: dict = {}
    for key in PT_KEYS:
        if key in manual and _json3_url(manual[key]):
            portuguese = {"key": key, "url": _json3_url(manual[key]), "manual": True}
            break
    if not portuguese:
        for key in ("pt", "pt-BR", "pt-PT"):
            if key in auto and _json3_url(auto[key]):
                portuguese = {"key": key, "url": _json3_url(auto[key]), "manual": False}
                break
    return original, portuguese


def _fetch_json(ydl: yt_dlp.YoutubeDL, url: str) -> dict:
    with ydl.urlopen(url) as response:
        raw = response.read()
    if not raw.strip():
        raise ValueError("resposta vazia")
    return json.loads(raw)


def to_wav(source: Path, dest: Path) -> None:
    proc = subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", str(source), "-vn", "-ar", "44100", "-ac", "2", str(dest)],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise PipelineError(f"ffmpeg falhou ao converter o áudio: {proc.stderr.strip()[-300:]}")


def fetch_source(
    video_id: str,
    workdir: Path,
    settings: Settings,
    want_translated: bool,
    need_audio: bool = True,
    progress: Callable[[float], None] | None = None,
) -> VideoSource:
    """Baixa o áudio original (WAV 44.1 kHz) e as legendas. Reaproveita o que já estiver no cache."""
    workdir.mkdir(parents=True, exist_ok=True)
    wav = workdir / "source.wav"
    info_file = workdir / "info.json"
    orig_file = workdir / "subs.orig.json3"
    pt_file = workdir / "subs.pt.json3"

    with _open_ydl(settings, workdir, progress) as ydl:
        try:
            info = ydl.extract_info(video_url(video_id), download=False)
        except DownloadError as exc:
            raise PipelineError(f"YouTube recusou o vídeo: {str(exc)[-300:]}") from exc
        if info.get("is_live"):
            raise PipelineError("Transmissões ao vivo não são suportadas.")
        duration = info.get("duration") or 0
        if duration > settings.max_duration_min * 60:
            raise PipelineError(f"Vídeo longo demais ({duration // 60} min; limite {settings.max_duration_min} min).")

        if need_audio and not wav.exists():
            try:
                ydl.process_ie_result(info, download=True)
            except DownloadError as exc:
                raise PipelineError(f"Falha ao baixar o áudio: {str(exc)[-300:]}") from exc
            downloaded = next((p for p in workdir.glob("source.*") if p.suffix not in (".wav", ".part")), None)
            if downloaded is None:
                raise PipelineError("O yt-dlp não produziu o arquivo de áudio.")
            to_wav(downloaded, wav)
            downloaded.unlink(missing_ok=True)

        original, portuguese = _choose_tracks(info)
        subs = SubtitleChoice(
            original_lang=original.get("lang", ""),
            original_is_asr=bool(original.get("asr")),
            portuguese_is_manual=bool(portuguese.get("manual")),
            portuguese_listed=bool(portuguese.get("url")),
        )

        if orig_file.exists():
            subs.original = json.loads(orig_file.read_text())
        elif original.get("url"):
            try:
                subs.original = _fetch_json(ydl, original["url"])
                orig_file.write_text(json.dumps(subs.original))
            except Exception as exc:  # noqa: BLE001 - rede/HTTP/JSON: seguimos sem a faixa original
                log.warning("faixa original (%s) indisponível: %s", original.get("key"), exc)

        if pt_file.exists():
            subs.portuguese = json.loads(pt_file.read_text())
        elif portuguese.get("url") and (want_translated or portuguese.get("manual")):
            try:
                subs.portuguese = _fetch_json(ydl, portuguese["url"])
                pt_file.write_text(json.dumps(subs.portuguese))
            except Exception as exc:  # noqa: BLE001 - tipicamente HTTP 429 sem cookies
                subs.portuguese_error = "HTTP 429" if "429" in str(exc) else str(exc)[-80:]
                log.warning("faixa em português (%s) indisponível: %s", portuguese.get("key"), exc)

    slim = {k: info.get(k) for k in ("id", "title", "duration", "language", "channel", "uploader")}
    info_file.write_text(json.dumps(slim, ensure_ascii=False))
    return VideoSource(video_id=video_id, info=slim, audio_path=wav, subs=subs)
