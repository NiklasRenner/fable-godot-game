"""Build an underground cave from a 2D plan.

A cave is a small graph in assets/caves/<name>.json: rooms (position, radius, ceiling height,
floor depth) joined by tunnels (width), plus spawn points, a boss room and torches. Everything
else derives from it:

  python tools/build_cave.py <name> [--plan-only]

  1. meshy/caves/<name>_plan.png      top-down plan + side profile to check by eye (dev only,
  2. meshy/caves/<name>_slices.png    horizontal slices through the carved rock    not shipped)
  3. assets/cave_<name>.glb           the rock with the tunnels hollowed out (marching cubes)
  4. assets/caves/<name>.out.json     derived, world-space data for the game: the hole to cut in
                                      the terrain, the flat zone, spawns, boss, torches

Coordinates in the spec are metres in the cave's own frame: x right, plan-up is -z (into the
hill), y is depth: 0 is the ground surface, rooms are at negative y. `origin` [x, z] and
`surface_y` place the frame in the world; the ground around the entrance is flattened to
surface_y so the tool knows exactly where the surface is. The entrance is a sloped shaft from
the mouth room up to the surface; the terrain mesh gets a hole where the shaft breaks through.

The hill the mouth leads into is terrain, not cave: the tool only describes it (a "mound" zone in
the .out.json that Terrain.height_at raises the heightmap with) and carves the cave to fit under
it. The one piece of cave rock above ground is the arch around the mouth, where the shaft's roof
stands proud of the hillside. The hill formula lives in both this file (hill_height) and
scripts/world/terrain.gd; the .out.json carries probe heights so the selftest catches any drift.
"""
import json
import math
import os
import struct
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAVES_DIR = os.path.join(ROOT, "assets", "caves")
CHECKS_DIR = os.path.join(ROOT, "meshy", "caves")  # check renders: dev only, not shipped
ASSETS_DIR = os.path.join(ROOT, "assets")
VOXEL = 0.5          # metres per voxel (visual mesh)
COLLISION_VOXEL = 1.0  # the collider is a coarser carve of the same field: ~4x fewer triangles
MAX_GRADE = 0.45     # rise/run the character can still walk comfortably (floor_max_angle is 55°)
SHAFT_W = 4.0        # entrance shaft width
SHAFT_H = 4.0        # entrance shaft height
SKIN = 6.0           # rock kept around the outermost room/tunnel (so walls are never thin)
MOUND_R = 18.0       # the hill the entrance leads into: radius of its skirt...
MOUND_H = 10.0       # ...height at its crown (spec "mound": {"radius", "height", "setback"} overrides)
MOUND_SETBACK = 0.65 # ...and how far behind the mouth its centre sits, as a fraction of the radius
CAP = 1.0            # the rock's top sits this far below the terrain surface (it rises flush only at the mouth)
LINTEL = 0.6         # rock kept above the shaft's ceiling: where the hill is lower, this is the mouth's arch
TERRAIN_GRID = 100   # Terrain.GRID / Terrain.SPACING: the hole's edge is the terrain's own triangles, so the
TERRAIN_SPACING = 2.0  # rock under it is shaped to those exact triangles (the .out.json records them; selftest checks)
MIN_COVER = 2.0      # rooms must keep their ceilings at least this far below the surface


# ------------------------------------------------------------------ spec

def load_spec(name):
    with open(os.path.join(CAVES_DIR, name + ".json"), encoding="utf-8") as f:
        spec = json.load(f)
    rooms = rooms_of(spec)
    for t in spec["tunnels"]:
        assert t["a"] in rooms and t["b"] in rooms, "tunnel %s references an unknown room" % t
    for s in spec.get("spawns", []):
        assert s["room"] in rooms, "spawn in unknown room %s" % s["room"]
    assert spec["boss"]["room"] in rooms
    return spec


def rooms_of(spec):
    return {r["id"]: r for r in spec["rooms"]}


def stable_hash(text):
    """Python's str hash is salted per process; the bow of a tunnel must not change between runs."""
    h = 0
    for ch in text:
        h = (h * 31 + ord(ch)) % 1000003
    return h


def entrance_points(spec):
    """(mouth centre, surface point) of the entrance shaft, in the plan frame (x, z)."""
    m = rooms_of(spec)[spec["mouth"]]
    ent = spec.get("entrance", {"dir": [0, 1], "length": 14})
    d = np.array(ent["dir"], float)
    d /= max(1e-6, np.linalg.norm(d))
    return np.array(m["pos"], float), np.array(m["pos"], float) + d * ent["length"]


def shaft_path(spec, n=40):
    """Points (x, z, y) of the entrance shaft floor: from the mouth floor, flat until the room's
    edge, then a straight ramp up to the surface point (which it reaches slightly above ground)."""
    m = rooms_of(spec)[spec["mouth"]]
    a, b = entrance_points(spec)
    L = float(np.linalg.norm(b - a))
    ea = m["r"] / L
    pts = []
    for i in range(n + 1):
        u = i / n
        p = a + (b - a) * u
        v = min(1.0, max(0.0, (u - ea) / max(1e-6, 1.0 - ea)))
        pts.append((p[0], p[1], m.get("y", -4.0) + (0.0 - m.get("y", -4.0)) * v))
    return pts, L


