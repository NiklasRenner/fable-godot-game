"""Turn Meshy outputs into game assets, in plain Python (no Blender).

    python tools/import_meshy.py model   <rigged_animated.glb> <assets/x.glb>  [--texture 512] [--brighten 1.1]
    python tools/import_meshy.py skin    <retextured.glb>      <assets/x_skin_y.png> [--texture 512] [--brighten 1.1]
    python tools/import_meshy.py regions <rigged.glb>          <assets/x_regions.png> [--texture 512]
    python tools/import_meshy.py sprite  <image.png>           <assets/fx/x.png> [--texture 256]
    python tools/import_meshy.py quadruped <model.glb>        <assets/x.glb> --size <length m> [--front +z]
    python tools/import_meshy.py rigid   <model.glb> <assets/x.glb> --kind weapon|shoulder|prop [--size 1.05] [--along x] [--texture 256]
    python tools/import_meshy.py fist    <assets/x.glb>        <assets/x.glb>
    python tools/import_meshy.py texture <image.png>           <assets/terrain/x.png> [--texture 512] [--brighten 1.0] [--saturation 1.0]

model    renames the clips to the ones Unit._drive_animation plays (CLIP_NAMES), detaches Meshy's
         helper node and shrinks/lifts the texture (Meshy bakes dark; Classic is bright and flat).
         It also adds the fist blend shapes (see fist) and prints their grip frames.
fist     the rigs have no finger bones, so a closed hand is a blend shape: each finger is bent onto
         an arc around a handle-sized axis ("fist_R"/"fist_L", see FIST_*). Prints the grip frame
         (handle centre and axis, in bind-pose mesh space) for GameData.MODELS[...].fist, which
         puts weapons through the fist. Re-running replaces the shapes.
skin     a retexture of the same body (Meshy retexture with enable_original_uv) keeps its UVs, so
         its texture is a drop-in "skin": armour painted onto the body, WoW Classic style. This
         writes it as a PNG the game layers per slot (Outfit._apply_skins).
regions  bakes which body region every texel belongs to, as a PNG whose red channel is the region
         index (REGIONS below): straight cuts at the collar, waist, boot tops and wrists, placed
         from the rig's joints. Equipping a chest piece copies only the chest texels of its skin
         over the base body. Needs scipy.
texture  a generated "seamless" texture image made truly tileable: trims a painted frame, blends a
         band along the edges with the image shifted by half (whose edges are its continuous
         middle), then resizes. For the terrain layers (assets/terrain/terrain.gdshader).
sprite   a cut-out image (text-to-image with remove_background) for ground clutter cards: trimmed
         to its visible pixels, minus grey rows at the bottom (a painted soil patch or shadow, so the
         card stands on its stems), resized to --texture pixels wide.
quadruped  a static four-legged model (Meshy's auto-rig is humanoid only) skinned to a simple rig
         found from its shape (legs = the separate columns under the belly) with idle, walk and
         attack clips written procedurally; faces -Z, scaled to --size metres long.
matte    <glb> [roughness]: makes an imported model's materials matte in place (no metal,
         roughness 1). model and rigid already do it; this fixes older imports.
clips    <dst glb> <src glb> Name:name ...: copies clips from another animation of the same rig
         into dst in place (renamed; replaces a clip of that name), leaving the rest untouched.
tweak    <glb> <clip> <new clip> op ...: a pose-edited copy of a clip, in place (see cmd_tweak:
         amp, rot, blend, hips, speed, wave), e.g. calmer idles or a harder-driving run.
fleshmask <skin png> [regions png]: alpha 0 where an armour skin painted bare skin (outside the
         head), so the base body's own skin shows through there (run after skin).
nobase   <glb>: removes a prop's downward-facing base cap in place (Meshy materials are
         double-sided, so it shows from above and z-fights with the ground) and lifts a flat floor
         (a tent's groundsheet) 3 cm clear. rigid --kind prop already does it; this fixes older
         imports.
icon     an ability icon from a generated image: finds the painted tile on its backdrop, trims its
         frame (--inset, fraction of the side) and resizes it to --texture pixels square; or
         --box x0,y0,x1,y1 crops that square instead (meshy/creatures.json has each icon's).
rigid    a weapon, shoulder piece or world prop, put in the game's convention: weapons get the
         grip at the origin, the blade along -Z, its flat facing ±X (edges ±Y), and are scaled to
         --size metres long; shoulders stay upright, get their bounding-box centre at the origin
         (the game centres it over the shoulder joint) and are scaled to --size metres wide; props
         stand on the origin, --size metres tall (or long along X with --along x). Materials are
         made matte (and props lose their base cap, see nobase). Hafted weapons (axes, clubs,
         staves, wands) have no guard: --grip 0.15 holds
         them that fraction of the length up from the butt, the heavier end forward.

Textures stay embedded in the .glb: project.godot's [importer_defaults] sets
gltf/embedded_image_handling=3, because Godot's default extracts the texture on the first import
and keeps applying that stale file to every re-import (a new model wears the old one's texture).

The glTF is edited in place structurally (existing node and accessor indices are unchanged; fist
only appends), so skins and animations stay valid. The recipe end to end: docs/art-pipeline.md. Meshy models face +Z; the game turns them with GameData.MODELS[...].yaw.
"""
import io
import json
import struct
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

# Meshy preset key -> clip name the game drives.
CLIP_NAMES = {
    "Idle": "idle",
    "run_fast_3_inplace": "walk",
    "Left_Slash": "attack",
    "mage_soell_cast": "cast",
    "Sit_Cross_Legged_on_Floor": "sit",
    "Regular_Jump": "jump",
    "Slow_Orc_Walk_inplace": "walk",   # trolls
    "Attack": "attack",
    "Heavy_Hammer_Swing": "attack",    # the troll boss
}
HELPER_NODES = ("Icosphere",)

# Body regions (index = value in the region map's red channel). Boundaries are straight cuts, like
# WoW Classic's texture regions: every texel is classed by its own bind-pose position against planes
# anchored to the skeleton, so armour pieces meet along clean lines whatever the triangles do.
REGIONS = ["head", "chest", "legs", "feet", "hands"]
ARM_BONES = ("Arm", "ForeArm", "Hand")  # Left/Right...: the arm chain; everything else is the body
COLLAR_UP = 0.15   # collar: this far above the Head joint, as a fraction of neck -> Head
BOOT_BELOW = 0.05  # boot tops: this far below the knee, as a fraction of knee -> ankle
WRIST_BACK = 0.25  # wrist: this far up the forearm from the Hand joint, as a fraction of its length
# The waist sits midway between the Hips and the lowest spine joint (the belt line).

# Fist blend shapes (the rig has no finger bones): each finger is bent onto an arc around a handle.
FIST_KNUCKLE = 0.5    # fingers bend from here, as a fraction of wrist -> fingertip
FIST_SPLIT = 0.58     # beyond this the fingers are separate prongs (their lines are measured there)
FIST_HANDLE_R = 0.018 # radius the fingers wrap around (m); our weapons' handles are ~3.5 cm thick
FIST_CURL_MAX = np.radians(200.0)

# ------------------------------------------------------------------ glb io

def read_glb(path):
    b = open(path, "rb").read()
    magic, _, _ = struct.unpack("<III", b[:12])
    assert magic == 0x46546C67, "not a GLB"
    jlen, _ = struct.unpack("<II", b[12:20])
    js = json.loads(b[20:20 + jlen])
    blen, _ = struct.unpack("<II", b[20 + jlen:28 + jlen])
    return js, bytearray(b[28 + jlen:28 + jlen + blen])


def write_glb(path, js, binary):
    def pad(data, fill):
        return data + fill * ((4 - len(data) % 4) % 4)
    jb = pad(json.dumps(js, separators=(",", ":")).encode("utf-8"), b" ")
    bb = pad(bytes(binary), b"\0")
    out = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(jb) + 8 + len(bb))
    out += struct.pack("<II", len(jb), 0x4E4F534A) + jb + struct.pack("<II", len(bb), 0x004E4942) + bb
    open(path, "wb").write(out)


def replace_views(js, binary, new_bytes):
    """Rebuild the binary chunk with some bufferViews' contents replaced ({view index: bytes})."""
    out = bytearray()
    for i, v in enumerate(js["bufferViews"]):
        start = v.get("byteOffset", 0)
        data = new_bytes.get(i, binary[start:start + v["byteLength"]])
        out += b"\0" * ((4 - len(out) % 4) % 4)
        v["byteOffset"] = len(out)
        v["byteLength"] = len(data)
        out += data
    js["buffers"][0]["byteLength"] = len(out)
    return out


