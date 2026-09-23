"""Fila de dublagens: um job por vez, com progresso, cancelamento e limpeza de cache."""
from __future__ import annotations

import json
import logging
import queue
import shutil
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

from .config import CACHE_DIR, Settings, load_settings
from .pipeline.download import PipelineError
from .pipeline.run import MIX_VERSION, STAGE_LABELS, output_path, run, video_dir

log = logging.getLogger(__name__)


@dataclass
class Job:
    id: str
    video_id: str
    status: str = "queued"      # queued | running | done | error | cancelled
    stage: str = ""
    progress: float = 0.0
    error: str | None = None
    title: str | None = None
    report: dict | None = None
    created: float = field(default_factory=time.time)
    finished: float | None = None
    cancel: threading.Event = field(default_factory=threading.Event, repr=False)

    def public(self) -> dict:
        return {
            "id": self.id,
            "video_id": self.video_id,
            "status": self.status,
            "stage": self.stage,
            "stage_label": STAGE_LABELS.get(self.stage, ""),
            "progress": round(self.progress, 3),
            "error": self.error,
            "title": self.title,
            "report": self.report,
            "audio_url": f"/jobs/{self.id}/audio" if self.status == "done" else None,
            "finished_at": self.finished,
        }


def job_id(video_id: str, settings: Settings) -> str:
    return f"{video_id}.{settings.target_lang}.{settings.voice}"


def history(limit: int = 5) -> list[dict]:
    """Dublagens prontas, lidas do cache: o histórico sobrevive a reinícios do motor."""
    entries: list[dict] = []
    for directory in CACHE_DIR.iterdir() if CACHE_DIR.exists() else []:
        dubs = sorted(directory.glob("dub.*.m4a"), key=lambda p: p.stat().st_mtime) if directory.is_dir() else []
        report = _read_json(directory / "report.json")
        if not dubs or not report:
            continue
        newest = dubs[-1]
        jid = f"{directory.name}.{newest.name[len('dub.'):-len('.m4a')]}"
        entries.append({
            "id": jid, "video_id": directory.name, "status": "done", "stage": "", "stage_label": "",
            "progress": 1.0, "error": None, "title": report.get("titulo"), "report": report,
            "audio_url": f"/jobs/{jid}/audio", "finished_at": newest.stat().st_mtime,
        })
    entries.sort(key=lambda e: -e["finished_at"])
    return entries[:limit]


def cache_size() -> int:
    return sum(f.stat().st_size for f in CACHE_DIR.rglob("*") if f.is_file()) if CACHE_DIR.exists() else 0


class JobManager:
    def __init__(self) -> None:
        self._jobs: dict[str, Job] = {}
        self._queue: queue.Queue[Job] = queue.Queue()
        self._lock = threading.Lock()
        self._worker = threading.Thread(target=self._loop, name="dublagem", daemon=True)
        self._worker.start()

    def submit(self, video_id: str) -> Job:
        settings = load_settings()
        jid = job_id(video_id, settings)
        with self._lock:
            existing = self._jobs.get(jid)
            if existing and existing.status in ("queued", "running"):
                return existing
            output = output_path(video_id, settings)
            report = _read_json(video_dir(video_id) / "report.json") if output.exists() else None
            if output.exists() and (report or {}).get("mix_version") == MIX_VERSION:
                job = Job(id=jid, video_id=video_id, status="done", progress=1.0)
                job.report = report
                job.title = (job.report or {}).get("titulo")
                output.touch()  # marca uso recente para a limpeza LRU
                self._jobs[jid] = job
                return job
            job = Job(id=jid, video_id=video_id)
            self._jobs[jid] = job
        self._queue.put(job)
        return job

    def get(self, jid: str) -> Job | None:
        with self._lock:
            return self._jobs.get(jid)

    def audio_path(self, jid: str) -> Path | None:
        video_id, _, rest = jid.partition(".")
        path = video_dir(video_id) / f"dub.{rest}.m4a"
        return path if path.exists() else None

    def cancel(self, jid: str) -> bool:
        job = self.get(jid)
        if not job or job.status not in ("queued", "running"):
            return False
        job.cancel.set()
        if job.status == "queued":
            job.status = "cancelled"
        return True

    def snapshot(self) -> dict:
        with self._lock:
            jobs = list(self._jobs.values())
        current = next((j for j in jobs if j.status == "running"), None)
        return {
            "current": current.public() if current else None,
            "queued": [j.public() for j in jobs if j.status == "queued"],
            "recent": self._recent(jobs),
        }

    @staticmethod
    def _recent(jobs: list[Job], limit: int = 5) -> list[dict]:
        # Prontas vêm do cache (persistem); falhas só existem na memória desta execução.
        merged = {entry["id"]: entry for entry in history(limit)}
        for job in jobs:
            if job.status == "error":
                merged[job.id] = job.public()
        ordered = sorted(merged.values(), key=lambda e: -(e.get("finished_at") or 0.0))
        return ordered[:limit]

    def clear_cache(self) -> int:
        """Apaga o cache de todos os vídeos que não estão na fila. Devolve os bytes liberados."""
        with self._lock:
            busy = {j.video_id for j in self._jobs.values() if j.status in ("queued", "running")}
            self._jobs = {k: j for k, j in self._jobs.items() if j.video_id in busy}
        before = cache_size()
        for directory in CACHE_DIR.iterdir() if CACHE_DIR.exists() else []:
            if directory.is_dir() and directory.name not in busy:
                shutil.rmtree(directory, ignore_errors=True)
        return before - cache_size()

    def _loop(self) -> None:
        while True:
            job = self._queue.get()
            if job.cancel.is_set():
                job.status = "cancelled"
                continue
            job.status = "running"
            settings = load_settings()

            def on_progress(stage: str, fraction: float, job: Job = job) -> None:
                job.stage, job.progress = stage, fraction

            def on_info(info: dict, job: Job = job) -> None:
                job.title = info.get("title")

            try:
                _, job.report = run(job.video_id, settings, on_progress, job.cancel.is_set, on_info)
                job.status, job.progress = "done", 1.0
            except PipelineError as exc:
                cancelled = job.cancel.is_set()
                job.status = "cancelled" if cancelled else "error"
                job.error = None if cancelled else str(exc)
                if not cancelled:
                    log.warning("job %s falhou: %s", job.id, exc)
            except Exception as exc:  # noqa: BLE001 - o worker não pode morrer por causa de um vídeo
                log.exception("job %s quebrou", job.id)
                job.status, job.error = "error", f"Erro inesperado: {exc}"
            job.finished = time.time()
            try:
                self._enforce_cache_limit(settings, keep=job.video_id)
            except OSError:
                log.exception("falha ao limpar o cache")

    def _enforce_cache_limit(self, settings: Settings, keep: str) -> None:
        limit = settings.cache_limit_gb * 1024**3
        directories = [d for d in CACHE_DIR.iterdir() if d.is_dir() and d.name != keep]
        directories.sort(key=lambda d: max((f.stat().st_mtime for f in d.iterdir()), default=0.0))
        total = cache_size()
        for directory in directories:  # do menos usado para o mais recente
            if total <= limit:
                break
            total -= sum(f.stat().st_size for f in directory.rglob("*") if f.is_file())
            shutil.rmtree(directory, ignore_errors=True)


def _read_json(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None