def mound(spec):
    """(centre (x, z), radius, height) of the hill the mouth leads into, in the plan frame: its
    centre sits `setback` radii behind the surface end of the shaft, along the entrance."""
    a, e = entrance_points(spec)
    m = spec.get("mound", {})
    r = float(m.get("radius", MOUND_R))
    back = (a - e) / max(1e-6, np.linalg.norm(a - e))
    return e + back * r * float(m.get("setback", MOUND_SETBACK)), r, float(m.get("height", MOUND_H))


def hill(spec):
    """The mound as the game sees it (world frame): what Terrain.height_at needs."""
    mc, mr, mh = mound(spec)
    a, e = entrance_points(spec)
    back = (a - e) / max(1e-6, np.linalg.norm(a - e))
    c, sn = rotation(spec)
    return {"mode": "mound", "center": list(to_world(spec, mc[0], mc[1])), "radius": mr, "height": mh,
            "seed": float(spec.get("seed", 1)), "back": [back[0] * c - back[1] * sn, back[0] * sn + back[1] * c]}


def hill_height(wx, wz, h):
    """Height the mound adds to the terrain at world (wx, wz). MUST match Terrain.hill_height()
    in scripts/world/terrain.gd. Not a perfect dome: the outline wobbles with the angle, the
    crown sits a little back from the centre, the slope eases out into a long skirt and a few
    broad lumps ride on top."""
    cx, cz = h["center"]
    r, sd = h["radius"], h["seed"]
    ang = np.arctan2(wz - cz, wx - cx)
    r_here = r * (1.0 + 0.12 * np.sin(2 * ang + sd) + 0.07 * np.sin(3 * ang - 1.3 * sd) + 0.04 * np.sin(5 * ang + 0.7 * sd))
    crown = (cx + h["back"][0] * r * 0.15, cz + h["back"][1] * r * 0.15)
    dm = np.clip(np.sqrt((wx - crown[0]) ** 2 + (wz - crown[1]) ** 2) / r_here, 0.0, 1.0)
    bump = (1.0 - dm * dm) ** 1.5 * (1.0 - 0.35 * dm) + 0.35 * dm * (1.0 - dm) ** 2
    lumps = 0.12 * (np.sin(wx * 0.21 + sd) * np.cos(wz * 0.17 - sd) + 0.6 * np.sin(wx * 0.4 - wz * 0.33 + 2 * sd))
    return h["height"] * bump * (1.0 + lumps)


def in_hole_world(spec, wx, wz):
    """Terrain.in_hole for this cave's hole, world frame (numpy ok)."""
    ha, hb, hr = terrain_hole(spec)
    a, b = np.array(to_world(spec, ha[0], ha[1])), np.array(to_world(spec, hb[0], hb[1]))
    seg = b - a
    t = np.clip(((wx - a[0]) * seg[0] + (wz - a[1]) * seg[1]) / max(1e-6, seg @ seg), 0.0, 1.0)
    return np.sqrt((wx - a[0] - seg[0] * t) ** 2 + (wz - a[1] - seg[1] * t) ** 2) <= hr


def terrain_mesh(spec, wx, wz):
    """(height, removed) of the terrain MESH at world (wx, wz): the same 2 m triangles
    Terrain.build() emits (flat ground + the hill, so only valid inside the flat zone) and whether
    that triangle is dropped for the hole. The rock under the hole follows these exactly, so the
    hole's ragged edge meets rock with no lip."""
    sy = spec.get("surface_y", 0.0)
    h = hill(spec)
    half = (TERRAIN_GRID - 1) * TERRAIN_SPACING * 0.5
    fx, fz = (wx + half) / TERRAIN_SPACING, (wz + half) / TERRAIN_SPACING
    ix, iz = np.floor(fx), np.floor(fz)
    u, v = fx - ix, fz - iz
    def vert(dx, dz):
        vx, vz = (ix + dx) * TERRAIN_SPACING - half, (iz + dz) * TERRAIN_SPACING - half
        return sy + hill_height(vx, vz, h), in_hole_world(spec, vx, vz)
    (ha_, ia), (hb_, ib), (hc_, ic), (hd_, idd) = vert(0, 0), vert(1, 0), vert(0, 1), vert(1, 1)
    first = u + v <= 1.0  # triangle (a, b, c), else (b, d, c)
    height = np.where(first, ha_ + u * (hb_ - ha_) + v * (hc_ - ha_), hd_ + (1 - u) * (hc_ - hd_) + (1 - v) * (hb_ - hd_))
    removed = np.where(first, ia | ib | ic, ib | idd | ic)
    return height, removed


def hill_height_plan(spec, x, z):
    """hill_height at plan-frame points (numpy ok)."""
    c, sn = rotation(spec)
    ox, oz = spec["origin"]
    return hill_height(ox + x * c - z * sn, oz + x * sn + z * c, hill(spec))


