"""Walking and standing shapes for the HD drivers' own bodies (the on-foot player, #35).

    python tools/convert_hd_walk.py [SLRR_DIR]

convert_driver_walk.py gives the slrr_* drivers a walk by copying a pedestrian's local bone rotations onto
their biped (both are 3ds Max bipeds with the same rest axes). The HD characters (Renderpeople, convert_hd.py)
are reduced to the same bone NAMES but not the same rest pose: their arms hang at 45 degrees (an A pose) and every bone's
rest frame is the world frame. So here the pedestrian's walk is retargeted by DIRECTION: each limb, spine and neck
bone is turned from its own rest direction to where the pedestrian's same limb points in that frame of the walk (shortest
arc), and the bones with no child (pelvis, head, hands, feet, toes) take the pedestrian's rotation change from ITS rest pose. Bone lengths stay the
HD character's, so the feet are planted at the HD stride; check() asserts the feet are under the hips and a planted
foot moves back, as for the slrr_* drivers.

Output per HD driver, in the pedestrian type format slrrPedestrians.followPlayer reads:
    art/slrr_drivers/<id>/walker/walk.dae, walk_slow.dae, walk_fast.dae, idle.dae, ped.json
Like the slrr_* drivers' shapes, they stand with their soles at z = 0, origin between the feet, and wear the driver's own material.
"""
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
ARGS = sys.argv[1:]
sys.argv = sys.argv[:1]
import convert_driver_walk as cdw  # noqa: E402
import convert_hd as ch  # noqa: E402
import convert_peds as cp  # noqa: E402
from slrr_skin import read_skl  # noqa: E402

SLRR = ARGS[0] if ARGS else cp.SLRR
ART = cdw.ART
FLIP = np.diag([-1.0, 1.0, -1.0])        # pedestrians face +z, the drivers -z: half a turn about y

# bone -> the bone whose position it points at (the pedestrian's equivalent has the same name)
CHAIN = {
    "Bip01 Spine": "Bip01 Spine1", "Bip01 Spine1": "Bip01 Neck", "Bip01 Neck": "Bip01 Head",
    "Bip01 L Clavicle": "Bip01 L UpperArm", "Bip01 L UpperArm": "Bip01 L Forearm", "Bip01 L Forearm": "Bip01 L Hand",
    "Bip01 R Clavicle": "Bip01 R UpperArm", "Bip01 R UpperArm": "Bip01 R Forearm", "Bip01 R Forearm": "Bip01 R Hand",
    "Bip01 L Thigh": "Bip01 L Calf", "Bip01 L Calf": "Bip01 L Foot", "Bip01 R Thigh": "Bip01 R Calf", "Bip01 R Calf": "Bip01 R Foot",
}


def world_rests(bones):
    """Rest world matrices (column vectors) of a read_skl skeleton."""
    W = [None] * len(bones)

    def w(i):
        if W[i] is None:
            m = cp.local_matrix(bones[i]["rot"].T, bones[i]["pos"])
            W[i] = m if bones[i]["parent"] < 0 else w(bones[i]["parent"]) @ m
        return W[i]
    for i in range(len(bones)):
        w(i)
    return W


def hd_skeleton(hd_bones):
    """The reduced HD bones in read_skl form: every rest rotation is the identity, the offsets are the world differences."""
    out = []
    for b in hd_bones:
        head = np.array(b["world"][3, :3])
        parent = b["parent"]
        pos = head - np.array(hd_bones[parent]["world"][3, :3]) if parent >= 0 else head
        out.append({"name": b["name"], "parent": parent, "pos": pos, "rot": np.eye(3), "world": b["world"]})
    return out


def arc(a, b):
    """The shortest rotation taking direction a to direction b."""
    a, b = a / np.linalg.norm(a), b / np.linalg.norm(b)
    v, c = np.cross(a, b), float(np.dot(a, b))
    s = np.linalg.norm(v)
    if s < 1e-9:
        return np.eye(3) if c > 0 else np.diag([1.0, -1.0, -1.0])
    k = v / s
    K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]])
    return np.eye(3) + s * K + (1 - c) * K @ K


