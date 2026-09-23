"""CLI: `dub <url ou id>` roda o pipeline inteiro e mostra o relatório."""
from __future__ import annotations

import argparse
import json
import logging
import re
import sys

from .config import VOICES, ensure_environment, load_settings
from .pipeline.download import PipelineError
from .pipeline.run import STAGE_LABELS, run

_ID = re.compile(r"(?:v=|youtu\.be/|/shorts/|/embed/)([\w-]{11})")


def parse_video_id(value: str) -> str:
    if re.fullmatch(r"[\w-]{11}", value):
        return value
    match = _ID.search(value)
    if not match:
        raise SystemExit(f"não reconheci um vídeo do YouTube em: {value}")
    return match.group(1)


def main() -> None:
    parser = argparse.ArgumentParser(prog="dub", description="Dubla um vídeo do YouTube para pt-BR.")
    parser.add_argument("video", help="URL ou ID do vídeo")
    parser.add_argument("--voz", choices=sorted(VOICES), help="voz do Kokoro")
    parser.add_argument("--tradutor", choices=("youtube", "ollama"))
    parser.add_argument("--separador", help="modelo do audio-separator")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    ensure_environment()
    logging.basicConfig(level=logging.INFO if args.verbose else logging.WARNING, format="%(levelname)s %(name)s: %(message)s")
    settings = load_settings()
    if args.voz:
        settings.voice = args.voz
    if args.tradutor:
        settings.translator = args.tradutor
    if args.separador:
        settings.separator_model = args.separador

    last = {"stage": ""}

    def on_progress(stage: str, fraction: float) -> None:
        if stage != last["stage"]:
            last["stage"] = stage
            print(f"[{fraction * 100:3.0f}%] {STAGE_LABELS.get(stage, stage)}…", file=sys.stderr, flush=True)

    try:
        output, report = run(parse_video_id(args.video), settings, on_progress)
    except PipelineError as exc:
        raise SystemExit(f"erro: {exc}") from exc
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print(output)


if __name__ == "__main__":
    main()