def bounds(spec, margin):
    xs, zs = [], []
    for r in spec["rooms"]:
        xs += [r["pos"][0] - r["r"] - margin, r["pos"][0] + r["r"] + margin]
        zs += [r["pos"][1] - r["r"] - margin, r["pos"][1] + r["r"] + margin]
    _, hb, hr = terrain_hole(spec)
    xs += [hb[0] - hr - margin, hb[0] + hr + margin]
    zs += [hb[1] - hr - margin, hb[1] + hr + margin]
    return min(xs), max(xs), min(zs), max(zs)


# ------------------------------------------------------------------ geometry

def tunnel_path(spec, t, rooms, n=24):
    """Points (x, z, y) along a tunnel: a quadratic curve bowed sideways by `bow` (fraction of its
    length, seeded so the plan and the mesh agree). The floor ramps between the two rooms' edges
    (inside a room its own flat floor wins), eased at both ends."""
    a, b = rooms[t["a"]], rooms[t["b"]]
    pa, pb = np.array(a["pos"], float), np.array(b["pos"], float)
    ab = pb - pa
    L = float(np.linalg.norm(ab))
    rng = np.random.default_rng(spec.get("seed", 1) * 7919 + (stable_hash(t["a"]) ^ stable_hash(t["b"])) % 1000)
    bow = t.get("bow", spec.get("bow", 0.25)) * L * rng.uniform(-1, 1)
    perp = np.array([-ab[1], ab[0]]) / max(L, 1e-6)
    ctrl = (pa + pb) / 2 + perp * bow
    ya, yb = a.get("y", -4.0), b.get("y", -4.0)
    ea, eb = a["r"] / L, 1.0 - b["r"] / L
    pts = []
    for i in range(n + 1):
        u = i / n
        p = (1 - u) ** 2 * pa + 2 * (1 - u) * u * ctrl + u ** 2 * pb
        v = min(1.0, max(0.0, (u - ea) / max(1e-6, eb - ea)))
        e = v * v * (3 - 2 * v)
        pts.append((p[0], p[1], ya + (yb - ya) * e))
    return pts, L


def check(spec):
    rooms = rooms_of(spec)
    for t in spec["tunnels"]:
        pts, L = tunnel_path(spec, t, rooms)
        rise = abs(rooms[t["b"]].get("y", -4.0) - rooms[t["a"]].get("y", -4.0))
        run = max(1.0, L - rooms[t["a"]]["r"] - rooms[t["b"]]["r"])
        if rise / run > MAX_GRADE:
            print("WARNING: tunnel %s-%s climbs %.1f m over %.1f m (grade %.2f > %.2f): walkable but steep" % (
                t["a"], t["b"], rise, run, rise / run, MAX_GRADE))
    m = rooms[spec["mouth"]]
    _, L = shaft_path(spec)
    rise = 0.0 - m.get("y", -4.0)
    run = max(1.0, L - m["r"])
    if rise / run > MAX_GRADE:
        print("WARNING: entrance shaft climbs %.1f m over %.1f m (grade %.2f): lengthen `entrance.length` or raise the mouth" % (rise, run, rise / run))
    for r in spec["rooms"]:
        top = r.get("y", -4.0) + r.get("h", 4.0)
        if top > -MIN_COVER:
            print("WARNING: room %s ceiling reaches %.1f m, less than %.1f m under the surface" % (r["id"], top, MIN_COVER))


# ------------------------------------------------------------------ 2D plan

