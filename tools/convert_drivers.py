"""Convert SLRR drivers (humans/drivers) into BeamNG shapes for the slrr_drivers mod.

    python convert_drivers.py [SLRR_DIR] [MOD_DIR]

For each SLRR driver mesh (vin, police) this bakes a seated pose with the original skin
weights, then splits it into rigid parts the GE Lua animates (body, head, upper arm,
forearm and hand per side). Parts are stored in the seat frame (x right, y forward,
z up, metres) relative to their joint; the seat origin is the driver's eye.

Output under MOD_DIR/art/slrr_drivers:
    models/<model>/<part>.dae   rig.json
    <driverId>/driver.json, <skin>.dds, main.materials.json
"""
import json
import math
import os
import shutil
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dae import write_dae  # noqa: E402
from slrr_skin import read_skl, read_skinned_scx  # noqa: E402

SLRR = sys.argv[1] if len(sys.argv) > 1 else r"L:\SteamLibrary\steamapps\common\Street Legal Racing Redline"
MOD = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mod")
OUT = os.path.join(MOD, "art", "slrr_drivers")

# SLRR (x right, y up, z back, cm) -> seat frame (x right, y forward, z up, m)
K = np.array([[1, 0, 0], [0, 0, -1], [0, 1, 0]], float)

# id, display name, mesh, skin texture (from humans.rpk: driver/opponent1/opponent2 use vin.skl, policeman police.skl)
DRIVERS = [
    ("slrr_mitch", "Mitch (SLRR player)", "vin", "Mitch_whole.dds"),
    ("slrr_opponent1", "Street racer 1 (SLRR)", "vin", "opponent1.dds"),
    ("slrr_opponent2", "Street racer 2 (SLRR)", "vin", "opponent2.dds"),
    ("slrr_police", "Police officer (SLRR)", "police", "police.dds"),
]

PARTS = {  # part -> skeleton bones whose triangles it takes; everything else is "body"
    "head": ["Bip01 Head", "Bip01 Neck"],
    "r_upperarm": ["Bip01 R UpperArm"], "r_forearm": ["Bip01 R Forearm"], "r_hand": ["Bip01 R Hand"],
    "l_upperarm": ["Bip01 L UpperArm"], "l_forearm": ["Bip01 L Forearm"], "l_hand": ["Bip01 L Hand"],
    "r_thigh": ["Bip01 R Thigh"], "r_calf": ["Bip01 R Calf"], "r_foot": ["Bip01 R Foot", "Bip01 R Toe0"],
    "l_thigh": ["Bip01 L Thigh"], "l_calf": ["Bip01 L Calf"], "l_foot": ["Bip01 L Foot", "Bip01 L Toe0"],
}
JOINT = {"head": "Bip01 Neck", "r_upperarm": "Bip01 R UpperArm", "r_forearm": "Bip01 R Forearm",
         "r_hand": "Bip01 R Hand", "l_upperarm": "Bip01 L UpperArm", "l_forearm": "Bip01 L Forearm",
         "l_hand": "Bip01 L Hand", "r_thigh": "Bip01 R Thigh", "r_calf": "Bip01 R Calf", "r_foot": "Bip01 R Foot",
         "l_thigh": "Bip01 L Thigh", "l_calf": "Bip01 L Calf", "l_foot": "Bip01 L Foot", "body": None}

# Base pose targets in the seat frame relative to the eye; the Lua uses the same numbers (slrrDrivers.lua WHEEL_*).
WHEEL_CENTER = np.array([0.0, 0.56, -0.30])
WHEEL_TILT = math.radians(25)      # wheel face leans back from vertical
WHEEL_RADIUS = 0.185
GRIP_ANGLE = math.radians(10)      # hands at a quarter past nine
WRIST_BACK = 0.07                  # wrist sits this far toward the driver from the rim
EYE_FROM_HEAD = np.array([0.0, 0.085, 0.075])   # eye relative to the head joint, rest pose
RECLINE = math.radians(14)


