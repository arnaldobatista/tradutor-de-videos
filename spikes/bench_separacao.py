"""Spike 2: tempo de separação voz/fundo por modelo no M1 Max (download do modelo fora da conta)."""
import logging
import sys
import time
from pathlib import Path

import soundfile as sf
from audio_separator.separator import Separator

MODELS = Path.home() / "Library/Application Support/TradutorDeVideos/models/separator"
audio = Path(sys.argv[1])
out = Path(sys.argv[2])
modelos = sys.argv[3:] or [
    "UVR-MDX-NET-Inst_HQ_3.onnx",
    "htdemucs.yaml",
    "vocals_mel_band_roformer.ckpt",
    "model_bs_roformer_ep_317_sdr_12.9755.ckpt",
]
dur = sf.info(audio).duration
print(f"áudio: {audio.name} ({dur:.0f} s)")

for nome in modelos:
    destino = out / Path(nome).stem
    destino.mkdir(parents=True, exist_ok=True)
    try:
        sep = Separator(
            log_level=logging.WARNING,
            model_file_dir=str(MODELS),
            output_dir=str(destino),
            output_format="WAV",
        )
        t0 = time.perf_counter()
        sep.load_model(model_filename=nome)
        t1 = time.perf_counter()
        arquivos = sep.separate(str(audio))
        t2 = time.perf_counter()
        print(
            f"{nome}: carregar+baixar {t1 - t0:.1f} s, separar {t2 - t1:.1f} s "
            f"({dur / (t2 - t1):.1f}x tempo real) -> {arquivos}"
        )
    except Exception as exc:  # noqa: BLE001 - spike: queremos ver qualquer falha e seguir
        print(f"{nome}: FALHOU {type(exc).__name__}: {exc}")
