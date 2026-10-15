"""Convert the HD player models (Renderpeople characters in "HD Model/") into drivers exactly like the
SLRR ones: the same 14 parts, pivots and rig.json, so slrrDrivers.lua runs them unchanged.

    python tools/convert_hd.py [BLENDER_EXE]

Each FBX is read by Blender (tools/fbx_dump.py), its skeleton reduced to the SLRR driver's Biped bones
(spine_02 + spine_03 -> Spine1, twist bones into their limb, face and finger bones into head and hand),
put in SLRR's units and axes (fingers curled into a grip first, like SLRR's modelled fists), and fed
through convert_drivers.bake_from: the same seated pose, split and
rig. The eye comes from the model's own eye bones. Textures go to the driver caps (colour and normal
1024, roughness 256 from the inverted gloss map).

Output: art/slrr_drivers/models/<model>/ and art/slrr_drivers/<id>/ (driver.json, materials, textures).
The source folder stays out of git (size); the converted output ships, credited in CREDITS.md.
"""
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
ARGS = sys.argv[1:]
sys.argv = sys.argv[:1]          # convert_drivers reads its own argv at import
import convert_drivers as cd  # noqa: E402

BLENDER = ARGS[0] if ARGS else r"C:\Program Files\Blender Foundation\Blender 3.6\blender.exe"
SRC = os.path.join(HERE, "..", "HD Model")
CACHE = os.path.join(HERE, "..", "build", "hd")
Image.MAX_IMAGE_PIXELS = None

# id, display name, folder, fbx, texture stem, model name
CHARACTERS = [
    ("hd_eric", "Eric (HD)", "male 1", "rp_eric_rigged_001_zup_a.fbx", "rp_eric_rigged_001", "rp_eric"),
    ("hd_manuel", "Manuel (HD)", "male 2", "rp_manuel_animated_001_dancing.fbx", "rp_manuel_animated_001", "rp_manuel"),
    ("hd_alison", "Alison (HD)", "female 1", "rp_alison_rigged_001_zup_a.fbx", "rp_alison_rigged_001", "rp_alison"),
    ("hd_carla", "Carla (HD)", "female 2", "rp_carla_rigged_001_zup_a.fbx", "rp_carla_rigged_001", "rp_carla"),
]
COLOR_PX, NORMAL_PX, ROUGH_PX = 1024, 1024, 256

# Renderpeople bone -> SLRR driver bone (the reduced skeleton keeps the first bone listed per target)
FIXED = {"root": "Bip01", "hip": "Bip01 Pelvis", "spine_01": "Bip01 Spine", "spine_02": "Bip01 Spine1",
         "spine_03": "Bip01 Spine1", "neck": "Bip01 Neck", "head": "Bip01 Head"}
SIDED = {"shoulder": "Clavicle", "upperarm": "UpperArm", "upperarm_twist": "UpperArm", "lowerarm": "Forearm",
         "lowerarm_twist": "Forearm", "hand": "Hand", "upperleg": "Thigh", "upperleg_twist": "Thigh",
         "lowerleg": "Calf", "lowerleg_twist": "Calf", "foot": "Foot", "ball": "Toe0", "foot_end": "Toe0"}


def target(name, parent_target):
    if name in FIXED:
        return FIXED[name]
    for side in ("l", "r"):
        if name.endswith("_" + side):
            stem = name[:-2]
            if stem in SIDED:
                return "Bip01 %s %s" % (side.upper(), SIDED[stem])
    return parent_target          # face, fingers, ends: part of their parent's bone


def to_slrr(p):
    """Blender (m, z up, facing -y) -> SLRR (cm, x right, y up, z back)."""
    x, y, z = p
    return np.array([-x, z, y]) * 100.0


def load(fbx):
    os.makedirs(CACHE, exist_ok=True)
    out = os.path.join(CACHE, os.path.splitext(os.path.basename(fbx))[0] + ".json")
    if not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(fbx):
        subprocess.run([BLENDER, "-b", "--factory-startup", "-P", os.path.join(HERE, "fbx_dump.py"), "--", fbx, out],
                       check=True, stdout=subprocess.DEVNULL)
    return json.load(open(out))