def prune_unused(js, new_views):
    """Drops accessors and bufferViews nothing references any more (clips replaced by `clips` or
    `tweak` leave their old data behind), renumbering the rest; `new_views` (pending
    replace_views contents) is remapped in place. Call just before replace_views."""
    if js.get("extensionsUsed"):
        return # compressed or extended data may reference views in ways not tracked here
    used_acc = set()
    for m in js.get("meshes", []):
        for pr in m["primitives"]:
            used_acc.update(pr.get("attributes", {}).values())
            if "indices" in pr:
                used_acc.add(pr["indices"])
            for t in pr.get("targets", []):
                used_acc.update(t.values())
    for sk in js.get("skins", []):
        if "inverseBindMatrices" in sk:
            used_acc.add(sk["inverseBindMatrices"])
    for an in js.get("animations", []):
        for sm in an["samplers"]:
            used_acc.update((sm["input"], sm["output"]))
    acc_map = {old: new for new, old in enumerate(sorted(used_acc))}
    js["accessors"] = [js["accessors"][i] for i in sorted(used_acc)]
    used_views = set()
    for a in js["accessors"]:
        if "bufferView" in a:
            used_views.add(a["bufferView"])
        for part in ("indices", "values"):
            if part in a.get("sparse", {}):
                used_views.add(a["sparse"][part]["bufferView"])
    used_views.update(im["bufferView"] for im in js.get("images", []) if "bufferView" in im)
    view_map = {old: new for new, old in enumerate(sorted(used_views))}
    js["bufferViews"] = [js["bufferViews"][i] for i in sorted(used_views)]
    for a in js["accessors"]:
        if "bufferView" in a:
            a["bufferView"] = view_map[a["bufferView"]]
        for part in ("indices", "values"):
            if part in a.get("sparse", {}):
                a["sparse"][part]["bufferView"] = view_map[a["sparse"][part]["bufferView"]]
    for im in js.get("images", []):
        if "bufferView" in im:
            im["bufferView"] = view_map[im["bufferView"]]
    for m in js.get("meshes", []):
        for pr in m["primitives"]:
            pr["attributes"] = {k: acc_map[v] for k, v in pr.get("attributes", {}).items()}
            if "indices" in pr:
                pr["indices"] = acc_map[pr["indices"]]
            if "targets" in pr:
                pr["targets"] = [{k: acc_map[v] for k, v in t.items()} for t in pr["targets"]]
    for sk in js.get("skins", []):
        if "inverseBindMatrices" in sk:
            sk["inverseBindMatrices"] = acc_map[sk["inverseBindMatrices"]]
    for an in js.get("animations", []):
        for sm in an["samplers"]:
            sm["input"], sm["output"] = acc_map[sm["input"]], acc_map[sm["output"]]
    moved = {view_map[k]: v for k, v in new_views.items() if k in view_map}
    new_views.clear()
    new_views.update(moved)


def accessor(js, binary, i):
    a = js["accessors"][i]
    v = js["bufferViews"][a["bufferView"]]
    n = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}[a["type"]]
    dt = {5126: np.float32, 5125: np.uint32, 5123: np.uint16, 5121: np.uint8}[a["componentType"]]
    data = np.frombuffer(bytes(binary), dt, a["count"] * n, v.get("byteOffset", 0) + a.get("byteOffset", 0))
    return data.reshape(a["count"], n) if n > 1 else data


def image_of(js, binary, img):
    v = js["bufferViews"][img["bufferView"]]
    return Image.open(io.BytesIO(bytes(binary[v.get("byteOffset", 0):v.get("byteOffset", 0) + v["byteLength"]]))).convert("RGB")


def treat(im, size, lift):
    im = im.resize((size, size), Image.LANCZOS)
    if lift != 1.0:
        a = np.asarray(im).astype(np.float32) / 255.0
        im = Image.fromarray((np.clip((a ** 0.9) * lift, 0.0, 1.0) * 255).astype(np.uint8))
    return im


def png_bytes(im):
    buf = io.BytesIO()
    im.save(buf, "PNG", optimize=True)
    return buf.getvalue()


def bind_joints(js, binary):
    """The skin's bone names and each joint's bind-pose position in mesh space."""
    skin = js["skins"][0]
    names = [js["nodes"][j]["name"] for j in skin["joints"]]
    ibm = accessor(js, binary, skin["inverseBindMatrices"]).reshape(-1, 4, 4)
    return names, {n: np.linalg.inv(m.T)[:3, 3] for n, m in zip(names, ibm)}


def retexture(js, binary, new_views, size, lift):
    """Shrinks/lifts every embedded texture (queued in new_views for replace_views)."""
    for img in js.get("images", []):
        if "bufferView" in img:
            new_views[img["bufferView"]] = png_bytes(treat(image_of(js, binary, img), size, lift))
            img["mimeType"] = "image/png"


# ------------------------------------------------------------------ fists

def _unit(v):
    return v / np.linalg.norm(v)


def _pieces(verts, tris, pos):
    """Connected pieces of the mesh restricted to `verts`. Vertices sharing a position are welded:
    the mesh is split along UV seams, which would otherwise cut a finger into several pieces."""
    key, weld = {}, np.array([0] * len(pos))
    for i, p in enumerate(pos):
        weld[i] = key.setdefault(tuple(np.round(p, 5)), i)
    vs = set(int(v) for v in verts)
    parent = {v: v for v in vs}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    for t in tris:
        tt = [int(v) for v in t if int(v) in vs]
        for a, b in zip(tt, tt[1:]):
            parent[find(a)] = find(b)
    first = {}
    for v in vs:
        if int(weld[v]) in first:
            parent[find(v)] = find(first[int(weld[v])])
        else:
            first[int(weld[v])] = v
    groups = {}
    for v in vs:
        groups.setdefault(find(v), []).append(v)
    return [np.array(g) for g in groups.values()]


