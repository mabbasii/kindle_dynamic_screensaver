#!/usr/bin/env python3
"""Prepare images for the Kindle Paperwhite 12th gen (1264x1680) photo clock.

For each image: crop (manual crop from CROPS, otherwise trim scanned paper
margins and captions automatically), shrink, and convert to the panel's 16
grays. Big originals are slow to decode on the Kindle and can run it out of
memory, so always run them through this first.

    .venv/bin/python prepare_images.py                 # originals/ -> photoclock/images/
    .venv/bin/python prepare_images.py SRC_DIR DST_DIR

Then copy photoclock/images/* to the Kindle's photoclock/images folder.
"""
import sys
from pathlib import Path

from PIL import Image, ImageOps

try:  # iPhone photos: pip install pillow-heif
    from pillow_heif import register_heif_opener
    register_heif_opener()
except ImportError:
    pass

HERE = Path(__file__).parent
DEFAULT_SRC, DEFAULT_DST = HERE / "originals", HERE / "photoclock" / "images"

# Full screen; the clock is drawn on top of the image.
MAX_W, MAX_H = 1264, 1680
EXTS = {".jpg", ".jpeg", ".png", ".heic", ".webp", ".bmp", ".gif"}

# Manual crops, as fractions of the original: (left, top, right, bottom).
# 0 0 1 1 is the whole image. Images listed here skip the automatic trim.
CROPS = {
    "courtyard-jameh-mosque-rawscan.jpg": (0.150, 0.030, 0.680, 0.920),
}

# Images to fill the whole screen instead of fitting inside it. The value is
# how much the image may be stretched (0.05 = 5%) to match the screen's shape;
# anything beyond that is cropped off the middle of the long side.
FILL = {
    "became-mad-rawscan.jpg": 0.04,
    "courtyard-jameh-mosque-rawscan.jpg": 0.03,
    "eddystone-waves-1600.jpg": 0.03,
    "fly-away-rawscan.jpg": 0.04,
}

# Auto trim: a pixel counts as ink if it is this much darker than the paper,
INK_DELTA = 40
# a row/column is part of the picture if at least this fraction of it is ink,
MIN_INK = 0.02
# and gaps narrower than this fraction of the image don't split the picture.
MAX_GAP = 0.015

# Drawn borders: a row/column this close to the edge (fraction of the image)
FRAME_REACH = 0.04
# that is at least this fraction dark counts as the border line,
FRAME_SOLID = 0.65
# if the picture inside it gets lighter than this within FRAME_DEPTH.
FRAME_INSIDE = 0.5
FRAME_DEPTH = 0.03
# Cut this much further past the border so no trace of it is left.
FRAME_INSET = 0.004

# Extra slice cut off the bottom of every image (fraction of its height), to
# remove the faint paper edge scans leave just inside the crop.
BOTTOM_TRIM = 0.012

# The panel shows 16 gray levels; quantize with dithering so gradients look smooth.
GRAY16 = Image.new("P", (1, 1))
GRAY16.putpalette([v for i in range(16) for v in (i * 17,) * 3] + [0] * 3 * 240)


def _main_run(profile: list[int], n: int) -> tuple[int, int]:
    """Longest stretch of inked rows/cols, bridging small gaps."""
    thr, max_gap = MIN_INK * 255, int(MAX_GAP * n) + 1
    runs: list[list[int]] = []
    for i, v in enumerate(profile):
        if v >= thr:
            if runs and i - runs[-1][1] <= max_gap:
                runs[-1][1] = i + 1
            else:
                runs.append([i, i + 1])
    if not runs:
        return 0, n
    start, end = max(runs, key=lambda r: r[1] - r[0])
    return start, end


