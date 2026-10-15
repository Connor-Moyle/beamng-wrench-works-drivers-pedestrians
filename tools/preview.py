"""Render each driver's baked seated pose (front 3/4 + side) to <driver>/preview.png.
Doubles as the visual check of the converter; colours are sampled from the skin per face."""
import glob
import json
import os
import re
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from mpl_toolkits.mplot3d.art3d import Poly3DCollection  # noqa: E402
from PIL import Image  # noqa: E402

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mod", "art", "slrr_drivers")


def load_dae(path):
    s = open(path, encoding="utf-8").read()
    arr = re.findall(r'<float_array id="[^"]*" count="\d+">([^<]*)</float_array>', s)
    pos = np.array(arr[0].split(), float).reshape(-1, 3)
    uv = np.array(arr[2].split(), float).reshape(-1, 2)
    tris = np.array(re.search(r"<p>([^<]*)</p>", s).group(1).split(), int).reshape(-1, 3)
    return pos, uv, tris


def render(model_dir, skin_path, out, hidden=()):
    rig = json.load(open(os.path.join(model_dir, "rig.json")))
    img = np.asarray(Image.open(skin_path).convert("RGB"), float) / 255
    h, w, _ = img.shape
    polys, cols = [], []
    for part, joint in rig["parts"].items():
        if part in hidden:
            continue
        pos, uv, tris = load_dae(os.path.join(model_dir, part + ".dae"))
        pos = pos + joint
        for t in tris:
            u, v = uv[t].mean(0)
            c = img[int((1 - v) % 1 * (h - 1)), int(u % 1 * (w - 1))]
            n = np.cross(pos[t[1]] - pos[t[0]], pos[t[2]] - pos[t[0]])
            n /= np.linalg.norm(n) + 1e-9
            cols.append(np.clip(c * (0.45 + 0.55 * max(0, n @ np.array([0.3, -0.6, 0.75]))), 0, 1))
            polys.append(pos[t])
    fig = plt.figure(figsize=(8, 4), dpi=80)
    for k, (el, az) in enumerate(((15, 60), (5, 0))):
        ax = fig.add_subplot(1, 2, k + 1, projection="3d")
        ax.add_collection3d(Poly3DCollection(polys, facecolors=cols, edgecolors="none"))
        # wheel rim guide
        a = np.linspace(0, 2 * np.pi, 40)
        t = np.radians(25)
        ax.plot(0.185 * np.cos(a), 0.56 - 0.185 * np.sin(a) * np.sin(t), -0.30 + 0.185 * np.sin(a) * np.cos(t), "k-", lw=1)
        ax.set_xlim(-0.6, 0.6); ax.set_ylim(-0.5, 0.7); ax.set_zlim(-1.0, 0.2)
        ax.set_box_aspect((1.2, 1.2, 1.2))
        ax.view_init(el, az)
        ax.set_axis_off()
    fig.tight_layout()
    fig.savefig(out)
    plt.close(fig)


if __name__ == "__main__":
    for dj in glob.glob(os.path.join(ROOT, "*", "driver.json")):
        d = json.load(open(dj))
        ddir = os.path.dirname(dj)
        skin = (glob.glob(os.path.join(ddir, "*.dds")) + glob.glob(os.path.join(ddir, "*.color.png")))[0]
        render(os.path.join(ROOT, "models", d["model"]), skin, os.path.join(ddir, "preview.png"))
        print(os.path.join(ddir, "preview.png"))
