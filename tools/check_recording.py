"""Check a driver pose recording against the QA gates (QA_MASTER.md, section J) and report them.

    python tools/check_recording.py recording.json [more.json ...] [--json report.json]

Per recording, from every frame:
  J1 rim    each fist's distance from the steering-wheel rim (not while that hand is re-gripping or on
            the gear lever): over 5 cm counts as off the rim
  J1 clip   arms through each other, through the torso or thighs, or through the wheel's disc
  J2 feet   a foot below the measured floor or past the firewall (recorded "feet" clearances)
            (capsule tests with the parts' joints; 2 cm of overlap is allowed for skin and sleeves)
  J1 pops   any joint moving more than 5 cm in one frame
  J2 seat   the body more than 7.5 cm from where it sat in the first frame (recordings start at rest)
  J6 cost   all drivers' ms per frame (smoothed, from the game)
Severity: HIGH = a pop, a seat breach, clipping in more than 3 frames, or off the rim in more than 10% of
frames; MED = off the rim in 2-10% of frames or any clipping; otherwise PASS.
"""
import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ART = os.path.join(HERE, "..", "mod", "art", "slrr_drivers")
sys.path.insert(0, HERE)
from preview import load_dae  # noqa: E402

RIM_R, RIM_TILT = 0.185, math.radians(25)
RIM_OFF = 0.05
POP = 0.05
SEAT = 0.075
OVERLAP = 0.02
R_ARM, R_HAND, R_LEG, R_TORSO = 0.045, 0.045, 0.065, 0.12
JOINTS = {"head": "neck", "r_upperarm": "r_shoulder", "r_forearm": "r_elbow", "r_hand": "r_wrist",
          "l_upperarm": "l_shoulder", "l_forearm": "l_elbow", "l_hand": "l_wrist", "r_thigh": "r_hip",
          "r_calf": "r_knee", "r_foot": "r_ankle", "l_thigh": "l_hip", "l_calf": "l_knee", "l_foot": "l_ankle"}


def seg_dist(p1, q1, p2, q2):
    """Closest distance between segments p1-q1 and p2-q2."""
    d1, d2, r = q1 - p1, q2 - p2, p1 - p2
    a, e, f = d1 @ d1, d2 @ d2, d2 @ r
    if a < 1e-12 and e < 1e-12:
        return float(np.linalg.norm(r))
    if a < 1e-12:
        s, t = 0.0, min(max(f / e, 0), 1)
    else:
        c = d1 @ r
        if e < 1e-12:
            t, s = 0.0, min(max(-c / a, 0), 1)
        else:
            b = d1 @ d2
            den = a * e - b * b
            s = min(max((b * f - c * e) / den, 0), 1) if den > 1e-12 else 0.0
            t = (b * s + f) / e
            if t < 0:
                t, s = 0.0, min(max(-c / a, 0), 1)
            elif t > 1:
                t, s = 1.0, min(max((b - c) / a, 0), 1)
    return float(np.linalg.norm((p1 + d1 * s) - (p2 + d2 * t)))


def rim_dist(q, c):
    n = np.array([0, -math.cos(RIM_TILT), math.sin(RIM_TILT)])
    v = q - c
    h = v @ n
    planar = v - h * n
    return math.hypot(h, np.linalg.norm(planar) - RIM_R)


def through_disc(a, b, c):
    """Does segment a-b pass through the wheel's disc (inside the rim)?"""
    n = np.array([0, -math.cos(RIM_TILT), math.sin(RIM_TILT)])
    da, db = (a - c) @ n, (b - c) @ n
    if da * db >= 0:
        return False
    p = a + (b - a) * (da / (da - db))
    return np.linalg.norm(p - c) < RIM_R - 0.03


