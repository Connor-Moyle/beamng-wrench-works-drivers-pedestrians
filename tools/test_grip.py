"""The gripping hands (an HD character's rig.json has grip.<side> = the hole of the curled fingers): while a hand holds the rim, its hole is on
the rim's centre line and its axis runs along the rim. Drives the stress script's cycle with rp_eric and reads the recording."""
import json
import math
import os
import sys
import tempfile

import numpy as np

os.environ["SLRR_RIG_MODEL"] = "rp_eric"
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.argv = sys.argv[:1]
import stress_driver as sd  # noqa: E402


def main():
    sd.HAND_JUMP = 1.0            # (the stress script's own pop gate is checked with the default rig; here only the grip)
    path = os.path.join(tempfile.mkdtemp(), "grip.json")
    sd.run(True, path)
    rec = json.load(open(path))
    rig = json.load(open(os.path.join(HERE, "..", "mod", "art", "slrr_drivers", "models", rec["model"], "rig.json")))
    grip = {s: (np.array(rig["grip"][s]["center"]), np.array(rig["grip"][s]["axis"]) / np.linalg.norm(rig["grip"][s]["axis"])) for s in "rl"}
    t = math.radians(25)
    n = np.array([0, -math.cos(t), math.sin(t)])
    x = np.array([1, 0, 0])
    u = np.cross(n, x)
    checked, worst = 0, {"radial": 0.0, "out": 0.0, "axis": 1.0}
    axes, radials = [], []
    for i, fr in enumerate(rec["frames"]):
        if i < 60 or fr["revK"] > 0.01 or fr["reach"] > 0.01 or fr["daze"] > 0.01:
            continue
        for s in "rl":
            if fr["regrip"][s] > 0:
                continue
            pose = fr["parts"][s + "_hand"]
            p0, rot = np.array(pose[:3]), np.array([pose[3:6], pose[6:9], pose[9:12]]).T
            q = p0 + rot @ grip[s][0] - np.array(fr["wheel"])
            w = rot @ grip[s][1]
            a = math.atan2(q @ u, q @ x)
            tangent = -math.sin(a) * x + math.cos(a) * u
            worst["radial"] = max(worst["radial"], abs(math.hypot(q @ x, q @ u) - 0.171))
            worst["out"] = max(worst["out"], abs(q @ n - 0.006))
            worst["axis"] = min(worst["axis"], abs(w @ tangent))
            axes.append(abs(w @ tangent))
            radials.append(abs(math.hypot(q @ x, q @ u) - 0.171))
            checked += 1
    assert checked > 1000, checked
    # (a hand just after a re-grip is still turning into place, GRIP_TURN a second: the odd frame is off, so percentiles)
    assert np.percentile(axes, 5) > 0.8 and np.percentile(axes, 50) > 0.98 and np.percentile(radials, 95) < 0.01, (
        np.percentile(axes, [5, 50]), np.percentile(radials, 95))
    print("grip ok: %d hand-frames, the hole on the rim's centre line (95%% within %.0f mm), its axis along the rim (5%% below %.2f)" % (
        checked, 1000 * np.percentile(radials, 95), np.percentile(axes, 5)))


if __name__ == "__main__":
    main()
