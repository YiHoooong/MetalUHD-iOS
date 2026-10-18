#!/usr/bin/env python3
"""Draw the MetalUHD app icon (Pillow, no borrowed artwork).

Concept: a Metal-HUD gauge ring with a glass play triangle inside it —
"game performance overlay" in one mark. Deep navy background, cyan→green
gauge gradient, soft glass highlights. Run `python3 tools/make-icon.py`.
"""
from __future__ import annotations

import math
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONSET = os.path.join(ROOT, "ios-app", "Assets.xcassets", "AppIcon.appiconset")

S = 1024
CX = CY = S // 2
CYAN = (94, 224, 255)
GREEN = (77, 255, 168)
DEEP = (5, 9, 20)
MID = (10, 26, 54)
WHITE = (248, 252, 255)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def background():
    img = Image.new("RGB", (S, S))
    d = ImageDraw.Draw(img)
    for y in range(S):
        t = y / (S - 1)
        c = lerp(DEEP, MID, t / 0.6) if t < 0.6 else lerp(MID, (7, 16, 34), (t - 0.6) / 0.4)
        d.line([(0, y), (S, y)], fill=c)
    img = img.convert("RGBA")

    # Big soft cyan bloom behind the ring.
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([160, 120, 864, 824], fill=(40, 150, 220, 70))
    gd.ellipse([-80, 520, 420, 1020], fill=(30, 90, 170, 45))
    img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(200)))

    # Vignette.
    vig = Image.new("L", (S, S), 0)
    vd = ImageDraw.Draw(vig)
    vd.ellipse([-160, -160, S + 160, S + 160], fill=120)
    vig = vig.filter(ImageFilter.GaussianBlur(160))
    dark = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    dark.putalpha(Image.eval(vig, lambda v: int((120 - v) * 0.45)))
    img = Image.alpha_composite(img, dark)
    return img


def arc_gradient(draw, box, start, end, width, c1, c2, steps=200):
    for i in range(steps):
        a0 = start + (end - start) * i / steps
        a1 = a0 + (end - start) / steps + 0.8
        draw.arc(box, a0, a1, fill=lerp(c1, c2, i / (steps - 1)) + (255,), width=width)


def cap(draw, radius, angle_deg, color, width):
    a = math.radians(angle_deg)
    x = CX + radius * math.cos(a)
    y = CY + radius * math.sin(a)
    r = width / 2
    draw.ellipse([x - r, y - r, x + r, y + r], fill=color + (255,))


def build():
    img = background()

    ring_r = 318          # outer radius of the gauge stroke centre line
    stroke = 78
    box = [CX - ring_r, CY - ring_r, CX + ring_r, CY + ring_r]
    start, end = 132, 408  # 276° sweep, gap at the bottom

    # Ring shadow.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.arc(box, start, end, fill=(0, 0, 0, 200), width=stroke + 8)
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(34)))

    # Gauge ring gradient.
    ring = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring)
    arc_gradient(rd, box, start, end, stroke, CYAN, GREEN)
    mid_r = ring_r - stroke / 2
    cap(rd, mid_r, start, CYAN, stroke)
    cap(rd, mid_r, end, GREEN, stroke)
    img = Image.alpha_composite(img, ring)

    # Glass highlight on the upper-left of the ring.
    hi = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    hd = ImageDraw.Draw(hi)
    hd.arc([x + 8 for x in box], 196, 300, fill=(255, 255, 255, 120), width=16)
    hi = hi.filter(ImageFilter.GaussianBlur(7))
    img = Image.alpha_composite(img, hi)

    # Play triangle (slightly right of optical centre), with a soft shadow.
    tri = [(438, 330), (438, 694), (716, 512)]

    tri_shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ts = ImageDraw.Draw(tri_shadow)
    ts.polygon([(x + 14, y + 22) for x, y in tri], fill=(0, 0, 0, 190))
    img = Image.alpha_composite(img, tri_shadow.filter(ImageFilter.GaussianBlur(30)))

    # Rounded triangle mask (draw the polygon several times with a shallow blur).
    mask = Image.new("L", (S, S), 0)
    md = ImageDraw.Draw(mask)
    md.polygon(tri, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(10))
    mask = mask.point(lambda v: 255 if v > 120 else 0)

    # White → pale-cyan vertical gradient fill for a glassy look.
    fill = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    fd = ImageDraw.Draw(fill)
    top, bottom = (330, 330), (330, 694)
    for y in range(top[1], bottom[1] + 1):
        t = (y - top[1]) / (bottom[1] - top[1])
        fd.line([(0, y), (S, y)], fill=lerp(WHITE, (176, 235, 255), t) + (255,))
    img = Image.composite(fill, img, mask)

    # Subtle outer HUD brackets: a quiet nod to the overlay, invisible at
    # 60pt but adds a tech edge at large sizes.
    d = ImageDraw.Draw(img)
    for x, y, dx, dy in [(86, 86, 1, 1), (938, 86, -1, 1),
                         (86, 938, 1, -1), (938, 938, -1, -1)]:
        d.line([(x, y + dy * 76), (x, y), (x + dx * 76, y)],
               fill=(160, 240, 255, 110), width=9)

    return img.convert("RGB")


def main():
    icon = build()
    sizes = {
        "AppIcon.png": 1024,
        "AppIcon-60@3x.png": 180,
        "AppIcon-60@2x.png": 120,
        "AppIcon-76@2x.png": 152,
        "AppIcon-83.5@2x.png": 167,
    }
    os.makedirs(ICONSET, exist_ok=True)
    for name, size in sizes.items():
        icon.resize((size, size), Image.LANCZOS).save(os.path.join(ICONSET, name))
        print("wrote", name, size)


if __name__ == "__main__":
    main()
