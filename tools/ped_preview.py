"""Skin a pedestrian at a few walk keys (same maths as the Collada) and render side views: a check of
the animation decode before it goes in game."""
import os, sys
import numpy as np
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from slrr_skin import read_skl, read_skinned_scx
ARGS = sys.argv[1:]
sys.argv = sys.argv[:1]   # convert_peds reads its own argv at import
from convert_peds import read_anim, q2m, local_matrix, CONV, SLRR
name, skin = ARGS[0], ARGS[1]
d = os.path.join(SLRR, "humans", "pedestrians")
B = read_skl(os.path.join(d, name + "_walk.skl")); S = read_skinned_scx(os.path.join(d, name + "_walk.SCX"))
T = read_anim(os.path.join(d, name + "_walk.matrixdata"), B)
n = len(B)
rest = [local_matrix(b["rot"].T, b["pos"]) for b in B]
def worlds(locs):
    W = [None] * n
    def w(i):
        if W[i] is None:
            p = B[i]["parent"]; W[i] = locs[i] if p < 0 else w(p) @ locs[i]
        return W[i]
    for i in range(n): w(i)
    return W
inv = [np.linalg.inv(m) for m in worlds(rest)]
img = np.asarray(Image.open(os.path.join(d, skin)).convert("RGB"), float) / 255
keys = [0, len(T[0]) // 4, len(T[0]) // 2, 3 * len(T[0]) // 4]
fig = plt.figure(figsize=(12, 4), dpi=70)
for k, ki in enumerate(keys):
    locs = [local_matrix(q2m(*T[i][ki][1]), np.array(T[i][ki][2]) * np.linalg.norm(B[i]["pos"])) for i in range(n)]
    W = worlds(locs); M = [CONV @ W[i] @ inv[i] for i in range(n)]
    polys, cols = [], []
    for s in S:
        P = np.array([sum(wt * (M[b] @ np.append(v, 1))[:3] for b, wt in wl) for v, wl in zip(s["pos"], s["weights"])])
        for t in s["tris"]:
            u, v = s["uv"][t].mean(0)
            cols.append(img[int(v % 1 * (img.shape[0] - 1)), int(u % 1 * (img.shape[1] - 1))]); polys.append(P[t])
    ax = fig.add_subplot(1, 4, k + 1, projection="3d")
    ax.add_collection3d(Poly3DCollection(polys, facecolors=cols, edgecolors="none"))
    ax.set_xlim(-0.6, 0.6); ax.set_ylim(-0.6, 0.6); ax.set_zlim(0, 1.9); ax.set_box_aspect((1, 1, 1.6))
    ax.view_init(5, 0); ax.set_axis_off(); ax.set_title("key %d" % ki)
plt.tight_layout(); plt.savefig(ARGS[2])
