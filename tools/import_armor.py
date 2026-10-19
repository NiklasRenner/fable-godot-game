"""Modelled armour: a set's helm, pauldron, gauntlet and boot, each its own Meshy model (pulled out
of the set's concept image with image-to-image, then image-to-3d), fitted onto the hero, skinned
to its skeleton and mirrored (left and right match); plus the set's chest and legs skin.

    python tools/import_armor.py <set> --helm h.glb --shoulder s.glb --glove g.glb --boot b.glb
                                 --fit meshy/armor/<set>_rig.glb [--skin skin.glb]
                                 [--match concept.png [--match-mid yes]] [--texture 512] [--brighten 1.1]
        -> assets/armor_<set>.glb        nodes armor_head, armor_shoulders, armor_hands, armor_feet
        -> assets/armor_<set>_cover.png  which body texels each piece hides (a bit per slot)
        -> assets/hero_skin_<set>.png    with --skin: the chest/legs skin (a Meshy retexture of the
                                         hero, styled on the set's base layer), bare skin let through

Fitting (where each piece sits, and how big): --fit is a rigged Meshy model of the hero wearing the
whole set (image-to-3d of the concept). It is carried onto the hero's bind pose and cut roughly
into slots; each piece is matched onto its slot by a similarity ICP (every 90-degree turn tried,
then rotation, uniform scale and offset refined; a turn that sinks the piece into the body scores
worse). Gloves and boots are then snugged onto the hero's own hand and lower leg, pauldrons rested
on the shoulder. The glove and boot images show a right one, the pauldron a left one.

Skinning: helm rigid on Head, pauldrons half collarbone, half upper arm; gauntlets and boots take
their weights from the nearest body surface, gauntlets also the body's fist shapes, so they close
around a weapon.

What a piece hides of the body (Outfit cuts those texels out when it is worn): a helm, rigid on the
head, only what sticks out through it (the face behind a visor stays); gauntlets the whole hand
(fingers bend inside them); boots the leg inside them that can't be seen from outside.
"""
import os
import sys

import numpy as np
from PIL import Image
from scipy.spatial import cKDTree
from scipy.spatial.transform import Rotation

sys.path.insert(0, os.path.dirname(__file__))
from import_meshy import (BOOT_BELOW, accessor, cmd_fleshmask, cmd_skin, flesh_amount, image_of,  # noqa: E402
                          make_matte, png_bytes, prune_unused, read_glb, replace_views, treat, write_glb)

SLOTS = ["head", "shoulders", "chest", "hands", "legs", "feet"]  # bit i of the cover mask = SLOTS[i]
SLOT_REGION = {"head": 0, "chest": 1, "legs": 2, "feet": 3, "hands": 4}  # body regions (hero_regions.png)
KINDS = {"helm": "head", "shoulder": "shoulders", "glove": "hands", "boot": "feet"}
FIT_SIDE = {"helm": 0, "shoulder": +1, "glove": -1, "boot": -1}  # +1 the hero's left (+X), -1 right
INFLATE = 0.004        # pieces pushed out along their normals (m): no z-fighting with the body
SINK = 0.05            # fit score penalty (m) for a piece lying wholly inside the body
SHELL = {"glove": 0.010, "boot": 0.014}  # gloves and boots hug the body this far out (m)
# a pauldron stands as its image does, upright, its top leaning in over the shoulder a little:
# the full-set model's shoulder is a rough target, and a fit to it alone can lean the plate out,
# its neck-side rim up by the ears (the left pauldron; +X is out)
UPRIGHT = {"shoulder": (np.array([-np.sin(np.radians(8)), np.cos(np.radians(8)), 0.0]), 10.0)}
# rough slot cuts of the full-set model (fit targets only)
HELM_FROM = 0.85       # helm: from this far up the neck (neck joint 0, Head joint 1)
GAUNTLET_FROM = 0.15   # gauntlets: from this far down the forearm (elbow 0, wrist 1)
PAULDRON_DROP = 0.16   # pauldrons: armour above this far below the shoulder joint (m) ...
PAULDRON_OUT = 0.10    # ... and further out than this from the shoulder joint, sideways (m)
SMALL_PART = 600       # separate bits of the full-set model smaller than this go to one slot whole
FLESH_DROP = 0.3       # a triangle this skin-like (share of its samples) is bare skin ...
FLESH_EDGE = 0.12      # ... and so is one next to bare skin that is this skin-like
# what each piece hides of the body
COVER = {"head": "poke", "hands": "whole", "feet": "unseen"}
COVER_REACH = 0.14     # armour this far out along a body normal encloses it (m)
COVER_TIGHT = 0.03     # body this close under armour can show through it (m) ...
COVER_POKE = 0.06      # ... as can body sticking out through it, by up to this much
SEEN = 0.02            # a covered body point that sees this much of the outside stays


# ------------------------------------------------------------------ meshes


def _bind(js, binary):
    """bone name -> 4x4 bind matrix (joint frame in mesh space)."""
    skin = js["skins"][0]
    names = [js["nodes"][j]["name"] for j in skin["joints"]]
    ibm = accessor(js, binary, skin["inverseBindMatrices"]).reshape(-1, 4, 4)
    return names, {n: np.linalg.inv(m.T) for n, m in zip(names, ibm)}


