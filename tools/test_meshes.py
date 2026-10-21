"""Every mesh the add-on names exists in its shipped files.

    python tools/test_meshes.py
"""
import glob, json, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
ART = os.path.join(HERE, "..", "mod", "art", "slrr_drivers")
COMMON = os.path.join(HERE, "..", "mod", "vehicles", "common", "slrr_drivers")
PARTS = "body head l_calf l_foot l_forearm l_hand l_thigh l_upperarm r_calf r_foot r_forearm r_hand r_thigh r_upperarm".split()


def main():
    bad = []
    for info in glob.glob(os.path.join(ART, "*", "driver.json")):
        d = json.load(open(info, encoding="utf8"))
        model, skin = d.get("model"), d.get("skin")
        if not model:
            continue
        for p in PARTS:
            if not os.path.exists(os.path.join(ART, "models", model, p + ".dae")):
                bad.append("%s: models/%s/%s.dae" % (info, model, p))
        if skin and not os.path.exists(os.path.join(COMMON, skin + "_body.dae")) and skin.startswith("hd_"):
            bad.append("%s: flex body %s_body.dae" % (info, skin))
    # the helmet is only added for a model that ships one
    src = open(os.path.join(HERE, "..", "mod", "lua", "ge", "extensions", "slrrDrivers.lua"), "rb").read().decode("cp1252")
    assert re.search(r"look\.helmet and FS:fileExists\(ROOT \.\. 'models/' \.\. d\.model \.\. '/helmet\.dae'\)", src), "rigged helmet is guarded by the shape's existence"
    assert 'part skipped' in src and 'if not shape then goto continue end' in src, 'a part with no shape is skipped, not drawn'
    assert not bad, bad
    print("meshes ok: every part of every driver model exists, the rigged helmet needs its shape")


if __name__ == "__main__":
    main()
