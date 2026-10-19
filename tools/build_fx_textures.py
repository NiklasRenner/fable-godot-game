"""Builds the spell-effect textures in assets/fx/tex/ (plain Python: numpy + PIL).

    python tools/build_fx_textures.py

Everything is greyscale density, coloured in the shaders (fx_particle, fx_ribbon): the
brightest parts burn white, the middle takes the effect's colour, the thin edges darken, and
"erosion" eats the low densities first as a particle ages, so effects tear apart into wisps
instead of fading as flat discs. That, and painted-looking irregular shapes instead of round
dots, is most of what makes stylised MMO effects read.

  noise.png   256 px, tiling: R/G/B are three independent fractal noises (distortion, erosion)
  fire.png    2x2 variants: painted flame balls (from meshy/fx/fire_src.png only)
  smoke.png   2x2 variants: billowy puffs; R = density, G = baked top light (for shading)
  wisp.png    2x2 variants: curled streaks of magic / wind
  glint.png   a four-point star with a soft halo (sparkles, impacts)
  spark.png   a short hot streak with a soft tail (velocity-aligned sparks)
  trail.png   256 x 64, tiling along X: torn streaks for ribbon trails and swing arcs
  swirl.png   a spiral of soft arms (arcane, blink, level-up rune centre)
  shards.png  2x2 variants: angular ice / crystal shards

Painted sources (Meshy text-to-image, greyscale on black, meshy/fx/*_src.png; task ids in
meshy/world.json under "fx"): fire comes only from its sheet; painted smoke and wisp replace the
procedural ones when present. Each 2x2 sheet is cut into its four shapes, each centred and padded into a 256 px cell, luminance
becoming density. Those hand-painted shapes (flame tongues, billowing puffs, crescents and
spirals) are what makes the effects read as painted rather than as noise.
  streak.png  a painted slash streak (the swing arcs), cropped from streak_src.png
  decal_rune / decal_frost / decal_shock / decal_scorch.png: painted ground decals (top-down,
              RGBA: colour white or soot, alpha the painted value)
"""
import os
import numpy as np
from PIL import Image, ImageFilter

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "fx", "tex")
rng = np.random.default_rng(7)


def fbm(n, beta=2.0, seed=0, aniso=(1.0, 1.0)):
    """Tiling fractal noise: white noise shaped to a 1/f^beta spectrum, normalised to 0..1."""
    r = np.random.default_rng(seed)
    w = r.standard_normal((n, n))
    fy = np.fft.fftfreq(n)[:, None] * aniso[1]
    fx = np.fft.fftfreq(n)[None, :] * aniso[0]
    f = np.sqrt(fx * fx + fy * fy)
    f[0, 0] = 1.0
    spec = np.fft.fft2(w) / f ** (beta / 2.0)
    spec[0, 0] = 0
    out = np.real(np.fft.ifft2(spec))
    out -= out.min()
    return out / out.max()


def sample(tex, x, y):
    """Bilinear, wrapping lookup of a square noise texture at pixel coords x, y (arrays)."""
    n = tex.shape[0]
    x0 = np.floor(x).astype(int)
    y0 = np.floor(y).astype(int)
    fx, fy = x - x0, y - y0
    x0 %= n
    y0 %= n
    x1, y1 = (x0 + 1) % n, (y0 + 1) % n
    return (tex[y0, x0] * (1 - fx) * (1 - fy) + tex[y0, x1] * fx * (1 - fy) +
            tex[y1, x0] * (1 - fx) * fy + tex[y1, x1] * fx * fy)


def smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def grid(n):
    y, x = np.mgrid[0:n, 0:n].astype(np.float64)
    return (x + 0.5) / n * 2 - 1, (y + 0.5) / n * 2 - 1  # -1..1, y down


def save(name, arr, mode="L"):
    arr = np.clip(arr, 0, 1)
    img = Image.fromarray((arr * 255).astype(np.uint8), mode)
    img.save(os.path.join(OUT, name))
    print("wrote", name, img.size)


