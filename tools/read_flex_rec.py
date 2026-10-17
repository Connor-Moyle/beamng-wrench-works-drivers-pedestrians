"""Summarise a ragdoll recording (slrrDriverMount.startRagdollRec / stopRagdollRec) of a flex driver: per joint node the range
it moved through in the seat frame, and how far it was from the target slrrDrivers sent (JOINTS order below).

    python tools/read_flex_rec.py recording.json
"""
import json
import sys

JOINTS = ["r_el", "l_el", "r_wr", "l_wr", "r_kn", "l_kn", "r_an", "l_an", "head"]


def main(path):
    rec = json.load(open(path))
    frames = rec["frames"]
    print("%d frames, max speed %.1f m/s" % (len(frames), max(f["speed"] for f in frames)))
    for name in sorted(rec["nodes"]):
        pts = [f["nodes"][name] for f in frames if name in f["nodes"]]
        lo = [min(p[i] for p in pts) for i in range(3)]
        hi = [max(p[i] for p in pts) for i in range(3)]
        line = "%-7s x %.2f..%.2f  y %.2f..%.2f  z %.2f..%.2f" % (name, lo[0], hi[0], lo[1], hi[1], lo[2], hi[2])
        if name in JOINTS:
            k = JOINTS.index(name)
            errs = [sum((a - b) ** 2 for a, b in zip(f["nodes"][name], f["targets"][k])) ** 0.5 for f in frames if f.get("targets")]
            if errs:
                line += "   target error mean %.3f max %.3f m" % (sum(errs) / len(errs), max(errs))
        print(line)


if __name__ == "__main__":
    main(sys.argv[1])