def _mesh(js, binary):
    pr = js["meshes"][0]["primitives"][0]
    get = lambda k: np.array(accessor(js, binary, pr["attributes"][k]), np.float64)
    names = js["meshes"][0].get("extras", {}).get("targetNames", [])
    morphs = {n: np.array(accessor(js, binary, t["POSITION"]), np.float64) for n, t in zip(names, pr.get("targets", []))}
    return {"pos": get("POSITION"), "nrm": get("NORMAL"), "uv": get("TEXCOORD_0"), "morphs": morphs,
            "joints": np.array(accessor(js, binary, pr["attributes"]["JOINTS_0"]), np.int64),
            "weights": get("WEIGHTS_0"), "tris": np.array(accessor(js, binary, pr["indices"]), np.int64).reshape(-1, 3)}


def load_piece(path):
    """A static Meshy model: positions (node transforms applied), normals, UVs, triangles, texture."""
    js, binary = read_glb(path)
    nodes = js["nodes"]
    parent = {c: i for i, n in enumerate(nodes) for c in n.get("children", [])}

    def world(i):
        n = nodes[i]
        if "matrix" in n:
            m = np.array(n["matrix"], np.float64).reshape(4, 4).T
        else:
            m = np.eye(4)
            m[:3, :3] = Rotation.from_quat(n.get("rotation", [0, 0, 0, 1])).as_matrix() * np.array(n.get("scale", [1, 1, 1]))
            m[:3, 3] = n.get("translation", [0, 0, 0])
        return world(parent[i]) @ m if i in parent else m

    P, N, U, T = [], [], [], []
    for i, n in enumerate(nodes):
        if "mesh" not in n:
            continue
        M = world(i)
        for pr in js["meshes"][n["mesh"]]["primitives"]:
            pos = np.array(accessor(js, binary, pr["attributes"]["POSITION"]), np.float64)
            nrm = np.array(accessor(js, binary, pr["attributes"]["NORMAL"]), np.float64)
            T.append(np.array(accessor(js, binary, pr["indices"]), np.int64).reshape(-1, 3) + sum(len(p) for p in P))
            P.append(pos @ M[:3, :3].T + M[:3, 3])
            N.append(nrm @ np.linalg.inv(M[:3, :3]))
            U.append(np.array(accessor(js, binary, pr["attributes"]["TEXCOORD_0"]), np.float64))
    N = np.concatenate(N)
    return {"pos": np.concatenate(P), "nrm": N / np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-9),
            "uv": np.concatenate(U), "tris": np.concatenate(T), "texture": image_of(js, binary, js["images"][0])}


def drop_stand(piece, kind):
    """A boot image often stands on a little plinth: drop it. A plinth is a separate flat part at
    the very bottom, wider than the boot standing on it. Everything else stays: a smart-topology
    boot comes in many separate parts (plates, straps, rivets), the sole among them."""
    from scipy.sparse import coo_matrix
    from scipy.sparse.csgraph import connected_components
    T, P = piece["tris"], piece["pos"]
    _, weld = np.unique(np.round(P, 5), axis=0, return_inverse=True)
    W = weld.ravel()[T]
    n = W.max() + 1
    _, lab = connected_components(coo_matrix((np.ones(len(T) * 2), (np.r_[W[:, 0], W[:, 1]], np.r_[W[:, 1], W[:, 2]])),
                                             shape=(n, n)), directed=False)
    part = lab[W[:, 0]]
    lo, hi = P[T].min((0, 1)), P[T].max((0, 1))
    height = hi[1] - lo[1]

    def footprint(m):
        q = P[T[m]].reshape(-1, 3)
        return np.ptp(q[:, 0]) * np.ptp(q[:, 2])

    keep = np.ones(len(T), bool)
    for k in np.unique(part):
        m = part == k
        q = P[T[m]].reshape(-1, 3)
        flat = np.ptp(q[:, 1]) < 0.12 * height and q[:, 1].max() < lo[1] + 0.15 * height
        if flat and (~m).any() and footprint(m) > 1.2 * footprint(~m & keep):
            keep &= ~m
    if (~keep).any():
        print("  %s: dropped a stand (%d triangles)" % (kind, (~keep).sum()))
    piece["tris"] = T[keep]
    return piece


def surface_points(pos, tris, n=4000, seed=0):
    rng = np.random.default_rng(seed)
    a = np.linalg.norm(np.cross(pos[tris[:, 1]] - pos[tris[:, 0]], pos[tris[:, 2]] - pos[tris[:, 0]]), axis=1)
    t = rng.choice(len(tris), n, p=a / a.sum())
    r1, r2 = rng.random(n), rng.random(n)
    s = np.sqrt(r1)
    w = np.stack([1 - s, s * (1 - r2), s * r2], 1)
    return np.einsum("nc,ncd->nd", w, pos[tris[t]])


def surface_samples(mesh, n_bones, per_edge=4):
    """Points spread over a mesh's triangles, with their interpolated position, normal, skin weights
    (dense, one column per bone) and UV."""
    bary = np.array([(i, j, per_edge - i - j) for i in range(per_edge + 1) for j in range(per_edge + 1 - i)], np.float64) / per_edge
    T = mesh["tris"]
    dense = np.zeros((len(mesh["pos"]), n_bones))
    for k in range(mesh["joints"].shape[1]):
        np.add.at(dense, (np.arange(len(mesh["pos"])), mesh["joints"][:, k]), mesh["weights"][:, k])
    lerp = lambda a: np.einsum("bc,tc...->tb...", bary, a[T]).reshape(-1, *a.shape[1:])
    nrm = lerp(mesh["nrm"])
    return lerp(mesh["pos"]), nrm / np.maximum(np.linalg.norm(nrm, axis=1, keepdims=True), 1e-9), lerp(dense), lerp(mesh["uv"])