def atlas(cells, cols):
    rows = (len(cells) + cols - 1) // cols
    n = cells[0].shape[0]
    out = np.zeros((rows * n, cols * n) + cells[0].shape[2:])
    for i, c in enumerate(cells):
        out[(i // cols) * n:(i // cols + 1) * n, (i % cols) * n:(i % cols + 1) * n] = c
    return out


N1 = fbm(256, 2.2, 1)
N2 = fbm(256, 1.8, 2)
N3 = fbm(256, 2.6, 3)
# smoother noises for the shapes themselves: big soft features, no speckle, so the shapes read as
# painted blobs and tongues (the erosion in the shaders then gives them crisp edges)
S1 = fbm(256, 3.4, 11)
S2 = fbm(256, 3.0, 12)
S3 = fbm(256, 3.2, 13)


def noise_tex():
    save("noise.png", np.dstack([N1, N2, N3]), "RGB")


def smoke():
    n = 128
    x, y = grid(n)
    cells = []
    for v in range(4):
        r0 = rng.uniform(0, 256, 2)
        warp = sample(S2, (x + 1) * 50 + r0[0], (y + 1) * 50 + r0[1]) - 0.5
        lobes = np.zeros_like(x)
        for _ in range(5):  # a few overlapping round billows make a cauliflower outline
            c = rng.uniform(-0.28, 0.28, 2)
            rr = rng.uniform(0.45, 0.62)
            lobes = np.maximum(lobes, smooth(rr, rr * 0.2, np.hypot(x - c[0] + warp * 0.3, y - c[1] + warp * 0.3)))
        detail = sample(S1, (x + 1) * 70 + r0[1], (y + 1) * 70 + r0[0])
        d = lobes * (0.6 + 0.6 * detail)
        d = smooth(0.12, 0.9, d) * smooth(1.0, 0.8, np.maximum(np.abs(x), np.abs(y)))
        # baked light from above: brighter on the upper side of each billow
        gy = np.gradient(d, axis=0)
        light = np.clip(0.75 - gy * 6.0 - y * 0.3, 0, 1)
        cells.append(np.dstack([d, light, np.zeros_like(d)]))
    save("smoke.png", atlas(cells, 2), "RGB")


def wisp():
    n = 128
    x, y = grid(n)
    cells = []
    for v in range(4):
        r0 = rng.uniform(0, 256, 2)
        bend = rng.uniform(0.5, 1.3) * rng.choice([-1, 1])
        # a curved streak: distance from a parabola, thinning toward both ends
        cx = bend * 0.45 * (y * y - 0.4)
        warp = sample(S2, (x + 1) * 60 + r0[0], (y + 1) * 30 + r0[1]) - 0.5
        dist = np.abs(x - cx + warp * 0.3)
        width = 0.28 * (1 - y * y) ** 0.7
        core = smooth(width, width * 0.15, dist)
        streaks = sample(S1, (x + 1) * 160 + r0[1], (y + 1) * 22 + r0[0])
        d = core * (0.45 + 0.8 * streaks) * smooth(1.0, 0.6, np.abs(y))
        cells.append(smooth(0.1, 0.9, d))
    save("wisp.png", atlas(cells, 2))


def glint():
    n = 128
    x, y = grid(n)
    r = np.hypot(x, y)
    a = np.arctan2(y, x)
    rays = np.abs(np.cos(2 * a)) ** 60 * smooth(1.0, 0.0, r) ** 1.5           # the main cross
    rays2 = np.abs(np.cos(2 * a + np.pi / 4)) ** 120 * smooth(0.6, 0.0, r) * 0.6  # thinner diagonals
    halo = smooth(0.7, 0.0, r) ** 3 * 0.55
    core = smooth(0.18, 0.0, r)
    save("glint.png", np.clip(rays + rays2 + halo + core, 0, 1))


def spark():
    n = 128
    x, y = grid(n)
    # a vertical streak: hot round head at the top, tapering tail below
    w = 0.16 * smooth(1.0, -0.6, y) + 0.02
    d = smooth(w, 0.0, np.abs(x)) * smooth(1.0, 0.75, np.abs(y)) * (0.35 + 0.65 * smooth(1.0, -0.7, y))
    head = smooth(0.25, 0.0, np.hypot(x, (y + 0.55) * 0.8))
    save("spark.png", np.clip(d + head, 0, 1))


def trail():
    w, h = 256, 64
    y, x = np.mgrid[0:h, 0:w].astype(np.float64)
    v = (y + 0.5) / h * 2 - 1
    # broad torn streaks running along X (the noise is sampled 1x along, 3x across: stretched),
    # tiling in X with the noise's 256 px period
    s = sample(S1, x, y * 1.5 + 20) * 0.65 + sample(S3, x * 2.0, y * 2.5 + 90) * 0.35
    wob = sample(S2, x, 10.0 + 0 * y) - 0.5
    edge = smooth(1.0, 0.1, np.abs(v + wob * 0.5))
    d = smooth(0.25, 0.85, s * (0.35 + edge))
    save("trail.png", d * smooth(1.0, 0.7, np.abs(v)))


def swirl():
    n = 256
    x, y = grid(n)
    r = np.hypot(x, y)
    a = np.arctan2(y, x)
    arms = 0.5 + 0.5 * np.cos(3 * (a + 3.2 * r))
    arms = arms ** 3
    detail = sample(S1, (a / np.pi + 1) * 128, r * 200)
    d = arms * smooth(1.0, 0.35, r) * smooth(0.0, 0.18, r) * (0.6 + 0.6 * detail) + smooth(0.25, 0.0, r) * 0.8
    save("swirl.png", smooth(0.05, 0.85, d))


def shards():
    n = 128
    x, y = grid(n)
    cells = []
    for v in range(4):
        d = np.zeros_like(x)
        for _ in range(rng.integers(3, 6)):
            # a long thin diamond, rotated, offset from the centre
            ang = rng.uniform(0, np.pi)
            c, s = np.cos(ang), np.sin(ang)
            o = rng.uniform(-0.25, 0.25, 2)
            u = (x - o[0]) * c + (y - o[1]) * s
            w = -(x - o[0]) * s + (y - o[1]) * c
            L = rng.uniform(0.4, 0.8)
            W = rng.uniform(0.07, 0.15)
            dia = 1 - (np.abs(u) / L + np.abs(w) / W)
            facet = np.where(w > 0, 1.0, 0.65)  # two faces, one in shade
            d = np.maximum(d, smooth(0.0, 0.08, dia) * facet * (0.75 + 0.25 * (1 - np.abs(u) / L)))
        cells.append(d)
    save("shards.png", atlas(cells, 2))


SRC = os.path.join(os.path.dirname(__file__), "..", "meshy", "fx")


def _cells_from_sheet(path, cell=256, pad=0.08):
    """The four shapes of a 2x2 greyscale sheet, each cropped to its bounding box, centred in a
    square with `pad` margin and resized to `cell` px; luminance 0..1 (black = empty)."""
    img = np.asarray(Image.open(path).convert("L")).astype(np.float64) / 255.0
    h, w = img.shape
    out = []
    for qy in range(2):
        for qx in range(2):
            q = img[qy * h // 2:(qy + 1) * h // 2, qx * w // 2:(qx + 1) * w // 2]
            ys, xs = np.nonzero(q > 0.08)
            y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
            side = int(max(y1 - y0, x1 - x0) * (1 + 2 * pad))
            sq = np.zeros((side, side))
            oy, ox = (side - (y1 - y0)) // 2, (side - (x1 - x0)) // 2
            sq[oy:oy + y1 - y0, ox:ox + x1 - x0] = q[y0:y1, x0:x1]
            im = Image.fromarray((sq * 255).astype(np.uint8)).resize((cell, cell), Image.LANCZOS)
            a = np.asarray(im).astype(np.float64) / 255.0
            a = np.clip((a - 0.04) / max(a.max() - 0.04, 1e-6), 0, 1)  # black floor to 0, peak to 1
            out.append(a)
    return out


def painted():
    done = []
    if os.path.exists(os.path.join(SRC, "fire_src.png")):
        save("fire.png", atlas(_cells_from_sheet(os.path.join(SRC, "fire_src.png")), 2))
        done.append("fire")
    if os.path.exists(os.path.join(SRC, "smoke_src.png")):
        cells = _cells_from_sheet(os.path.join(SRC, "smoke_src.png"))
        # R: density (the painted value: dark undersides erode first), G: the same value as light
        save("smoke.png", atlas([np.dstack([c, c, np.zeros_like(c)]) for c in cells], 2), "RGB")
        done.append("smoke")
    if os.path.exists(os.path.join(SRC, "wisp_src.png")):
        save("wisp.png", atlas(_cells_from_sheet(os.path.join(SRC, "wisp_src.png")), 2))
        done.append("wisp")
    if os.path.exists(os.path.join(SRC, "streak_src.png")):
        img = np.asarray(Image.open(os.path.join(SRC, "streak_src.png")).convert("L")).astype(np.float64) / 255.0
        ys, xs = np.nonzero(img > 0.08)
        crop = img[max(0, ys.min() - 4):ys.max() + 5, xs.min():xs.max() + 1]
        im = Image.fromarray((crop * 255).astype(np.uint8)).resize((512, 128), Image.LANCZOS)
        save("streak.png", np.asarray(im).astype(np.float64) / 255.0)
        done.append("streak")
    # ground decals: white shape with alpha = painted value (the decal's modulate colours it),
    # scorch dark soot instead; FxKit.decal_texture prefers these over its procedural ones
    for name, color, gamma, gain in [("rune", (1, 1, 1), 1.0, 1.0), ("frost", (1, 1, 1), 1.6, 0.85),
                                     ("shock", (1, 1, 1), 1.2, 1.0), ("scorch", (0.07, 0.05, 0.035), 1.0, 0.9)]:
        src = os.path.join(SRC, name + "_src.png")
        if not os.path.exists(src):
            continue
        L = np.asarray(Image.open(src).convert("L").resize((512, 512), Image.LANCZOS)).astype(np.float64) / 255.0
        L = np.clip((L - 0.05) / 0.95, 0, 1) ** gamma * gain
        y, x = np.mgrid[0:512, 0:512]
        r = np.hypot(x - 255.5, y - 255.5) / 256.0
        if name == "scorch":  # the painted crater's darker cracks would be holes: fill them in
            blur = np.asarray(Image.fromarray((L * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(14))) / 255.0
            L = np.clip(np.maximum(L, blur * 1.35), 0, 0.92)
        L *= np.clip((1.0 - r) / 0.04, 0, 1)  # nothing reaches the decal box's edge
        rgba = np.dstack([np.full_like(L, c) for c in color] + [L])
        save("decal_%s.png" % name, rgba, "RGBA")
        done.append("decal_" + name)
    return done


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    noise_tex()
    smoke()
    wisp()
    painted()  # fire, and painted smoke / wisp over the drawn ones, when the sources exist
    glint()
    spark()
    trail()
    swirl()
    shards()
