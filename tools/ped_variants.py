"""Clothing variants of the pedestrians, recoloured from the existing textures (W8: types per area).

    python tools/ped_variants.py            (after convert_peds.py / remaster_textures.py; build.py runs it)

For every pedestrian folder mod/art/slrr_pedestrians/<name>/ (one with <name>.dae) and every variant below, a
folder <name>_<variant>/ is written: the walk and idle shapes copied with their material renamed, a recoloured
base colour (the skin is kept, the clothes are tinted), a materials file that reuses the base folder's normal,
roughness and ambient-occlusion maps, and a ped.json with the variant's "kind" (what density_<level>.json's
areas ask for by "types"). The base folders get "kind": "casual". Re-running overwrites the variants.
"""
import glob
import json
import os
import shutil

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
PEDS = os.path.join(HERE, "..", "mod", "art", "slrr_pedestrians")

# tint: the colour the clothes are pulled towards, k: how far (0..1); sat / val: multipliers after that
VARIANTS = {
    "worker": dict(kind="worker", tint=(255, 120, 0), k=0.55, sat=1.25, val=1.05),     # hi-vis orange
    "business": dict(kind="business", tint=(30, 32, 48), k=0.6, sat=0.45, val=0.85),   # a dark suit
}
SHAPES = ("", "_slow", "_fast", "_idle")   # the cheer shape (spectators) is left to the base types


def skin_mask(rgb):
    """Skin (and close hair tones): a warm hue with middling saturation, not too dark."""
    r, g, b = [rgb[..., i].astype(np.float32) / 255 for i in range(3)]
    mx, mn = np.max(rgb, axis=-1).astype(np.float32) / 255, np.min(rgb, axis=-1).astype(np.float32) / 255
    sat = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0)
    warm = (r > g) & (g >= b * 0.95) & (r - b > 0.08)
    return warm & (sat > 0.12) & (sat < 0.8) & (mx > 0.3)


def recolour(src, dst, spec):
    im = Image.open(src).convert("RGB")
    rgb = np.asarray(im).astype(np.float32)
    keep = skin_mask(rgb)
    tint = np.array(spec["tint"], dtype=np.float32)
    lum = rgb.mean(axis=-1, keepdims=True)                      # the folds and shading survive the tint
    out = rgb * (1 - spec["k"]) + (tint * (lum / 255)) * spec["k"]
    mean = out.mean(axis=-1, keepdims=True)
    out = mean + (out - mean) * spec["sat"]
    out = out * spec["val"]
    out = np.where(keep[..., None], rgb, out)
    Image.fromarray(np.clip(out, 0, 255).astype(np.uint8)).save(dst)
    return int(keep.sum())


def make_variant(name, variant, spec):
    base = os.path.join(PEDS, name)
    out = os.path.join(PEDS, "%s_%s" % (name, variant))
    os.makedirs(out, exist_ok=True)
    vname = "%s_%s" % (name, variant)
    for suffix in SHAPES:
        src = os.path.join(base, name + suffix + ".dae")
        if not os.path.exists(src):
            continue
        text = open(src, encoding="utf-8").read()
        text = text.replace('name="slrr_ped_%s"' % name, 'name="slrr_ped_%s"' % vname)
        open(os.path.join(out, vname + suffix + ".dae"), "w", encoding="utf-8").write(text)
    kept = recolour(os.path.join(base, name + ".color.png"), os.path.join(out, vname + ".color.png"), spec)
    mats = json.load(open(os.path.join(base, "main.materials.json")))
    stage = mats["slrr_ped_" + name]["Stages"][0]
    mats = {"slrr_ped_" + vname: {
        "name": "slrr_ped_" + vname, "mapTo": "slrr_ped_" + vname, "class": "Material", "version": 1.5, "materialTag0": "beamng",
        "Stages": [dict(stage, baseColorMap="/art/slrr_pedestrians/%s/%s.color.png" % (vname, vname)), {}, {}, {}]}}
    json.dump(mats, open(os.path.join(out, "main.materials.json"), "w"), indent=1)
    ped = json.load(open(os.path.join(base, "ped.json")))
    walks = {k.replace(name, vname, 1): v for k, v in ped.get("walks", {}).items()}
    info = {"kind": spec["kind"], "cycle": ped.get("cycle"), "walks": walks}
    if ped.get("idle"):
        info["idle"], info["idleCycle"] = ped["idle"].replace(name, vname, 1), ped.get("idleCycle")
    json.dump({k: v for k, v in info.items() if v is not None}, open(os.path.join(out, "ped.json"), "w"), indent=1)
    return kept


def main():
    bases = [d for d in sorted(os.listdir(PEDS)) if os.path.exists(os.path.join(PEDS, d, d + ".dae")) and "_" not in d]
    for name in bases:
        p = os.path.join(PEDS, name, "ped.json")
        ped = json.load(open(p))
        if ped.get("kind") != "casual":
            ped["kind"] = "casual"
            json.dump(ped, open(p, "w"), indent=1)
        for variant, spec in VARIANTS.items():
            kept = make_variant(name, variant, spec)
            print("%s_%s: skin kept on %d px" % (name, variant, kept))
    print("%d base types, %d variants" % (len(bases), len(bases) * len(VARIANTS)))


if __name__ == "__main__":
    main()
