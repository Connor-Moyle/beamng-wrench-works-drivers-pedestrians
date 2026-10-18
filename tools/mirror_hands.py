"""The HD characters' left hands came out of convert_hd.py half open with the thumb out (the finger curl turned the wrong way on that side), the
right hands are clean fists. Rebuild each left hand as the mirror image of its right hand: x negated in positions and normals, the winding
reversed, the fist point in rig.json mirrored. Run it after convert_hd.py (it rewrites the files in place; running it twice gives the same files).

    python tools/mirror_hands.py
"""
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.join(HERE, "..", "mod")
GAME = os.path.join(MOD, "vehicles", "common", "slrr_drivers")
MODELS = os.path.join(MOD, "art", "slrr_drivers", "models")
NAMES = ("alison", "carla", "eric", "manuel")


def mirror(text, old, new):
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
    text = re.sub(r"(<p>)([^<]*)</p>", wind, text)
    return text.replace(old, new)


def main():
    for n in NAMES:
        src = open(os.path.join(GAME, "hd_%s_r_hand.dae" % n)).read()
        open(os.path.join(GAME, "hd_%s_l_hand.dae" % n), "w").write(mirror(src, "hd_%s_r_hand" % n, "hd_%s_l_hand" % n))
        mdir = os.path.join(MODELS, "rp_" + n)
        src = open(os.path.join(mdir, "r_hand.dae")).read()
        out = mirror(src, "driver_rhand", "driver_lhand")
        open(os.path.join(mdir, "l_hand.dae"), "w").write(out)
        rig = json.load(open(os.path.join(mdir, "rig.json")))
        x, y, z = rig["fist"]["r"]
        rig["fist"]["l"] = [-x, y, z]
        json.dump(rig, open(os.path.join(mdir, "rig.json"), "w"), indent=1)
        print(n, "left hand = mirrored right hand, fist", rig["fist"]["l"])


if __name__ == "__main__":
    main()