# ------------------------------------------------------------------ fitting


def retarget(arm, a_names, a_bind, h_bind):
    """Armour vertices and normals carried from the armour rig's bind pose onto the hero's."""
    mats = np.array([h_bind[n] @ np.linalg.inv(a_bind[n]) if n in h_bind else np.eye(4) for n in a_names])
    M = np.einsum("vk,vkij->vij", arm["weights"], mats[arm["joints"]])
    p = np.einsum("vij,vj->vi", M, np.c_[arm["pos"], np.ones(len(arm["pos"]))])[:, :3]
    n = np.einsum("vij,vj->vi", M[:, :3, :3], arm["nrm"])
    return p, n / np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-9)


def classify(p, tris, dominant, joint):
    """Slot index per triangle, from its centre in the hero's bind pose."""
    c = p[tris].mean(1)
    head, neck = joint["Head"][1], joint["neck"][1]
    collar = neck + HELM_FROM * (head - neck)
    spine_low = min(joint[n][1] for n in joint if n.startswith("Spine"))
    waist = (joint["Hips"][1] + spine_low) / 2
    knee = (joint["LeftLeg"][1] + joint["RightLeg"][1]) / 2
    ankle = (joint["LeftFoot"][1] + joint["RightFoot"][1]) / 2
    boot = knee - BOOT_BELOW * (knee - ankle)
    slot = np.where(c[:, 1] >= collar, 0, np.where(c[:, 1] >= waist, 2, np.where(c[:, 1] >= boot, 4, 5)))
    for side in ("Left", "Right"):
        on_arm = np.array([d.startswith(side) and d[len(side):] in ("Arm", "ForeArm", "Hand", "Shoulder") for d in dominant])
        el, ha = joint[side + "ForeArm"], joint[side + "Hand"]
        cuff = el + GAUNTLET_FROM * (ha - el)
        axis = (ha - el) / np.linalg.norm(ha - el)
        slot[on_arm & (((c - cuff) @ axis) >= 0)] = 3
        sh = joint[side + "Arm"]
        out = (c[:, 0] - sh[0]) * (1 if side == "Left" else -1)
        pauldron = (c[:, 1] > sh[1] - PAULDRON_DROP) & (c[:, 1] < sh[1] + 0.35) & \
                   (out > -PAULDRON_OUT * 0.6) & (np.abs(c[:, 0]) > abs(sh[0]) - PAULDRON_OUT)
        slot[pauldron & ((slot == 2) | (slot == 0)) & np.array([d.startswith(side) for d in dominant])] = 1
    return slot


def dominant_bones(mesh, names):
    """Each triangle's dominant bone (most summed skin weight over its corners)."""
    T = mesh["tris"]
    W = np.zeros((len(T), len(names)))
    for k in range(mesh["joints"].shape[1]):
        for c in range(3):
            np.add.at(W, (np.arange(len(T)), mesh["joints"][T[:, c], k]), mesh["weights"][T[:, c], k])
    return [names[i] for i in W.argmax(1)]


def neighbours(pos, tris):
    """Pairs of triangles sharing an edge (once coincident vertices are welded: Meshy splits them
    at texture seams), and the welded corners of every triangle."""
    _, weld = np.unique(np.round(pos, 5), axis=0, return_inverse=True)
    W = weld.ravel()[tris]
    e = np.sort(W[:, [0, 1, 1, 2, 2, 0]].reshape(-1, 2), 1)
    t = np.repeat(np.arange(len(tris)), 3)
    order = np.lexsort((e[:, 1], e[:, 0]))
    e, t = e[order], t[order]
    same = (e[1:] == e[:-1]).all(1)
    return t[:-1][same], t[1:][same], W


def sample_texture(img, uv, tris):
    """RGB (0..1) at 7 points of every triangle (corners, edge middles, centre): (T, 7, 3)."""
    a = np.asarray(img.convert("RGB"))
    h, w = a.shape[:2]
    c = uv[tris]
    pts = np.concatenate([c, (c + np.roll(c, -1, 1)) / 2, c.mean(1, keepdims=True)], 1)
    x = np.clip((pts[..., 0] * w).astype(int), 0, w - 1)
    y = np.clip((pts[..., 1] * h).astype(int), 0, h - 1)
    return a[y, x]


def keep_parts_whole(slot, weld_tris, area):
    """Separate bits of geometry (a pauldron cap, a buckle) go wholly to the slot holding most of
    their area, so a seam never runs through one."""
    from scipy.sparse import coo_matrix
    from scipy.sparse.csgraph import connected_components
    n = weld_tris.max() + 1
    r = np.r_[weld_tris[:, 0], weld_tris[:, 1]]
    c = np.r_[weld_tris[:, 1], weld_tris[:, 2]]
    _, lab = connected_components(coo_matrix((np.ones(len(r)), (r, c)), shape=(n, n)), directed=False)
    part = lab[weld_tris[:, 0]]
    slot = slot.copy()
    for k in np.unique(part):
        m = part == k
        if m.sum() < SMALL_PART:
            slot[m] = np.argmax(np.bincount(slot[m], weights=area[m], minlength=len(SLOTS)))
    return slot


def bare_skin(flesh7, a, b):
    """Triangles that are bare skin the armour model painted: mostly skin-coloured, or partly and
    next to one that is (the ragged rim of a skin patch)."""
    share = (flesh7 > 0.5).mean(1)
    drop = share >= FLESH_DROP
    for _ in range(2):
        near = np.zeros(len(drop), bool)
        near[a[drop[b]]] = True
        near[b[drop[a]]] = True
        drop |= near & (share >= FLESH_EDGE)
    return drop