def render_plan(spec, path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Circle

    rooms = rooms_of(spec)
    x0, x1, z0, z1 = bounds(spec, 5.0)
    w_in = 10.0
    h_plan = w_in * (z1 - z0) / (x1 - x0)
    h_prof = 3.2
    fig = plt.figure(figsize=(w_in, h_plan + h_prof))
    fig.patch.set_facecolor("#2a2420")
    ax = fig.add_axes([0, h_prof / (h_plan + h_prof), 1, h_plan / (h_plan + h_prof)])
    ax.set_facecolor("#4a4038")
    ys = [r.get("y", -4.0) for r in spec["rooms"]]
    ymin = min(ys + [-1.0])

    def shade(y, base):  # deeper = darker
        k = 1.0 - 0.6 * (y / ymin)
        return tuple(min(1.0, c * k) for c in base)
    for t in spec["tunnels"]:
        pts, _ = tunnel_path(spec, t, rooms)
        for (ax1, az1, ay1), (ax2, az2, ay2) in zip(pts[:-1], pts[1:]):
            ax.plot([ax1, ax2], [az1, az2], color=shade((ay1 + ay2) / 2, (0.62, 0.54, 0.44)),
                    linewidth=t.get("w", 4.0) * 72 / w_in * 0.9, solid_capstyle="round", zorder=1)
    spts, _ = shaft_path(spec)
    for (ax1, az1, ay1), (ax2, az2, ay2) in zip(spts[:-1], spts[1:]):
        ax.plot([ax1, ax2], [az1, az2], color=shade((ay1 + ay2) / 2, (0.62, 0.54, 0.44)),
                linewidth=SHAFT_W * 72 / w_in * 0.9, solid_capstyle="round", zorder=1)
    for r in spec["rooms"]:
        boss = r["id"] == spec["boss"]["room"]
        ax.add_patch(Circle(r["pos"], r["r"], color=shade(r.get("y", -4.0), (0.78, 0.66, 0.52) if boss else (0.68, 0.60, 0.50)), zorder=2))
        ax.text(r["pos"][0], r["pos"][1] + r["r"] + 0.6, "%s  (r%.0f h%.0f y%.0f)" % (r["id"], r["r"], r.get("h", 4), r.get("y", -4.0)),
                ha="center", fontsize=8, color="#eee6d8", zorder=5)
    rng = np.random.default_rng(1)
    for s in spec.get("spawns", []):
        r = rooms[s["room"]]
        for i in range(s["n"]):
            a, d = rng.uniform(0, 2 * math.pi), rng.uniform(0, r["r"] * 0.6)
            ax.plot(r["pos"][0] + math.cos(a) * d, r["pos"][1] + math.sin(a) * d, "o", color="#d84a3a", markersize=7, zorder=4)
    br = rooms[spec["boss"]["room"]]
    ax.plot(br["pos"][0], br["pos"][1], "*", color="#ffd34a", markersize=22, zorder=4)
    for tx, tz in spec.get("torches", []):
        ax.plot(tx, tz, "^", color="#ffa030", markersize=9, zorder=4)
    mc, mr, mh = mound(spec)
    ax.add_patch(Circle(mc, mr * 1.1, color="#5c6b3e", alpha=0.6, zorder=0.5))
    ax.text(mc[0], mc[1] - mr * 1.1 - 0.8, "the hill (terrain): ~r%.0f, %.0f m high" % (mr * 1.1, mh), ha="center", fontsize=8, color="#c8d8a0", zorder=5)
    hole_a, hole_b, hole_r = terrain_hole(spec)
    ax.plot([hole_a[0], hole_b[0]], [hole_a[1], hole_b[1]], color="#9fd3ff", linewidth=hole_r * 2 * 72 / w_in * 0.9,
            solid_capstyle="round", alpha=0.25, zorder=3)
    ax.annotate("entrance (surface hole in blue)", xy=hole_b, xytext=(hole_b[0], hole_b[1] + 3.5),
                color="#9fd3ff", ha="center", fontsize=9, arrowprops=dict(arrowstyle="->", color="#9fd3ff"), zorder=5)
    ax.plot([x0 + 2, x0 + 12], [z0 + 2, z0 + 2], color="#eee6d8", linewidth=2)
    ax.text(x0 + 7, z0 + 2.7, "10 m", ha="center", color="#eee6d8", fontsize=8)
    ax.set_autoscale_on(False)
    ax.set_xlim(x0, x1)
    ax.set_ylim(z1, z0)
    ax.set_xticks([])
    ax.set_yticks([])
    ax.text(0.5, 0.985, "%s  —  %d rooms, %d tunnels, %d dwellers + boss, down to %.0f m" % (
        spec["name"], len(spec["rooms"]), len(spec["tunnels"]), sum(s["n"] for s in spec.get("spawns", [])), ymin),
        transform=ax.transAxes, ha="center", va="top", color="#eee6d8", fontsize=11)

    # Side profile: floor depth along the walk from the entrance (shortest path through the graph).
    px = fig.add_axes([0.08, 0.1 * h_prof / (h_plan + h_prof), 0.9, 0.75 * h_prof / (h_plan + h_prof)])
    px.set_facecolor("#2a2420")
    dist = {spec["mouth"]: 0.0}
    frontier = [spec["mouth"]]
    adj = {}
    for t in spec["tunnels"]:
        adj.setdefault(t["a"], []).append((t["b"], t))
        adj.setdefault(t["b"], []).append((t["a"], t))
    while frontier:
        cur = frontier.pop(0)
        for nxt, t in adj.get(cur, []):
            _, L = tunnel_path(spec, t, rooms)
            if nxt not in dist or dist[cur] + L < dist[nxt]:
                dist[nxt] = dist[cur] + L
                frontier.append(nxt)
    _, shaft_L = shaft_path(spec)
    px.axhline(0, color="#9fd3ff", linewidth=1, linestyle="--")
    px.text(-shaft_L, 0.5, "surface", color="#9fd3ff", fontsize=8)
    px.plot([-shaft_L, -rooms[spec["mouth"]]["r"]], [0.6, rooms[spec["mouth"]].get("y", -4.0)], color="#c8b49a", linewidth=3)
    for t in spec["tunnels"]:
        a, b = t["a"], t["b"]
        pts, L = tunnel_path(spec, t, rooms)
        if dist[b] < dist[a]:
            a, b = b, a
            pts = pts[::-1]
        xs_ = [dist[a] + L * i / (len(pts) - 1) for i in range(len(pts))]
        px.plot(xs_, [p[2] for p in pts], color="#c8b49a", linewidth=3)
    for rid, d in dist.items():
        r = rooms[rid]
        px.plot([d - r["r"], d + r["r"]], [r.get("y", -4.0)] * 2, color="#e0c9a6", linewidth=6, solid_capstyle="butt")
        px.plot([d - r["r"], d + r["r"]], [r.get("y", -4.0) + r.get("h", 4.0)] * 2, color="#8c7a66", linewidth=2)
        px.text(d, r.get("y", -4.0) + r.get("h", 4.0) + 0.4, rid, ha="center", color="#eee6d8", fontsize=8)
    px.set_xlabel("distance walked from the entrance (m)", color="#eee6d8", fontsize=8)
    px.set_ylabel("depth (m)", color="#eee6d8", fontsize=8)
    px.tick_params(colors="#eee6d8", labelsize=7)
    for sp in px.spines.values():
        sp.set_color("#6a5f52")
    fig.savefig(path, dpi=110)
    plt.close(fig)
    print("plan", path)


# ------------------------------------------------------------------ voxels -> mesh

def mouth_path(spec, n=40):
    """The shaft floor continued past its surface end out to the hill's skirt: (x, z, y)."""
    pts, L = shaft_path(spec, n)
    a, e = entrance_points(spec)
    d = (e - a) / max(1e-6, L)
    mc, mr, _ = mound(spec)
    step = L / n
    k = 1
    while k * step < mr * 1.4:
        q = e + d * (k * step)
        pts.append((q[0], q[1], 0.2 * min(1.0, k * step / 4.0)))  # rises gently to meet the hill's skirt
        k += 1
    return pts


def terrain_hole(spec):
    """The opening in the terrain: a stadium along the shaft where the hillside cuts through the
    shaft's air — from where the hill first dips below the roof, out to where the ground is level
    with the floor again. Returns (a, b, radius) in the plan frame."""
    pts = mouth_path(spec)
    inside = [y + 0.05 < hill_height_plan(spec, x, z) < y + SHAFT_H + 0.3 for (x, z, y) in pts]
    first = inside.index(True)
    last = len(inside) - 1 - inside[::-1].index(True)
    return np.array(pts[first][:2]), np.array(pts[last][:2]), SHAFT_W / 2 + 0.2


def carve(spec, voxel=VOXEL):
    """Signed field over a voxel box: negative = rock, positive = air."""
    rooms = rooms_of(spec)
    x0, x1, z0, z1 = bounds(spec, SKIN)
    depth = min(r.get("y", -4.0) for r in spec["rooms"])
    _, _, mh = mound(spec)
    y0, y1 = depth - 3.0, max(SHAFT_H + LINTEL, mh) + 1.5  # the rock under the hole's edge follows the hillside up
    nx, ny, nz = (int((x1 - x0) / voxel), int((y1 - y0) / voxel), int((z1 - z0) / voxel))
    xs = x0 + (np.arange(nx) + 0.5) * voxel
    ys = y0 + (np.arange(ny) + 0.5) * voxel
    zs = z0 + (np.arange(nz) + 0.5) * voxel
    X, Y, Z = np.meshgrid(xs, ys, zs, indexing="ij")
    col_x, col_z = X[:, 0, :], Z[:, 0, :]

    # Rock: everything under the terrain (CAP below it), but only within SKIN of the cave (no
    # point meshing the rest). Around the hole the hidden rock rises almost to the surface, so the
    # terrain's ragged hole edge never shows a gap; around the shaft a shell is always kept LINTEL
    # above the roof — hidden under the hill, except at the mouth where it is the arch you see.
    near = np.full(X.shape, 1e9)
    def dist_xz(px, pz):
        return np.sqrt((X - px) ** 2 + (Z - pz) ** 2)
    for r in spec["rooms"]:
        near = np.minimum(near, dist_xz(*r["pos"]) - r["r"])
    for t in spec["tunnels"]:
        pts, _ = tunnel_path(spec, t, rooms, n=16)
        for (px, pz, _) in pts:
            near = np.minimum(near, dist_xz(px, pz) - t.get("w", 4.0) / 2)
    mpts = mouth_path(spec, n=16)
    for (px, pz, _) in mpts:
        near = np.minimum(near, dist_xz(px, pz) - SHAFT_W / 2)
    # The ground above each column, as the terrain mesh will actually have it; under the
    # triangles the terrain drops for the hole the rock rises to meet their edges exactly.
    c_, sn_ = rotation(spec)
    ox, oz = spec["origin"]
    terrain, removed = terrain_mesh(spec, ox + col_x * c_ - col_z * sn_, oz + col_x * sn_ + col_z * c_)
    terrain = terrain - spec.get("surface_y", 0.0)  # plan frame: y = 0 at the flat ground
    # ...and for a metre or two around them it stays just under the intact terrain, so the step
    # down to CAP (smeared over a voxel by marching cubes) happens out of sight.
    from scipy.ndimage import binary_dilation
    band = binary_dilation(removed, iterations=int(math.ceil(1.5 / voxel)))
    top = np.where(removed, terrain - 0.02, np.where(band, terrain - 0.08, terrain - CAP))
    spts, _ = shaft_path(spec, n=40)
    sx, sz, sy = (np.array([p[i] for p in spts]) for i in range(3))
    d2 = (col_x[..., None] - sx) ** 2 + (col_z[..., None] - sz) ** 2
    nearest = np.argmin(d2, axis=-1)
    shell = (np.sqrt(np.min(d2, axis=-1)) < SHAFT_W / 2 + 1.3) & (nearest < len(spts) - 1)  # ends at the mouth
    top = np.where(shell, np.maximum(top, sy[nearest] + SHAFT_H + LINTEL), top)
    rock = np.maximum(Y - top[:, None, :], near - SKIN)  # negative inside

    # Air: rooms are flat-floored domes, tunnels and the shaft are swept capsules.
    air = np.full(X.shape, 1e9)
    def capsule(px, pz, radius, height, floor_y):
        yy = np.clip(Y, floor_y, floor_y + max(0.0, height - radius))
        d = np.sqrt((X - px) ** 2 + (Y - yy) ** 2 + (Z - pz) ** 2) - radius
        return np.maximum(d, floor_y - Y)  # nothing below this floor
    for r in spec["rooms"]:
        air = np.minimum(air, capsule(r["pos"][0], r["pos"][1], r["r"], r.get("h", 4.0), r.get("y", -4.0)))
    for t in spec["tunnels"]:
        _, L = tunnel_path(spec, t, rooms, n=2)
        pts, _ = tunnel_path(spec, t, rooms, n=max(2, int(L / (voxel * 1.2))))
        for (px, pz, py) in pts:
            air = np.minimum(air, capsule(px, pz, t.get("w", 4.0) / 2, t.get("h", 3.5), py))
    for (px, pz, py) in mouth_path(spec, n=60):
        air = np.minimum(air, capsule(px, pz, SHAFT_W / 2, SHAFT_H, py))
    # Rough walls and ceilings, smooth floors: the noise fades out within a metre of the floor
    # (floor height at each column = floor of the nearest room/tunnel sample).
    rough = spec.get("roughness", 0.35)
    if rough > 0:
        sd = spec.get("seed", 1)
        samples = [(r["pos"][0], r["pos"][1], r.get("y", -4.0)) for r in spec["rooms"]]
        for t in spec["tunnels"]:
            samples += tunnel_path(spec, t, rooms)[0]
        samples += shaft_path(spec)[0]
        sx = np.array([p[0] for p in samples])
        sz = np.array([p[1] for p in samples])
        sy = np.array([p[2] for p in samples])
        d2 = (col_x[..., None] - sx) ** 2 + (col_z[..., None] - sz) ** 2
        floor_map = sy[np.argmin(d2, axis=-1)]  # (nx, nz)
        above = Y - floor_map[:, None, :]
        weight = np.clip((above - 0.4) / 1.2, 0.0, 1.0)
        noise = np.sin(X * 1.7 + sd) * np.sin(Y * 2.1 + Z * 0.6) + 0.6 * np.sin(Z * 1.3 - X * 0.8 + sd) * np.cos(Y * 1.1)
        air = air + rough * weight * noise
    field = np.maximum(rock, -air)
    return field, (x0, y0, z0)


def mesh_from_field(field, origin, voxel=VOXEL):
    from skimage import measure
    verts, faces, normals, _ = measure.marching_cubes(field, level=0.0, spacing=(voxel, voxel, voxel))
    verts = verts + np.array(origin) + voxel * 0.5  # field samples sit at voxel centres
    # skimage's faces are counter-clockwise seen from the air side, which is glTF's front-face
    # convention (Godot's importer handles the rest); its vertex normals point into the rock, so flip those.
    return verts.astype(np.float32), faces.astype(np.uint32), (-normals).astype(np.float32)


def flat_shade(verts, faces):
    """Unwelds the mesh so every triangle has its own three vertices and one face normal: the
    same low-poly look as the terrain's 2 m facets (three times the vertices, same triangles)."""
    tri = verts[faces]  # (n, 3, 3)
    n = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
    n /= np.maximum(1e-9, np.linalg.norm(n, axis=1))[:, None]
    normals = np.repeat(n, 3, axis=0).astype(np.float32)
    return tri.reshape(-1, 3).astype(np.float32), np.arange(len(faces) * 3, dtype=np.uint32).reshape(-1, 3), normals


ROCK_COLOR = (0.30, 0.27, 0.25)
GRASS_COLOR = (0.13, 0.34, 0.10)


def vertex_colors(verts, normals):
    """Rock everywhere, grass on gentle slopes above the cap (the hill and the mouth's rim);
    cave interiors are below the cap so they stay rock."""
    gentle = np.clip((normals[:, 1] - 0.45) / 0.3, 0.0, 1.0)
    above = np.clip((verts[:, 1] + CAP) / 0.8, 0.0, 1.0)
    k = (gentle * above)[:, None]
    return (np.array(ROCK_COLOR) * (1 - k) + np.array(GRASS_COLOR) * k).astype(np.float32)


def write_glb(path, meshes, color=(1.0, 1.0, 1.0)):
    """Minimal glTF 2.0 binary: `meshes` is [(node_name, verts, faces, normals, colors)], one node
    each, one shared white material multiplied by the vertex colours. Y up; Godot reads it directly."""
    def pad(b):
        return b + b"\0" * ((4 - len(b) % 4) % 4)
    bin_chunk = b""
    views, accessors, gl_meshes, nodes = [], [], [], []
    for name, verts, faces, normals, colors in meshes:
        verts = np.ascontiguousarray(verts, dtype=np.float32)
        normals = np.ascontiguousarray(normals, dtype=np.float32)
        colors = np.ascontiguousarray(colors, dtype=np.float32)
        idx = np.ascontiguousarray(faces.reshape(-1), dtype=np.uint32)
        base = len(accessors)
        for data, target, ctype, atype, extra in (
                (verts, 34962, 5126, "VEC3", {"min": verts.min(axis=0).tolist(), "max": verts.max(axis=0).tolist()}),
                (normals, 34962, 5126, "VEC3", {}),
                (colors, 34962, 5126, "VEC3", {}),
                (idx, 34963, 5125, "SCALAR", {})):
            blob = pad(data.tobytes())
            views.append({"buffer": 0, "byteOffset": len(bin_chunk), "byteLength": len(blob), "target": target})
            accessors.append({"bufferView": len(views) - 1, "componentType": ctype, "count": len(data), "type": atype, **extra})
            bin_chunk += blob
        gl_meshes.append({"primitives": [{"attributes": {"POSITION": base, "NORMAL": base + 1, "COLOR_0": base + 2}, "indices": base + 3, "material": 0}]})
        nodes.append({"mesh": len(gl_meshes) - 1, "name": name})
        print("mesh", name, "%d verts %d tris" % (len(verts), len(faces)))
    gltf = {
        "asset": {"version": "2.0", "generator": "thornhill build_cave.py"},
        "scene": 0, "scenes": [{"nodes": list(range(len(nodes)))}], "nodes": nodes, "meshes": gl_meshes,
        "materials": [{"name": "cave_rock", "pbrMetallicRoughness": {"baseColorFactor": [*color, 1.0], "metallicFactor": 0.0, "roughnessFactor": 0.95}}],
        "buffers": [{"byteLength": len(bin_chunk)}],
        "bufferViews": views, "accessors": accessors,
    }
    js = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    js += b" " * ((4 - len(js) % 4) % 4)
    total = 12 + 8 + len(js) + 8 + len(bin_chunk)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(js), 0x4E4F534A))
        f.write(js)
        f.write(struct.pack("<II", len(bin_chunk), 0x004E4942))
        f.write(bin_chunk)
    print("wrote", path)


