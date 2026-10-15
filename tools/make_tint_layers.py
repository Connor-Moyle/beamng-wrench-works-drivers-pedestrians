"""Clothing tint layers and the helmet, for driver customisation (slrrDrivers.setAppearance).

    python tools/make_tint_layers.py            # after convert_drivers.py and remaster_textures.py

Per driver (art/slrr_drivers/<id>/):
  <stem>_shirt.data.png, <stem>_trousers.data.png   masks: where the shirt / trousers are on the skin
      texture. Drawn from the body's own UV triangles (arms and the torso above the waist are shirt,
      legs and hips are trousers), minus bare skin inside them (a T-shirt's forearms), by colour.
  <stem>_shade.color.png    the cloth's shading as grey, normalised so a garment's average is 0.8;
      the tint layer is this grey times the chosen colour, so folds and seams stay.
  <stem>_tint.bin           the skin, shade and both masks packed (1024 x 1024 x 6 bytes) for baking a
      tinted colour map in game when material layers aren't used.
Per body (art/slrr_drivers/models/<model>/):
  helmet.dae    a closed shell around the head piece (same pivot), material base_helmet.
"""
import glob
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ART = os.path.join(HERE, "..", "mod", "art", "slrr_drivers")
sys.path.insert(0, HERE)
from dae import write_dae  # noqa: E402
from preview import load_dae  # noqa: E402

MASK_PX = 512
SHADE_PX = 1024
SHIRT_PARTS = ("r_upperarm", "l_upperarm", "r_forearm", "l_forearm")
TROUSER_PARTS = ("r_thigh", "l_thigh", "r_calf", "l_calf")


def part_masks(model):
    """UV-space masks (MASK_PX square, 0..255) of the shirt and trousers areas of a body."""
    mdir = os.path.join(ART, "models", model)
    rig = json.load(open(os.path.join(mdir, "rig.json")))
    waist = rig["pelvis"][2] + 0.08          # torso triangles above this are shirt, below are trousers
    shirt = Image.new("L", (MASK_PX, MASK_PX), 0)
    trousers = Image.new("L", (MASK_PX, MASK_PX), 0)
    ds, dt = ImageDraw.Draw(shirt), ImageDraw.Draw(trousers)
    for part in SHIRT_PARTS + TROUSER_PARTS + ("body",):
        pos, uv, tris = load_dae(os.path.join(mdir, part + ".dae"))
        pos = pos + np.array(rig["parts"][part])
        for t in tris:
            poly = [(uv[k][0] % 1 * MASK_PX, (1 - uv[k][1] % 1) * MASK_PX) for k in t]
            if part in SHIRT_PARTS or (part == "body" and pos[t][:, 2].mean() > waist):
                ds.polygon(poly, fill=255)
            else:
                dt.polygon(poly, fill=255)
    return shirt, trousers


def is_skin(rgb):
    """Bare skin by hue (0-35 degrees: reds and browns, not the yellows of a shirt) and moderate saturation."""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    mx, mn = rgb.max(-1), rgb.min(-1)
    d = mx - mn + 1e-6
    hue = np.where(mx == r, ((g - b) / d) % 6, np.where(mx == g, (b - r) / d + 2, (r - g) / d + 4)) * 60
    sat = d / (mx + 1e-6)
    return (mx == r) & (hue < 35) & (sat > 0.15) & (sat < 0.65) & (mx > 0.2)