def fit_targets(rig_path, h_bind):
    """Target points per slot in the hero's bind pose: the full-set model carried onto the hero's
    skeleton (through the bones that move each vertex, so it sits on the hero's joints even where
    the auto-rigger put them a little differently), cut roughly into slots, bare skin dropped."""
    js, binary = read_glb(rig_path)
    a_names, a_bind = _bind(js, binary)
    arm = _mesh(js, binary)
    p, _ = retarget(arm, a_names, a_bind, h_bind)
    T = arm["tris"]
    joint = {k: v[:3, 3] for k, v in h_bind.items()}
    slot = classify(p, T, dominant_bones(arm, a_names), joint)
    a, b, weld = neighbours(arm["pos"], T)
    area = np.linalg.norm(np.cross(p[T[:, 1]] - p[T[:, 0]], p[T[:, 2]] - p[T[:, 0]]), axis=1) / 2
    slot = keep_parts_whole(slot, weld, area)
    rgb = sample_texture(image_of(js, binary, js["images"][0]), arm["uv"], T)
    bare = bare_skin(flesh_amount(rgb), a, b) & np.isin(slot, [SLOTS.index(n) for n in ("head", "shoulders", "chest", "hands")])
    return {n: surface_points(p, T[(slot == s) & ~bare], 6000) for s, n in enumerate(SLOTS) if ((slot == s) & ~bare).any()}


def _umeyama(src, dst):
    """Similarity (scale, rotation, translation) taking src onto dst, least squares."""
    ms, md = src.mean(0), dst.mean(0)
    a, b = src - ms, dst - md
    U, S, Vt = np.linalg.svd(b.T @ a / len(src))
    D = np.eye(3)
    D[2, 2] = np.sign(np.linalg.det(U @ Vt))
    R = U @ D @ Vt
    scale = np.trace(np.diag(S) @ D) / max((a ** 2).sum() / len(src), 1e-12)
    return scale, R, md - scale * R @ ms


def upright(R, up, max_deg):
    """R turned the least that keeps the piece's own up (+Y, the image's up) within max_deg of up."""
    cur = R[:, 1]
    ang = np.arccos(np.clip(cur @ up, -1, 1))
    lim = np.radians(max_deg)
    if ang <= lim:
        return R
    axis = np.cross(cur, up)
    axis /= max(np.linalg.norm(axis), 1e-12)
    return Rotation.from_rotvec(axis * (ang - lim)).as_matrix() @ R


def refine(src_pts, dst_pts, s, R, t, iters=40, up=None):
    """ICP from a given pose, both ways (so the piece can neither shrink into nor balloon over part
    of the target): the refined (err, scale, R, t), err the mean gap both ways (m, summed).
    up: (direction, degrees) the piece's up must stay within."""
    tree_d = cKDTree(dst_pts)
    for _ in range(iters):
        moved = s * src_pts @ R.T + t
        _, i_d = tree_d.query(moved)
        _, i_s = cKDTree(moved).query(dst_pts)
        src, dst = np.r_[src_pts, src_pts[i_s]], np.r_[dst_pts[i_d], dst_pts]
        s, R, t = _umeyama(src, dst)
        if up is not None:
            R = upright(R, *up)
            t = dst.mean(0) - s * R @ src.mean(0)
    moved = s * src_pts @ R.T + t
    return tree_d.query(moved)[0].mean() + cKDTree(moved).query(dst_pts)[0].mean(), s, R, t


def fit(src_pts, dst_pts, skin, iters=40, up=None):
    """Best similarity transform (err, scale, R, t) of a piece onto its target: every 90-degree
    turn tried, then refined. A turn that sinks more of the piece into the body (skin: points and
    normals of its surface) scores worse: a thin pauldron fits a thick target about as well inside
    out, its dome turned in against the neck, and only this tells the two apart."""
    tree_b = cKDTree(skin[0])
    cs, cd = src_pts.mean(0), dst_pts.mean(0)
    s0 = np.sqrt(((dst_pts - cd) ** 2).sum(1).mean() / ((src_pts - cs) ** 2).sum(1).mean())
    best = None
    for R0 in Rotation.create_group("O").as_matrix():  # the 24 turns of a cube
        if up is not None and R0[:, 1] @ up[0] < 0.5:
            continue
        err, s, R, t = refine(src_pts, dst_pts, s0, R0, cd - s0 * R0 @ cs, iters, up)
        moved = s * src_pts @ R.T + t
        _, i = tree_b.query(moved)
        err += SINK * (((moved - skin[0][i]) * skin[1][i]).sum(1) < 0).mean()
        if best is None or err < best[0]:
            best = (err, s, R, t)
    return best


def body_shell(body, kind, cut, joint):
    """Where a close-fitting piece should sit: the body's own surface, pushed out a little, over
    the stretch the piece covers (from the cut piece: how far up the forearm a cuff reaches, how
    high a boot goes). Fitting to this, not to the full-set model's piece, keeps a glove's palm
    and a boot's shin inside them: the full-set model's limbs are thicker and sit elsewhere."""
    pts, nrm, _, _ = surface_samples(body, int(body["joints"].max()) + 1, per_edge=6)
    right = pts[:, 0] < 0
    if kind == "glove":
        el, ha = joint["RightForeArm"], joint["RightHand"]
        axis = (ha - el) / np.linalg.norm(ha - el)
        s_cut = (cut - el) @ axis
        s_pts = (pts - el) @ axis
        radial = np.linalg.norm((pts - el) - np.outer(s_pts, axis), axis=1)
        keep = right & (s_pts >= s_cut.min()) & (radial < 0.12)
    else:
        keep = right & (pts[:, 1] <= cut[:, 1].max()) & (pts[:, 1] < joint["RightUpLeg"][1] - 0.15)
    return pts[keep] + nrm[keep] * SHELL[kind]