def render_slices(field, origin, path, spec=None):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    depth = origin[1] + 3.0
    heights = [depth + 0.5, depth + 2.5, -3.0, -0.5]
    fig, axes = plt.subplots(1, len(heights) + 1, figsize=(4 * (len(heights) + 1), 4.5))
    # A vertical cut along the entrance axis (x = 0 in the plan frame): shows the shaft and the hill.
    xi = min(field.shape[0] - 1, max(0, int((0.0 - origin[0]) / VOXEL)))
    axes[0].imshow((field[xi, :, :] > 0), cmap="gray", origin="lower", aspect="equal",
                   extent=(origin[2], origin[2] + field.shape[2] * VOXEL, origin[1], origin[1] + field.shape[1] * VOXEL))
    axes[0].axhline(0, color="#4a90d9", linewidth=1, linestyle="--")
    if spec is not None:
        zz = np.linspace(origin[2], origin[2] + field.shape[2] * VOXEL, 200)
        axes[0].plot(zz, hill_height_plan(spec, np.zeros_like(zz), zz), color="#7fc46a", linewidth=1.5)
    axes[0].set_title("side cut along the entrance (x = 0); green = terrain")
    for ax, y in zip(axes[1:], heights):
        yi = min(field.shape[1] - 1, max(0, int((y - origin[1]) / VOXEL)))
        ax.imshow((field[:, yi, :] > 0).T, cmap="gray", origin="upper",
                  extent=(origin[0], origin[0] + field.shape[0] * VOXEL, origin[2] + field.shape[2] * VOXEL, origin[2]))
        ax.set_title("y = %.1f m (white = air)" % y)
        ax.set_xticks([])
        ax.set_yticks([])
    fig.tight_layout()
    fig.savefig(path, dpi=90)
    plt.close(fig)
    print("slices", path)


