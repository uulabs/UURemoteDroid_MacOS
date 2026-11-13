#!/usr/bin/env python3
"""Generate the RemoteDroid macOS app icon.

Run with a Python that has Pillow; the output is Resources/AppIcon.icns.
"""
from __future__ import annotations

import math
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Resources"
ICONSET = ROOT / ".build" / "AppIcon.iconset"
SCALE = 4
SIZE = 1024
CANVAS = SIZE * SCALE


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def gradient_array(size: int, stops: list[tuple[float, float, tuple[int, int, int]]]) -> np.ndarray:
    y, x = np.mgrid[0:size, 0:size]
    xn = x / max(size - 1, 1)
    yn = y / max(size - 1, 1)
    arr = np.zeros((size, size, 3), dtype=np.float32)
    for (x0, y0, color) in stops:
        arr += 0
    # Base diagonal then radial glows.
    base_a = np.array(stops[0][2], dtype=np.float32)
    base_b = np.array(stops[1][2], dtype=np.float32)
    t = np.clip((xn * 0.55 + yn * 0.45), 0, 1)[..., None]
    arr = base_a * (1 - t) + base_b * t
    for cx, cy, radius, color, strength in [
        (0.26, 0.20, 0.55, (53, 227, 199), 0.20),
        (0.78, 0.80, 0.62, (120, 140, 255), 0.16),
        (0.52, 0.38, 0.40, (84, 130, 255), 0.08),
    ]:
        dist = np.sqrt((xn - cx) ** 2 + (yn - cy) ** 2)
        falloff = np.clip(1 - dist / radius, 0, 1) ** 2.2 * strength
        arr += np.array(color, dtype=np.float32) * falloff[..., None]
    return np.clip(arr, 0, 255).astype(np.uint8)


def scaled(*values: float) -> tuple[int, ...]:
    return tuple(int(round(v * SCALE)) for v in values)


