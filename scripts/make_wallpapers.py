"""Draw Capture's background wallpapers: layered silk waves in soft gradients.

Our own art (no stock images): each wallpaper is a few wave sheets stacked over a gradient,
each sheet lit along its crest and casting a soft shadow on the one behind. Run it again after
changing a palette; it rewrites assets/wallpapers/<id>.jpg and thumbs/<id>.jpg.

    python3 scripts/make_wallpapers.py
"""
import math
import pathlib

import numpy as np
from PIL import Image

W, H = 2560, 1440
OUT = pathlib.Path(__file__).resolve().parent.parent / "assets" / "wallpapers"


def hexrgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)], dtype=np.float32)


# id, name, background top-left -> bottom-right, sheets back to front (each: crest colour, deep colour), fine lines
WALLPAPERS = [
    ("aurora", "Aurora", "#7FE3E0", "#6A4BC4", [("#B794F4", "#5B3FB8"), ("#5EEAD4", "#1E7FA8"), ("#F472D0", "#7C2D92"), ("#3B4CCA", "#1B1F6B")], False),
    ("lagoon", "Lagoon", "#B9F5D0", "#0F7A55", [("#7EE0A8", "#1F9D63"), ("#2FBF71", "#007A3D"), ("#11A05A", "#00552B"), ("#0B6B3A", "#02331A")], False),
    ("ocean", "Ocean", "#A5E8FF", "#2563EB", [("#7DD3FC", "#1D74C9"), ("#38BDF8", "#1E40AF"), ("#60A5FA", "#1E3A8A"), ("#1E3A8A", "#0B1640")], False),
    ("sunset", "Sunset", "#FFC7A8", "#E8476A", [("#FFB088", "#F0603E"), ("#FF8A65", "#D9363E"), ("#F25A5A", "#A3123A"), ("#B3124A", "#5C0628")], False),
    ("dusk", "Dusk", "#F9C6E8", "#5B6CF0", [("#F0A6E0", "#B05BD0"), ("#C4B5FD", "#6D5BD8"), ("#8EA2FF", "#3B4CCA"), ("#3D3BAA", "#191A5C")], False),
    ("spectrum", "Spectrum", "#5EEAD4", "#F0ABFC", [("#99F6E4", "#14B8A6"), ("#86EFAC", "#16A34A"), ("#93C5FD", "#6366F1"), ("#F0ABFC", "#A21CAF")], False),
    ("plum", "Plum", "#E9C8FF", "#4C1D95", [("#D8B4FE", "#9333EA"), ("#C084FC", "#6B21A8"), ("#A855F7", "#4C1D95"), ("#581C87", "#22073F")], False),
    ("ember", "Ember", "#FF9E7A", "#7A0C2E", [("#FF7A59", "#D3302F"), ("#F43F5E", "#9F1239"), ("#E11D48", "#6B0A27"), ("#7F1D1D", "#2A0610")], False),
    ("glacier", "Glacier", "#F4FAFF", "#B9D8F2", [("#FFFFFF", "#CFE3F5"), ("#E3F0FB", "#A9C8E8"), ("#D2E6F7", "#8FB4DB"), ("#BCD5EE", "#7FA3CC")], False),
    ("rose", "Rose", "#FFE4EE", "#F2A7C3", [("#FFF1F6", "#F5B8CF"), ("#FFD3E2", "#EC8DB0"), ("#F9B9CF", "#DB6F98"), ("#EE9DBB", "#C2557F")], False),
    ("mint", "Mint", "#F0FFF6", "#A7E8C5", [("#FFFFFF", "#C9F0DA"), ("#E1F8EA", "#9FDDBB"), ("#C8F1D9", "#7CCBA2"), ("#A9E5C3", "#5DB487")], False),
    ("forest", "Forest", "#1F5C3F", "#04170E", [("#2E8B57", "#0D3B24"), ("#1E6B44", "#072818"), ("#155A38", "#041C10"), ("#0C3B24", "#020D07")], True),
    ("midnight", "Midnight", "#1E2A6B", "#05070F", [("#3442A8", "#111847"), ("#27348C", "#0A0F33"), ("#1B2470", "#070A24"), ("#11174D", "#03050F")], True),
    ("cobalt", "Cobalt", "#1E5BD8", "#0A1440", [("#3B82F6", "#1E3A8A"), ("#2563EB", "#172C6E"), ("#1D4ED8", "#0F1F57"), ("#1E3A8A", "#08112E")], True),
    ("graphite", "Graphite", "#3A3F47", "#060708", [("#5B616B", "#1C1F24"), ("#454A52", "#121418"), ("#33373E", "#0B0C0E"), ("#24272C", "#050506")], True),
    ("obsidian", "Obsidian", "#141414", "#000000", [("#2A2A2A", "#050505"), ("#1F1F1F", "#030303"), ("#171717", "#020202"), ("#0E0E0E", "#000000")], True),
    ("pearl", "Pearl", "#FAFAFA", "#C9CCD1", [("#FFFFFF", "#DADDE2"), ("#F2F3F5", "#C8CCD2"), ("#E6E8EB", "#B4B9C0"), ("#D6D9DE", "#A3A9B1")], True),
    ("slate", "Slate", "#94A3B8", "#1E293B", [("#A8B5C8", "#475569"), ("#7C8BA1", "#334155"), ("#5B6B82", "#1E293B"), ("#334155", "#0F172A")], False),
]


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def draw(seed, bg0, bg1, sheets, lines):
    rng = np.random.default_rng(seed)
    x = np.linspace(0, 1, W, dtype=np.float32)[None, :]
    y = np.linspace(0, 1, H, dtype=np.float32)[:, None]
    px = 1 / H  # one pixel in y units

    # Diagonal gradient behind everything, with a soft glow from one corner.
    t = np.clip(0.55 * x + 0.75 * y, 0, 1)[..., None]
    img = hexrgb(bg0) * (1 - t) + hexrgb(bg1) * t
    gx, gy = rng.uniform(0.15, 0.85), rng.uniform(0.05, 0.35)
    glow = np.exp(-(((x - gx) * 1.6) ** 2 + ((y - gy) * 2.2) ** 2) * 2.5)[..., None]
    img = img + (1 - img) * glow * 0.18

    n = len(sheets)
    slope = rng.choice([-1, 1]) * rng.uniform(0.25, 0.5)
    for k, (crest, deep) in enumerate(sheets):
        base = 0.22 + k * (0.62 / n) + rng.uniform(-0.04, 0.04)
        f1, f2 = rng.uniform(0.3, 0.6), rng.uniform(0.9, 1.5)
        p1, p2 = rng.uniform(0, 1), rng.uniform(0, 1)
        a1, a2 = rng.uniform(0.09, 0.17), rng.uniform(0.015, 0.035)
        edge = base + slope * (x - 0.5) + a1 * np.sin(2 * math.pi * (f1 * x + p1)) + a2 * np.sin(2 * math.pi * (f2 * x + p2))
        d = y - edge  # > 0 inside the sheet

        # The sheet in front darkens the one behind along its crest.
        shadow = np.where(d < 0, np.exp(d / 0.06), 0)[..., None]
        img = img * (1 - 0.28 * shadow)

        # Fine silk lines running along the crest, on the dark sets.
        if lines:
            # Lines fan out from the crest: each one follows the edge, a bit further and flatter.
            for j in range(1, 36):
                off = j * 0.0032 * (1 + 0.05 * j)
                warp = 1 - 0.012 * j
                line = np.exp(-(((y - (base + slope * (x - 0.5)) - (edge - base - slope * (x - 0.5)) * warp + off) / (0.8 * px)) ** 2))
                fade = math.exp(-j / 16)
                img = img + (1 - img) * (line * 0.16 * fade)[..., None]

        # Colour runs from the crest into the deep tone, and slightly across.
        depth = np.clip(d / 0.35 + 0.25 * (x - 0.5), 0, 1)[..., None]
        sheet = hexrgb(crest) * (1 - depth) + hexrgb(deep) * depth
        light = np.exp(-((d / 0.03) ** 2))[..., None]  # soft sheen just below the crest
        sheet = sheet + (1 - sheet) * light * 0.22
        mask = smoothstep(-1.2 * px, 1.2 * px, d)[..., None]
        img = img * (1 - mask) + sheet * mask

    # A little grain, so the gradients never band in an 8-bit video.
    img = img + rng.normal(0, 1.0 / 255, img.shape).astype(np.float32)
    return Image.fromarray((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8))


def main():
    (OUT / "thumbs").mkdir(parents=True, exist_ok=True)
    for i, (wid, _name, bg0, bg1, sheets, lines) in enumerate(WALLPAPERS):
        im = draw(1000 + i * 7, bg0, bg1, sheets, lines)
        im.save(OUT / f"{wid}.jpg", quality=90, subsampling=0, optimize=True)
        im.resize((384, 216), Image.LANCZOS).save(OUT / "thumbs" / f"{wid}.jpg", quality=85)
        print(wid)


if __name__ == "__main__":
    main()