def fist_shape(pos, tris, joints, weights, bone_names, joint, side):
    """Bent positions of `side`'s hand closed into a fist, plus the grip frame in bind (mesh) space:
    `point` is the middle of the handle, `axis` the handle's direction out of the thumb side (where
    a blade leaves the fist), `edge` the direction the knuckles face (a blade's edge)."""
    hi = bone_names.index(side + "Hand")
    w_hand = np.zeros(len(pos))
    for k in range(joints.shape[1]):
        w_hand += np.where(joints[:, k] == hi, weights[:, k], 0.0)
    H = joint[side + "Hand"]
    hand = np.nonzero(w_hand > 0.5)[0]
    far = hand[np.argsort(np.linalg.norm(pos[hand] - H, axis=1))[-max(8, len(hand) // 10):]]
    f = _unit((pos[far] - H).mean(0))  # wrist -> fingertips
    s = (pos - H) @ f
    s_max = s[hand].max()
    s_k = FIST_KNUCKLE * s_max
    fingers = sorted([c for c in _pieces(hand[s[hand] > FIST_SPLIT * s_max], tris, pos) if len(c) >= 6], key=len)[-4:]
    thumbs = [c for c in _pieces(hand[s[hand] > 0.4 * s_max], tris, pos) if s[c].max() < FIST_SPLIT * s_max]
    if not thumbs or len(fingers) < 2:
        # a mitten or claw (monsters): nothing to bend; grip across the hand, out of the front (an
        # A-posed hand's thumb faces the way the model looks, +Z), like a held club
        axis = _unit(np.array([0.0, 0.0, 1.0]) - f * f[2])
        print("  %s hand: no separate fingers/thumb, grip frame only (no fist shape)" % side)
        return pos.copy(), {"point": H + f * 0.6 * s_max, "axis": axis, "edge": _unit(f - axis * (f @ axis))}
    thumb = max(thumbs, key=len)
    allf = np.concatenate(fingers)
    F = pos[allf] - pos[allf].mean(0)
    F -= np.outer(F @ f, f)
    n = np.linalg.svd(F)[2][1]  # the fingers' thin axis ([2] is f itself, projected out)
    n = _unit(n - f * (n @ f))
    sgn = 1.0 if side == "Right" else -1.0
    if sgn * (np.cross(f, n) @ (pos[thumb].mean(0) - pos[allf].mean(0))) < 0:
        n = -n  # palm side: the thumb is on f x palm for a right hand, palm x f for a left
    axis = np.cross(f, n) * sgn
    frames = []  # per finger: knuckle point, direction, palm normal, side axis, wrap radius, lateral pos
    for c in fingers:
        P = pos[c]
        m = P.mean(0)
        fi = np.linalg.svd(P - m)[2][0]
        fi = _unit(fi if fi @ f > 0 else -fi)
        ni = _unit(n - fi * (n @ fi))
        B = m + fi * ((s_k - (m - H) @ f) / (fi @ f))
        R = FIST_HANDLE_R + ((P - m) @ ni).std()
        frames.append((B, fi, ni, np.cross(fi, ni), R, (m - H) @ axis))
    lat = np.array([fr[5] for fr in frames])
    sigma = np.ptp(lat) / 6.0
    new = pos.copy()
    for v in np.setdiff1d(hand[s[hand] > s_k - 0.01], thumb):
        # webbing between fingers blends its neighbours' bends, so nothing tears
        k = np.exp(-(((pos[v] - H) @ axis - lat) / sigma) ** 2)
        k /= k.sum()
        acc = np.zeros(3)
        for kk, (B, fi, ni, wi, R, _) in zip(k, frames):
            q = pos[v] - B
            t, h, l = q @ fi, q @ ni, q @ wi
            if t <= 0:
                acc += kk * pos[v]
                continue
            phi = min(t / R, FIST_CURL_MAX)
            rad = -ni * np.cos(phi) + fi * np.sin(phi)
            tan = ni * np.sin(phi) + fi * np.cos(phi)
            acc += kk * (B + ni * R + wi * l + rad * (R - h) + tan * (t - phi * R))
        new[v] = acc
    point = np.mean([B + ni * R for B, fi, ni, wi, R, _ in frames], 0)
    edge = _unit(f - axis * (f @ axis))
    return new, {"point": point, "axis": axis, "edge": edge}


def _vertex_normals(pos, tris):
    key, weld = {}, np.zeros(len(pos), int)
    for i, p in enumerate(pos):
        weld[i] = key.setdefault(tuple(np.round(p, 5)), len(key))
    fn = np.cross(pos[tris[:, 1]] - pos[tris[:, 0]], pos[tris[:, 2]] - pos[tris[:, 0]])
    acc = np.zeros((len(key), 3))
    for c in range(3):
        np.add.at(acc, weld[tris[:, c]], fn)
    acc = acc[weld]
    return acc / (np.linalg.norm(acc, axis=1, keepdims=True) + 1e-12)


def add_fists(js, binary, new_views):
    """Adds "fist_R"/"fist_L" morph targets to the body mesh (replacing earlier ones) and returns the
    grip frames. Appends bufferViews: pass `new_views` on to replace_views."""
    bone_names, joint = bind_joints(js, binary)
    mesh = js["meshes"][0]
    prim = mesh["primitives"][0]
    pos = accessor(js, binary, prim["attributes"]["POSITION"]).astype(np.float64)
    nrm = accessor(js, binary, prim["attributes"]["NORMAL"]).astype(np.float64)
    tris = accessor(js, binary, prim["indices"]).reshape(-1, 3).astype(np.int64)
    joints = accessor(js, binary, prim["attributes"]["JOINTS_0"]).astype(np.int64)
    weights = accessor(js, binary, prim["attributes"]["WEIGHTS_0"]).astype(np.float64)
    old = sorted({i for t in prim.get("targets", []) for i in t.values()})
    n_acc = len(js["accessors"])
    if old and old == list(range(n_acc - len(old), n_acc)):  # our own earlier fists: drop them
        views = sorted(js["accessors"][i]["bufferView"] for i in old)
        del js["accessors"][n_acc - len(old):]
        if views == list(range(len(js["bufferViews"]) - len(views), len(js["bufferViews"]))):
            del js["bufferViews"][views[0]:]
    base_n = _vertex_normals(pos, tris)
    targets, names, grips = [], [], {}
    for side, tag in (("Right", "R"), ("Left", "L")):
        new, grip = fist_shape(pos, tris, joints, weights, bone_names, joint, side)
        grips[side + "Hand"] = grip
        moved = np.linalg.norm(new - pos, axis=1) > 1e-7
        n2 = nrm + (_vertex_normals(new, tris) - base_n)
        n2 /= np.linalg.norm(n2, axis=1, keepdims=True) + 1e-12
        dn = np.where(moved[:, None], n2 - nrm, 0.0)
        target = {}
        for attr, delta in (("POSITION", new - pos), ("NORMAL", dn)):
            data = delta.astype(np.float32)
            js["bufferViews"].append({"buffer": 0, "byteOffset": 0, "byteLength": 0})
            new_views[len(js["bufferViews"]) - 1] = data.tobytes()
            js["accessors"].append({"bufferView": len(js["bufferViews"]) - 1, "componentType": 5126,
                                    "count": len(data), "type": "VEC3",
                                    "min": data.min(0).tolist(), "max": data.max(0).tolist()})
            target[attr] = len(js["accessors"]) - 1
        targets.append(target)
        names.append("fist_" + tag)
    prim["targets"] = targets
    mesh["weights"] = [0.0] * len(targets)
    mesh.setdefault("extras", {})["targetNames"] = names
    return grips


def print_grips(grips):
    v = lambda a: "Vector3(%.4f, %.4f, %.4f)" % tuple(a)
    print("fist blend shapes fist_R / fist_L; for GameData.MODELS (bind-pose mesh space):")
    for bone, g in grips.items():
        print('    "fist": {"bone": "%s", "shape": "fist_%s", "point": %s, "axis": %s, "edge": %s},' % (
            bone, bone[0], v(g["point"]), v(g["axis"]), v(g["edge"])))


def cmd_fist(src, dst):
    js, binary = read_glb(src)
    new_views = {}
    grips = add_fists(js, binary, new_views)
    write_glb(dst, js, replace_views(js, binary, new_views))
    print_grips(grips)


def cmd_model(src, dst, size, lift):
    js, binary = read_glb(src)
    renamed = []
    for a in js.get("animations", []):
        if a.get("name") in CLIP_NAMES:
            renamed.append("%s -> %s" % (a["name"], CLIP_NAMES[a["name"]]))
            a["name"] = CLIP_NAMES[a["name"]]
    helpers = {i for i, n in enumerate(js["nodes"]) if n.get("name", "").startswith(HELPER_NODES)}
    for scene in js["scenes"]:
        scene["nodes"] = [n for n in scene["nodes"] if n not in helpers]
    for n in js["nodes"]:
        if "children" in n:
            n["children"] = [c for c in n["children"] if c not in helpers]
    new_views = {}
    retexture(js, binary, new_views, size, lift)
    grips = add_fists(js, binary, new_views)
    make_matte(js)
    write_glb(dst, js, replace_views(js, binary, new_views))
    print_grips(grips)
    print("clips:", ", ".join(renamed) or "none renamed")
    print("helpers detached:", [js["nodes"][i]["name"] for i in helpers])
    print("texture -> %dpx, brighten %.2f; wrote %s" % (size, lift, dst))


def cmd_skin(src, dst, size, lift):
    js, binary = read_glb(src)
    treat(image_of(js, binary, js["images"][0]), size, lift).save(dst, optimize=True)
    print("skin -> %s (%dpx, brighten %.2f)" % (dst, size, lift))


def cmd_regions(src, dst, size):
    from scipy import ndimage
    js, binary = read_glb(src)
    bone_names, joint = bind_joints(js, binary)
    prim = js["meshes"][0]["primitives"][0]
    pos = accessor(js, binary, prim["attributes"]["POSITION"]).astype(np.float64)
    uv = accessor(js, binary, prim["attributes"]["TEXCOORD_0"]).astype(np.float64)
    joints = accessor(js, binary, prim["attributes"]["JOINTS_0"])
    weights = accessor(js, binary, prim["attributes"]["WEIGHTS_0"])
    tris = accessor(js, binary, prim["indices"]).reshape(-1, 3)

    head, neck = joint["Head"][1], joint["neck"][1]
    collar = head + COLLAR_UP * (head - neck)
    spine_low = min(joint[n][1] for n in bone_names if n.startswith("Spine"))
    waist = (joint["Hips"][1] + spine_low) / 2
    knee = (joint["LeftLeg"][1] + joint["RightLeg"][1]) / 2
    ankle = (joint["LeftFoot"][1] + joint["RightFoot"][1]) / 2
    boot = knee - BOOT_BELOW * (knee - ankle)
    wrist = {}  # side -> (point on the wrist plane, normal pointing into the hand)
    for side in ("Left", "Right"):
        h, f = joint[side + "Hand"], joint[side + "ForeArm"]
        wrist[side] = (h + WRIST_BACK * (f - h), (h - f) / np.linalg.norm(h - f))

    # Which chain moves each triangle (its dominant bone, by summed skin weight).
    arm_side = []
    for t in tris:
        w = {}
        for v in t:
            for j, wt in zip(joints[v], weights[v]):
                w[bone_names[j]] = w.get(bone_names[j], 0.0) + float(wt)
        bone = max(w, key=w.get)
        side = "Left" if bone.startswith("Left") else "Right" if bone.startswith("Right") else ""
        arm_side.append(side if side and bone[len(side):] in ARM_BONES else "")

    # Rasterise every triangle in UV space; each covered texel gets its interpolated 3D position.
    # A second pass grows the triangles by 1.5 texels into still-unowned texels (the gutter around
    # each UV island), so texture filtering at an island's edge reads that island's own region.
    owner = np.full((size, size), -1, np.int32)
    xyz = np.zeros((size, size, 3))

    def raster(ti, t, margin):
        p = uv[t] * size - 0.5  # texel centres sit at integer coordinates
        x0, y0 = np.floor(p.min(0) - margin).astype(int)
        x1, y1 = np.ceil(p.max(0) + margin).astype(int)
        x0, y0, x1, y1 = max(x0, 0), max(y0, 0), min(x1, size - 1), min(y1, size - 1)
        d = (p[1, 1] - p[2, 1]) * (p[0, 0] - p[2, 0]) + (p[2, 0] - p[1, 0]) * (p[0, 1] - p[2, 1])
        if x1 < x0 or y1 < y0 or abs(d) < 1e-9:
            return
        gx, gy = np.meshgrid(np.arange(x0, x1 + 1), np.arange(y0, y1 + 1))
        l0 = ((p[1, 1] - p[2, 1]) * (gx - p[2, 0]) + (p[2, 0] - p[1, 0]) * (gy - p[2, 1])) / d
        l1 = ((p[2, 1] - p[0, 1]) * (gx - p[2, 0]) + (p[0, 0] - p[2, 0]) * (gy - p[2, 1])) / d
        l2 = 1.0 - l0 - l1
        # barycentric -> distance (texels) from the opposite edge: l_i * height_i
        h = [abs(d) / max(np.linalg.norm(p[(i + 1) % 3] - p[(i + 2) % 3]), 1e-9) for i in range(3)]
        out = -np.minimum(np.minimum(l0 * h[0], l1 * h[1]), l2 * h[2])  # texels outside, <= 0 inside
        inside = out <= margin + 1e-6
        sub = owner[y0:y1 + 1, x0:x1 + 1]
        if margin > 0:  # growing: only into the gutter, and the nearest triangle wins
            near = gap[y0:y1 + 1, x0:x1 + 1]
            inside &= ((sub < 0) | (near > 0)) & (out < near)
            near[inside] = out[inside]
        if not inside.any():
            return
        q = l0[..., None] * pos[t[0]] + l1[..., None] * pos[t[1]] + l2[..., None] * pos[t[2]]
        sub[inside] = ti
        xyz[y0:y1 + 1, x0:x1 + 1][inside] = q[inside]

    for ti, t in enumerate(tris):
        raster(ti, t, 0.0)
    # Slivers too thin to contain a texel centre still own the texels under their corners and
    # middle, or those would inherit a region from whatever UV island happens to be nearest.
    for ti, t in enumerate(tris):
        for w in ((1, 0, 0), (0, 1, 0), (0, 0, 1), (1 / 3, 1 / 3, 1 / 3)):
            w = np.array(w)
            tx, ty = np.clip(np.rint(w @ uv[t] * size - 0.5).astype(int), 0, size - 1)
            if owner[ty, tx] < 0:
                owner[ty, tx] = ti
                xyz[ty, tx] = w @ pos[t]
    gap = np.where(owner < 0, np.inf, 0.0)  # grown texels: distance to their triangle
    for ti, t in enumerate(tris):
        raster(ti, t, 1.5)
    covered = owner >= 0
    y = xyz[..., 1]
    region = np.where(y >= collar, 0, np.where(y >= waist, 1, np.where(y >= boot, 2, 3)))  # body chain
    sides = np.array(arm_side + [""])[owner]  # owner -1 picks the trailing ""
    for side, (point, normal) in wrist.items():
        arm = covered & (sides == side)
        in_hand = ((xyz - point) @ normal) >= 0.0
        region[arm] = np.where(in_hand[arm], 4, 1)
    # Unused texels take the nearest region, so filtering across a UV seam never mixes regions.
    _, (iy, ix) = ndimage.distance_transform_edt(~covered, return_indices=True)
    region = region[iy, ix].astype(np.uint8)
    img = Image.fromarray(region, "L")
    Image.merge("RGB", (img, img, img)).save(dst, optimize=True)
    counts = np.bincount(region[covered], minlength=len(REGIONS))
    print("regions -> %s: cuts at collar %.2f, waist %.2f, boots %.2f m; %s" % (
        dst, collar, waist, boot, ", ".join("%s %d texels" % (REGIONS[i], counts[i]) for i in range(len(REGIONS)))))


TEXTURE_TRIM = 0.015  # fraction cut from each side (generated tiles sometimes come framed)
TEXTURE_BAND = 0.14   # width of the edge band that is blended for the seam, as a fraction


def cmd_texture(src, dst, size, lift, saturation=1.0):
    im = Image.open(src).convert("RGB")
    w, h = im.size
    t = int(round(min(w, h) * TEXTURE_TRIM))
    a = np.asarray(im.crop((t, t, w - t, h - t))).astype(np.float32)
    h, w = a.shape[:2]
    rolled = np.roll(a, (h // 2, w // 2), axis=(0, 1))
    # weight of the original: 1 in the middle, 0 at the edges (where the shifted copy is seamless)
    def ramp(n):
        d = np.minimum(np.arange(n), np.arange(n)[::-1]) / (n * TEXTURE_BAND)
        return np.clip(d, 0.0, 1.0)
    k = np.outer(ramp(h), ramp(w))
    k = (k * k * (3 - 2 * k))[..., None]  # smoothstep
    a = a * k + rolled * (1 - k)
    if saturation != 1.0:
        grey = a.mean(axis=2, keepdims=True)
        a = grey + (a - grey) * saturation
    out = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))
    treat(out, size, lift).save(dst, optimize=True)
    b = np.asarray(Image.open(dst)).astype(np.float32)
    print("texture -> %s (%dpx): seam %.1f vs %.1f inside" % (
        dst, size, np.abs(b[:, 0] - b[:, -1]).mean(), np.abs(b[:, 1:] - b[:, :-1]).mean()))


SPRITE_GROUND_SATURATION = 0.25  # pixels greyer than this are ground (soil, shadow), not plant


def cmd_sprite(src, dst, size):
    a = np.asarray(Image.open(src).convert("RGBA"))
    ys, xs = np.nonzero(a[:, :, 3] > 20)
    a = a[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    bottom = a.shape[0]
    while bottom > a.shape[0] // 2:
        row = a[bottom - 1]
        rgb = row[row[:, 3] > 20, :3].astype(np.float32)
        sat = (rgb.max(1) - rgb.min(1)) / np.maximum(rgb.max(1), 1)
        if len(rgb) and (sat < SPRITE_GROUND_SATURATION).mean() < 0.3:  # mostly plant
            break
        bottom -= 1
    cut = a.shape[0] - bottom
    a = a[:bottom]
    ys, xs = np.nonzero(a[:, :, 3] > 20)  # re-trim the sides after cutting the ground
    a = a[:, xs.min():xs.max() + 1]
    im = Image.fromarray(a)
    im = im.resize((size, max(1, round(size * im.height / im.width))), Image.LANCZOS)
    im.save(dst, optimize=True)
    print("sprite -> %s: %dx%d (cut %d ground rows)" % (dst, im.width, im.height, cut))


def cmd_icon(src, dst, size, inset, box=None):
    """An ability icon: generated images are a painted tile (often with its own frame) on a plain
    backdrop. Finds the tile (rows/columns mostly unlike the backdrop), cuts its painted frame off
    (`inset`, a fraction of the side; the game draws its own frame) and resizes it square."""
    a = np.asarray(Image.open(src).convert("RGB")).astype(np.float32)
    if box:  # the tile's inner square, by eye (x0,y0,x1,y1): dark tiles on dark backdrops fool the search
        x0, y0, x1, y1 = box
        im = Image.fromarray(a[y0:y1, x0:x1].astype(np.uint8)).resize((size, size), Image.LANCZOS)
        im.save(dst, optimize=True)
        print("icon -> %s: box %s" % (dst, box))
        return
    border = np.concatenate([a[0], a[-1], a[:, 0], a[:, -1]])
    diff = np.abs(a - np.median(border, 0)).max(2) > 28
    rows = np.nonzero(diff.mean(1) > 0.5)[0]
    cols = np.nonzero(diff.mean(0) > 0.5)[0]
    if len(rows) < a.shape[0] // 4 or len(cols) < a.shape[1] // 4:
        rows, cols = np.arange(a.shape[0]), np.arange(a.shape[1])  # full-bleed: keep it all
    y0, y1, x0, x1 = rows.min(), rows.max() + 1, cols.min(), cols.max() + 1
    side = min(y1 - y0, x1 - x0)
    cy, cx = (y0 + y1) // 2, (x0 + x1) // 2
    cut = int(side * inset)
    half = side // 2 - cut
    im = Image.fromarray(a[cy - half:cy + half, cx - half:cx + half].astype(np.uint8))
    im = im.resize((size, size), Image.LANCZOS)
    im.save(dst, optimize=True)
    print("icon -> %s: tile %dx%d at (%d, %d), %d px frame cut" % (dst, x1 - x0, y1 - y0, x0, y0, cut))


def make_matte(js, roughness=1.0):
    """Classic is hand-painted, not shiny: no metal, (almost) fully rough, no packed
    metal/roughness map. Meshy's defaults (roughness ~0.55) read as plastic under the sun."""
    for m in js.get("materials", []):
        pbr = m.setdefault("pbrMetallicRoughness", {})
        pbr["metallicFactor"] = 0.0
        pbr["roughnessFactor"] = roughness
        pbr.pop("metallicRoughnessTexture", None)


def _own_view(js, acc_index, new_views, data):
    """A bufferView holding `data` for accessor `acc_index`: its current one when nothing else uses
    it (so repeated passes don't pile up dead bytes), else a new one."""
    view = js["accessors"][acc_index]["bufferView"]
    users = sum(a.get("bufferView") == view for a in js["accessors"]) + sum(im.get("bufferView") == view for im in js.get("images", []))
    if users > 1:
        js["bufferViews"].append({"buffer": 0, "byteOffset": 0, "byteLength": 0})
        view = len(js["bufferViews"]) - 1
    new_views[view] = data
    return view


def drop_base(js, binary, new_views, cap=0.06, floor=0.025, lift=0.03):
    """A prop's base, made safe to stand on the ground: downward-facing triangles within `cap` of
    y = 0 are removed (nobody sees a prop's underside, and Meshy materials are double-sided, so
    that cap would show from above and z-fight with the ground), and upward-facing flat ones
    within `floor` of it (a tent's groundsheet) are lifted to `lift`, clear of the terrain.
    Appends bufferViews: pass `new_views` on to replace_views. Returns (removed, lifted)."""
    removed = lifted = 0
    for m in js["meshes"]:
        for pr in m["primitives"]:
            if "indices" not in pr:
                continue
            P = accessor(js, binary, pr["attributes"]["POSITION"]).astype(np.float64)
            T = accessor(js, binary, pr["indices"]).reshape(-1, 3)
            Q = P[T]
            n = np.cross(Q[:, 1] - Q[:, 0], Q[:, 2] - Q[:, 0])
            n /= np.linalg.norm(n, axis=1, keepdims=True) + 1e-12
            low = Q[:, :, 1].max(1)
            down = (low < cap) & (n[:, 1] < -0.9)
            up = (low < floor) & (n[:, 1] > 0.9)
            if down.any():
                keep = T[~down].astype(T.dtype).ravel()
                js["accessors"][pr["indices"]].update({"bufferView": _own_view(js, pr["indices"], new_views, keep.tobytes()),
                                                        "byteOffset": 0, "count": int(len(keep))})
                removed += int(down.sum())
            if up.any():
                vs = np.unique(T[up & ~down])
                P2 = P.copy()
                P2[vs, 1] = np.maximum(P2[vs, 1], lift)
                i = pr["attributes"]["POSITION"]
                js["accessors"][i].update({"bufferView": _own_view(js, i, new_views, P2.astype(np.float32).tobytes()),
                                           "byteOffset": 0, "min": P2.min(0).tolist(), "max": P2.max(0).tolist()})
                lifted += int(up.sum())
    return removed, lifted


def cmd_nobase(path):
    js, binary = read_glb(path)
    new_views = {}
    removed, lifted = drop_base(js, binary, new_views)
    write_glb(path, js, replace_views(js, binary, new_views))
    print("nobase -> %s (%d base triangles removed, %d floor triangles lifted)" % (path, removed, lifted))


def flesh_amount(rgb):
    """0..1 per texel: how much it looks like bare skin (warm peach / pink hue, light, moderately
    saturated). Meshy's armour retextures paint the body's exposed bits (a collar's neck, sandal
    toes, bare arms) in their own, pinker flesh tone; those texels are let through to the base body
    instead, so every outfit shares the body's own skin."""
    a = rgb.astype(np.float64) / 255.0
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    mx, mn = a.max(-1), a.min(-1)
    d = np.maximum(mx - mn, 1e-6)
    h = np.where(mx == r, ((g - b) / d) % 6, np.where(mx == g, (b - r) / d + 2, (r - g) / d + 4)) * 60
    h = np.where(h > 300, h - 360, h)
    s = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0)

    def band(x, lo, hi, soft):
        return np.clip((x - (lo - soft)) / soft, 0, 1) * np.clip(((hi + soft) - x) / soft, 0, 1)
    return (band(h, 9, 30, 5) * band(s, 0.14, 0.5, 0.05) * np.clip((mx - 0.5) / 0.12, 0, 1)
            * ((r > g) & (g >= b * 0.95)))


def cmd_fleshmask(skin_png, regions_png):
    """Writes the skin texture back with alpha = not-flesh over the armour regions (everything but
    the head), so Outfit.dress blends the base body through where the armour painted skin."""
    img = Image.open(skin_png).convert("RGB")
    rgb = np.asarray(img)
    reg = np.asarray(Image.open(regions_png).convert("L").resize(img.size, Image.NEAREST))
    f = flesh_amount(rgb) * (reg > 0)
    alpha = Image.fromarray((np.clip(1.0 - f * 1.4, 0, 1) * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.0))
    out = img.copy()
    out.putalpha(alpha)
    out.save(skin_png, optimize=True)
    print("fleshmask -> %s: %.1f%% of texels let through to the body" % (skin_png, 100.0 * (f > 0.5).mean()))



# ------------------------------------------------------------------ clip tweaks

def _tqmul(a, b):
    """Hamilton product of (N,4) or (4,) quaternions in glTF order x, y, z, w."""
    ax, ay, az, aw = np.moveaxis(np.asarray(a, np.float64), -1, 0)
    bx, by, bz, bw = np.moveaxis(np.asarray(b, np.float64), -1, 0)
    return np.stack([aw * bx + ax * bw + ay * bz - az * by, aw * by - ax * bz + ay * bw + az * bx,
                     aw * bz + ax * by - ay * bx + az * bw, aw * bw - ax * bx - ay * by - az * bz], -1)


def _tqinv(q):
    q = np.array(q, np.float64)
    q[..., :3] *= -1
    return q


def _tqpow(q, k):
    """q^k for unit quaternions (scales the rotation angle by k about the same axis)."""
    q = np.array(q, np.float64)
    k = np.asarray(k, np.float64)
    q *= np.where(q[..., 3:4] < 0, -1, 1)
    ang = 2 * np.arccos(np.clip(q[..., 3], -1, 1))
    s = np.sin(ang / 2)
    axis = np.where(s[..., None] > 1e-8, q[..., :3] / np.maximum(s, 1e-8)[..., None], [1, 0, 0])
    a = ang * k
    return np.concatenate([axis * np.sin(a / 2)[..., None], np.cos(a / 2)[..., None]], -1)


def _tqmean(qs):
    """Mean rotation of a key set (sign-aligned average, renormalized)."""
    qs = np.array(qs, np.float64)
    qs *= np.where((qs @ qs[0])[:, None] < 0, -1, 1)
    m = qs.mean(0)
    return m / np.linalg.norm(m)


def _tslerp(a, b, w):
    return _tqmul(a, _tqpow(_tqmul(_tqinv(a), b), w))


def _teuler_q(deg):
    from scipy.spatial.transform import Rotation
    return Rotation.from_euler("xyz", deg, degrees=True).as_quat()


def _clip_tracks(js, binary, anim):
    """{(node, path): [times, values, interpolation]} of one animation."""
    tracks = {}
    for c in anim["channels"]:
        smp = anim["samplers"][c["sampler"]]
        tracks[(c["target"]["node"], c["target"]["path"])] = [
            np.array(accessor(js, binary, smp["input"]), np.float64),
            np.array(accessor(js, binary, smp["output"]), np.float64), smp.get("interpolation", "LINEAR")]
    return tracks


def _sample_track(times, vals, t, path):
    t = np.clip(t, times[0], times[-1])
    j = np.clip(np.searchsorted(times, t), 1, len(times) - 1) if len(times) > 1 else np.zeros_like(t, int)
    if len(times) == 1:
        return np.repeat(vals[:1], len(t), 0)
    a = ((t - times[j - 1]) / np.maximum(times[j] - times[j - 1], 1e-9))[:, None]
    if path == "rotation":
        return _tslerp(vals[j - 1], vals[j], a[:, 0])
    return vals[j - 1] * (1 - a) + vals[j] * a


def _tsample_grid(tr, grid):
    vals = _sample_track(tr[0], tr[1], grid, "rotation")
    return vals / np.linalg.norm(vals, axis=-1, keepdims=True)


def cmd_tweak(glb, src_name, new_name, ops):
    """Writes clip `new_name` into `glb` (in place): a copy of `src_name` with pose edits, in order:
         amp:BONES:k          scale each bone's motion around its average pose by k (k > 1:
                              bigger strides / swings, k < 1: calmer)
         rot:BONES:x,y,z      add a fixed local rotation (degrees, the bone's own axes)
         blend:CLIP:BONES:w   move the bones w of the way to another clip's pose (its time scaled
                              to this clip's length), e.g. a crouch's legs with an idle's arms
         wave:BONES:x,y,z:n[:phase]  add a slow sine sway (degrees per axis), n whole periods
                              over the clip (so it still loops), phase in turns; breathing,
                              weight sway, a look around
         hips:x,y,z           shift the hips (rig units, centimetres on Meshy rigs)
         speed:k              play k times faster (shorter clip)
       BONES: comma-separated names or fnmatch patterns (*UpLeg,*Leg,Spine*), * for all."""
    import fnmatch
    js, binary = read_glb(glb)
    anims = js.get("animations", [])
    src = next((a for a in anims if a.get("name") == src_name), None)
    if src is None:
        sys.exit("no clip %r in %s (has: %s)" % (src_name, glb, [a.get("name") for a in anims]))
    names = {i: n.get("name", "") for i, n in enumerate(js["nodes"])}
    tracks = _clip_tracks(js, binary, src)
    length = max(t[0][-1] for t in tracks.values())

    def bones(spec):
        pats = spec.split(",")
        return {i for i, n in names.items() if any(fnmatch.fnmatchcase(n, p) for p in pats)}

    for op in ops:
        kind, _, rest = op.partition(":")
        if kind == "amp":
            spec, k = rest.rsplit(":", 1)
            for (node, path), tr in tracks.items():
                if path == "rotation" and node in bones(spec):
                    m = _tqmean(tr[1])
                    tr[1] = _tqmul(m, _tqpow(_tqmul(_tqinv(m), tr[1]), float(k)))
        elif kind == "rot":
            spec, deg = rest.rsplit(":", 1)
            off = _teuler_q([float(v) for v in deg.split(",")])
            for (node, path), tr in tracks.items():
                if path == "rotation" and node in bones(spec):
                    tr[1] = _tqmul(tr[1], off)
        elif kind == "blend":
            other_name, spec, w = rest.split(":")
            other = next((a for a in anims if a.get("name") == other_name), None)
            if other is None:
                sys.exit("no clip %r to blend with" % other_name)
            otr = _clip_tracks(js, binary, other)
            olen = max(t[0][-1] for t in otr.values())
            for (node, path), tr in tracks.items():
                if path == "rotation" and node in bones(spec) and (node, path) in otr:
                    o = _sample_track(otr[(node, path)][0], otr[(node, path)][1], tr[0] / length * olen, path)
                    o *= np.where(np.sum(o * tr[1], -1, keepdims=True) < 0, -1, 1)
                    tr[1] = _tslerp(tr[1], o, float(w))
        elif kind == "wave":
            # resampled onto a 30 fps grid so a sway can ride on tracks that have only a few keys
            parts = rest.split(":")
            spec, deg, cycles = parts[0], [float(v) for v in parts[1].split(",")], float(parts[2])
            phase = float(parts[3]) if len(parts) > 3 else 0.0
            grid = np.linspace(0.0, length, max(2, int(round(length * 30)) + 1))
            for (node, path), tr in tracks.items():
                if path == "rotation" and node in bones(spec):
                    vals = _tsample_grid(tr, grid)
                    w = np.sin(2 * np.pi * (cycles * grid / length + phase))
                    offs = np.array([_teuler_q(np.array(deg) * x) for x in w])
                    tr[0], tr[1] = grid, _tqmul(vals, offs)
        elif kind == "hips":
            d = np.array([float(v) for v in rest.split(",")])
            for (node, path), tr in tracks.items():
                if path == "translation" and names[node] == "Hips":
                    tr[1] = tr[1] + d
        elif kind == "speed":
            for tr in tracks.values():
                tr[0] = tr[0] / float(rest)
        else:
            sys.exit("unknown tweak %r" % op)

    new_views = {}

    def add(data, like):
        data = np.ascontiguousarray(data, np.float32)
        js["bufferViews"].append({"buffer": 0, "byteOffset": 0, "byteLength": 0})
        new_views[len(js["bufferViews"]) - 1] = data.tobytes()
        a = {k: v for k, v in like.items() if k not in ("byteOffset", "min", "max", "sparse", "normalized")}
        a.update({"bufferView": len(js["bufferViews"]) - 1, "componentType": 5126, "count": len(data)})
        if "min" in like:
            flat = data.reshape(len(data), -1)
            a["min"], a["max"] = flat.min(0).tolist(), flat.max(0).tolist()
        js["accessors"].append(a)
        return len(js["accessors"]) - 1

    clip = {"name": new_name, "samplers": [], "channels": []}
    for c in src["channels"]:
        key = (c["target"]["node"], c["target"]["path"])
        smp = src["samplers"][c["sampler"]]
        times, vals, interp = tracks[key]
        if key[1] == "rotation":
            vals = vals / np.linalg.norm(vals, axis=-1, keepdims=True)
        clip["samplers"].append({"input": add(times, js["accessors"][smp["input"]]),
                                 "output": add(vals, js["accessors"][smp["output"]]), "interpolation": interp})
        clip["channels"].append({"sampler": len(clip["samplers"]) - 1, "target": dict(c["target"])})
    js["animations"] = [a for a in anims if a.get("name") != new_name] + [clip]
    prune_unused(js, new_views)
    write_glb(glb, js, replace_views(js, binary, new_views))
    print("tweak %s -> %s in %s: %s" % (src_name, new_name, glb, " ".join(ops) or "copy"))


def cmd_clips(dst, src, specs):
    """Copies animation clips from `src` (another Meshy animation of the same rig) into `dst`,
    in place: each spec is "SourceName:name" (the clip's name in src, the name to give it in dst;
    an existing clip of that name is replaced). Channels are matched to dst's nodes by name, so
    the model, its textures, fists and other clips are left exactly as they are."""
    js, binary = read_glb(dst)
    sj, sb = read_glb(src)
    node_of = {n.get("name"): i for i, n in enumerate(js["nodes"])}
    new_views = {}

    def copy_accessor(i):
        a = dict(sj["accessors"][i])
        data = accessor(sj, sb, i)
        js["bufferViews"].append({"buffer": 0, "byteOffset": 0, "byteLength": 0})
        new_views[len(js["bufferViews"]) - 1] = np.ascontiguousarray(data).tobytes()
        a["bufferView"] = len(js["bufferViews"]) - 1
        a.pop("byteOffset", None)
        js["accessors"].append(a)
        return len(js["accessors"]) - 1

    done = []
    for spec in specs:
        src_name, name = spec.split(":") if ":" in spec else (spec, spec)
        anim = next((a for a in sj.get("animations", []) if a.get("name") == src_name), None)
        if anim is None:
            sys.exit("no clip %r in %s (has: %s)" % (src_name, src, [a.get("name") for a in sj.get("animations", [])]))
        clip = {"name": name, "samplers": [], "channels": []}
        for s in anim["samplers"]:
            clip["samplers"].append({"input": copy_accessor(s["input"]), "output": copy_accessor(s["output"]),
                                     "interpolation": s.get("interpolation", "LINEAR")})
        skipped = 0
        for c in anim["channels"]:
            node = node_of.get(sj["nodes"][c["target"]["node"]].get("name"))
            if node is None:
                skipped += 1
                continue
            clip["channels"].append({"sampler": c["sampler"], "target": {"node": node, "path": c["target"]["path"]}})
        js["animations"] = [a for a in js.get("animations", []) if a.get("name") != name] + [clip]
        done.append("%s -> %s (%d channels%s)" % (src_name, name, len(clip["channels"]), ", %d unmatched" % skipped if skipped else ""))
    prune_unused(js, new_views)
    write_glb(dst, js, replace_views(js, binary, new_views))
    print("clips into %s: %s" % (dst, "; ".join(done)))


def cmd_matte(path, roughness):
    js, binary = read_glb(path)
    make_matte(js, roughness)
    write_glb(path, js, binary)
    print("matte -> %s (roughness %.2f)" % (path, roughness))


def cmd_rigid(src, dst, kind, size, texture=256, along_x=False, grip_at=None):
    js, binary = read_glb(src)
    prims = [pr for m in js["meshes"] for pr in m["primitives"]]  # smart topology can split parts
    pos_ids = sorted({pr["attributes"]["POSITION"] for pr in prims})
    nrm_ids = sorted({pr["attributes"]["NORMAL"] for pr in prims if "NORMAL" in pr["attributes"]})
    P = np.concatenate([accessor(js, binary, i).astype(np.float64) for i in pos_ids])
    c = P.mean(0)
    _, _, vt = np.linalg.svd(P - c, full_matrices=False)
    axes = vt  # rows: longest, middle, shortest extent
    if kind == "weapon":
        along = axes[0]
        t = (P - c) @ along
        width = np.abs((P - c) @ axes[1])
        bins = np.linspace(t.min(), t.max(), 41)
        idx = np.clip(np.digitize(t, bins) - 1, 0, 39)
        prof = np.array([width[idx == i].max() if (idx == i).any() else 0 for i in range(40)])
        guard = (bins[prof.argmax()] + bins[prof.argmax() + 1]) / 2
        if grip_at is not None:
            # A hafted weapon (axe, club, staff, wand): no guard, the head is the heavier end
            # (more width in its outer quarter); the hand holds the haft `grip_at` of the length
            # up from the butt.
            if prof[30:].sum() >= prof[:10].sum():
                blade_dir, butt = along, t.min()
            else:
                blade_dir, butt = -along, t.max()
            length = t.max() - t.min()
            grip = c + along * (butt + (grip_at * length if butt == t.min() else -grip_at * length))
        # A blade: the handle is the short side of the guard, the blade the long one.
        elif (t.max() - guard) > (guard - t.min()):
            blade_dir, handle_end = along, t.min()
            grip = c + along * ((guard + handle_end) / 2)
        else:
            blade_dir, handle_end = -along, t.max()
            grip = c + along * ((guard + handle_end) / 2)
        z = -blade_dir                      # blade along -Z
        y = axes[1] - z * (axes[1] @ z)     # width along Y
        y /= np.linalg.norm(y)
        x = np.cross(y, z)
        scale = size / (t.max() - t.min())
        origin = grip
    elif kind == "shoulder":
        # Kept upright as generated (+Y up), centred on its bounding box so it can sit around the
        # shoulder joint, and scaled to --size metres wide.
        x, y, z = np.eye(3)
        scale = size / max(np.ptp(P[:, 0]), np.ptp(P[:, 2]))
        origin = (P.min(0) + P.max(0)) / 2
    else:
        # Prop: upright, standing on the origin (bottom centre of its bounding box), --size metres
        # tall; with --along x its longest horizontal extent is turned onto X and --size is that
        # length instead (fence sections, logs).
        x, y, z = np.eye(3)
        if along_x:
            h = axes[0] - np.array([0, 1, 0]) * axes[0][1]
            h /= np.linalg.norm(h)
            x, z = h, np.cross(h, np.array([0.0, 1.0, 0.0]))
        R0 = np.stack([x, y, z])
        Q = P @ R0.T
        lo, hi = Q.min(0), Q.max(0)
        scale = size / ((hi[0] - lo[0]) if along_x else (hi[1] - lo[1]))
        origin = R0.T @ np.array([(lo[0] + hi[0]) / 2, lo[1], (lo[2] + hi[2]) / 2])
    R = np.stack([x, y, z])  # rows = new axes in old coords
    new_views = {}
    for i in pos_ids:
        P2 = ((accessor(js, binary, i).astype(np.float64) - origin) @ R.T) * scale
        new_views[js["accessors"][i]["bufferView"]] = P2.astype(np.float32).tobytes()
        js["accessors"][i]["min"] = P2.min(0).tolist()
        js["accessors"][i]["max"] = P2.max(0).tolist()
    for i in nrm_ids:
        N2 = accessor(js, binary, i).astype(np.float64) @ R.T
        N2 /= np.linalg.norm(N2, axis=1, keepdims=True) + 1e-12
        new_views[js["accessors"][i]["bufferView"]] = N2.astype(np.float32).tobytes()
    retexture(js, binary, new_views, texture, 1.1)
    make_matte(js, 1.0 if kind == "prop" else 0.85)  # weapons keep the faintest sheen on metal
    for n in js["nodes"]:
        for k in ("matrix", "rotation", "translation", "scale"):
            n.pop(k, None)
    write_glb(dst, js, replace_views(js, binary, new_views))
    if kind == "prop":
        cmd_nobase(dst)  # the base cap would z-fight with the ground
    Pn = ((P - origin) @ R.T) * scale
    tris = sum(js["accessors"][pr["indices"]]["count"] // 3 for pr in prims if "indices" in pr)
    print("%s -> %s: extents %s m, %d triangles" % (kind, dst, np.round(np.ptp(Pn, axis=0), 3).tolist(), tris))


# ------------------------------------------------------------------ quadrupeds

def _quat_x(deg):
    a = np.radians(deg) / 2
    return [float(np.sin(a)), 0.0, 0.0, float(np.cos(a))]


def _quat_y(deg):
    a = np.radians(deg) / 2
    return [0.0, float(np.sin(a)), 0.0, float(np.cos(a))]


def _slab_clusters(Q, y0, y1, radius):
    """Horizontal clusters of the vertices between heights y0 and y1 (legs show up as separate ones)."""
    pts = Q[(Q[:, 1] >= y0) & (Q[:, 1] < y1)][:, [0, 2]]
    if len(pts) == 0:
        return []
    cell = {}
    for i, (x, z) in enumerate(pts):
        cell.setdefault((int(x // radius), int(z // radius)), []).append(i)
    parent = list(range(len(pts)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    for (cx, cz), idx in cell.items():
        near = [j for dx in (-1, 0, 1) for dz in (-1, 0, 1) for j in cell.get((cx + dx, cz + dz), [])]
        for i in idx:
            for j in near:
                if j > i and np.hypot(*(pts[i] - pts[j])) < radius:
                    parent[find(i)] = find(j)
    groups = {}
    for i in range(len(pts)):
        groups.setdefault(find(i), []).append(i)
    return sorted([pts[g] for g in groups.values() if len(g) >= 3], key=len, reverse=True)


def cmd_quadruped(src, dst, length, texture=512, front="+z"):
    """A static four-legged Meshy model -> skinned, animated glb (Meshy's auto-rig is humanoid only).
    The body is turned to face -Z (Godot forward), stood on the origin and scaled to `length` metres
    nose to tail. Legs are found as the separate columns under the belly; each gets a hip and a knee
    bone, plus body, head and tail. Clips: idle, walk (a trot), attack (a lunge)."""
    js, binary = read_glb(src)
    prim = js["meshes"][0]["primitives"][0]
    pi, ni = prim["attributes"]["POSITION"], prim["attributes"].get("NORMAL")
    P = accessor(js, binary, pi).astype(np.float64)
    N = accessor(js, binary, ni).astype(np.float64) if ni is not None else None
    turn = {"+z": 180.0, "-z": 0.0, "+x": 90.0, "-x": -90.0}[front]  # head end -> -Z
    a = np.radians(turn)
    R = np.array([[np.cos(a), 0, np.sin(a)], [0, 1, 0], [-np.sin(a), 0, np.cos(a)]])
    Q = P @ R.T
    lo, hi = Q.min(0), Q.max(0)
    scale = length / (hi[2] - lo[2])
    Q = (Q - np.array([(lo[0] + hi[0]) / 2, lo[1], (lo[2] + hi[2]) / 2])) * scale
    H = Q[:, 1].max()
    L = length
    # legs: the separate columns at the ground; the belly is the lowest point of the torso between
    # the front and back legs, away from any leg column
    r = 0.06 * L
    feet = [c.mean(0) for c in _slab_clusters(Q, 0.0, 0.08 * H, r)[:4]]
    assert len(feet) == 4, "expected four feet, found %d" % len(feet)
    feet = sorted(feet, key=lambda f: f[1])  # front (-z) first
    front_z = (feet[0][1] + feet[1][1]) / 2
    back_z = (feet[2][1] + feet[3][1]) / 2
    dist = np.min([np.hypot(Q[:, 0] - f[0], Q[:, 2] - f[1]) for f in feet], axis=0)
    between = (Q[:, 2] > front_z + 0.08 * L) & (Q[:, 2] < back_z - 0.08 * L) & (dist > 0.1 * L)
    belly = float(Q[between, 1].min())
    upper = H - belly
    body_y = belly + 0.35 * upper
    hip_y = belly + 0.15 * upper
    knee_y = belly * 0.5
    head = np.array([0.0, belly + 0.6 * upper, front_z - 0.08 * L])
    tail = np.array([0.0, belly + 0.6 * upper, back_z + 0.08 * L])
    body = np.array([0.0, body_y, (front_z + back_z) / 2])
    names = ["body", "head", "tail"]
    world = [body, head, tail]
    parents = [-1, 0, 0]
    legs = []
    for f in feet:
        side = "L" if f[0] > 0 else "R"
        end = "front" if f[1] < (front_z + back_z) / 2 else "back"
        hi_i = len(names)
        names += ["%s_%s_upper" % (end, side), "%s_%s_lower" % (end, side)]
        world += [np.array([f[0], hip_y, f[1]]), np.array([f[0], knee_y, f[1]])]
        parents += [0, hi_i]
        legs.append((end, side, hi_i, f))

    # weights: legs below the belly by their nearest foot (knee blend), head/tail ramps, body the rest
    n = len(Q)
    J = np.zeros((n, 4), np.uint16)
    W = np.zeros((n, 4), np.float32)
    band = 0.06 * L
    for v in range(n):
        x, y, z = Q[v]
        bones = {}
        d = [np.hypot(x - f[0], z - f[1]) for (_, _, _, f) in legs]
        k = int(np.argmin(d))
        if y < belly + 0.1 * upper and d[k] < 0.14 * L:
            _, _, hi_i, _ = legs[k]
            t_knee = np.clip((y - (knee_y - 0.05 * H)) / (0.1 * H), 0, 1)       # 0 below knee
            t_body = np.clip((y - (belly - 0.02 * H)) / (0.12 * upper + 0.04 * H), 0, 1)  # 1 into the body
            bones[hi_i + 1] = (1 - t_knee) * (1 - t_body)
            bones[hi_i] = t_knee * (1 - t_body)
            bones[0] = t_body
        else:
            th = np.clip((head[2] + band / 2 - z) / band, 0, 1)
            tt = np.clip((z - (tail[2] - band / 2)) / band, 0, 1) if y > belly else 0.0
            bones[1] = th
            bones[2] = tt * (1 - th)
            bones[0] = 1 - bones[1] - bones[2]
        top = sorted(((w, b) for b, w in bones.items() if w > 1e-4), reverse=True)[:4]
        tot = sum(w for w, _ in top)
        for i, (w, b) in enumerate(top):
            J[v, i] = b
            W[v, i] = w / tot

    # nodes: an armature root holding the joint tree and the skinned mesh
    base = len(js["nodes"])
    joint_nodes = []
    for i, nm in enumerate(names):
        rel = world[i] - (world[parents[i]] if parents[i] >= 0 else 0)
        joint_nodes.append({"name": nm, "translation": [float(c) for c in rel]})
    for i, p in enumerate(parents):
        if p >= 0:
            joint_nodes[p].setdefault("children", []).append(base + i)
    mesh_node = next(i for i, nd in enumerate(js["nodes"]) if "mesh" in nd)
    for k in ("matrix", "rotation", "translation", "scale"):
        js["nodes"][mesh_node].pop(k, None)
    js["nodes"] += joint_nodes
    js["nodes"].append({"name": "rig", "children": [base, mesh_node]})
    rig = len(js["nodes"]) - 1
    for nd in js["nodes"][:base]:
        if "children" in nd:
            nd["children"] = [c for c in nd["children"] if c != mesh_node]
    js["scenes"][js.get("scene", 0)]["nodes"] = [rig]
    js["nodes"][mesh_node]["skin"] = 0

    new_views = {js["accessors"][pi]["bufferView"]: Q.astype(np.float32).tobytes()}
    js["accessors"][pi]["min"] = Q.min(0).tolist()
    js["accessors"][pi]["max"] = Q.max(0).tolist()
    if N is not None:
        N2 = N @ R.T
        N2 /= np.linalg.norm(N2, axis=1, keepdims=True) + 1e-12
        new_views[js["accessors"][ni]["bufferView"]] = N2.astype(np.float32).tobytes()

    def add(data, ctype, atype, **extra):
        js["bufferViews"].append({"buffer": 0, "byteOffset": 0, "byteLength": 0})
        new_views[len(js["bufferViews"]) - 1] = data.tobytes()
        js["accessors"].append({"bufferView": len(js["bufferViews"]) - 1, "componentType": ctype,
                                "count": len(data), "type": atype, **extra})
        return len(js["accessors"]) - 1
    prim["attributes"]["JOINTS_0"] = add(J, 5123, "VEC4")
    prim["attributes"]["WEIGHTS_0"] = add(W, 5126, "VEC4")
    ibm = np.stack([np.eye(4) for _ in names])
    for i, w in enumerate(world):
        ibm[i][:3, 3] = -w
    js["skins"] = [{"joints": [base + i for i in range(len(names))], "skeleton": base,
                    "inverseBindMatrices": add(np.ascontiguousarray(ibm.transpose(0, 2, 1)).astype(np.float32).reshape(-1, 16), 5126, "MAT4")}]

    # animations: per clip, per bone a function t -> rotation (and the body a translation)
    def clip(name, dur, rot, move=None, fps=15):
        ts = np.linspace(0, dur, int(dur * fps) + 1).astype(np.float32)
        t_acc = add(ts, 5126, "SCALAR", min=[0.0], max=[float(dur)])
        samplers, channels = [], []
        for b, f in rot.items():
            out = np.array([f(t) for t in ts], np.float32)
            samplers.append({"input": t_acc, "output": add(out, 5126, "VEC4"), "interpolation": "LINEAR"})
            channels.append({"sampler": len(samplers) - 1, "target": {"node": base + b, "path": "rotation"}})
        if move:
            out = np.array([world[0] + move(t) for t in ts], np.float32)
            samplers.append({"input": t_acc, "output": add(out, 5126, "VEC3"), "interpolation": "LINEAR"})
            channels.append({"sampler": len(samplers) - 1, "target": {"node": base, "path": "translation"}})
        js.setdefault("animations", []).append({"name": name, "samplers": samplers, "channels": channels})

    tau = 2 * np.pi
    idle_d, walk_d, atk_d = 2.4, 0.7, 0.9
    idle = {1: lambda t: _quat_x(3 * np.sin(tau * t / idle_d)), 2: lambda t: _quat_y(10 * np.sin(tau * t / idle_d * 2))}
    walk = {1: lambda t: _quat_x(4 * np.sin(2 * tau * t / walk_d)), 2: lambda t: _quat_y(14 * np.sin(tau * t / walk_d))}
    attack = {}
    for end, side, hi_i, f in legs:
        ph = 0.0 if (end == "front") == (side == "L") else np.pi  # trot: diagonal pairs together
        walk[hi_i] = (lambda ph: lambda t: _quat_x(26 * np.sin(tau * t / walk_d + ph)))(ph)
        walk[hi_i + 1] = (lambda ph: lambda t: _quat_x(-28 * max(0.0, np.sin(tau * t / walk_d + ph + np.pi / 2))))(ph)
        idle[hi_i] = lambda t: _quat_x(0.0)
        # the lunge: front legs reach, back legs push
        attack[hi_i] = (lambda s: lambda t: _quat_x(s * 18 * np.sin(np.pi * np.clip((t - 0.25) / 0.4, 0, 1))))(1 if end == "front" else -1)

    def lunge(t):  # wind up (0-0.25 s), strike (0.25-0.45), recover
        if t < 0.25:
            return -np.sin(np.pi / 2 * t / 0.25)
        if t < 0.45:
            return -1 + 2.6 * np.sin(np.pi / 2 * (t - 0.25) / 0.2)
        return 1.6 * (1 - (t - 0.45) / (atk_d - 0.45))
    attack[0] = lambda t: _quat_x(-4 * lunge(t))
    attack[1] = lambda t: _quat_x(-14 * lunge(t))
    attack[2] = lambda t: _quat_y(20 * np.sin(tau * t / atk_d))
    clip("idle", idle_d, idle, lambda t: np.array([0, 0.012 * H * np.sin(tau * t / idle_d), 0]))
    clip("walk", walk_d, walk, lambda t: np.array([0, 0.025 * H * abs(np.sin(tau * t / walk_d)), 0]))
    clip("attack", atk_d, attack, lambda t: np.array([0, 0, -0.08 * L * max(0.0, lunge(t))]))

    retexture(js, binary, new_views, texture, 1.1)
    for m in js.get("materials", []):
        pbr = m.setdefault("pbrMetallicRoughness", {})
        pbr["metallicFactor"] = 0.0
        pbr["roughnessFactor"] = 1.0
        pbr.pop("metallicRoughnessTexture", None)
    write_glb(dst, js, replace_views(js, binary, new_views))
    print("quadruped -> %s: %.2f m long, %.2f m tall, belly %.2f m; legs at %s" % (
        dst, L, H, belly, ", ".join("%s %s (%.2f, %.2f)" % (e, s_, f[0], f[1]) for e, s_, _, f in legs)))


def main():
    cmd, src = sys.argv[1], sys.argv[2]
    dst = sys.argv[3] if len(sys.argv) > 3 else ""
    opts = dict(zip(sys.argv[4::2], sys.argv[5::2]))
    size = int(opts.get("--texture", 512))
    lift = float(opts.get("--brighten", 1.1))
    if cmd == "model":
        cmd_model(src, dst, size, lift)
    elif cmd == "skin":
        cmd_skin(src, dst, size, lift)
    elif cmd == "regions":
        cmd_regions(src, dst, size)
    elif cmd == "fist":
        cmd_fist(src, dst)
    elif cmd == "texture":
        cmd_texture(src, dst, size, float(opts.get("--brighten", 1.0)), float(opts.get("--saturation", 1.0)))
    elif cmd == "sprite":
        cmd_sprite(src, dst, int(opts.get("--texture", 256)))
    elif cmd == "nobase":
        cmd_nobase(src)
    elif cmd == "clips":
        cmd_clips(src, dst, sys.argv[4:])
    elif cmd == "tweak":
        cmd_tweak(src, dst, sys.argv[4], sys.argv[5:])
    elif cmd == "fleshmask":
        cmd_fleshmask(src, dst or "assets/hero_regions.png")
    elif cmd == "matte":
        cmd_matte(src, float(dst) if dst else 1.0)
    elif cmd == "icon":
        cmd_icon(src, dst, int(opts.get("--texture", 128)), float(opts.get("--inset", 0.07)),
                 [int(v) for v in opts["--box"].split(",")] if "--box" in opts else None)
    elif cmd == "quadruped":
        cmd_quadruped(src, dst, float(opts.get("--size", 1.7)), int(opts.get("--texture", 512)), opts.get("--front", "+z"))
    elif cmd == "rigid":
        kind = opts.get("--kind", "weapon")
        cmd_rigid(src, dst, kind, float(opts.get("--size", {"weapon": 1.05, "shoulder": 0.34}.get(kind, 1.0))),
                  int(opts.get("--texture", 256)), opts.get("--along") == "x",
                  float(opts["--grip"]) if "--grip" in opts else None)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
