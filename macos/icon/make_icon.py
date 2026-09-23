"""Gera o ícone do app (AppIcon.icns) e os ícones da extensão a partir do mesmo desenho.

Uso: ../../engine/.venv/bin/python make_icon.py   (precisa de Pillow e do iconutil do macOS)
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).parent
EXTENSION_ICONS = HERE.parent.parent / "extension" / "icons"
SIZE = 1024
S = 4  # desenha em 4x e reduz: bordas suaves em qualquer tamanho

BLUE_TOP, BLUE_BOTTOM = (76, 158, 232), (22, 92, 168)
BAR_BLUE = (24, 95, 165)
WHITE = (255, 255, 255)


def rounded_mask(size: int, box: tuple[int, int, int, int], radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def vertical_gradient(size: int, top: tuple, bottom: tuple) -> Image.Image:
    gradient = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        gradient.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return gradient.resize((size, size))


def draw_artwork(full_bleed: bool) -> Image.Image:
    """`full_bleed=False`: grid do macOS (quadrado de 824 centrado em 1024). `True`: ocupa a tela toda (extensão)."""
    n = SIZE * S
    margin = 0 if full_bleed else 100 * S
    side = n - 2 * margin
    radius = round(side * 0.225)
    box = (margin, margin, margin + side - 1, margin + side - 1)

    canvas = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    body = vertical_gradient(n, BLUE_TOP, BLUE_BOTTOM).convert("RGBA")
    canvas.paste(body, (0, 0), rounded_mask(n, box, radius))

    # brilho suave no topo, como os ícones do sistema
    glow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((margin - side * 0.2, margin - side * 0.55, margin + side * 1.2, margin + side * 0.45),
                                 fill=(255, 255, 255, 28))
    glow = glow.filter(ImageFilter.GaussianBlur(side * 0.06))
    glow.putalpha(Image.composite(glow.getchannel("A"), Image.new("L", (n, n), 0), rounded_mask(n, box, radius)))
    canvas = Image.alpha_composite(canvas, glow)

    # balão de fala
    def at(fx: float, fy: float) -> tuple[float, float]:
        return margin + side * fx, margin + side * fy

    layer = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    x0, y0 = at(0.16, 0.20)
    x1, y1 = at(0.84, 0.68)
    draw.rounded_rectangle((x0, y0, x1, y1), radius=side * 0.13, fill=WHITE)
    draw.polygon([at(0.30, 0.66), at(0.30, 0.83), at(0.45, 0.66)], fill=WHITE)
    # sombra discreta do balão sobre o azul
    shadow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((x0, y0 + side * 0.02, x1, y1 + side * 0.02), radius=side * 0.13, fill=(0, 0, 0, 60))
    shadow = shadow.filter(ImageFilter.GaussianBlur(side * 0.02))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas = Image.alpha_composite(canvas, layer)

    # onda sonora dentro do balão
    draw = ImageDraw.Draw(canvas)
    cy = margin + side * 0.44
    bar_w = side * 0.055
    gap = side * 0.036
    heights = (0.12, 0.22, 0.30, 0.19, 0.10)
    total = len(heights) * bar_w + (len(heights) - 1) * gap
    x = margin + side * 0.5 - total / 2
    for h in heights:
        half = side * h / 2
        draw.rounded_rectangle((x, cy - half, x + bar_w, cy + half), radius=bar_w / 2, fill=BAR_BLUE)
        x += bar_w + gap
    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


def main() -> None:
    app_art = draw_artwork(full_bleed=False)
    iconset = HERE / "AppIcon.iconset"
    shutil.rmtree(iconset, ignore_errors=True)
    iconset.mkdir()
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = points * scale
            name = f"icon_{points}x{points}" + ("@2x" if scale == 2 else "") + ".png"
            app_art.resize((px, px), Image.LANCZOS).save(iconset / name)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(HERE / "AppIcon.icns")], check=True)
    shutil.rmtree(iconset)
    app_art.save(HERE / "AppIcon-1024.png")

    extension_art = draw_artwork(full_bleed=True)
    for px in (16, 48, 128):
        extension_art.resize((px, px), Image.LANCZOS).save(EXTENSION_ICONS / f"icon{px}.png")
    print("ok:", HERE / "AppIcon.icns", "+ ícones da extensão")


if __name__ == "__main__":
    main()