def unsink(src_pts, s, R, t, skin, gap=0.005, iters=30):
    """Turns and shifts a fitted piece (scale kept) until it no longer sinks into the body: each
    point inside, or closer than gap, is pulled out to gap off the skin, the rest stay put, and the
    rigid move that best does both is taken. A pauldron rests on the shoulder; a fit to a rough
    target can leave its collar edge buried in the neck and its outer edge flared off the arm."""
    tree_b = cKDTree(skin[0])
    for _ in range(iters):
        moved = s * src_pts @ R.T + t
        _, i = tree_b.query(moved)
        depth = ((moved - skin[0][i]) * skin[1][i]).sum(1)
        want = moved + skin[1][i] * np.maximum(gap - depth, 0)[:, None]
        mc, wc = moved.mean(0), want.mean(0)
        U, _, Vt = np.linalg.svd((want - wc).T @ (moved - mc))
        D = np.eye(3)
        D[2, 2] = np.sign(np.linalg.det(U @ Vt))
        dR = U @ D @ Vt
        R, t = dR @ R, dR @ (t - mc) + wc
    return s, R, t


# ------------------------------------------------------------------ textures


def steel_tone(img):
    """Median colour of a texture's steel: light, unsaturated texels (not gold trim, leather or the
    background), as RGB 0..1."""
    im = np.asarray(img.convert("RGB")) / 255.0
    corners = np.array([im[2, 2], im[2, -3], im[-3, 2], im[-3, -3]])
    a = im.reshape(-1, 3)
    mx, mn = a.max(1), a.min(1)
    steel = (mx - mn < 0.12) & (mx > 0.35) & (mx < 0.97)
    if np.ptp(corners, 0).max() < 0.03:  # a picture on a plain backdrop (a concept): not the backdrop
        steel &= np.abs(a - corners.mean(0)).max(1) > 0.06
    return np.median(a[steel], 0) if steel.sum() > 50 else None


def match_tone(img, ref):
    """Shifts a piece's colours so its steel has the reference's tone (generated pieces each come
    out a little bluer, greyer or brighter than the concept)."""
    tone = steel_tone(img)
    if tone is None or ref is None:
        return img
    a = np.asarray(img.convert("RGB")).astype(np.float64) / 255.0
    a = np.clip(a * (ref / np.maximum(tone, 1e-3)), 0, 1)
    return Image.fromarray((a * 255).astype(np.uint8))


def mid_tone(img):
    """Median grey of a texture's metal over its whole range, shadows included (unsaturated texels,
    not the backdrop): how dark it is overall, where steel_tone is how its highlights read."""
    im = np.asarray(img.convert("RGB")) / 255.0
    corners = np.array([im[2, 2], im[2, -3], im[-3, 2], im[-3, -3]])
    a = im.reshape(-1, 3)
    mx, mn = a.max(1), a.min(1)
    m = (mx - mn < 0.12) & (mx > 0.06) & (mx < 0.97)
    if np.ptp(corners, 0).max() < 0.03:
        m &= np.abs(a - corners.mean(0)).max(1) > 0.06
    return float(np.median(a[m].mean(1))) if m.sum() > 50 else None


def match_mid(img, ref):
    """A gamma that brings a piece's overall darkness to the reference's (highlights move least):
    for a set that is one metal all over (blackened plate), where one piece can come out a shade
    lighter than the rest. Not for a set whose concept is mostly something else (mail, cloth)."""
    mid = mid_tone(img)
    if mid is None or ref is None:
        return img
    g = np.log(ref) / np.log(mid)
    a = np.asarray(img.convert("RGB")).astype(np.float64) / 255.0
    return Image.fromarray((np.clip(a, 1e-4, 1) ** g * 255).astype(np.uint8))


def mirror(pc):
    """The other side's piece: x flipped, triangle winding flipped back."""
    m = dict(pc)
    m["pos"] = pc["pos"] * [-1, 1, 1]
    m["nrm"] = pc["nrm"] * [-1, 1, 1]
    m["tris"] = pc["tris"][:, ::-1]
    return m


def merge(a, b):
    out = {k: np.concatenate([a[k], b[k]]) for k in ("pos", "nrm", "uv")}
    out["tris"] = np.concatenate([a["tris"], b["tris"] + len(a["pos"])])
    return out


# ------------------------------------------------------------------ skinning, cover, output


def transfer_weights(p, samples, k=8):
    """Skin weights for points p from the nearest body surface samples (inverse distance), as the
    4 strongest bones, renormalised."""
    pts, _, dense, _ = samples
    d, idx = cKDTree(pts).query(p, k=k)
    w = 1.0 / np.maximum(d, 1e-4) ** 2
    blend = np.einsum("vk,vkb->vb", w, dense[idx]) / w.sum(1, keepdims=True)
    top = np.argsort(-blend, axis=1)[:, :4]
    tw = np.take_along_axis(blend, top, 1)
    return top, tw / np.maximum(tw.sum(1, keepdims=True), 1e-9)


