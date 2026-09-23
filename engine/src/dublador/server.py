"""API HTTP local do motor. Só escuta em 127.0.0.1 e só aceita a extensão como origem de navegador."""
from __future__ import annotations

import logging
import os
import re
import time
from logging.handlers import RotatingFileHandler

import uvicorn
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel

from . import __version__
from .config import (ALLOWED_ORIGINS, APP_SUPPORT, COOKIES_FILE, HOST, LOG_DIR, PORT, VOICES, ensure_environment,
                     load_settings, update_settings)
from .jobs import JobManager, cache_size
from .pipeline import download

log = logging.getLogger("dublador")
app = FastAPI(title="Tradutor de Vídeos", version=__version__, docs_url=None, redoc_url=None)
manager: JobManager | None = None

_VIDEO_ID = re.compile(r"^[\w-]{11}$")
_ALLOWED_HOSTS = {f"127.0.0.1:{PORT}", f"localhost:{PORT}"}


@app.middleware("http")
async def guard(request: Request, call_next):
    # Host fixo barra DNS rebinding; Origin barra sites que tentem usar o motor pelo navegador do usuário.
    if request.headers.get("host") not in _ALLOWED_HOSTS:
        return JSONResponse({"detail": "host não permitido"}, status_code=403)
    origin = request.headers.get("origin")
    if origin is not None and origin not in ALLOWED_ORIGINS:
        return JSONResponse({"detail": "origem não permitida"}, status_code=403)
    if request.method == "OPTIONS":
        response = JSONResponse({})
    else:
        response = await call_next(request)
    if origin:
        response.headers["Access-Control-Allow-Origin"] = origin
        response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
        response.headers["Access-Control-Allow-Headers"] = "Content-Type"
        response.headers["Vary"] = "Origin"
    return response


class JobRequest(BaseModel):
    video_id: str


class Cookie(BaseModel):
    domain: str
    name: str
    value: str
    path: str = "/"
    secure: bool = False
    httpOnly: bool = False
    hostOnly: bool = False
    expirationDate: float | None = None


class CookiesRequest(BaseModel):
    cookies: list[Cookie]


def _manager() -> JobManager:
    assert manager is not None
    return manager


@app.get("/health")
def health() -> dict:
    return {"ok": True, "version": __version__}


@app.get("/status")
def status() -> dict:
    cookies_age = time.time() - COOKIES_FILE.stat().st_mtime if COOKIES_FILE.exists() else None
    return {
        "version": __version__,
        "jobs": _manager().snapshot(),
        "cache_bytes": cache_size(),
        "cookies": {
            "present": cookies_age is not None,
            "age_s": round(cookies_age) if cookies_age is not None else None,
            "browser": load_settings().cookies_from_browser,
            "browser_ok": download.browser_cookies["ok"],
        },
        "settings": load_settings().public(),
        "voices": VOICES,
    }


@app.post("/jobs")
def create_job(body: JobRequest) -> dict:
    if not _VIDEO_ID.match(body.video_id):
        raise HTTPException(400, "video_id inválido")
    return _manager().submit(body.video_id).public()


@app.get("/jobs/{job_id}")
def get_job(job_id: str) -> dict:
    job = _manager().get(job_id)
    if not job:
        raise HTTPException(404, "job não encontrado")
    return job.public()


@app.delete("/jobs/{job_id}")
def cancel_job(job_id: str) -> dict:
    return {"cancelled": _manager().cancel(job_id)}


@app.get("/jobs/{job_id}/audio")
def job_audio(job_id: str):
    if not re.fullmatch(r"[\w-]{11}\.[\w-]+\.\w+", job_id):
        raise HTTPException(400, "job inválido")
    path = _manager().audio_path(job_id)
    if not path:
        raise HTTPException(404, "áudio ainda não disponível")
    return FileResponse(path, media_type="audio/mp4", headers={"Cache-Control": "no-store"})


@app.get("/settings")
def get_settings() -> dict:
    return load_settings().public()


@app.put("/settings")
def put_settings(changes: dict) -> dict:
    try:
        return update_settings(changes).public()
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc


SAMPLE_TEXT = "Olá! Esta é a voz que vai dublar os seus vídeos em português."


@app.get("/voices/{voice}/sample")
def voice_sample(voice: str):
    """Amostra curta da voz, para escolher ouvindo. Gerada uma vez e guardada."""
    if voice not in VOICES:
        raise HTTPException(404, "voz desconhecida")
    path = APP_SUPPORT / "samples" / f"{voice}.wav"
    if not path.exists():
        import soundfile as sf

        from .pipeline import tts

        engine = tts.get_engine()
        audio = engine.synthesize(SAMPLE_TEXT, voice, 1.0)
        path.parent.mkdir(parents=True, exist_ok=True)
        partial = path.with_suffix(".part.wav")
        sf.write(partial, audio, engine.sample_rate, subtype="PCM_16")
        os.replace(partial, path)
    return FileResponse(path, media_type="audio/wav")


@app.put("/cookies")
def put_cookies(body: CookiesRequest) -> dict:
    """Recebe da extensão os cookies do youtube.com e grava no formato Netscape para o yt-dlp. Nunca são logados."""
    lines = ["# Netscape HTTP Cookie File", ""]
    kept = 0
    for cookie in body.cookies:
        domain = cookie.domain
        if not domain.lstrip(".").endswith("youtube.com") or any(c in cookie.value for c in "\t\n\r"):
            continue
        if not cookie.hostOnly and not domain.startswith("."):
            domain = "." + domain
        prefix = "#HttpOnly_" if cookie.httpOnly else ""
        expires = int(cookie.expirationDate) if cookie.expirationDate else 0
        lines.append("\t".join([
            prefix + domain, "FALSE" if cookie.hostOnly else "TRUE", cookie.path or "/",
            "TRUE" if cookie.secure else "FALSE", str(expires), cookie.name, cookie.value,
        ]))
        kept += 1
    COOKIES_FILE.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(COOKIES_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        handle.write("\n".join(lines) + "\n")
    os.chmod(COOKIES_FILE, 0o600)
    return {"ok": True, "count": kept}


@app.delete("/cookies")
def delete_cookies() -> dict:
    COOKIES_FILE.unlink(missing_ok=True)
    return {"ok": True}


@app.post("/cache/clear")
def clear_cache() -> dict:
    return {"freed_bytes": _manager().clear_cache()}


def main() -> None:
    global manager
    ensure_environment()
    handler = RotatingFileHandler(LOG_DIR / "motor.log", maxBytes=2_000_000, backupCount=2, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    logging.basicConfig(level=logging.INFO, handlers=[handler, logging.StreamHandler()])
    manager = JobManager()
    log.info("motor %s ouvindo em http://%s:%d", __version__, HOST, PORT)
    uvicorn.run(app, host=HOST, port=PORT, log_level="warning", access_log=False)


if __name__ == "__main__":
    main()