# the grip: curl per finger joint (degrees), as SLRR's drivers have their hands modelled as fists
CURL = {"01": 70, "02": 85, "03": 55}
THUMB_CURL = {"01": 15, "02": 35, "03": 30}


def rodrigues(k, a):
    k = k / np.linalg.norm(k)
    K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]])
    return np.eye(3) + np.sin(a) * K + (1 - np.cos(a)) * K @ K


def grip(dump):
    """Curl the fingers into a grip: each finger bone turns about its own joint, toward the palm (the side
    the thumb is on), and the mesh follows through the original skin weights."""
    rb = dump["bones"]
    names = [b["name"] for b in rb]
    hip = next(n for n in names if n.endswith("hip"))
    prefix = hip[:-3]
    short = [n[len(prefix):] if n.startswith(prefix) else n for n in names]
    at = {n: i for i, n in enumerate(short)}
    head = [np.array(b["head"]) for b in rb]
    T = [None] * len(rb)                  # per bone: (rotation, translation) of its delta, world space
    for side in ("l", "r"):
        hand = at["hand_" + side]
        mid = head[at["middle_01_" + side]] - head[hand]
        lateral = head[at["index_01_" + side]] - head[at["pinky_01_" + side]]
        palm = np.cross(mid, lateral)
        palm /= np.linalg.norm(palm)
        if np.dot(head[at["thumb_02_" + side]] - head[hand], palm) < 0:
            palm = -palm                  # the palm faces the thumb
        for finger in ("thumb", "index", "middle", "ring", "pinky"):
            curl = THUMB_CURL if finger == "thumb" else CURL
            R, t = np.eye(3), np.zeros(3)
            for j in ("01", "02", "03"):
                n = "%s_%s_%s" % (finger, j, side)
                if n not in at:
                    break
                i = at[n]
                d = np.array(rb[i]["tail"]) - head[i]
                axis = np.cross(d, palm)  # turning about d x palm brings d toward the palm
                Rj = rodrigues(axis, np.radians(curl[j]))
                # about its own (original) joint, then carried by the joints before it
                R, t = R @ Rj, R @ (head[i] - Rj @ head[i]) + t
                T[i] = (R, t)
            # the end bone (if any) follows the last joint
            e = "%s_end_%s" % (finger, side)
            if e in at:
                T[at[e]] = (R, t)
    for m in dump["meshes"]:
        for vi, wl in enumerate(m["weights"]):
            moved = [(T[b], w) for b, w in wl if T[b] is not None]
            if not moved:
                continue
            v, n = np.array(m["pos"][vi]), np.array(m["nrm"][vi])
            rest = 1.0 - sum(w for _, w in moved)
            m["pos"][vi] = list(rest * v + sum(w * (R @ v + t) for (R, t), w in moved))
            nn = rest * n + sum(w * (R @ n) for (R, t), w in moved)
            m["nrm"][vi] = list(nn / np.linalg.norm(nn))
    return dump


