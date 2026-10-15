"""Foot-slide check: render a pedestrian's cycle (skinned offline, same maths as the Collada) at 60 fps, side
view, with the ground scrolling back at the walking speed Lua uses. Planted feet (filled dots) must stay still on
the grid; if they slide, the speed in ped.json is wrong.

    python walk_review.py <name> <skin.dds> <out.mp4> [speed m/s] [walk|jitter]

speed defaults to ped.json's speed for <name>.dae (0 for jitter). Needs ffmpeg on PATH.
"""
import json
import os
import subprocess
import sys
import tempfile

import numpy as np
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt  # noqa: E702
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from slrr_skin import read_skl, read_skinned_scx  # noqa: E402
ARGS = sys.argv[1:]
sys.argv = sys.argv[:1]   # convert_peds reads its own argv at import
from convert_peds import (read_anim, local_matrix, CONV, SLRR, find, pose_at, ankle_paths, slide, cycle_time,
                          PLANTED, FEET as FEET_NAMES)  # noqa: E402

MOD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mod")
name, skin, out = ARGS[0], ARGS[1], ARGS[2]
kind = ARGS[4] if len(ARGS) > 4 else "walk"
if len(ARGS) > 3:
    speed = float(ARGS[3])
elif kind == "walk":
    speed = json.load(open(os.path.join(MOD, "art", "slrr_pedestrians", name, "ped.json")))["walks"][name + ".dae"]
else:
    speed = 0.0

d = os.path.join(SLRR, "humans", "pedestrians")
B = read_skl(find(d, "%s_%s.skl" % (name, kind)))
S = read_skinned_scx(find(d, "%s_%s.SCX" % (name, kind)))
T = read_anim(find(d, "%s_%s.matrixdata" % (name, kind)), B)
n, cycle = len(B), cycle_time(T)
rest = [local_matrix(b["rot"].T, b["pos"]) for b in B]


def worlds(locs):
    W = [None] * n

    def w(i):
        if W[i] is None:
            p = B[i]["parent"]
            W[i] = locs[i] if p < 0 else w(p) @ locs[i]
        return W[i]
    for i in range(n):
        w(i)
    return W


inv = [np.linalg.inv(m) for m in worlds(rest)]
FEET = [i for i, b in enumerate(B) if b["name"] in FEET_NAMES]
ts, ankles = ankle_paths(B, T)
ankle_min = {i: p[:, 2].min() for i, p in zip(FEET, ankles)}
img = np.asarray(Image.open(os.path.join(d, skin)).convert("RGB"), float) / 255
colours = [img[int(v % 1 * (img.shape[0] - 1)), int(u % 1 * (img.shape[1] - 1))]
           for s in S for u, v in (s["uv"][tri].mean(0) for tri in s["tris"])]

fig = plt.figure(figsize=(6, 6), dpi=80)
ax = fig.add_subplot(111, projection="3d")
frames = int(round(3 * cycle * 60))
with tempfile.TemporaryDirectory() as tmp:
    for f in range(frames):
        t = f / 60
        W = pose_at(B, T, t)
        M = [CONV @ W[i] @ inv[i] for i in range(n)]
        ax.cla()
        shift = (speed * t) % 0.25     # ground scrolls back under a walker heading +y
        for x in np.arange(-1, 1.01, 0.25):
            ax.plot([x, x], [-1.5, 1.5], [0, 0], color="grey", linewidth=0.8)
        for y in np.arange(-1.5, 1.51, 0.25) - shift:
            ax.plot([-1, 1], [y, y], [0, 0], color="grey", linewidth=0.8)
        for i, c in zip(FEET, ("red", "blue")):
            p = (CONV @ W[i])[:3, 3]
            planted = p[2] < ankle_min[i] + PLANTED
            ax.scatter([p[0]], [p[1]], [0], s=30, c=c if planted else "none", edgecolors=c)
        polys = []
        for s in S:
            P = np.array([sum(wt * (M[b] @ np.append(v, 1))[:3] for b, wt in wl) for v, wl in zip(s["pos"], s["weights"])])
            polys += [P[tri] for tri in s["tris"]]
        ax.add_collection3d(Poly3DCollection(polys, facecolors=colours, edgecolors="none"))
        ax.set_xlim(-1, 1); ax.set_ylim(-1.5, 1.5); ax.set_zlim(0, 2); ax.set_box_aspect((2, 3, 2))  # noqa: E702
        ax.view_init(elev=8, azim=0); ax.set_axis_off()  # noqa: E702
        ax.set_title("%s %s  speed %.2f m/s  t=%.2fs" % (name, kind, speed, t))
        fig.savefig(os.path.join(tmp, "f%05d.png" % f))
    plt.close(fig)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", os.path.join(tmp, "f%05d.png"),
                    "-pix_fmt", "yuv420p", "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", out], check=True)
print(out, frames, "frames; planted foot slides %.1f cm per stance" % (100 * slide(ts, ankles, cycle, speed)))
