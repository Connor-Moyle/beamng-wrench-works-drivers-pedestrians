"""After convert_hd.py: make the HD characters' hands grip a steering wheel.

    python tools/grip_hands.py

convert_hd.py curls the right hands into a loose C (a hole about 20 mm wide where the rim goes) but its left hands come out half open with the
thumb out (the curl turns the wrong way on that side). So each left hand is rebuilt as the mirror image of the right one (x negated in
positions and normals, winding reversed). Then the hole of the right hand (tools/hand_hole.py) is found and written to rig.json as
grip.<side> = {center, axis} (the left one mirrored; `fist`, the point slrrDrivers puts on the rim, is the hole's centre), the changed meshes
are copied to the props (vehicles/common/slrr_drivers/slrr_<model>_<part>.dae) and prop_meshes.py makes the skins' copies.
Running it twice gives the same files.
"""
import json
import os
import re
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import prop_meshes  # noqa: E402
from hand_hole import find_hole  # noqa: E402
from preview import load_dae  # noqa: E402

MOD = os.path.join(HERE, "..", "mod")
GAME = os.path.join(MOD, "vehicles", "common", "slrr_drivers")
MODELS = os.path.join(MOD, "art", "slrr_drivers", "models")
NAMES = ("alison", "carla", "eric", "manuel")


def mirror(text):
    def flip(m):
        v = m.group(2).split()
        v[0::3] = ["%.7g" % -float(x) for x in v[0::3]]
        return m.group(1) + " ".join(v) + "</float_array>"
    for src in ("g0-p-a", "g0-n-a"):
        text = re.sub(r'(<float_array id="%s" count="\d+">)([^<]*)</float_array>' % src, flip, text)

    def wind(m):
        i = m.group(2).split()
        for k in range(0, len(i), 3):
            i[k + 1], i[k + 2] = i[k + 2], i[k + 1]
        return m.group(1) + " ".join(i) + "</p>"
    return re.sub(r"(<p>)([^<]*)</p>", wind, text).replace("driver_rhand", "driver_lhand")


def main():
    for n in NAMES:
        model = "rp_" + n
        mdir = os.path.join(MODELS, model)
        right = open(os.path.join(mdir, "r_hand.dae")).read()
        open(os.path.join(mdir, "l_hand.dae"), "w").write(mirror(right))
        rig = json.load(open(os.path.join(mdir, "rig.json")))
        arm = rig["arms"]["r"]
        fa = np.array(arm["wrist"]) - np.array(arm["elbow"])
        pos, _, tris = load_dae(os.path.join(mdir, "r_hand.dae"))
        c, d, r = find_hole(pos, tris, fa / np.linalg.norm(fa))
        c, d = [round(float(x), 5) for x in c], [round(float(x), 4) for x in d]
        rig["grip"] = {"r": {"center": c, "axis": d, "radius": round(float(r), 4)},
                       "l": {"center": [-c[0], c[1], c[2]], "axis": [-d[0], d[1], d[2]], "radius": round(float(r), 4)}}
        rig["fist"] = {"r": c, "l": [-c[0], c[1], c[2]]}
        json.dump(rig, open(os.path.join(mdir, "rig.json"), "w"), indent=1)
        for part in ("r_hand", "l_hand", "r_forearm", "l_forearm"):
            text = open(os.path.join(mdir, part + ".dae")).read()
            open(os.path.join(GAME, "slrr_%s_%s.dae" % (model, part)), "w", encoding="utf-8", newline="\n").write(
                re.sub(r'name="(driver_[^"]*)"', 'name="slrr_%s_%s"' % (model, part), text))
        print(n, "grip hole %.1f mm, centre %s, axis %s" % (r * 1000, c, d))
    prop_meshes.main()


if __name__ == "__main__":
    main()