def reduce(dump):
    """The dump's skeleton and mesh as convert_drivers expects them (read_skl / read_skinned_scx shapes)."""
    rb = dump["bones"]
    # some exports prefix every bone with the character's name: strip what comes before "hip"
    hip = next(b["name"] for b in rb if b["name"].endswith("hip"))
    prefix = hip[:-3]
    rb = [dict(b, name=b["name"][len(prefix):] if b["name"].startswith(prefix) else b["name"]) for b in rb]
    tgt = [None] * len(rb)
    for i, b in enumerate(rb):       # parents come first in Blender's bone list
        tgt[i] = target(b["name"], tgt[b["parent"]] if b["parent"] >= 0 else None)
    names, first = [], {}
    for i, t in enumerate(tgt):
        if t and t not in first:
            first[t] = i
            names.append(t)
    idx = {n: k for k, n in enumerate(names)}
    bones = []
    for n in names:
        i = first[n]
        p = rb[i]["parent"]
        while p >= 0 and tgt[p] == n:  # the parent is the nearest ancestor mapped to another bone
            p = rb[p]["parent"]
        world = np.eye(4)
        world[3, :3] = to_slrr(rb[i]["head"])
        bones.append({"name": n, "parent": idx[tgt[p]] if p >= 0 and tgt[p] else -1, "world": world})
    subs = []
    for m in dump["meshes"]:
        weights = []
        for wl in m["weights"]:
            acc = {}
            for b, w in wl:
                if tgt[b]:
                    acc[idx[tgt[b]]] = acc.get(idx[tgt[b]], 0.0) + w
            tot = sum(acc.values()) or 1.0
            weights.append([(b, w / tot) for b, w in acc.items()] or [(idx["Bip01 Pelvis"], 1.0)])
        subs.append({"pos": np.array([to_slrr(p) for p in m["pos"]]),
                     "nrm": np.array([to_slrr(n) / 100.0 for n in m["nrm"]]),
                     "uv": np.array([(u, 1.0 - v) for u, v in m["uv"]]),   # bake flips v back
                     "tris": [tuple(t) for t in m["tris"]], "weights": weights})
    # the eye: between the two eye bones, from the head joint, in the seat frame (m)
    rbi = {b["name"]: b for b in rb}
    eye = (np.array(rbi["eye_l"]["head"]) + np.array(rbi["eye_r"]["head"])) / 2 - np.array(rbi["head"]["head"])
    eye_seat = np.array([-eye[0], -eye[1], eye[2]])
    return bones, subs, eye_seat


def textures(did, folder, stem):
    tex = os.path.join(SRC, folder, "tex", stem + "_%s.jpg")
    ddir = os.path.join(cd.OUT, did)
    os.makedirs(ddir, exist_ok=True)
    Image.open(tex % "dif").convert("RGB").resize((COLOR_PX, COLOR_PX), Image.LANCZOS).save(os.path.join(ddir, stem + ".color.png"))
    Image.open(tex % "norm").convert("RGB").resize((NORMAL_PX, NORMAL_PX), Image.LANCZOS).save(os.path.join(ddir, stem + ".normal.png"))
    gloss = Image.open(tex % "gloss").convert("L").resize((ROUGH_PX, ROUGH_PX), Image.LANCZOS)
    Image.eval(gloss, lambda g: 255 - g).save(os.path.join(ddir, stem + "_r.data.png"))
    mat = did + "_driver"
    base = "/art/slrr_drivers/%s/%s" % (did, stem)
    json.dump({mat: {"name": mat, "mapTo": mat, "class": "Material", "version": 1.5, "materialTag0": "beamng",
                     "Stages": [{"baseColorMap": base + ".color.png", "normalMap": base + ".normal.png",
                                 "roughnessMap": base + "_r.data.png", "metallicFactor": 0}, {}, {}, {}]}},
              open(os.path.join(ddir, "main.materials.json"), "w"), indent=1)


def main():
    for did, name, folder, fbx, stem, model in CHARACTERS:
        path = os.path.join(SRC, folder, fbx)
        if not os.path.exists(path):
            print("skipped", did, "(no", path + ")")
            continue
        bones, subs, eye = reduce(grip(load(path)))
        got = {b["name"] for b in bones}
        need = {n for n in sum(cd.PARTS.values(), []) if n != "Bip01 R Toe0" and n != "Bip01 L Toe0"} | {"Bip01 Pelvis", "Bip01 Spine"}
        assert need <= got, (did, sorted(need - got))
        # arms bent as the runtime holds them (its REACH): the baked elbow sets the way each arm bends
        print(did, cd.bake_from(model, bones, subs, eye, reach_frac=0.85))
        textures(did, folder, stem)
        json.dump({"name": name, "model": model, "skin": did}, open(os.path.join(cd.OUT, did, "driver.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