def transfer_morphs(p, body, k=4):
    """The body's blend shapes (the fists) carried over to points p: each point moves like the body
    surface nearest to it, so a gauntlet closes around a weapon with the hand inside it."""
    if not body["morphs"]:
        return {}
    per_edge = 4
    bary = np.array([(i, j, per_edge - i - j) for i in range(per_edge + 1) for j in range(per_edge + 1 - i)], np.float64) / per_edge
    T = body["tris"]
    lerp = lambda a: np.einsum("bc,tc...->tb...", bary, a[T]).reshape(-1, *a.shape[1:])
    d, idx = cKDTree(lerp(body["pos"])).query(p, k=k)
    w = 1.0 / np.maximum(d, 1e-4) ** 2
    w /= w.sum(1, keepdims=True)
    return {name: np.einsum("vk,vkc->vc", w, lerp(delta)[idx]) for name, delta in body["morphs"].items()}


def rigid_weights(count, bones):
    """{bone index: share} for every vertex of a rigid piece."""
    j = np.zeros((count, 4), np.int64)
    w = np.zeros((count, 4))
    for i, (b, share) in enumerate(bones.items()):
        j[:, i], w[:, i] = b, share
    return j, w


def _ray_hit(orig, d, v0, v1, v2, t_min, t_max):
    """Möller–Trumbore: distance along orig + t d to the nearest of the triangles hit within
    t_min..t_max (inf if none)."""
    e1, e2 = v1 - v0, v2 - v0
    pv = np.cross(d, e2)
    det = (e1 * pv).sum(1)
    ok = np.abs(det) > 1e-12
    inv = 1.0 / np.where(ok, det, 1.0)
    tv = orig - v0
    u = (tv * pv).sum(1) * inv
    qv = np.cross(tv, e1)
    v = (qv * d).sum(1) * inv
    t = (e2 * qv).sum(1) * inv
    hit = ok & (u >= 0) & (v >= 0) & (u + v <= 1) & (t >= t_min) & (t <= t_max)
    return t[hit].min() if hit.any() else np.inf


def _raster_uv(uv, tris, size, values):
    """Paints per-corner values (T, 3) over each triangle's texels in UV space (barycentric
    interpolation); texels no triangle covers stay -1. Each texel belongs only to its own
    triangle, so nothing leaks across UV islands."""
    out = np.full((size, size), -1.0)
    for t in range(len(tris)):
        q = uv[tris[t]] * size - 0.5
        x0, y0 = np.maximum(np.floor(q.min(0)).astype(int), 0)
        x1, y1 = np.minimum(np.ceil(q.max(0)).astype(int), size - 1)
        if x1 < x0 or y1 < y0:
            continue
        gx, gy = np.meshgrid(np.arange(x0, x1 + 1), np.arange(y0, y1 + 1))
        d = (q[1, 1] - q[2, 1]) * (q[0, 0] - q[2, 0]) + (q[2, 0] - q[1, 0]) * (q[0, 1] - q[2, 1])
        if abs(d) < 1e-12:
            continue
        l0 = ((q[1, 1] - q[2, 1]) * (gx - q[2, 0]) + (q[2, 0] - q[1, 0]) * (gy - q[2, 1])) / d
        l1 = ((q[2, 1] - q[0, 1]) * (gx - q[2, 0]) + (q[0, 0] - q[2, 0]) * (gy - q[2, 1])) / d
        l2 = 1 - l0 - l1
        inside = (l0 >= -0.02) & (l1 >= -0.02) & (l2 >= -0.02)
        val = l0 * values[t, 0] + l1 * values[t, 1] + l2 * values[t, 2]
        sub = out[y0:y1 + 1, x0:x1 + 1]
        sub[inside] = np.maximum(sub[inside], val[inside])
    return out


def _hemisphere(k=64):
    """k directions spread over the +Z hemisphere (Fibonacci), not grazing."""
    i = np.arange(k) + 0.5
    z = 0.12 + 0.88 * (1 - i / k)
    r = np.sqrt(1 - z ** 2)
    a = np.pi * (3 - np.sqrt(5)) * i
    return np.stack([r * np.cos(a), r * np.sin(a), z], 1)


def _seen(p, n, tri, dirs):
    """Share of rays from p out over n's hemisphere that escape every triangle in tri: how much
    of the outside world p can see, so how much it can be seen from."""
    t = np.cross(n, [0.0, 1.0, 0.0] if abs(n[1]) < 0.9 else [1.0, 0.0, 0.0])
    t /= np.linalg.norm(t)
    d = dirs @ np.stack([t, np.cross(n, t), n])
    o = p + n * 0.004
    v0 = tri[:, 0]
    e1, e2 = tri[:, 1] - v0, tri[:, 2] - v0
    pv = np.cross(d[:, None, :], e2[None])                    # rays x triangles x 3
    det = (pv * e1[None]).sum(2)
    inv = 1.0 / np.where(np.abs(det) > 1e-12, det, np.inf)
    tv = o - v0
    u = (pv * tv[None]).sum(2) * inv
    qv = np.cross(tv, e1)
    v = (d @ qv.T) * inv
    tt = (qv * e2).sum(1)[None] * inv
    hit = (u >= 0) & (v >= 0) & (u + v <= 1) & (tt > 1e-4)
    return 1.0 - hit.any(1).mean()


