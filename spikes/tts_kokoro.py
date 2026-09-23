"""Spike 3: Kokoro pt-BR — velocidade (RTF), ritmo de fala e efeito do parâmetro speed."""
import sys
import time
from pathlib import Path

import soundfile as sf
from kokoro_onnx import Kokoro

MODELS = Path.home() / "Library/Application Support/TradutorDeVideos/models"
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / "out"
OUT.mkdir(parents=True, exist_ok=True)

FRASES = [
    "Rust é uma linguagem de programação compilada e segura em memória, que entrega simplicidade de alto nível com desempenho de baixo nível.",
    "É uma escolha popular para construir sistemas onde o desempenho é absolutamente crítico, como motores de jogos, bancos de dados ou sistemas operacionais.",
    "Nos últimos trinta dias, eu decidi tentar algo novo todos os dias.",
]

t0 = time.perf_counter()
kokoro = Kokoro(str(MODELS / "kokoro-v1.0.onnx"), str(MODELS / "voices-v1.0.bin"))
print(f"carregar modelo: {time.perf_counter() - t0:.2f} s")
print("vozes pt-BR:", [v for v in kokoro.get_voices() if v.startswith("p")])

for voz in ("pf_dora", "pm_alex", "pm_santa"):
    for speed in (1.0, 1.3):
        total_audio = total_wall = total_chars = 0.0
        for i, frase in enumerate(FRASES):
            t = time.perf_counter()
            samples, sr = kokoro.create(frase, voice=voz, speed=speed, lang="pt-br")
            total_wall += time.perf_counter() - t
            total_audio += len(samples) / sr
            total_chars += len(frase)
            if i == 0:
                sf.write(OUT / f"kokoro_{voz}_{speed}.wav", samples, sr)
        print(
            f"{voz} speed={speed}: áudio {total_audio:5.1f} s em {total_wall:4.1f} s "
            f"(RTF {total_wall / total_audio:.3f}, {total_chars / total_audio:4.1f} chars/s, sr={sr})"
        )