# ------------------------------------------------------------------ placement

def rotation(spec):
    """Rotation (cos, sin) turning the plan's entrance direction (0, +1) into the world direction
    `facing` the entrance opens towards: x' = x c - z s, z' = x s + z c."""
    f = np.array(spec.get("facing", [0, 1]), float)
    f /= max(1e-6, np.linalg.norm(f))
    # R(theta) * (0, 1) = (-sin, cos) = (fx, fz)
    return float(f[1]), float(-f[0])


def to_world(spec, x, z, y=None):
    c, s = rotation(spec)
    ox, oz = spec["origin"]
    wx, wz = ox + x * c - z * s, oz + x * s + z * c
    return (wx, wz) if y is None else (wx, spec.get("surface_y", 0.0) + y, wz)


# ------------------------------------------------------------------ game data

def write_out(spec, path):
    """World-space data for scripts/world/cave.gd. Plan (x, z) -> world (ox + x, oz + z); depth y -> surface_y + y."""
    sy = spec.get("surface_y", 0.0)
    rooms = rooms_of(spec)
    rng = np.random.default_rng(spec.get("seed", 1))
    spawns = []
    for s in spec.get("spawns", []):
        r = rooms[s["room"]]
        for i in range(s["n"]):
            a, d = rng.uniform(0, 2 * math.pi), rng.uniform(0, r["r"] * 0.55)
            spawns.append({"kind": s["kind"], "pos": list(to_world(spec, r["pos"][0] + math.cos(a) * d, r["pos"][1] + math.sin(a) * d, r.get("y", -4.0) + 0.5)),
                           "wander": max(0.5, r["r"] - 1.5 - d)})
    br = rooms[spec["boss"]["room"]]
    spawns.append({"kind": spec["boss"]["kind"], "pos": list(to_world(spec, br["pos"][0], br["pos"][1], br.get("y", -4.0) + 0.5)), "boss": True, "wander": max(0.5, br["r"] - 2.0)})
    samples = [(r["pos"][0], r["pos"][1], r.get("y", -4.0)) for r in spec["rooms"]]
    for t in spec["tunnels"]:
        samples += tunnel_path(spec, t, rooms)[0]
    samples += shaft_path(spec)[0]
    torches = []
    for tx, tz in spec.get("torches", []):
        floor = min(samples, key=lambda p: math.hypot(p[0] - tx, p[1] - tz))[2]
        torches.append(list(to_world(spec, tx, tz, floor + 1.6)))
    ha, hb, hr = terrain_hole(spec)
    x0, x1, z0, z1 = bounds(spec, SKIN)
    # Terrain zones: flat right around the opening (the rim must meet the shaft exactly), and a
    # "floor" over each room and tunnel so hills may rise above the cave but never dip into it.
    mc, mr, _ = mound(spec)
    h = hill(spec)
    zones = [{"mode": "flat", "center": h["center"], "radius": mr * 1.4 + 1.0, "blend": 12.0, "height": sy, "reserve": False}, h,
             {"mode": "reserve", "center": list(to_world(spec, hb[0], hb[1])), "radius": hr + 5.0, "blend": 0.0, "height": 0.0}]
    # Floor zones reach 3.5 m past the rock so the terrain's 2 m triangles sag only beyond it.
    for r in spec["rooms"]:
        zones.append({"mode": "floor", "center": list(to_world(spec, r["pos"][0], r["pos"][1])), "radius": r["r"] + SKIN + 3.5, "blend": 8.0, "height": sy})
    for t in spec["tunnels"]:
        for (px, pz, _) in tunnel_path(spec, t, rooms, n=6)[0]:
            zones.append({"mode": "floor", "center": list(to_world(spec, px, pz)), "radius": t.get("w", 4.0) / 2 + SKIN + 3.5, "blend": 8.0, "height": sy})
    for (px, pz, _) in shaft_path(spec, n=4)[0]:
        zones.append({"mode": "floor", "center": list(to_world(spec, px, pz)), "radius": SHAFT_W / 2 + SKIN + 3.5, "blend": 8.0, "height": sy})
    # Probe heights: the selftest checks Terrain.height_at against these, so the two copies of
    # the hill formula cannot drift apart unnoticed.
    prng = np.random.default_rng(5)
    probes = []
    for i in range(12):
        ang, d = prng.uniform(0, 2 * math.pi), prng.uniform(0, mr * 1.2)
        wx, wz = h["center"][0] + math.cos(ang) * d, h["center"][1] + math.sin(ang) * d
        probes.append([wx, wz, sy + float(hill_height(wx, wz, h))])
    out = {
        "name": spec["name"], "mesh": "res://assets/cave_%s.glb" % spec["name"],
        "probes": probes, "terrain": {"grid": TERRAIN_GRID, "spacing": TERRAIN_SPACING},
        "origin": [spec["origin"][0], sy, spec["origin"][1]],
        "zones": zones,
        "hole": {"a": list(to_world(spec, ha[0], ha[1])), "b": list(to_world(spec, hb[0], hb[1])), "radius": hr},
        "spawns": spawns, "torches": torches,
        "boss_room": list(to_world(spec, br["pos"][0], br["pos"][1], br.get("y", -4.0))),
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1)
    print("game data", path)


