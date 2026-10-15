"""Walking and standing shapes for the drivers' own bodies (the on-foot player, X31b).

    python tools/convert_driver_walk.py [SLRR_DIR]

SLRR's drivers have no walk animation, so a pedestrian's walk cycle is retargeted onto the
driver skeletons (both are 3ds Max bipeds with the same Bip01 names and bone axes): each driver bone
takes the pedestrian bone's local rotation as is, so the pose carries over and only the bone lengths
are the driver's. (Rotations relative to each rig's rest pose would keep the drivers' bind pose, legs
spread 0.34 m.) The drivers have no Spine2: their Spine1
takes the pedestrian's Spine1 and Spine2 together. SLRR's drivers face -z where its pedestrians face +z,
so the root's sway is turned round, and the shapes use the drivers' own axis conversion (facing +y).

Output per driver, in the pedestrian type format slrrPedestrians.followPlayer reads:
    art/slrr_drivers/<id>/walker/walk.dae, walk_slow.dae, walk_fast.dae, idle.dae, ped.json
Like the pedestrians, the shapes stand with their soles at z = 0, origin between the feet.
The shapes use the driver's own material (<id>_driver), so they wear his skin.
"""
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
ARGS = sys.argv[1:]
sys.argv = sys.argv[:1]          # convert_peds reads its own argv at import
import convert_peds as cp  # noqa: E402
from slrr_skin import read_skl, read_skinned_scx  # noqa: E402

SLRR = ARGS[0] if ARGS else cp.SLRR
ART = os.path.join(HERE, "..", "mod", "art", "slrr_drivers")
SOURCE = "gambler"               # the pedestrian whose walk the drivers borrow
# SLRR cm, y up, drivers facing -z  ->  m, z up, facing +y
DRIVER_CONV = np.array([[0.01, 0, 0, 0], [0, 0, -0.01, 0], [0, 0.01, 0, 0], [0, 0, 0, 1]])


def m2q(m):
    """Rotation matrix (column vectors) -> quaternion (x, y, z, w)."""
    t = np.trace(m)
    if t > 0:
        s = 0.5 / np.sqrt(t + 1)
        return ((m[2, 1] - m[1, 2]) * s, (m[0, 2] - m[2, 0]) * s, (m[1, 0] - m[0, 1]) * s, 0.25 / s)
    i = int(np.argmax(np.diag(m)))
    j, k = (i + 1) % 3, (i + 2) % 3
    s = 2 * np.sqrt(1 + m[i, i] - m[j, j] - m[k, k])
    q = [0.0, 0.0, 0.0, 0.0]
    q[i] = 0.25 * s
    q[j] = (m[j, i] + m[i, j]) / s
    q[k] = (m[k, i] + m[i, k]) / s
    q[3] = (m[k, j] - m[j, k]) / s
    return tuple(q)


def retarget(dbones, pbones, ptracks):
    """The pedestrian's local rotations, copied bone for bone (only the lengths stay the driver's)."""
    pidx = {b["name"]: i for i, b in enumerate(pbones)}
    nk = len(ptracks[0])

    def rot(name, k):
        return cp.q2m(*ptracks[pidx[name]][k][1])

    flip = np.diag([-1.0, 1.0, -1.0])                # half a turn about y: pedestrians face +z, drivers -z
    out = []
    for b in dbones:
        length = np.linalg.norm(b["pos"])
        rest_dir = b["pos"] / length if length > 1e-9 else np.zeros(3)
        keys = []
        for k in range(nk):
            t = ptracks[0][k][0]
            if b["name"] == "Bip01 Spine1" and "Bip01 Spine2" in pidx:
                r = rot("Bip01 Spine1", k) @ rot("Bip01 Spine2", k)
            elif b["name"] in pidx:
                r = rot(b["name"], k)
            else:
                r = b["rot"].T
            dirv = rest_dir
            if b["parent"] < 0 and b["name"] in pidx:
                # the root carries the facing and the sway: turned round to face the driver's way
                r = flip @ r
                dirv = flip @ np.array(ptracks[pidx[b["name"]]][k][2])
            keys.append((t, m2q(r), tuple(dirv)))
        out.append(keys)
    return out


