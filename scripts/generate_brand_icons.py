"""Render SimonTalk's code-defined mark; requires Pillow (10+).

Run from anywhere: uv run --with pillow scripts/generate_brand_icons.py
This changes only generated launcher assets, never user-provided images.
"""

import json
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1] / "apps/client"
COLOR = "#245C45"
BACKGROUND = "#F5F7F2"


def curve(start, a, b, end):
    return [
        tuple((1-t)**3 * start[d] + 3*(1-t)**2*t*a[d]
              + 3*(1-t)*t*t*b[d] + t**3*end[d] for d in (0, 1))
        for t in (i / 80 for i in range(81))
    ]


PATHS = [
    curve((41, 14), (18, 2), (3, 19), (13, 36)) + [(10, 46), (22, 42)]
    + curve((22, 42), (30, 45), (40, 41), (43, 35)),
    curve((23, 29), (26, 19), (44, 18), (51, 28))
    + curve((51, 28), (59, 40), (50, 49), (43, 49)) + [(49, 57), (36, 51)]
    + curve((36, 51), (29, 50), (24, 45), (24, 40)),
]


def render(path, size):
    canvas_size = max(1024, size * 2)
    image = Image.new("RGB", (canvas_size, canvas_size), BACKGROUND)
    draw = ImageDraw.Draw(image)
    scale = canvas_size * .72 / 64
    offset = canvas_size * .14
    stroke = round(3.4 * scale)
    for points in PATHS:
        coordinates = [(x * scale + offset, y * scale + offset) for x, y in points]
        draw.line(coordinates, fill=COLOR, width=stroke, joint="curve")
        for x, y in [coordinates[0], coordinates[-1]]:
            radius = stroke / 2
            draw.ellipse((x-radius, y-radius, x+radius, y+radius), fill=COLOR)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.resize((size, size), Image.Resampling.LANCZOS).save(path)


for density, size in {"mdpi":48, "hdpi":72, "xhdpi":96, "xxhdpi":144, "xxxhdpi":192}.items():
    render(ROOT / f"android/app/src/main/res/mipmap-{density}/ic_launcher.png", size)

icon_folder = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
for icon in json.loads((icon_folder / "Contents.json").read_text())["images"]:
    size = round(float(icon["size"].split("x")[0]) * float(icon["scale"].removesuffix("x")))
    render(icon_folder / icon["filename"], size)

for size in (192, 512):
    render(ROOT / f"web/icons/Icon-{size}.png", size)
    render(ROOT / f"web/icons/Icon-maskable-{size}.png", size)
render(ROOT / "web/favicon.png", 32)
