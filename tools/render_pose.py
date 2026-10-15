"""Render a driver pose recording to a video, for reviewing the animation frame by frame.

    python tools/render_pose.py recording.json out.mp4 [--view outside|inside|both] [--fps 60] [--frames a:b]

A recording comes from slrrDrivers.startRecording(vehId) / stopRecording(vehId, path) in the game,
or from tools/stress_driver.py. Each frame holds every part's pose in the seat frame (x right,
y forward, z up, origin at the eyes). The parts are drawn with their real meshes and skin
(flat-shaded, depth-sorted), with the steering wheel rim for reference, and a caption with
speed, steering, pedals and gear. ffmpeg makes the video.
"""
import json
import math
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ART = os.path.join(HERE, "..", "mod", "art", "slrr_drivers")
sys.path.insert(0, HERE)
from preview import load_dae  # noqa: E402

W, H = 640, 480
LIGHT = np.array([0.3, -0.5, 0.8]) / np.linalg.norm([0.3, -0.5, 0.8])
VIEWS = {   # camera position, look-at point (seat frame), vertical field of view
    "outside": (np.array([-1.5, 0.25, -0.25]), np.array([0.0, 0.25, -0.45]), 50),
    "inside": (np.array([0.0, 0.0, 0.0]), np.array([0.0, 1.0, -0.35]), 75),
}


def load_parts(model, skin):
    mdir = os.path.join(ART, "models", model)
    rig = json.load(open(os.path.join(mdir, "rig.json")))
    tex_dir = os.path.join(ART, skin)
    tex = [f for f in os.listdir(tex_dir) if f.endswith(".color.png") or f.endswith(".dds")][0]
    img = np.asarray(Image.open(os.path.join(tex_dir, tex)).convert("RGB"), float) / 255
    parts = {}
    for name in rig["parts"]:
        pos, uv, tris = load_dae(os.path.join(mdir, name + ".dae"))
        u, v = uv[tris].mean(1).T
        cols = img[((1 - v) % 1 * (img.shape[0] - 1)).astype(int), (u % 1 * (img.shape[1] - 1)).astype(int)]
        parts[name] = (pos, tris, cols)
    return parts


def camera(view):
    eye, at, fov = VIEWS[view]
    f = (at - eye) / np.linalg.norm(at - eye)
    r = np.cross(f, [0, 0, 1])
    r /= np.linalg.norm(r)
    u = np.cross(r, f)
    return eye, np.array([r, u, f]), H / 2 / math.tan(math.radians(fov) / 2)


def rim(fr):
    c = np.array(fr["wheel"])
    t = math.radians(25)
    a = np.linspace(0, 2 * math.pi, 48)
    return np.stack([0.185 * np.cos(a), -0.185 * np.sin(a) * math.sin(t), 0.185 * np.sin(a) * math.cos(t)], 1) + c


def draw(fr, parts, view):
    eye, cam, focal = camera(view)
    im = Image.new("RGB", (W, H), (205, 214, 224))
    d = ImageDraw.Draw(im)
    polys = []
    for name, (pos, tris, cols) in parts.items():
        pose = fr["parts"].get(name)
        if not pose or pose[12] or (view == "inside" and name == "head"):
            continue   # the game hides the head from the driver camera
        p0 = np.array(pose[0:3])
        R = np.array([pose[3:6], pose[6:9], pose[9:12]]).T     # columns: the part's axes
        world = pos @ R.T + p0
        v = (world - eye) @ cam.T                               # camera space: x right, y up, z forward
        tri = v[tris]
        n = np.cross(world[tris[:, 1]] - world[tris[:, 0]], world[tris[:, 2]] - world[tris[:, 0]])
        n /= np.linalg.norm(n, axis=1, keepdims=True) + 1e-9
        shade = 0.45 + 0.55 * np.clip(n @ LIGHT, 0, 1)
        z = tri[:, :, 2]
        facing = np.einsum("ij,ij->i", n, world[tris[:, 0]] - eye) < 0    # back faces aren't drawn, as in the game
        ok = (z > 0.05).all(1) & facing
        xy = np.stack([W / 2 + tri[:, :, 0] / z * focal, H / 2 - tri[:, :, 1] / z * focal], 2)
        for k in np.nonzero(ok)[0]:
            polys.append((z[k].mean(), xy[k], tuple(int(c) for c in np.clip(cols[k] * shade[k] * 255, 0, 255))))
    polys.sort(key=lambda t: -t[0])
    for _, xy, col in polys:
        d.polygon([tuple(p) for p in xy], fill=col)
    # wheel rim for reference
    v = (rim(fr) - eye) @ cam.T
    if (v[:, 2] > 0.05).all():
        d.line([(W / 2 + p[0] / p[2] * focal, H / 2 - p[1] / p[2] * focal) for p in v], fill=(40, 40, 40), width=3)
    d.text((8, 8), "%s  %5.1f m/s  steer %4.0f  thr %.2f  brk %.2f  clu %.2f  gear %d" % (
        view, fr["speed"], fr["steer"], fr["throttle"], fr["brake"], fr.get("clutch") or 0, fr["gear"]), fill=(0, 0, 0))
    return im


def render(rec, out, views=("outside",), fps=60, frames=None):
    parts = load_parts(rec["model"], rec["skin"])
    fr_list = rec["frames"][slice(*frames) if frames else slice(None)]
    with tempfile.TemporaryDirectory() as tmp:
        for i, fr in enumerate(fr_list):
            ims = [draw(fr, parts, v) for v in views]
            sheet = Image.new("RGB", (W * len(ims), H))
            for k, im in enumerate(ims):
                sheet.paste(im, (W * k, 0))
            sheet.save(os.path.join(tmp, "f%05d.png" % i))
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(fps), "-i", os.path.join(tmp, "f%05d.png"),
                        "-pix_fmt", "yuv420p", "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", out], check=True)
    return len(fr_list)


if __name__ == "__main__":
    rec = json.load(open(sys.argv[1]))
    view = sys.argv[sys.argv.index("--view") + 1] if "--view" in sys.argv else "both"
    fps = int(sys.argv[sys.argv.index("--fps") + 1]) if "--fps" in sys.argv else 60
    frames = None
    if "--frames" in sys.argv:
        a, b = sys.argv[sys.argv.index("--frames") + 1].split(":")
        frames = (int(a or 0), int(b) if b else None)
    n = render(rec, sys.argv[2], ("outside", "inside") if view == "both" else (view,), fps, frames)
    print("rendered %d frames to %s" % (n, sys.argv[2]))