def cover_mask(body, piece_tris, regions_png):
    """uint8 image in the body's UV space (the region map's size): bit s set where slot s's piece
    hides the body (COVER). Worked out per body vertex and painted per body triangle, so it never
    leaks across UV islands into a neighbouring part of the body. Pauldrons hide nothing: they
    stand off the shoulder, and the arm under them moves."""
    reg_img = np.asarray(Image.open(regions_png).convert("L"))
    size = reg_img.shape[0]
    pts, nrm, uv, T = body["pos"], body["nrm"], body["uv"], body["tris"]
    nrm = nrm / np.maximum(np.linalg.norm(nrm, axis=1, keepdims=True), 1e-9)
    cuv = np.clip((uv[T].mean(1) * size).astype(int), 0, size - 1)
    tri_region = reg_img[cuv[:, 1], cuv[:, 0]]
    out = np.zeros((size, size), np.uint8)
    for s, tri in piece_tris.items():
        how = COVER.get(SLOTS[s])
        if how is None or len(tri) == 0:
            continue
        cen = tri.mean(1)
        tree = cKDTree(cen)
        ext = np.linalg.norm(tri - cen[:, None], axis=2).max() + 0.01
        out_t = np.full(len(pts), np.inf)  # armour out along the body normal ...
        in_t = np.full(len(pts), np.inf)   # ... and in: the body sticks out through it
        for i, cand in enumerate(tree.query_ball_point(pts + nrm * COVER_REACH * 0.5, COVER_REACH * 0.5 + ext)):
            if cand:
                c = np.array(cand)
                out_t[i] = _ray_hit(pts[i], nrm[i], tri[c, 0], tri[c, 1], tri[c, 2], -0.01, COVER_REACH)
        for i, cand in enumerate(tree.query_ball_point(pts - nrm * COVER_POKE * 0.5, COVER_POKE * 0.5 + ext)):
            if cand:
                c = np.array(cand)
                in_t[i] = _ray_hit(pts[i], -nrm[i], tri[c, 0], tri[c, 1], tri[c, 2], 0.0, COVER_POKE)
        poke = in_t <= COVER_POKE
        in_own = tri_region == SLOT_REGION[SLOTS[s]]
        hide = poke.astype(float)
        if how == "whole":
            hide = (poke | (out_t <= COVER_TIGHT)).astype(float)
        elif how == "unseen":
            # the body inside that can't be seen from outside (rays out past the piece and the body)
            near = np.zeros(len(pts), bool)
            near[T[in_own].ravel()] = True
            near = (near | (out_t <= COVER_TIGHT)) & ~poke & (np.linalg.norm(pts - cen.mean(0), axis=1) < 0.5)
            occl = np.concatenate([tri, pts[T]])
            occl = occl[np.linalg.norm(occl.mean(1) - cen.mean(0), axis=1) < 0.6]
            dirs = _hemisphere()
            for i in np.nonzero(near)[0]:
                hide[i] = float(_seen(pts[i], nrm[i], occl, dirs) < SEEN)
        corner = hide[T]
        if how == "whole":
            corner = np.where(in_own[:, None], 1.0, corner)
        # a triangle hides only where its corners agree strongly: armour edges stay conservative
        covered = _raster_uv(uv, T, size, corner) >= 0.75
        out |= (covered.astype(np.uint8) << s)
        print("  cover %-9s hides %4.1f%% of the body's triangles (%s)" % (SLOTS[s], 100.0 * (corner.mean(1) >= 0.75).mean(), how))
    return out


def write_armor(hero_js, hero_bin, pieces, texture, dst):
    """The hero glb's skeleton and skin with the body mesh swapped for one mesh per slot."""
    js = {k: v for k, v in hero_js.items()}
    js["nodes"] = [dict(n) for n in hero_js["nodes"]]
    js.pop("animations", None)
    js["meshes"], js["materials"] = [], []
    textures = texture if isinstance(texture, list) else [texture]  # pieces pick one by "material"
    js["images"] = [{"bufferView": None, "mimeType": "image/png", "name": "armor%d" % i} for i in range(len(textures))]
    js["textures"] = [{"sampler": 0, "source": i} for i in range(len(textures))]
    js["samplers"] = [{"magFilter": 9729, "minFilter": 9987}]
    # double-sided: through an armhole or under a pauldron rim you see the inside of the plate
    js["materials"] = [{"name": "armor%d" % i, "doubleSided": True, "pbrMetallicRoughness": {"baseColorTexture": {"index": i}}}
                       for i in range(len(textures))]
    make_matte(js)
    js["accessors"] = [dict(a) for a in hero_js["accessors"]]
    js["bufferViews"] = [dict(v) for v in hero_js["bufferViews"]]
    new_views = {}

    def view(data):
        js["bufferViews"].append({"buffer": 0, "byteOffset": 0, "byteLength": 0})
        new_views[len(js["bufferViews"]) - 1] = np.ascontiguousarray(data).tobytes()
        return len(js["bufferViews"]) - 1

    def acc(data, ctype, kind, minmax=False):
        a = {"bufferView": view(data), "componentType": ctype, "count": len(data), "type": kind}
        if minmax:
            a["min"], a["max"] = data.min(0).tolist(), data.max(0).tolist()
        js["accessors"].append(a)
        return len(js["accessors"]) - 1

    for i, tex in enumerate(textures):
        js["images"][i]["bufferView"] = view(png_bytes(tex))
    body_node = next(i for i, n in enumerate(js["nodes"]) if "mesh" in n)
    parent = next(i for i, n in enumerate(js["nodes"]) if body_node in n.get("children", []))
    js["nodes"][body_node] = {"name": "unused"}
    js["nodes"][parent]["children"] = [c for c in js["nodes"][parent]["children"] if c != body_node]
    for slot, pc in pieces.items():
        prim = {"attributes": {
            "POSITION": acc(pc["pos"].astype(np.float32), 5126, "VEC3", True),
            "NORMAL": acc(pc["nrm"].astype(np.float32), 5126, "VEC3"),
            "TEXCOORD_0": acc(pc["uv"].astype(np.float32), 5126, "VEC2"),
            "JOINTS_0": acc(pc["joints"].astype(np.uint16), 5123, "VEC4"),
            "WEIGHTS_0": acc(pc["weights"].astype(np.float32), 5126, "VEC4")},
            "indices": acc(pc["tris"].reshape(-1).astype(np.uint32), 5125, "SCALAR"), "material": pc.get("material", 0)}
        mesh = {"name": "armor_" + slot, "primitives": [prim]}
        if pc["morphs"]:
            prim["targets"] = [{"POSITION": acc(d.astype(np.float32), 5126, "VEC3", True)} for d in pc["morphs"].values()]
            mesh["weights"] = [0.0] * len(pc["morphs"])
            mesh["extras"] = {"targetNames": list(pc["morphs"])}
        js["meshes"].append(mesh)
        js["nodes"].append({"name": "armor_" + slot, "mesh": len(js["meshes"]) - 1, "skin": 0})
        js["nodes"][parent]["children"].append(len(js["nodes"]) - 1)
    prune_unused(js, new_views)
    write_glb(dst, js, replace_views(js, hero_bin, new_views))


