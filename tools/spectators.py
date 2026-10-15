"""Spectator spots for Valo City's venues (X32): python spectators.py

Zones: every raceline (racelines/*.json: the start/finish and three more stretches round the lap), the test
track's drag strip (its tt_drag racelines), and the car meets (pois.json kind "meet"). Spots stand in rows
SIDE_MIN..SIDE_MAX m beside the track edge (both sides), facing it, on solid ground (the level's collision
meshes or terrain, within 3 m of track height), never on a track, a lane or water. Writes
mod/art/slrr_pedestrians/spectators_slrr_valo_city.json: {zones: [{id, kind, c: [x, y, z], r, spots: [[x, y, z, fx, fy]]}]}.
"""
import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ped_paths as pp  # noqa: E402

OUT = os.path.join(pp.MOD, "art", "slrr_pedestrians", "spectators_slrr_valo_city.json")
SIDE_MIN, ROW, ROWS = 4.0, 1.4, 2      # first row this far past the track edge, rows this far apart
SPACING, STRETCH = 1.3, 30.0           # along the track: a spot every SPACING m over STRETCH m per stand
MAX_SPOTS = 80                         # per zone
MEET_R = (9.0, 13.0)                   # ring round a meet point


def stand(points, k, half):
    """Candidate spots beside raceline point k: both sides, ROWS rows, over STRETCH m centred on it."""
    p = np.array(points)
    seg = np.linalg.norm(np.diff(p[:, :2], axis=0), axis=1)
    cum = np.concatenate([[0], np.cumsum(seg)])
    out = []
    for d in np.arange(cum[k] - STRETCH / 2, cum[k] + STRETCH / 2, SPACING):
        d = d % cum[-1]
        j = min(int(np.searchsorted(cum, d, side="right")) - 1, len(p) - 2)
        t = (d - cum[j]) / max(seg[j], 1e-6)
        c = p[j] + (p[j + 1] - p[j]) * t
        tan = (p[j + 1, :2] - p[j, :2]) / max(seg[j], 1e-6)
        n = np.array([tan[1], -tan[0]])
        w = (p[j, 3] if p.shape[1] > 3 else 2 * half) / 2
        for side in (1, -1):
            for row in range(ROWS):
                off = w + SIDE_MIN + row * ROW
                xy = c[:2] + side * n * off
                out.append([xy[0], xy[1], c[2], -side * n[0], -side * n[1]])   # facing the track
    return out


def zones():
    lvl = pp.LEVEL
    out = []
    rl = os.path.join(lvl, "racelines")
    for fn in sorted(os.listdir(rl)):
        d = json.load(open(os.path.join(rl, fn)))
        pts = d["points"]
        ks = [0] + [len(pts) * i // 4 for i in (1, 2, 3)]
        spots = [s for k in ks for s in stand(pts, k, 4.0)]
        out.append({"id": d["id"], "kind": "race", "line": [p[:3] for p in pts], "spots": spots,
                    "half": [p[3] / 2 if len(p) > 3 else 4.0 for p in pts]})
    # the drag strip has its own racelines (tt_drag_l, tt_drag_r), so it needs no zone of its own
    for p in json.load(open(os.path.join(lvl, "pois.json"))):
        if p["kind"] == "meet":
            c = np.array(p["pos"])
            spots = []
            for r in MEET_R:
                for a in np.arange(0, 2 * math.pi, SPACING / r):
                    xy = c[:2] + r * np.array([math.cos(a), math.sin(a)])
                    f = (c[:2] - xy) / r
                    spots.append([xy[0], xy[1], c[2], f[0], f[1]])
            out.append({"id": p["id"], "kind": "meet", "line": [list(c)], "spots": spots})
    return out


def main():
    zs = zones()
    tris, mats = pp.collision_triangles()
    gt = pp._mat_ground_types()
    A, B, W = pp.lanes()
    # every raceline as road too: nobody stands on a track
    for z in zs:
        if z["kind"] != "meet":
            A = np.concatenate([A, np.array(z["line"][:-1], float)])
            B = np.concatenate([B, np.array(z["line"][1:], float)])
            W = np.concatenate([W, np.array(z["half"][:-1], float)])
    allspots = np.array([s for z in zs for s in z["spots"]], float)
    print(len(zs), "zones,", len(allspots), "candidate spots")
    mz, mm = pp.mesh_ground(allspots[:, :3], tris, mats)
    tz, _ = pp.terrain_ground(allspots[:, :3])
    ground = np.where(np.isnan(mz), tz, np.where(np.isnan(tz), mz, np.maximum(mz, tz)))
    kerb = pp.road_distance(allspots[:, :3], A, B, W)
    water = np.array(["water" in (m or "").lower() for m in mm])
    ok = ~np.isnan(ground) & (np.abs(ground - allspots[:, 2]) < 3) & (kerb > 1.0) & ~water
    print("kept %d of %d (no ground %d, too high/low %d, on a track or lane %d)" % (
        ok.sum(), len(ok), np.isnan(ground).sum(), (np.abs(ground - allspots[:, 2]) >= 3).sum(), (kerb <= 1.0).sum()))
    i = 0
    result = []
    for z in zs:
        n = len(z["spots"])
        keep = [[round(float(allspots[i + j, 0]), 2), round(float(allspots[i + j, 1]), 2), round(float(ground[i + j]), 2),
                 round(float(allspots[i + j, 3]), 3), round(float(allspots[i + j, 4]), 3)] for j in range(n) if ok[i + j]]
        i += n
        if len(keep) > MAX_SPOTS:
            keep = [keep[int(k)] for k in np.linspace(0, len(keep) - 1, MAX_SPOTS)]
        if keep:
            xy = np.array([s[:3] for s in keep])
            c = xy.mean(0)
            result.append({"id": z["id"], "kind": z["kind"], "c": [round(float(v), 2) for v in c],
                           "r": round(float(np.max(np.linalg.norm(xy[:, :2] - c[:2], axis=1))), 1), "spots": keep})
            print("  %-30s %-5s %3d spots" % (z["id"], z["kind"], len(keep)))
    json.dump({"zones": result}, open(OUT, "w"), separators=(",", ":"))
    print(len(result), "zones ->", OUT)


if __name__ == "__main__":
    main()
