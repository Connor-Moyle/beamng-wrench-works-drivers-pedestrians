"""Remaster the driver and pedestrian skins and turn them into PBR materials.

    python tools/remaster_textures.py [--upscaler path/to/realesrgan-ncnn-vulkan.exe]

Run after convert_drivers.py / convert_peds.py (build.py does it). For every skin texture in
mod/art/slrr_drivers/<id>/ and mod/art/slrr_pedestrians/<name>/:

1. the SLRR texture is decoded and its DXT1 blocks softened, so they don't get sharpened into detail;
2. it is upscaled 4x with Real-ESRGAN (realesrgan-ncnn-vulkan, model realesrgan-x4plus) when given,
   otherwise with Lanczos and an unsharp mask; drivers end at 2048 px (seen up close), pedestrians 1024;
3. PBR maps are made from it:
   <name>.color.png     base colour (sRGB)
   <name>.normal.png    normal map from the fine detail of the texture (cloth weave, seams, folds)
   <name>_r.data.png    roughness: skin ~0.55, cloth ~0.85, hair, shoes and belts ~0.6, by colour
   <name>_ao.data.png   ambient occlusion from the creases
4. the folder's main.materials.json is rewritten to use them, and the original .dds is removed.
"""
import glob
import json
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

HERE = os.path.dirname(os.path.abspath(__file__))
ART = os.path.join(HERE, "..", "mod", "art")
SIZE = {"slrr_drivers": 2048, "slrr_pedestrians": 1024}
NORMAL_STRENGTH = 2.2


def upscale(img, upscaler):
    img = img.filter(ImageFilter.GaussianBlur(0.45))          # soften DXT1 4x4 blocks first
    if upscaler and os.path.isfile(upscaler):
        with tempfile.TemporaryDirectory() as tmp:
            src, dst = os.path.join(tmp, "in.png"), os.path.join(tmp, "out.png")
            img.save(src)
            subprocess.run([upscaler, "-i", src, "-o", dst, "-n", "realesrgan-x4plus", "-s", "4"],
                           check=True, cwd=os.path.dirname(upscaler), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return Image.open(dst).convert("RGB")
    big = img.resize((img.width * 4, img.height * 4), Image.LANCZOS)
    return big.filter(ImageFilter.UnsharpMask(radius=2, percent=60, threshold=2))


def hsv(rgb):
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    mx, mn = rgb.max(-1), rgb.min(-1)
    d = mx - mn + 1e-6
    h = np.where(mx == r, ((g - b) / d) % 6, np.where(mx == g, (b - r) / d + 2, (r - g) / d + 4)) * 60
    s = np.where(mx > 0, (mx - mn) / (mx + 1e-6), 0)
    return h, s, mx


def pbr_maps(rgb):
    """rgb: float HxWx3 in 0..1. Returns normal (uint8 HxWx3), roughness, ao (uint8 HxW)."""
    lum = rgb @ np.array([0.299, 0.587, 0.114])
    # height from the fine detail only: large-scale shading painted into the skin is not relief
    detail = lum - ndimage.gaussian_filter(lum, 6)
    height = ndimage.gaussian_filter(detail, 0.8)
    h, s, v = hsv(rgb)
    skin = (h < 50) & (s > 0.15) & (s < 0.7) & (v > 0.25)
    dark = v < 0.16                     # hair, shoes, belts
    # painted faces and hands should not turn into relief: skin gets a third of the bump
    strength = NORMAL_STRENGTH * 50 * ndimage.gaussian_filter(np.where(skin, 0.35, 1.0), 3)
    gy, gx = np.gradient(height)
    n = np.dstack([-gx * strength, gy * strength, np.ones_like(height)])   # green up
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    normal = ((n * 0.5 + 0.5) * 255).astype(np.uint8)

    rough = np.full(lum.shape, 0.85)
    rough[skin] = 0.55
    rough[dark & ~skin] = 0.6
    rough = ndimage.gaussian_filter(rough, 2) - detail * 0.6          # worn highlights a little smoother
    rough = (np.clip(rough, 0.25, 0.95) * 255).astype(np.uint8)

    cavity = np.clip(ndimage.gaussian_filter(height, 4) - height, 0, None)
    ao = np.clip(1 - cavity * 6, 0.55, 1)
    ao = (ndimage.gaussian_filter(ao, 1) * 255).astype(np.uint8)
    return normal, rough, ao


replaced = {}   # old .dds path -> new colour map, for other materials that point at it


def remaster_folder(folder, size, upscaler):
    mats_path = os.path.join(folder, "main.materials.json")
    srcs = glob.glob(os.path.join(folder, "*.dds"))
    if not srcs or not os.path.isfile(mats_path):
        return False
    src = srcs[0]
    stem = os.path.splitext(os.path.basename(src))[0].lower()
    img = upscale(Image.open(src).convert("RGB"), upscaler).resize((size, size), Image.LANCZOS)
    rgb = np.asarray(img, float) / 255
    normal, rough, ao = pbr_maps(rgb)
    img.save(os.path.join(folder, stem + ".color.png"))
    # the series' video-memory budget (6 GB): normals at most 1024, roughness and AO at most 256
    side = lambda a, n: Image.fromarray(a).resize((min(size, n), min(size, n)), Image.LANCZOS)   # noqa: E731
    side(normal, 1024).save(os.path.join(folder, stem + ".normal.png"))
    side(rough, 256).save(os.path.join(folder, stem + "_r.data.png"))
    side(ao, 256).save(os.path.join(folder, stem + "_ao.data.png"))
    os.remove(src)
    rel = "/art/" + os.path.relpath(folder, ART).replace(os.sep, "/") + "/" + stem
    replaced["/art/" + os.path.relpath(src, ART).replace(os.sep, "/")] = rel + ".color.png"
    mats = json.load(open(mats_path))
    for m in mats.values():
        m["Stages"][0] = {"baseColorMap": rel + ".color.png", "normalMap": rel + ".normal.png",
                          "roughnessMap": rel + "_r.data.png", "ambientOcclusionMap": rel + "_ao.data.png",
                          "metallicFactor": 0}
    json.dump(mats, open(mats_path, "w"), indent=1)
    return True


def main():
    upscaler = None
    if "--upscaler" in sys.argv:
        upscaler = sys.argv[sys.argv.index("--upscaler") + 1]
    for kind, size in SIZE.items():
        for mats in glob.glob(os.path.join(ART, kind, "*", "main.materials.json")):
            folder = os.path.dirname(mats)
            if os.path.basename(folder) == "models":
                continue
            if remaster_folder(folder, size, upscaler):
                print("remastered", os.path.relpath(folder, ART))
    # other materials using a replaced texture (the drivers' base_driver placeholder)
    for mats_path in glob.glob(os.path.join(ART, "*", "models", "main.materials.json")):
        text = open(mats_path).read()
        for old, new in replaced.items():
            text = text.replace(old, new)
        open(mats_path, "w").write(text)


if __name__ == "__main__":
    main()