def rot_x(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])


def rot_between(a, b):
    a, b = a / np.linalg.norm(a), b / np.linalg.norm(b)
    v, c = np.cross(a, b), float(np.dot(a, b))
    if c < -0.9999:
        return -np.eye(3)
    vx = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + vx + vx @ vx / (1 + c)


def norm(v):
    return v / np.linalg.norm(v)


def wheel_basis():
    n = np.array([0.0, -math.cos(WHEEL_TILT), math.sin(WHEEL_TILT)])   # face normal, toward the driver
    x = np.array([1.0, 0, 0])
    up = np.cross(n, x)
    return x, norm(up), n


def wrist_target(side):
    x, up, n = wheel_basis()
    s = 1 if side == "r" else -1
    rim = WHEEL_CENTER + WHEEL_RADIUS * (s * math.cos(GRIP_ANGLE) * x + math.sin(GRIP_ANGLE) * up)
    return rim + WRIST_BACK * n


def two_bone_ik(root, target, la, lb, pole):
    d = target - root
    dist = min(np.linalg.norm(d), (la + lb) * 0.999)
    d = norm(d)
    cos_a = (la * la + dist * dist - lb * lb) / (2 * la * dist)
    a = math.acos(max(-1.0, min(1.0, cos_a)))
    bend = norm(pole - np.dot(pole, d) * d)
    elbow = root + la * (math.cos(a) * d + math.sin(a) * bend)
    return elbow, root + d * dist


def pose_model(bones):
    """Return per-bone (delta rotation, posed joint position) in the seat frame, rest positions too."""
    names = [b["name"] for b in bones]
    idx = {n: i for i, n in enumerate(names)}
    rest_p = [K @ b["world"][3, :3] * 0.01 for b in bones]
    children = {i: [j for j, b in enumerate(bones) if b["parent"] == i] for i in range(len(bones))}

    def rest_dir(i):
        ch = children[i]
        return rest_p[ch[0]] - rest_p[i] if ch else None

    aim = {}
    for s, x in (("R", 1), ("L", -1)):
        aim["Bip01 %s Thigh" % s] = np.array([0.1 * x, 1.0, 0.1])
        aim["Bip01 %s Calf" % s] = np.array([0.04 * x, 0.6, -0.85])

    D = [None] * len(bones)
    P = [None] * len(bones)
    order = []

    def visit(i):
        order.append(i)
        for c in children[i]:
            visit(c)
    for i, b in enumerate(bones):
        if b["parent"] < 0:
            visit(i)

    for i in order:
        n = names[i]
        par = bones[i]["parent"]
        Dp = D[par] if par >= 0 else np.eye(3)
        P[i] = rest_p[i] if par < 0 else P[par] + Dp @ (rest_p[i] - rest_p[par])
        if n == "Bip01 Spine":
            D[i] = rot_x(RECLINE)
        elif n in ("Bip01 Neck", "Bip01 Head"):
            D[i] = rot_x(RECLINE * 0.3)    # neck brings the gaze back level
        elif n in aim:
            D[i] = rot_between(Dp @ rest_dir(i), aim[n]) @ Dp
        else:
            D[i] = Dp
    # arms: IK the posed shoulders onto the wheel after moving the model so the eye is the origin
    head = idx["Bip01 Head"]
    eye = P[head] + D[head] @ EYE_FROM_HEAD
    P = [p - eye for p in P]
    # short-armed bodies (police) slide forward in the seat until the hands reach the base wheel
    ua, fa, hd = idx["Bip01 R UpperArm"], idx["Bip01 R Forearm"], idx["Bip01 R Hand"]
    reach = 0.97 * (np.linalg.norm(rest_p[fa] - rest_p[ua]) + np.linalg.norm(rest_p[hd] - rest_p[fa]))
    t, s0 = wrist_target("r"), P[ua]
    lateral = math.hypot(t[0] - s0[0], t[2] - s0[2])
    shortfall = (t[1] - s0[1]) - math.sqrt(max(0.0, reach * reach - lateral * lateral))
    if shortfall > 0:
        P = [p + np.array([0, shortfall, 0]) for p in P]
    for s, x in (("R", 1), ("L", -1)):
        ua, fa, hd = idx["Bip01 %s UpperArm" % s], idx["Bip01 %s Forearm" % s], idx["Bip01 %s Hand" % s]
        la = np.linalg.norm(rest_p[fa] - rest_p[ua])
        lb = np.linalg.norm(rest_p[hd] - rest_p[fa])
        elbow, wrist = two_bone_ik(P[ua], wrist_target(s.lower()), la, lb, np.array([0.6 * x, -0.2, -1.0]))
        D[ua] = rot_between(D[ua] @ (rest_p[fa] - rest_p[ua]), elbow - P[ua]) @ D[ua]
        P[fa] = elbow
        D[fa] = rot_between(D[ua] @ (rest_p[hd] - rest_p[fa]), wrist - elbow) @ D[ua]
        P[hd] = wrist
        D[hd] = D[fa]
    return names, D, P, rest_p