def retarget(hbones, hrest, pbones, prest, ptracks):
    """Tracks (t, quaternion, direction) for the HD skeleton from the pedestrian's walk."""
    pidx = {b["name"]: i for i, b in enumerate(pbones)}
    hidx = {b["name"]: i for i, b in enumerate(hbones)}
    nk = len(ptracks[0])
    tracks = [[] for _ in hbones]
    for k in range(nk):
        t = ptracks[0][k][0]
        P = cp.pose_at(pbones, ptracks, t)                     # pedestrian world matrices at this key
        world_rot = [None] * len(hbones)
        for i, b in enumerate(hbones):                         # parents come first
            n = b["name"]
            if n in CHAIN and CHAIN[n] in pidx and n in pidx:
                d_target = FLIP @ (P[pidx[CHAIN[n]]][:3, 3] - P[pidx[n]][:3, 3])
                d_rest = hrest[hidx[CHAIN[n]]][:3, 3] - hrest[i][:3, 3]
                R = arc(d_rest, d_target)
            elif n in pidx:
                delta = P[pidx[n]][:3, :3] @ prest[pidx[n]][:3, :3].T
                R = FLIP @ delta @ FLIP
            else:
                R = np.eye(3)
            world_rot[i] = R
        for i, b in enumerate(hbones):
            local = world_rot[i] if b["parent"] < 0 else world_rot[b["parent"]].T @ world_rot[i]
            length = np.linalg.norm(b["pos"])
            rest_dir = b["pos"] / length if length > 1e-9 else np.zeros(3)
            dirv = rest_dir                                    # (the offsets stay: a root with a length, as Manuel's, would be thrown a metre by the pedestrian's sway direction)
            tracks[i].append((t, cdw.m2q(local), tuple(dirv)))
    return tracks


def main():
    pdir = os.path.join(SLRR, "humans", "pedestrians")
    pbones = read_skl(cp.find(pdir, cdw.SOURCE + "_walk.skl"))
    ptracks = cp.read_anim(cp.find(pdir, cdw.SOURCE + "_walk.matrixdata"), pbones)
    prest = world_rests(pbones)
    for did, name, folder, fbx, stem, model in ch.CHARACTERS:
        path = os.path.join(ch.SRC, folder, fbx)
        dump = os.path.join(ch.CACHE, os.path.splitext(fbx)[0] + ".json")
        if not os.path.exists(path) and not os.path.exists(dump):
            print("skipped", did, "(no", path + ")")
            continue
        raw, subs, _ = ch.reduce(ch.grip(ch.load(path) if os.path.exists(path) else json.load(open(dump))))
        bones = hd_skeleton(raw)
        hrest = world_rests(bones)
        cp.CONV = cdw.DRIVER_CONV
        walk = retarget(bones, hrest, pbones, prest, ptracks)
        cdw.check(bones, walk)
        idle = cdw.stand(bones, walk)
        ground = -cdw.sole(bones, subs, idle)
        cp.CONV = cdw.DRIVER_CONV.copy()
        cp.CONV[2, 3] = ground
        cycle, speed = cp.gait(bones, walk)
        out = os.path.join(ART, did, "walker")
        os.makedirs(out, exist_ok=True)
        mat = did + "_driver"
        walks = {"walk.dae": round(speed, 3)}
        cp.write_skinned_dae(os.path.join(out, "walk.dae"), model, bones, subs, walk, mat)
        for tag, tempo in cp.TEMPOS.items():
            cp.write_skinned_dae(os.path.join(out, "walk_%s.dae" % tag), model, bones, subs, cp.retimed(walk, tempo), mat)
            walks["walk_%s.dae" % tag] = round(speed * tempo, 3)
        cp.write_skinned_dae(os.path.join(out, "idle.dae"), model, bones, subs, idle, mat)
        json.dump({"cycle": round(cycle, 3), "walks": walks, "idle": "idle.dae", "idleCycle": round(cp.cycle_time(idle), 3)},
                  open(os.path.join(out, "ped.json"), "w"), indent=1)
        print(did, "walk %.2f m/s, stride %.2f m per %.2f s, soles %.3f m below the hips" % (speed, speed * cycle, cycle, ground))
        cp.CONV = cdw.DRIVER_CONV


if __name__ == "__main__":
    main()