def check(rec):
    model = rec["model"]
    rig = json.load(open(os.path.join(ART, "models", model, "rig.json")))
    # the middle of each fist, relative to the wrist, in the hand piece's own frame
    fist = {}
    for side in "rl":
        pos, _, _ = load_dae(os.path.join(ART, "models", model, side + "_hand.dae"))
        fist[side] = pos.mean(0)
    pelvis = np.array(rig["pelvis"])
    frames = rec["frames"]
    out = {"feet": [], "frames": len(frames), "rim_off": 0, "rim_checked": 0, "rim_worst": 0.0, "clips": 0, "clip_kinds": {},
           "pops": [], "seat_worst": 0.0, "cost_ms": 0.0}
    prev, base = None, []
    for i, fr in enumerate(frames):
        P = fr["parts"]

        def pose(name):
            v = P[name]
            return np.array(v[0:3]), np.array([v[3:6], v[6:9], v[9:12]]).T
        j = {JOINTS[k]: pose(k)[0] for k in JOINTS if k in P}
        for side in "rl":
            p, R = pose(side + "_hand")
            j[side + "_fist"] = p + R @ fist[side]
        bp, bR = pose("body")
        j["pelvis"] = bp + bR @ pelvis
        c = np.array(fr["wheel"])
        # J1 rim
        for side in "rl":
            on_lever = fr.get("shiftSide") == side and fr.get("reach", 0) > 0.05
            on_lever = on_lever or fr.get("revK", 0) > 0.05     # reversing: hands deliberately moved (seat back, top of rim)
            on_lever = on_lever or (fr.get("shiftSide") == side and fr.get("daze", 0) > 0.01)   # holding his head after a crash
            regrip = (fr.get("regrip") or {}).get(side, 0)
            if not on_lever and not regrip:
                d = rim_dist(j[side + "_fist"], c)
                out["rim_checked"] += 1
                out["rim_worst"] = max(out["rim_worst"], d)
                out["rim_off"] += d > RIM_OFF
        # J2 feet: above the measured floor and behind the firewall in every frame
        for side, f in (fr.get("feet") or {}).items():
            if f.get("floor") is not None and f["floor"] < -0.01:
                out["feet"].append("J2 %s foot %.3f m through the floor" % (side, -f["floor"]))
            if f.get("wall") is not None and f["wall"] < -0.01:
                out["feet"].append("J2 %s foot %.3f m through the firewall" % (side, -f["wall"]))
        # J1 clipping
        caps = {"r_upper": (j["r_shoulder"], j["r_elbow"], R_ARM), "l_upper": (j["l_shoulder"], j["l_elbow"], R_ARM),
                "r_fore": (j["r_elbow"], j["r_fist"], R_HAND), "l_fore": (j["l_elbow"], j["l_fist"], R_HAND),
                "torso": (j["pelvis"], j["neck"], R_TORSO),
                "r_thigh": (j["r_hip"], j["r_knee"], R_LEG), "l_thigh": (j["l_hip"], j["l_knee"], R_LEG)}
        pairs = [("r_fore", "l_fore"), ("r_fore", "l_upper"), ("l_fore", "r_upper"), ("r_upper", "l_upper"),
                 ("r_fore", "torso"), ("l_fore", "torso"), ("r_fore", "r_thigh"), ("l_fore", "l_thigh"),
                 ("r_fore", "l_thigh"), ("l_fore", "r_thigh")]
        hit = []
        for a, b in pairs:
            (a0, a1, ra), (b0, b1, rb) = caps[a], caps[b]
            if seg_dist(a0, a1, b0, b1) < ra + rb - OVERLAP:
                hit.append(a + "/" + b)
        for side in "rl":
            if through_disc(j[side + "_elbow"], j[side + "_fist"], c):
                hit.append(side + "_fore/wheel")
        if hit:
            out["clips"] += 1
            for h in hit:
                out["clip_kinds"][h] = out["clip_kinds"].get(h, 0) + 1
        # J1 pops
        if prev is not None:
            for k, v in j.items():
                step = float(np.linalg.norm(v - prev[k]))
                if step > POP:
                    out["pops"].append((i, k, round(step, 3)))
        prev = j
        # J2 seat: against where the body sat in the first frame (recordings start at rest)
        if not base:
            base.append(bp)
        out["seat_worst"] = max(out["seat_worst"], float(np.linalg.norm(bp - base[0])))
        out["cost_ms"] = max(out["cost_ms"], fr.get("perfMs") or 0)
    rim_frac = out["rim_off"] / max(1, out["rim_checked"])
    high, med = [], []
    if out["pops"]:
        high.append("J1 %d pops (worst %s)" % (len(out["pops"]), max(out["pops"], key=lambda p: p[2])))
    if out["seat_worst"] > SEAT:
        high.append("J2 body %.3f m from the seat" % out["seat_worst"])
    if out["feet"]:
        high.append("%s (%d frames)" % (out["feet"][0], len(out["feet"])))
    if out["clips"] > 3:
        high.append("J1 clipping in %d frames %s" % (out["clips"], out["clip_kinds"]))
    elif out["clips"]:
        med.append("J1 clipping in %d frames %s" % (out["clips"], out["clip_kinds"]))
    if rim_frac > 0.10:
        high.append("J1 hands off the rim in %.0f%% of frames (worst %.3f m)" % (100 * rim_frac, out["rim_worst"]))
    elif rim_frac > 0.02:
        med.append("J1 hands off the rim in %.0f%% of frames (worst %.3f m)" % (100 * rim_frac, out["rim_worst"]))
    if out["cost_ms"] > 1.0:
        high.append("J6 drivers cost %.2f ms per frame" % out["cost_ms"])
    out.update(high=high, med=med, rim_frac=rim_frac, pops=out["pops"][:20])
    return out


if __name__ == "__main__":
    paths = [a for a in sys.argv[1:] if a.endswith(".json") and a != (sys.argv[sys.argv.index("--json") + 1] if "--json" in sys.argv else None)]
    reports = {}
    for path in paths:
        r = check(json.load(open(path)))
        reports[os.path.basename(path)] = r
        verdict = "HIGH" if r["high"] else ("MED" if r["med"] else "PASS")
        print("%s: %s  (%d frames; rim off %.1f%%, worst %.3f m; clips %d; pops %d; seat %.3f m; cost %.2f ms)" % (
            os.path.basename(path), verdict, r["frames"], 100 * r["rim_frac"], r["rim_worst"], r["clips"],
            len(r["pops"]), r["seat_worst"], r["cost_ms"]))
        for h in r["high"]:
            print("   HIGH", h)
        for m in r["med"]:
            print("   MED ", m)
    if "--json" in sys.argv:
        json.dump(reports, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1, default=str)
