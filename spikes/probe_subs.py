"""Spike 1: o que o yt-dlp enxerga de áudio e legendas em cada vídeo de teste."""
import json
import subprocess
import sys

VIDEOS = sys.argv[1:] or ["jNQXAC9IVRw", "UNP03fDSj1U", "5C_HPTJg5ek"]

for vid in VIDEOS:
    proc = subprocess.run(
        ["yt-dlp", "-J", "--skip-download", f"https://www.youtube.com/watch?v={vid}"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        print(f"== {vid}: ERRO\n{proc.stderr[-800:]}")
        continue
    info = json.loads(proc.stdout)
    subs = info.get("subtitles") or {}
    auto = info.get("automatic_captions") or {}
    audio = [f for f in info["formats"] if f.get("vcodec") == "none" and f.get("acodec") != "none"]
    best = max(audio, key=lambda f: f.get("abr") or 0) if audio else None
    print(f"== {vid}: {info['title']!r} ({info['duration']} s, idioma={info.get('language')})")
    print(f"   legendas manuais: {sorted(subs)[:40]}")
    print(f"   auto (pt*/en*/orig): {sorted(k for k in auto if k.startswith(('pt', 'en')) or k.endswith('-orig'))}")
    print(f"   total de faixas auto: {len(auto)}")
    if "pt" in auto:
        print(f"   formatos de auto[pt]: {[f['ext'] for f in auto['pt']]}")
    if best:
        print(f"   melhor áudio: id={best['format_id']} {best.get('acodec')} {best.get('abr')} kbps, faixas de áudio={len(audio)}")