def make_driver_layers(ddir, model, masks):
    tex = [f for f in glob.glob(os.path.join(ddir, "*.color.png")) if not f.endswith("_shade.color.png")]
    if not tex:
        return None
    stem = os.path.basename(tex[0])[:-len(".color.png")]
    rgb_full = Image.open(tex[0]).convert("RGB")
    rgb = np.asarray(rgb_full.resize((MASK_PX, MASK_PX), Image.BILINEAR), float) / 255
    skin = is_skin(rgb)
    lum_full = np.asarray(rgb_full.resize((SHADE_PX, SHADE_PX), Image.BILINEAR).convert("L"), float) / 255
    shade = np.zeros_like(lum_full)
    out = {}
    for name, m in zip(("shirt", "trousers"), masks):
        mask = (np.asarray(m, float) / 255 > 0.5) & ~skin
        img = Image.fromarray((mask * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.2))
        img.save(os.path.join(ddir, "%s_%s.data.png" % (stem, name)))
        big = np.asarray(img.resize((SHADE_PX, SHADE_PX), Image.BILINEAR), float) / 255 > 0.5
        if big.any():
            mean = lum_full[big].mean()
            shade[big] = np.clip(lum_full[big] / max(mean, 1e-3) * 0.8, 0, 1)
        out[name] = float(mask.mean())
    Image.fromarray((shade * 255).astype(np.uint8)).convert("RGB").save(os.path.join(ddir, stem + "_shade.color.png"))
    # the same at SHADE_PX, packed for baking tints in game (the fallback to material layers):
    # per pixel r, g, b (the skin), shade, shirt mask, trousers mask; rows top to bottom
    base = np.asarray(rgb_full.resize((SHADE_PX, SHADE_PX), Image.BILINEAR), np.uint8)
    m_s = np.asarray(Image.open(os.path.join(ddir, "%s_shirt.data.png" % stem)).resize((SHADE_PX, SHADE_PX), Image.BILINEAR), np.uint8)
    m_t = np.asarray(Image.open(os.path.join(ddir, "%s_trousers.data.png" % stem)).resize((SHADE_PX, SHADE_PX), Image.BILINEAR), np.uint8)
    packed = np.dstack([base, (shade * 255).astype(np.uint8), m_s, m_t])
    open(os.path.join(ddir, stem + "_tint.bin"), "wb").write(packed.tobytes())
    return stem, out


def make_helmet(model):
    """A low-poly closed shell a little larger than the head piece, in the head piece's frame."""
    mdir = os.path.join(ART, "models", model)
    pos, _, _ = load_dae(os.path.join(mdir, "head.dae"))
    lo, hi = pos.min(0), pos.max(0)
    # the helmet covers the skull, not the neck: from a little under the chin line up
    zmid = lo[2] + (hi[2] - lo[2]) * 0.35
    c = np.array([(lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2 - 0.005, (zmid + hi[2]) / 2 + 0.01])
    r = np.array([(hi[0] - lo[0]) / 2 + 0.025, (hi[1] - lo[1]) / 2 + 0.025, (hi[2] - zmid) / 2 + 0.03])
    rings, segs = 10, 20
    verts, nrms, uvs, tris = [], [], [], []
    for i in range(rings + 1):
        th = math.pi * i / rings
        for j in range(segs + 1):
            ph = 2 * math.pi * j / segs
            n = np.array([math.sin(th) * math.cos(ph), math.sin(th) * math.sin(ph), math.cos(th)])
            verts.append(tuple(c + n * r))
            nrms.append(tuple(n))
            uvs.append((j / segs, 1 - i / rings))
    for i in range(rings):
        for j in range(segs):
            a, b = i * (segs + 1) + j, i * (segs + 1) + j + 1
            cc, d = a + segs + 1, b + segs + 1
            tris += [(a, cc, b), (b, cc, d)]
    write_dae(os.path.join(mdir, "helmet.dae"), [("driver_helmet_a", [{"material": "base_helmet", "pos": verts, "nrm": nrms,
                                                                        "uv": uvs, "tris": tris}])])
    return len(tris)


if __name__ == "__main__":
    bodies = {}
    for dj in glob.glob(os.path.join(ART, "*", "driver.json")):
        d = json.load(open(dj))
        bodies.setdefault(d["model"], []).append(os.path.dirname(dj))
    for model, dirs in bodies.items():
        masks = part_masks(model)
        for ddir in dirs:
            print(os.path.basename(ddir), make_driver_layers(ddir, model, masks))
        print(model, "helmet", make_helmet(model), "triangles")
    json.dump({"base_helmet": {"name": "base_helmet", "mapTo": "base_helmet", "class": "Material", "version": 1.5,
                               "materialTag0": "beamng",
                               "Stages": [{"baseColorFactor": [0.9, 0.9, 0.9, 1], "roughnessFactor": 0.25,
                                           "metallicFactor": 0, "clearCoatFactor": 1}, {}, {}, {}]}},
              open(os.path.join(ART, "models", "helmet.materials.json"), "w"), indent=1)