def build(name, plan_only=False):
    spec = load_spec(name)
    os.makedirs(CAVES_DIR, exist_ok=True)
    check(spec)
    os.makedirs(CHECKS_DIR, exist_ok=True)
    render_plan(spec, os.path.join(CHECKS_DIR, name + "_plan.png"))
    if plan_only:
        return
    field, origin = carve(spec)
    render_slices(field, origin, os.path.join(CHECKS_DIR, name + "_slices.png"), spec)
    c, sn = rotation(spec)
    meshes = []
    for node_name, fld, org, vox in (("cave", field, origin, VOXEL), ("cave_collision",) + carve(spec, COLLISION_VOXEL) + (COLLISION_VOXEL,)):
        verts, faces, normals = mesh_from_field(fld, org, vox)
        if node_name == "cave":
            verts, faces, normals = flat_shade(verts, faces)  # faceted like the terrain, not smooth
        colors = vertex_colors(verts, normals)
        for arr in (verts, normals):
            x, z = arr[:, 0].copy(), arr[:, 2].copy()
            arr[:, 0], arr[:, 2] = x * c - z * sn, x * sn + z * c
        meshes.append((node_name, verts, faces, normals, colors))
    write_glb(os.path.join(ASSETS_DIR, "cave_%s.glb" % name), meshes)
    write_out(spec, os.path.join(CAVES_DIR, name + ".out.json"))


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    build(args[0] if args else "warren", plan_only="--plan-only" in sys.argv)