def bake(model):
    d = os.path.join(SLRR, "humans", "drivers")
    bones = read_skl(os.path.join(d, model + ".skl"))
    subs = read_skinned_scx(os.path.join(d, model + ".SCX"))
    names, D, P, rest_p = pose_model(bones)
    part_of_bone = {}
    for part, bl in PARTS.items():
        for bn in bl:
            if bn in names:
                part_of_bone[names.index(bn)] = part
    joints = {p: (P[names.index(j)] if j else np.zeros(3)) for p, j in JOINT.items()}
    geo = {p: {"pos": [], "nrm": [], "uv": [], "tris": []} for p in JOINT}
    for s in subs:
        pos = s["pos"] @ K.T * 0.01
        nrm = s["nrm"] @ K.T
        posed, pnrm, dom = [], [], []
        for v, nv, w in zip(pos, nrm, s["weights"]):
            pv = sum(wt * (D[b] @ (v - rest_p[b]) + P[b]) for b, wt in w)
            pn = norm(sum(wt * (D[b] @ nv) for b, wt in w))
            posed.append(pv)
            pnrm.append(pn)
            dom.append(part_of_bone.get(max(w, key=lambda t: t[1])[0], "body"))
        # SLRR winds clockwise; flip when the faces disagree with the normals
        agree = 0.0
        for a, b, c in s["tris"]:
            agree += np.dot(np.cross(pos[b] - pos[a], pos[c] - pos[a]), nrm[a] + nrm[b] + nrm[c])
        for a, b, c in s["tris"]:
            if agree < 0:
                b, c = c, b
            votes = [dom[a], dom[b], dom[c]]
            parts = {max(set(votes), key=votes.count)}
            if "head" not in votes:
                parts = set(votes)   # a triangle across a joint goes into both parts so the joint never opens a gap
            for part in parts:
                g = geo[part]
                remap = g.setdefault("_map", {})
                out = []
                for vi in (a, b, c):
                    key = (id(s), vi)
                    if key not in remap:
                        remap[key] = len(g["pos"])
                        g["pos"].append(tuple(posed[vi] - joints[part]))
                        g["nrm"].append(tuple(pnrm[vi]))
                        u, v = s["uv"][vi]
                        g["uv"].append((u, 1.0 - v))
                    out.append(remap[key])
                g["tris"].append(tuple(out))
    mdir = os.path.join(OUT, "models", model)
    os.makedirs(mdir, exist_ok=True)
    for part, g in geo.items():
        g.pop("_map", None)
        g["material"] = "base_driver"
        write_dae(os.path.join(mdir, part + ".dae"), [("driver_" + part.replace("_", "") + "_a", [g])])
    ix = {n: i for i, n in enumerate(names)}
    rig = {"model": model, "parts": {p: [round(float(c), 5) for c in joints[p]] for p in JOINT},
           "pelvis": [round(float(c), 5) for c in P[names.index("Bip01 Pelvis")]],
           "arms": {}, "legs": {}}
    for s in ("R", "L"):
        rig["arms"][s.lower()] = {k: [round(float(c), 5) for c in P[ix["Bip01 %s %s" % (s, b)]]]
                                  for k, b in (("shoulder", "UpperArm"), ("elbow", "Forearm"), ("wrist", "Hand"))}
    for s in ("R", "L"):
        hip, knee, ankle = (P[ix["Bip01 %s %s" % (s, b)]] for b in ("Thigh", "Calf", "Foot"))
        # ball of the foot (where it presses a pedal): the front, lower part of the foot piece
        fp = np.array(geo[s.lower() + "_foot"]["pos"]) + ankle
        front = fp[fp[:, 1] > fp[:, 1].max() - 0.06]
        ball = np.array([front[:, 0].mean(), front[:, 1].mean(), front[:, 2].min() + 0.02])
        rig["legs"][s.lower()] = {k: [round(float(c), 5) for c in v]
                                  for k, v in (("hip", hip), ("knee", knee), ("ankle", ankle), ("ball", ball))}
    # the middle of each fist relative to its wrist (hand piece frame): the point that holds the rim
    rig["fist"] = {s: [round(float(c), 5) for c in np.mean(geo[s + "_hand"]["pos"], 0)] for s in ("r", "l")}
    json.dump(rig, open(os.path.join(mdir, "rig.json"), "w"), indent=1)
    # self-check: the arms keep their rest lengths and reach toward the wheel (short arms may fall short)
    for s in ("r", "l"):
        a = {k: np.array(v) for k, v in rig["arms"][s].items()}
        S = s.upper()
        for j0, j1, b0, b1 in (("shoulder", "elbow", "UpperArm", "Forearm"), ("elbow", "wrist", "Forearm", "Hand")):
            rest = np.linalg.norm(rest_p[ix["Bip01 %s %s" % (S, b1)]] - rest_p[ix["Bip01 %s %s" % (S, b0)]])
            assert abs(np.linalg.norm(a[j1] - a[j0]) - rest) < 1e-3, (model, s, j0)
        print("  %s wrist misses the grip by %.3f m" % (s, np.linalg.norm(a["wrist"] - wrist_target(s))))
    return {p: len(g["tris"]) for p, g in geo.items()}