def stand(bones, walk, period=3.0, hz=30):
    """A calm standing idle: each leg as at its own mid-stance, each arm where its swing passes the shoulder,
    every other bone at its average rotation over the walk, breathing slowly through the spine. (SLRR's pedestrian idles are race-crowd cheers, arms up.)"""
    nk = int(period * hz)
    # a leg is straight under the hip at mid-stance (its ankle lowest): each leg's bones keep that key
    feet = {b["name"]: i for i, b in enumerate(bones) if b["name"] in cp.FEET}
    low = {}
    for side in "LR":
        f = feet["Bip01 %s Foot" % side]
        heights = [(cp.CONV @ cp.pose_at(bones, walk, k[0])[f])[2, 3] for k in walk[f]]
        low[side] = int(np.argmin(heights))
    # an arm hangs at the point of its swing where the hand passes under the shoulder
    names = {b["name"]: i for i, b in enumerate(bones)}
    hang = {}
    for side in "LR":
        h, sh = names["Bip01 %s Hand" % side], names["Bip01 %s UpperArm" % side]
        ahead = [abs((cp.CONV @ W[h])[1, 3] - (cp.CONV @ W[sh])[1, 3])
                 for W in (cp.pose_at(bones, walk, k[0]) for k in walk[h])]
        hang[side] = int(np.argmin(ahead))
    out = []
    for b, keys in zip(bones, walk):
        side = b["name"][6] if b["name"][6:8] in ("L ", "R ") else None
        if side and any(part in b["name"] for part in ("Thigh", "Calf", "Foot", "Toe")):
            keys = [keys[low[side]]]
        elif side and any(part in b["name"] for part in ("Clavicle", "UpperArm", "Forearm", "Hand", "Finger")):
            keys = [keys[hang[side]]]
        qs = np.array([k[1] for k in keys])
        qs[qs @ qs[0] < 0] *= -1                     # one hemisphere before averaging
        q = qs.mean(0)
        q /= np.linalg.norm(q)
        d = np.mean([k[2] for k in keys], 0)
        r = cp.q2m(*q)
        track = []
        for k in range(nk):
            a = np.radians(1.5) * np.sin(2 * np.pi * k / nk) if b["name"] == "Bip01 Spine1" else 0.0
            c, s_ = np.cos(a), np.sin(a)
            bend = np.array([[c, -s_, 0], [s_, c, 0], [0, 0, 1]])   # biped bones bend about their local z
            track.append((k / hz, m2q(r @ bend), tuple(d)))
        out.append(track)
    # the walk leans into its stride: tip the whole body back until the head is over the ankles
    idx = {b["name"]: i for i, b in enumerate(bones)}
    W = cp.pose_at(bones, out, 0)
    v = W[idx["Bip01 Head"]][:3, 3] - (W[idx["Bip01 L Foot"]][:3, 3] + W[idx["Bip01 R Foot"]][:3, 3]) / 2
    a = np.arctan2(-v[2], v[1])                      # SLRR is y up: turn about x until v has no z
    tip = np.array([[1, 0, 0], [0, np.cos(a), -np.sin(a)], [0, np.sin(a), np.cos(a)]])
    root = next(i for i, b in enumerate(bones) if b["parent"] < 0)
    out[root] = [(t, m2q(tip @ cp.q2m(*q)), dv) for t, q, dv in out[root]]
    return out


def sole(bones, subs, tracks):
    """Height (m) of the lowest skinned vertex below the origin at the start of a cycle."""
    n = len(bones)
    rest, W = [None] * n, cp.pose_at(bones, tracks, 0)

    def world(i):
        if rest[i] is None:
            m = cp.local_matrix(bones[i]["rot"].T, bones[i]["pos"])
            rest[i] = m if bones[i]["parent"] < 0 else world(bones[i]["parent"]) @ m
        return rest[i]
    M = [DRIVER_CONV @ W[i] @ np.linalg.inv(world(i)) for i in range(n)]
    return min(sum(wt * (M[b] @ np.append(v, 1))[2] for b, wt in wl)
               for s_ in subs for v, wl in zip(s_["pos"], s_["weights"]))


def check(bones, tracks):
    """The retargeted walk faces +y and walks forwards: feet under the hips, a planted foot moving back."""
    ts, (left, right) = cp.ankle_paths(bones, tracks)
    for p in (left, right):
        assert abs(p[:, 0]).max() < 0.25, "feet spread %.2f m: the legs kept the bind pose" % abs(p[:, 0]).max()
        on = p[:, 2] < p[:, 2].min() + cp.PLANTED
        dy = np.diff(p[:, 1])[on[1:] & on[:-1]]
        assert dy.sum() < 0, "a planted foot moves forwards: the walk is backwards"


def main():
    pdir = os.path.join(SLRR, "humans", "pedestrians")
    pw_bones = read_skl(cp.find(pdir, SOURCE + "_walk.skl"))
    pw_tracks = cp.read_anim(cp.find(pdir, SOURCE + "_walk.matrixdata"), pw_bones)
    ddir = os.path.join(SLRR, "humans", "drivers")
    cp.CONV = DRIVER_CONV                            # write_skinned_dae and gait use the module's conversion
    by_model = {}
    for dj in sorted(os.listdir(ART)):
        f = os.path.join(ART, dj, "driver.json")
        if os.path.isfile(f):
            by_model.setdefault(json.load(open(f))["model"], []).append(dj)
    for model, ids in by_model.items():
        bones = read_skl(os.path.join(ddir, model + ".skl"))
        subs = read_skinned_scx(os.path.join(ddir, model + ".SCX"))
        walk = retarget(bones, pw_bones, pw_tracks)
        check(bones, walk)
        idle = stand(bones, walk)
        # origin between the feet, soles at z = 0, as the pedestrians (SLRR's drivers have it at the hips)
        ground = -sole(bones, subs, idle)
        cp.CONV = DRIVER_CONV.copy()
        cp.CONV[2, 3] = ground
        cycle, speed = cp.gait(bones, walk)
        for did in ids:
            out = os.path.join(ART, did, "walker")
            os.makedirs(out, exist_ok=True)
            mat = did + "_driver"
            walks = {"walk.dae": round(speed, 3)}
            cp.write_skinned_dae(os.path.join(out, "walk.dae"), model, bones, subs, walk, mat)
            for tag, tempo in cp.TEMPOS.items():
                cp.write_skinned_dae(os.path.join(out, "walk_%s.dae" % tag), model, bones, subs, cp.retimed(walk, tempo), mat)
                walks["walk_%s.dae" % tag] = round(speed * tempo, 3)
            cp.write_skinned_dae(os.path.join(out, "idle.dae"), model, bones, subs, idle, mat)
            json.dump({"cycle": round(cycle, 3), "walks": walks, "idle": "idle.dae",
                       "idleCycle": round(cp.cycle_time(idle), 3)}, open(os.path.join(out, "ped.json"), "w"), indent=1)
        print(model, "walk %.2f m/s, stride %.2f m per %.2f s, soles %.3f m below the hips, for %s"
              % (speed, speed * cycle, cycle, ground, ", ".join(ids)))
        cp.CONV = DRIVER_CONV


if __name__ == "__main__":
    main()