def main() -> None:
    RESOURCES.mkdir(parents=True, exist_ok=True)
    ICONSET.mkdir(parents=True, exist_ok=True)

    # Base canvas with a soft transparent margin.
    margin = 64
    inner = SIZE - margin * 2
    radius = int(inner * 0.225)
    mask_small = rounded_mask(inner, radius)
    colors = gradient_array(inner, [
        (0, 0, (9, 13, 19)),
        (1, 1, (16, 26, 38)),
    ])
    base = Image.fromarray(colors, "RGB").convert("RGBA")
    base.putalpha(mask_small)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    base = base.resize((inner * SCALE, inner * SCALE), Image.Resampling.LANCZOS)
    canvas.alpha_composite(base, scaled(margin, margin))

    draw = ImageDraw.Draw(canvas)

    # Ghost devices behind the centered phone.
    for offset, alpha in [(-112, 48), (112, 38)]:
        x0, y0, x1, y1 = scaled(390 + offset, 280, 634 + offset, 772)
        draw.rounded_rectangle(
            (x0, y0, x1, y1),
            radius=int(74 * SCALE),
            outline=(111, 227, 220, alpha),
            width=int(2.2 * SCALE),
        )

    # Phone body.
    px0, py0, px1, py1 = scaled(348, 222, 676, 808)
    body_radius = int(76 * SCALE)
    phone = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    phone_draw = ImageDraw.Draw(phone)
    phone_draw.rounded_rectangle(
        (px0, py0, px1, py1),
        radius=body_radius,
        fill=(5, 8, 13, 255),
        outline=(100, 246, 225, 110),
        width=int(2.5 * SCALE),
    )
    # Deep outer shadow.
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle(
        (px0 - 12 * SCALE, py0 + 8 * SCALE, px1 + 12 * SCALE, py1 + 26 * SCALE),
        radius=body_radius,
        fill=(0, 0, 0, 150),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(30 * SCALE))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(phone)

    # Screen gradient.
    sx0, sy0, sx1, sy1 = scaled(370, 250, 654, 780)
    screen_w, screen_h = sx1 - sx0, sy1 - sy0
    y, x = np.mgrid[0:screen_h, 0:screen_w]
    xn, yn = x / max(screen_w - 1, 1), y / max(screen_h - 1, 1)
    teal = np.array((75, 235, 207), dtype=np.float32)
    blue = np.array((108, 139, 255), dtype=np.float32)
    violet = np.array((164, 126, 255), dtype=np.float32)
    t = np.clip(xn * 0.55 + yn * 0.45, 0, 1)[..., None]
    screen = teal * (1 - t) + blue * t
    # Darken the lower portion for a console-like screen.
    vignette = (1 - 0.26 * np.clip((yn - 0.15) / 0.85, 0, 1))[..., None]
    screen = screen * vignette
    # Add a few horizontal UI bands.
    for band_y, band_h, alpha in [(0.10, 0.07, 0.18), (0.25, 0.035, 0.13), (0.33, 0.035, 0.10), (0.41, 0.035, 0.08)]:
        y0 = int(band_y * screen_h)
        y1 = min(screen_h, y0 + int(band_h * screen_h))
        banner = np.zeros_like(screen)
        banner[y0:y1, int(0.10 * screen_w):int(0.90 * screen_w)] = 255
        blur = Image.fromarray((banner[..., 0]).astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(3 * SCALE))
        a = np.array(blur, dtype=np.float32)[..., None] / 255 * alpha
        screen = screen * (1 - a) + np.array((6, 15, 23), dtype=np.float32) * a
    screen_img = Image.fromarray(np.clip(screen, 0, 255).astype(np.uint8), "RGB").convert("RGBA")
    screen_mask = Image.new("L", (screen_w, screen_h), 0)
    ImageDraw.Draw(screen_mask).rounded_rectangle(
        (0, 0, screen_w - 1, screen_h - 1),
        radius=int(55 * SCALE),
        fill=255,
    )
    screen_img.putalpha(screen_mask)
    canvas.alpha_composite(screen_img, (sx0, sy0))

    # Cursor arrow with a click ring.
    cursor = [
        (470, 420), (470, 588), (508, 551), (544, 625), (576, 609), (540, 536), (590, 536)
    ]
    cursor_pts = [(int(x * SCALE), int(y * SCALE)) for x, y in cursor]
    # shadow
    shadow_pts = [(x + int(7 * SCALE), y + int(9 * SCALE)) for x, y in cursor_pts]
    draw.polygon(shadow_pts, fill=(0, 0, 0, 95))
    draw.polygon(cursor_pts, fill=(250, 255, 255, 255))
    ring_center = (int(474 * SCALE), int(421 * SCALE))
    ring_r = int(27 * SCALE)
    draw.ellipse(
        (ring_center[0] - ring_r, ring_center[1] - ring_r, ring_center[0] + ring_r, ring_center[1] + ring_r),
        outline=(255, 255, 255, 125),
        width=int(3.5 * SCALE),
    )

    # Device camera dot and a soft accent highlight on the top edge.
    draw.ellipse(
        scaled(501, 234, 523, 246),
        fill=(10, 18, 26, 255),
        outline=(126, 245, 230, 130),
        width=int(1.2 * SCALE),
    )
    highlight = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    hd = ImageDraw.Draw(highlight)
    hd.rounded_rectangle(
        (px0 + int(28 * SCALE), py0 + int(22 * SCALE), px1 - int(28 * SCALE), py0 + int(26 * SCALE)),
        radius=int(3 * SCALE),
        fill=(255, 255, 255, 52),
    )
    canvas.alpha_composite(highlight)

    # Rounded outer border for a finished app-icon silhouette.
    border = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    bd = ImageDraw.Draw(border)
    bd.rounded_rectangle(
        scaled(margin, margin, SIZE - margin, SIZE - margin),
        radius=int(radius * SCALE),
        outline=(255, 255, 255, 30),
        width=int(1.5 * SCALE),
    )
    canvas.alpha_composite(border)

    master = canvas.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    master.save(RESOURCES / "AppIcon-1024.png")

    sizes = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }
    for name, dim in sizes.items():
        master.resize((dim, dim), Image.Resampling.LANCZOS).save(ICONSET / name)

    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(RESOURCES / "AppIcon.icns")], check=True)
    print(f"Wrote {RESOURCES / 'AppIcon.icns'}")


if __name__ == "__main__":
    main()
