#!/usr/bin/env python3
"""Build the app icon set from tools/icon-source.png.

The source is the MetalHUD artwork with the white background already removed
(transparent alpha). iOS requires the icon asset itself to be opaque, so this
script crops to the artwork bounds, scales to 1024 and composites it over black.
Black matches the artwork's own dark background, and iOS then applies its
squircle mask on top, so the rounded silhouette stays exactly as designed.

Run `python3 tools/make-icon.py` after replacing the source image.
"""
from __future__ import annotations

import os

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "tools", "icon-source.png")
ICONSET = os.path.join(ROOT, "ios-app", "Assets.xcassets", "AppIcon.appiconset")

SIZES = {
    "AppIcon.png": 1024,
    "AppIcon-60@3x.png": 180,
    "AppIcon-60@2x.png": 120,
    "AppIcon-76@2x.png": 152,
    "AppIcon-83.5@2x.png": 167,
}


def build() -> Image.Image:
    source = Image.open(SOURCE).convert("RGBA")
    alpha = source.getchannel("A")
    bbox = alpha.getbbox()
    if bbox is None:
        raise SystemExit("the source image is fully transparent")

    artwork = source.crop(bbox).resize((1024, 1024), Image.LANCZOS)

    # Opaque base: black matches the artwork's own dark surround.
    canvas = Image.new("RGB", (1024, 1024), (0, 0, 0))
    canvas.paste(artwork, (0, 0), artwork)
    return canvas


def main() -> None:
    icon = build()
    os.makedirs(ICONSET, exist_ok=True)
    for name, size in SIZES.items():
        icon.resize((size, size), Image.LANCZOS).save(os.path.join(ICONSET, name))
        print("wrote", name, size)


if __name__ == "__main__":
    main()
