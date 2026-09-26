"""Caminhos, ajustes persistidos e constantes do motor."""
from __future__ import annotations

import json
import os
import re
import threading
from dataclasses import asdict, dataclass, fields
from pathlib import Path

APP_NAME = "TradutorDeVideos"
HOME = Path.home()
APP_SUPPORT = HOME / "Library/Application Support" / APP_NAME
CACHE_DIR = HOME / "Library/Caches" / APP_NAME
LOG_DIR = HOME / "Library/Logs" / APP_NAME
MODELS_DIR = APP_SUPPORT / "models"
SETTINGS_FILE = APP_SUPPORT / "settings.json"
COOKIES_FILE = APP_SUPPORT / "cookies.txt"

HOST = "127.0.0.1"
# TDV_PORT só existe para testar uma segunda instância sem derrubar a principal.
PORT = int(os.environ.get("TDV_PORT", "47811"))

# ID fixo da extensão, derivado da chave pública em extension/manifest.json.
EXTENSION_ID = "ilmjfenckbenkgighlfojdejdoiiflmo"
ALLOWED_ORIGINS = (f"chrome-extension://{EXTENSION_ID}",)

KOKORO_BASE_URL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
KOKORO_FILES = ("kokoro-v1.0.onnx", "voices-v1.0.bin")

VOICES = {
    "pf_dora": "Dora (feminina)",
    "pm_alex": "Alex (masculina)",
    "pm_santa": "Santa (masculina)",
}

# Apps iniciados pelo Finder/launchd não herdam o PATH do shell: ffmpeg e deno ficam no Homebrew.
_EXTRA_PATH = ("/opt/homebrew/bin", "/usr/local/bin")


def ensure_environment() -> None:
    parts = os.environ.get("PATH", "").split(os.pathsep)
    for extra in _EXTRA_PATH:
        if extra not in parts:
            parts.append(extra)
    os.environ["PATH"] = os.pathsep.join(p for p in parts if p)
    for directory in (APP_SUPPORT, CACHE_DIR, LOG_DIR, MODELS_DIR):
        directory.mkdir(parents=True, exist_ok=True)


@dataclass
class Settings:
    target_lang: str = "pt"
    voice: str = "pf_dora"
    separator_model: str = "htdemucs.yaml"
    # "youtube": faixa traduzida do próprio YouTube; "ollama": tradução local.
    translator: str = "youtube"
    ollama_fallback: bool = True
    # Usa o LLM local para pontuar a transcrição (falas por frase) e enxugar o que não cabe no tempo.
    ollama_assist: bool = True
    ollama_model: str = ""
    ollama_url: str = "http://127.0.0.1:11434"
    use_cookies: bool = True
    # Navegador de onde o yt-dlp lê os cookies (--cookies-from-browser): "chrome", "chrome:Profile 1", "safari"...
    # Vazio = usa só os cookies enviados pela extensão.
    cookies_from_browser: str = ""
    base_speed: float = 1.0
    max_speed: float = 1.4
    # Fundo intocado sob a fala, como no original. Negativo abaixa o fundo enquanto a voz fala.
    duck_db: float = 0.0
    # Voz dublada em relação ao volume da voz original (dB). 0 = igual.
    voice_offset_db: float = 0.0
    cache_limit_gb: float = 10.0
    # Cor de destaque do macOS (#RRGGBB), publicada pelo app para a extensão usar a mesma cor.
    ui_accent: str = ""
    max_duration_min: int = 180

    def public(self) -> dict:
        return asdict(self)


_lock = threading.Lock()
_settings: Settings | None = None


def load_settings() -> Settings:
    global _settings
    with _lock:
        if _settings is None:
            data = {}
            if SETTINGS_FILE.exists():
                try:
                    data = json.loads(SETTINGS_FILE.read_text())
                except (OSError, ValueError):
                    data = {}
            known = {f.name for f in fields(Settings)}
            _settings = Settings(**{k: v for k, v in data.items() if k in known})
        return _settings


def update_settings(changes: dict) -> Settings:
    current = load_settings()
    types = {f.name: type(getattr(current, f.name)) for f in fields(Settings)}
    with _lock:
        for key, value in changes.items():
            if key not in types:
                raise ValueError(f"ajuste desconhecido: {key}")
            expected = types[key]
            if expected is float and isinstance(value, int) and not isinstance(value, bool):
                value = float(value)
            if not isinstance(value, expected):
                raise ValueError(f"tipo inválido para {key}: esperado {expected.__name__}")
            if key == "voice" and value not in VOICES:
                raise ValueError(f"voz desconhecida: {value}")
            if key == "translator" and value not in ("youtube", "ollama"):
                raise ValueError(f"tradutor desconhecido: {value}")
            if key == "voice_offset_db" and not -12.0 <= value <= 12.0:
                raise ValueError("voice_offset_db fora da faixa (-12 a 12 dB)")
            if key == "duck_db" and not -12.0 <= value <= 0.0:
                raise ValueError("duck_db fora da faixa (-12 a 0 dB)")
            if key == "ui_accent" and value and not re.fullmatch(r"#[0-9A-Fa-f]{6}", value):
                raise ValueError("ui_accent precisa ser #RRGGBB")
            if key == "cache_limit_gb" and not 1.0 <= value <= 500.0:
                raise ValueError("cache_limit_gb fora da faixa (1 a 500)")
            setattr(current, key, value)
        APP_SUPPORT.mkdir(parents=True, exist_ok=True)
        SETTINGS_FILE.write_text(json.dumps(asdict(current), indent=2, ensure_ascii=False))
    return current