def main():
    name = sys.argv[1]
    opts = dict(zip(sys.argv[2::2], sys.argv[3::2]))
    size, lift = int(opts.get("--texture", 512)), float(opts.get("--brighten", 1.1))
    regions = opts.get("--regions", "assets/hero_regions.png")
    hj, hb = read_glb(opts.get("--hero", "assets/hero.glb"))
    h_names, h_bind = _bind(hj, hb)
    hidx = {n: i for i, n in enumerate(h_names)}
    joint = {k: v[:3, 3] for k, v in h_bind.items()}
    body = _mesh(hj, hb)
    samples = surface_samples(body, len(h_names))
    skin = samples[0], samples[1]
    targets = fit_targets(opts["--fit"], h_bind)
    concept = Image.open(opts["--match"]) if "--match" in opts else None
    ref_tone = steel_tone(concept) if concept else None
    ref_mid = mid_tone(concept) if concept and opts.get("--match-mid") == "yes" else None
    pieces, piece_tris, textures = {}, {}, []
    for kind, slot in KINDS.items():
        pc = load_piece(opts["--" + kind])
        if kind == "boot":
            pc = drop_stand(pc, kind)
        side = FIT_SIDE[kind]
        tgt = targets[slot]
        if side:
            tgt = tgt[(tgt[:, 0] > 0) == (side > 0)]
        src = surface_points(pc["pos"], pc["tris"])
        _, s, R, t = fit(src, tgt, skin, up=UPRIGHT.get(kind))
        if kind in SHELL:  # then snug onto the hero's own hand / leg
            tgt = body_shell(body, kind, tgt, joint)
            _, s, R, t = refine(src, tgt, s, R, t)
        elif kind == "shoulder":  # then rested on the shoulder, not sunk into it
            s, R, t = unsink(src, s, R, t, skin)
        moved = s * src @ R.T + t
        err = cKDTree(tgt).query(moved)[0].mean() + cKDTree(moved).query(tgt)[0].mean()
        print("  %-8s fitted: scale %.3f, turned %.0f deg, mean gap %.1f cm" % (
            kind, s, np.degrees(Rotation.from_matrix(R).magnitude()), err * 50))
        pc["pos"] = s * pc["pos"] @ R.T + t
        pc["nrm"] = pc["nrm"] @ R.T
        tex = match_tone(pc["texture"], ref_tone)
        tex = match_mid(tex, ref_mid)
        textures.append(treat(tex, size, lift))
        both = merge(pc, mirror(pc)) if side else pc
        used, local = np.unique(both["tris"], return_inverse=True)
        pp, nn = both["pos"][used] + both["nrm"][used] * INFLATE, both["nrm"][used]
        if slot == "head":
            j, w = rigid_weights(len(used), {hidx["Head"]: 1.0})
        elif slot == "shoulders":
            # rigid per side, half on the collarbone and half on the upper arm (like a pauldron
            # strapped to the arm): it rides the shoulder without the arm swinging through it
            j, w = np.zeros((len(used), 4), np.int64), np.zeros((len(used), 4))
            left = pp[:, 0] > 0
            for sd, m in (("Left", left), ("Right", ~left)):
                j[m, 0], j[m, 1] = hidx[sd + "Shoulder"], hidx[sd + "Arm"]
                w[m, 0], w[m, 1] = 0.5, 0.5
        else:
            j, w = transfer_weights(pp, samples)
        pieces[slot] = {"pos": pp, "nrm": nn, "uv": both["uv"][used], "joints": j, "weights": w,
                        "tris": local.reshape(-1, 3), "material": len(textures) - 1,
                        "morphs": transfer_morphs(pp, body) if slot == "hands" else {}}
        piece_tris[SLOTS.index(slot)] = both["pos"][both["tris"]]
    write_armor(hj, hb, pieces, textures, "assets/armor_%s.glb" % name)
    cover = cover_mask(body, piece_tris, regions)
    Image.fromarray(cover, "L").save("assets/armor_%s_cover.png" % name, optimize=True)
    print("wrote assets/armor_%s.glb and assets/armor_%s_cover.png" % (name, name))
    if "--skin" in opts:
        dst = "assets/hero_skin_%s.png" % name
        cmd_skin(opts["--skin"], dst, size, lift)
        cmd_fleshmask(dst, regions)


if __name__ == "__main__":
    main()
