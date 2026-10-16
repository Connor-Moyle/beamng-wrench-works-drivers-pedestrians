"""Per-skin driver meshes for the car's props: vehicles/common/slrr_drivers/<skin>_<part>.dae.

    python tools/prop_meshes.py

A prop drawn by the car cannot take a material override at runtime (it crashes the engine, slot of
2026-10-16), so each driver skin gets its own copy of its model's 14 part meshes with the skin's material
(<skin>_driver) named in the dae. Made from the per-model prop meshes slrr_<model>_<part>.dae in the same
folder by renaming.
shortcut: the per-model meshes are the committed source instead of art/slrr_drivers/models, so every skin
costs 1.2 MB of copies; when the props ship, write them from the model daes and drop the per-model set.
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ART = os.path.join(HERE, "..", "mod", "art", "slrr_drivers")
OUT = os.path.join(HERE, "..", "mod", "vehicles", "common", "slrr_drivers")
PARTS = ["body", "head", "r_upperarm", "r_forearm", "r_hand", "l_upperarm", "l_forearm", "l_hand",
         "r_thigh", "r_calf", "r_foot", "l_thigh", "l_calf", "l_foot"]


def main():
    n = 0
    for d in sorted(os.listdir(ART)):
        path = os.path.join(ART, d, "driver.json")
        if not os.path.isfile(path):
            continue
        info = json.load(open(path))
        skin, model = info.get("skin", d), info["model"]
        for part in PARTS:
            src = os.path.join(OUT, "slrr_%s_%s.dae" % (model, part))
            dst = os.path.join(OUT, "%s_%s.dae" % (skin, part))
            text = open(src, encoding="utf-8").read()
            assert text.count("slrr_%s_%s" % (model, part)) >= 1, src
            if src != dst:   # a skin named after its model (slrr_police) is its own source: only the material changes
                assert text.count('name="base_driver"') == 1, src
                text = text.replace("slrr_%s_%s" % (model, part), "%s_%s" % (skin, part))
            text = text.replace('name="base_driver"', 'name="%s_driver"' % skin)
            open(dst, "w", encoding="utf-8", newline="\n").write(text)
            n += 1
    print("%d prop meshes written to %s" % (n, os.path.relpath(OUT)))


if __name__ == "__main__":
    main()
