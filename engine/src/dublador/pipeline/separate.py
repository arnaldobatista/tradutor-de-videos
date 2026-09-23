"""Separa a voz original do fundo (música, efeitos, ambiente)."""
from __future__ import annotations

import logging
import shutil
import tempfile
import threading
from pathlib import Path

import numpy as np
import soundfile as sf

from ..config import MODELS_DIR
from .download import PipelineError

log = logging.getLogger(__name__)

_lock = threading.Lock()
_loaded: tuple[str, object] | None = None


def _separator(model: str, output_dir: Path):
    """Mantém o modelo carregado entre jobs; só troca o diretório de saída."""
    global _loaded
    from audio_separator.separator import Separator

    if _loaded is None or _loaded[0] != model:
        separator = Separator(
            log_level=logging.WARNING,
            model_file_dir=str(MODELS_DIR / "separator"),
            output_dir=str(output_dir),
            output_format="WAV",
        )
        separator.load_model(model_filename=model)
        _loaded = (model, separator)
    separator = _loaded[1]
    separator.output_dir = str(output_dir)
    if getattr(separator, "model_instance", None) is not None:
        separator.model_instance.output_dir = str(output_dir)
    return separator


def separate(source: Path, vocals_out: Path, background_out: Path, model: str) -> None:
    (MODELS_DIR / "separator").mkdir(parents=True, exist_ok=True)
    with _lock, tempfile.TemporaryDirectory(prefix="dublador-sep-") as tmp:
        tmp_dir = Path(tmp)
        try:
            produced = _separator(model, tmp_dir).separate(str(source))
        except Exception as exc:  # noqa: BLE001 - a lib levanta tipos variados; a mensagem vai para o usuário
            raise PipelineError(f"Falha na separação de voz ({model}): {exc}") from exc

        stems = {}
        for name in produced:
            path = Path(name)
            path = path if path.is_absolute() else tmp_dir / path
            label = path.stem.split("_(")[-1].split(")")[0].lower() if "_(" in path.stem else path.stem.lower()
            stems[label] = path
        vocals = stems.get("vocals")
        if vocals is None:
            raise PipelineError(f"O modelo {model} não devolveu a faixa de voz (saídas: {sorted(stems)}).")

        rest = [p for label, p in stems.items() if label != "vocals"]
        if len(rest) == 1:
            shutil.move(str(rest[0]), background_out)
        else:  # modelos de 4 faixas (Demucs): fundo = tudo que não é voz
            total, rate = None, 44100
            for path in rest:
                data, rate = sf.read(path, dtype="float32", always_2d=True)
                total = data if total is None else total[: len(data)] + data[: len(total)]
            sf.write(background_out, np.clip(total, -1.0, 1.0), rate, subtype="PCM_16")
        shutil.move(str(vocals), vocals_out)