def write_driver(did, name, model, skin):
    ddir = os.path.join(OUT, did)
    os.makedirs(ddir, exist_ok=True)
    shutil.copyfile(os.path.join(SLRR, "humans", "drivers", skin), os.path.join(ddir, skin))
    mat = did + "_driver"
    mats = {mat: {"name": mat, "mapTo": mat, "class": "Material", "version": 1.5, "materialTag0": "beamng",
                  "Stages": [{"baseColorMap": "/art/slrr_drivers/%s/%s" % (did, skin), "roughnessFactor": 0.8,
                              "metallicFactor": 0}, {}, {}, {}]}}
    json.dump(mats, open(os.path.join(ddir, "main.materials.json"), "w"), indent=1)
    json.dump({"name": name, "model": model, "skin": did}, open(os.path.join(ddir, "driver.json"), "w"), indent=1)


if __name__ == "__main__":
    for model in sorted({d[2] for d in DRIVERS}):
        print(model, bake(model))
    for d in DRIVERS:
        write_driver(*d)
    # the shapes' own material name; the default skin until a driver's skin replaces "base"
    first = DRIVERS[0]
    mats = {"base_driver": {"name": "base_driver", "mapTo": "base_driver", "class": "Material", "version": 1.5,
                            "materialTag0": "beamng",
                            "Stages": [{"baseColorMap": "/art/slrr_drivers/%s/%s" % (first[0], first[3])}, {}, {}, {}]}}
    json.dump(mats, open(os.path.join(OUT, "models", "main.materials.json"), "w"), indent=1)
    print("written to", os.path.abspath(OUT))
