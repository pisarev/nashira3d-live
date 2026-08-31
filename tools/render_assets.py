"""The pictures for this page. Drawn by the same core the product uses.

    NASHIRA3D_LIB=<path to the built library> python tools/render_assets.py

Why not screenshots. A screenshot is taken by hand, and a month later it shows
a version that is gone, with nobody to say so. Here the pictures are built from
the library by one command, so they have nowhere to drift.

WHY LINE DRAWINGS AND NOT COLOUR. The page is set in the paper style: warm
paper, ink, hairline rules. A dark frame from the viewer would read as a
sticker glued onto that. So the contour shading is taken and turned into dark
lines on light paper, which gives a drawing rather than a screenshot.

The inversion is applied ONLY inside the silhouette of the surface, and the
silhouette is taken from the COLOUR frame: under contour lines the surface is
neutral, and saturation cannot tell it from the background. The same trick as
in tests/probe_contours.py in the library.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "assets")

# The core comes from an environment variable: this page has no build of its
# own and must not have one.
if "NASHIRA3D_LIB" not in os.environ:
    sys.exit("set NASHIRA3D_LIB - the path to the built library")
if "NASHIRA3D_PY" in os.environ:
    sys.path.insert(0, os.environ["NASHIRA3D_PY"])

import numpy as np
import nashira3d
from PIL import Image

PAPER = np.array([0xF0, 0xF1, 0xEC], dtype=float)
INK = np.array([0x17, 0x1A, 0x18], dtype=float)


def paper_drawing(formula, w, h, dom, bz, cam, quality=95, pad=18):
    """A drawing of the surface: dark lines on light paper, cropped to the edge.

    The frame is rendered WIDER than needed and cropped to the silhouette.

    The crop does NOT go by the whole silhouette. The colour bar is the most
    saturated thing in the frame, so it enters the mask first, and a box around
    the whole mask stretched to the left edge along with it. The first guess -
    "the bar is outside the silhouette" - was wrong the other way round.

    It is separated by THICKNESS instead: the bar is about thirteen pixels
    wide, the surface hundreds. The mask is narrowed horizontally by twenty
    pixels on each side, which removes the bar entirely and leaves the surface.
    """
    with nashira3d.Session(formula, quality=quality) as s:
        s.domain = dom
        s.grid = True
        s.axes = False
        s.box = (1, 1, bz)
        s.fit = False
        s.camera = cam
        s.shading = "colour"
        col = s.render(w, h)[:, :, :3].astype(int)
        s.shading = "contours"
        con = s.render(w, h)[:, :, :3].astype(float)

    sat = col.max(axis=2) - col.min(axis=2)
    mask = sat > 28
    if not mask.any():
        raise SystemExit("no silhouette found: " + formula)

    lum = 0.2126 * con[:, :, 0] + 0.7152 * con[:, :, 1] + 0.0722 * con[:, :, 2]
    out = np.tile(PAPER, (h, w, 1))
    v = lum[mask]
    # The ends come from percentiles rather than from the minimum and maximum:
    # one bright highlight would drag the whole scale and wash the drawing out.
    lo, hi = np.percentile(v, 2), np.percentile(v, 98)
    t = np.clip((lum - lo) / max(hi - lo, 1e-6), 0, 1)[..., None]
    out[mask] = (INK * (1 - t) + PAPER * t)[mask]

    thin = 20
    wide = mask.copy()
    for d in range(1, thin + 1):
        wide &= np.roll(mask, d, axis=1) & np.roll(mask, -d, axis=1)
    if not wide.any():
        wide = mask
    ys, xs = np.where(wide)
    y0 = max(0, ys.min() - pad)
    y1 = min(h, ys.max() + pad + 1)
    x0 = max(0, xs.min() - thin - pad)
    x1 = min(w, xs.max() + thin + pad + 1)
    return Image.fromarray(out[y0:y1, x0:x1].astype(np.uint8), "RGB")


# The samples shown on the page. The formulas come from the gallery in the
# viewer: what is shown here should be what a person gets when they press a
# button, not something picked to look good.
SHOTS = [
    ("hero", "sin(3*x)*cos(3*y)*exp(-(x*x+y*y))", 1500, 1050,
     (-2, 2, -2, 2), 0.45, (0.9, 0.5, 3.2, 0.9)),
    ("saddle", "x*x - y*y", 900, 700,
     (-1, 1, -1, 1), 0.5, (0.8, 0.45, 3.2, 0.9)),
    ("ripple", "sin(5*sqrt(x**2+y**2))/(1+2*(x**2+y**2))", 900, 700,
     (-2.5, 2.5, -2.5, 2.5), 0.5, (0.9, 0.55, 3.2, 0.9)),
    ("peak", "exp(-40*((x-0.137)**2 + y*y))", 900, 700,
     (-1, 1, -1, 1), 0.6, (0.9, 0.5, 3.0, 0.9)),
]


def main():
    if not os.path.isdir(OUT):
        os.makedirs(OUT)
    print("core:", nashira3d.version())
    for name, f, w, h, dom, bz, cam in SHOTS:
        im = paper_drawing(f, w, h, dom, bz, cam)
        p = os.path.join(OUT, name + ".png")
        im.convert("P", palette=Image.ADAPTIVE, colors=64).save(p, optimize=True)
        print("  %-8s %4dx%-4d %7d bytes  %s"
              % (name, im.width, im.height, os.path.getsize(p), f))


if __name__ == "__main__":
    main()
