"""Report a coverage sweep (tools/slrr_sweep.lua) per model: flex or props, mount time, the QA gates of check_recording on that
car's own wheel (rim radius and tilt), head room above the eye, bad numbers in the pose.

    python tools/check_sweep.py <the slrr_sweep folder of the game's user directory> [--json report.json]
A model is flagged when it fell back to props, mounted slowly (over 3 s), has a non-finite or runaway pose, less than 14 cm of room above
the eye node (the top of the head is about 12 cm above it), or a HIGH finding from check_recording.
"""
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_recording as cr  # noqa: E402

HEAD_ROOM = 0.14
MOUNT_S = 3.0


def main(folder):
    summary = json.load(open(os.path.join(folder, "summary.json")))
    rows, report = [], {}
    for s in summary:
        flags = []
        if s.get("error"):
            flags.append(s["error"])
        if not s.get("flex"):
            flags.append("props (no flex driver)")
        if s.get("mountS") and s["mountS"] > MOUNT_S + 4:   # (includes the 4 s settle in the tool)
            flags.append("mount %.1f s" % (s["mountS"] - 4))
        if s.get("bad"):
            flags.append("%d non-finite or runaway pose values" % s["bad"])
        if s.get("roomAboveEye") is not None and s["roomAboveEye"] < HEAD_ROOM:
            flags.append("head room %.2f m" % s["roomAboveEye"])
        if not s.get("hasSeatBack"):
            flags.append("no passenger seat back found (fixed place)")
        res = None
        path = os.path.join(folder, s["model"] + ".json")
        if os.path.exists(path):
            cr.RIM_R = s.get("wheelR") or 0.185
            cr.RIM_TILT = math.radians(s["wheelTilt"]) if s.get("wheelTilt") is not None else math.radians(25)
            res = cr.check(json.load(open(path)))
            flags += ["HIGH " + h for h in res["high"]]
        rows.append((s["model"], "flex" if s.get("flex") else "props", res, flags, s))
        report[s["model"]] = {"flags": flags, "rim_worst": res and res["rim_worst"], "seat_worst": res and res["seat_worst"]}
    for model, rig, res, flags, s in rows:
        print("%-16s %-5s mount %4.1f s  rim %s  room %s  %s" % (
            model, rig, (s.get("mountS") or 0) - 4, "%.3f m" % res["rim_worst"] if res else "-",
            "%.2f" % s["roomAboveEye"] if s.get("roomAboveEye") is not None else "-", "; ".join(flags) or "ok"))
    bad = [r for r in rows if r[3]]
    print("%d models, %d flagged" % (len(rows), len(bad)))
    if "--json" in sys.argv:
        json.dump(report, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1, default=str)


if __name__ == "__main__":
    main(sys.argv[1])
