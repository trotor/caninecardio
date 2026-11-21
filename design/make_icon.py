#!/usr/bin/env python3
"""Renders CanineCardio/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png (requires Pillow).

Usage: python design/make_icon.py CanineCardio/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"""
import math, sys
from PIL import Image, ImageDraw, ImageFilter

N = 4096                     # supersampled canvas, downscaled to 1024 at the end
out = sys.argv[1]

# Background: vertical gradient, deep teal-navy
bg = Image.new("RGB", (N, N))
top, bot = (14, 42, 54), (7, 20, 28)
px = bg.load()
for y in range(N):
    f = y / (N - 1)
    c = tuple(round(top[i] * (1 - f) + bot[i] * f) for i in range(3))
    for x in range(N):
        px[x, y] = c

layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
d = ImageDraw.Draw(layer)

# Heart-shaped main pad
cx, cy, s = N * 0.5, N * 0.64, N * 0.0168
heart = []
for i in range(720):
    t = 2 * math.pi * i / 720
    x = 16 * math.sin(t) ** 3
    y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
    heart.append((cx + s * x, cy - s * y))
coral = (255, 92, 96, 255)
d.polygon(heart, fill=coral)

# Toe beans: four rotated ellipses on an arc above the heart
mint = (226, 245, 236, 255)
toes = [(-0.235, 0.335, 22), (-0.088, 0.245, 7), (0.088, 0.245, -7), (0.235, 0.335, -22)]
for dx, dy, ang in toes:
    w, h = N * 0.112, N * 0.142
    toe = Image.new("RGBA", (int(w * 1.6), int(h * 1.6)), (0, 0, 0, 0))
    ImageDraw.Draw(toe).ellipse([(toe.width - w) / 2, (toe.height - h) / 2,
                                 (toe.width + w) / 2, (toe.height + h) / 2], fill=mint)
    toe = toe.rotate(ang, resample=Image.BICUBIC)
    layer.alpha_composite(toe, (int(cx + dx * N - toe.width / 2), int(dy * N - toe.height / 2)))

# Heartbeat trace: drawn across the whole width, in mint outside the heart and as a
# dark cut-out inside it.
yb = cy - N * 0.035
u = N * 0.0085
pts = [(N * 0.10, yb), (cx - 34 * u, yb), (cx - 28 * u, yb - 4 * u), (cx - 23 * u, yb),
       (cx - 12 * u, yb), (cx - 7 * u, yb + 7 * u), (cx - 1 * u, yb - 19 * u), (cx + 6 * u, yb + 14 * u),
       (cx + 11 * u, yb), (cx + 21 * u, yb), (cx + 27 * u, yb - 6 * u), (cx + 33 * u, yb), (N * 0.90, yb)]
lw = int(N * 0.017)

def trace(color, width):
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    g = ImageDraw.Draw(img)
    g.line(pts, fill=color, width=width, joint="curve")
    for p in (pts[0], pts[-1]):
        g.ellipse([p[0] - width / 2, p[1] - width / 2, p[0] + width / 2, p[1] + width / 2], fill=color)
    return img

heart_mask = Image.new("L", (N, N), 0)
ImageDraw.Draw(heart_mask).polygon(heart, fill=255)
outside = trace(mint, lw)
outside.putalpha(Image.composite(Image.new("L", (N, N), 0), outside.getchannel("A"), heart_mask))
inside = trace((10, 30, 40, 255), lw)
inside.putalpha(Image.composite(inside.getchannel("A"), Image.new("L", (N, N), 0), heart_mask))

# Soft glow under the heart for depth
glow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
ImageDraw.Draw(glow).polygon(heart, fill=(255, 92, 96, 90))
glow = glow.filter(ImageFilter.GaussianBlur(N * 0.03))

img = bg.convert("RGBA")
img.alpha_composite(glow)
img.alpha_composite(layer)
img.alpha_composite(outside)
img.alpha_composite(inside)
img.convert("RGB").resize((1024, 1024), Image.LANCZOS).save(out, optimize=True)
print("wrote", out)