def content_box(img: Image.Image) -> tuple[int, int, int, int] | None:
    """Box around the main illustration, dropping paper margins and captions."""
    g = img.convert("L")
    scale = min(1.0, 1000 / max(g.size))
    small = g.resize((max(1, round(g.width * scale)), max(1, round(g.height * scale))), Image.BOX)
    w, h = small.size

    px = small.load()
    edge = [px[x, y] for x in range(w) for y in (0, h - 1)] + [px[x, y] for y in range(h) for x in (0, w - 1)]
    paper = sorted(edge)[len(edge) // 2]
    ink = small.point(lambda v: 255 if v < paper - INK_DELTA else 0)

    # Averaging the ink mask down to one column/row gives ink density per row/column.
    top, bottom = _main_run(list(ink.resize((1, h), Image.BOX).tobytes()), h)
    band = ink.crop((0, top, w, bottom))
    left, right = _main_run(list(band.resize((w, 1), Image.BOX).tobytes()), w)

    # Full-bleed photos have no paper margin; a tiny result means detection failed.
    if (right - left) < 0.5 * w or (bottom - top) < 0.5 * h:
        return None
    return tuple(round(v / scale) for v in (left, top, right, bottom))


def _frame_edge(profile: list[int]) -> int | None:
    """Index of the outermost solid line near the start of the profile, if it
    is a thin line (the picture inside is lighter), else None."""
    n = len(profile)
    reach, depth = int(FRAME_REACH * n) + 1, int(FRAME_DEPTH * n) + 1
    for i in range(reach):
        if profile[i] >= FRAME_SOLID * 255:
            if any(v < FRAME_INSIDE * 255 for v in profile[i : i + depth]):
                return i
            return None
    return None


def frame_box(img: Image.Image) -> tuple[int, int, int, int] | None:
    """If the picture has a drawn border on all four sides, the box just
    inside it, so the border (which scans rarely show evenly) is removed."""
    gray = img.convert("L")
    dark = gray.point(lambda v: 255 if v < 100 else 0)
    w, h = dark.size
    rows = list(dark.resize((1, h), Image.BOX).tobytes())
    cols = list(dark.resize((w, 1), Image.BOX).tobytes())
    profiles = (cols, rows, cols[::-1], rows[::-1])
    edges = [_frame_edge(p) for p in profiles]
    if None in edges:
        return None

    # Walk from the border's outer edge to where the picture starts.
    for i, p in enumerate(profiles):
        while edges[i] < len(p) and p[edges[i]] >= FRAME_INSIDE * 255:
            edges[i] += 1
    left, top, right, bottom = edges
    dx, dy = round(FRAME_INSET * w), round(FRAME_INSET * h)
    box = [left + dx, top + dy, w - right - dx, h - bottom - dy]

    # A tilted scan leaves bits of the border along an edge: keep moving that
    # edge inward while it is still mostly border.
    def has_border(line: Image.Image) -> bool:
        data = line.tobytes()
        return sum(v < 100 for v in data) > FRAME_INSIDE * len(data)

    for _ in range(int(FRAME_DEPTH * min(w, h))):
        l, t, r, b = box
        sides = {
            0: gray.crop((l, t, l + 1, b)), 1: gray.crop((l, t, r, t + 1)),
            2: gray.crop((r - 1, t, r, b)), 3: gray.crop((l, b - 1, r, b)),
        }
        bad = [i for i, line in sides.items() if has_border(line)]
        if not bad:
            break
        for i in bad:
            box[i] += 1 if i < 2 else -1
    return tuple(box)


def fill_screen(img: Image.Image, max_stretch: float) -> Image.Image:
    """Bring the image to the screen's shape: stretch up to max_stretch, crop the rest."""
    target = MAX_W / MAX_H
    if img.width / img.height < target:  # too narrow: widen, then trim top/bottom
        f = min(target * img.height / img.width, 1 + max_stretch)
        img = img.resize((round(img.width * f), img.height), Image.LANCZOS)
        h = min(img.height, round(img.width / target))
        top = (img.height - h) // 2
        return img.crop((0, top, img.width, top + h))
    # too wide: make taller, then trim the sides
    f = min(img.width / (target * img.height), 1 + max_stretch)
    img = img.resize((img.width, round(img.height * f)), Image.LANCZOS)
    w = min(img.width, round(img.height * target))
    left = (img.width - w) // 2
    return img.crop((left, 0, left + w, img.height))


def convert(src: Path, dst_dir: Path) -> None:
    img = Image.open(src)
    img = ImageOps.exif_transpose(img).convert("RGB")
    if src.name in CROPS:
        l, t, r, b = CROPS[src.name]
        box = (round(l * img.width), round(t * img.height), round(r * img.width), round(b * img.height))
    else:
        box = content_box(img)
    if box:
        img = img.crop(box)
    frame = frame_box(img)
    if frame:
        img = img.crop(frame)  # already inside the border; no bottom trim needed
    else:
        img = img.crop((0, 0, img.width, img.height - round(img.height * BOTTOM_TRIM)))
    if src.name in FILL:
        img = fill_screen(img, FILL[src.name]).resize((MAX_W, MAX_H), Image.LANCZOS)
    else:
        # Fit the screen, scaling up small images too (better here than on the Kindle).
        scale = min(MAX_W / img.width, MAX_H / img.height)
        img = img.resize((round(img.width * scale), round(img.height * scale)), Image.LANCZOS)
    img = ImageOps.autocontrast(img.convert("L"), cutoff=1)
    img = img.convert("RGB").quantize(palette=GRAY16, dither=Image.Dither.FLOYDSTEINBERG)
    out = dst_dir / (src.stem + ".png")
    img.convert("L").save(out, optimize=True)
    how = "manual crop" if src.name in CROPS else ("trimmed" if box else "no trim")
    if frame:
        how += ", drawn border removed"
    if src.name in FILL:
        how += ", filled screen"
    print(f"{src.name} -> {out.name} {img.size} ({how})")


def main() -> None:
    if len(sys.argv) == 3:
        src_dir, dst_dir = Path(sys.argv[1]).expanduser(), Path(sys.argv[2]).expanduser()
    elif len(sys.argv) == 1:
        src_dir, dst_dir = DEFAULT_SRC, DEFAULT_DST
    else:
        sys.exit(__doc__)
    dst_dir.mkdir(parents=True, exist_ok=True)
    for p in sorted(src_dir.iterdir()):
        if p.suffix.lower() in EXTS:
            try:
                convert(p, dst_dir)
            except Exception as e:  # e.g. HEIC without pillow-heif installed
                print(f"skipped {p.name}: {e}")


if __name__ == "__main__":
    main()
