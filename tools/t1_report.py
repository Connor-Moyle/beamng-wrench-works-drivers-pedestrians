"""Report on a pedestrian recording from the game (slrrPedestrians.record, written by tools/t1_peds.js):

    python t1_report.py [recording.json]

Frame time (and whether frames with a walk/idle shape swap are slower: the swap hitch), position pops (a jump
bigger than walking or dodging can explain), and the closest a moving car came to anyone on a road crossing (K5).
Prints PASS / MED / HIGH per check.
"""
import json
import math
import os
import sys

import numpy as np

REC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.environ["LOCALAPPDATA"], "BeamNG", "BeamNG.drive", "current",
                                                         "temp", "slrr_peds_t1.json")
POP = 0.25         # metres beyond what walking at 1.3 m/s plus a dodge could cover in the frame


def main():
    frames = json.load(open(REC))["frames"]
    ms = np.array([f["ms"] for f in frames])
    swap = np.zeros(len(frames), bool)
    pops, near_car = [], math.inf
    last = {}
    for i, f in enumerate(frames):
        dt = f["ms"] / 1000
        for p in f["peds"]:
            prev = last.get(p["id"])
            if prev:
                if prev["shape"] != p["shape"]:
                    swap[i] = True
                jump = math.hypot(p["x"] - prev["x"], p["y"] - prev["y"])
                if jump > 1.3 * dt + 6 * dt + POP:
                    pops.append((round(f["t"], 2), p["id"], round(jump, 2), prev["shape"] != p["shape"]))
            last[p["id"]] = p
            if p["cross"]:
                for c in f["cars"]:
                    if c["v"] > 1:
                        near_car = min(near_car, math.hypot(p["x"] - c["x"], p["y"] - c["y"]))
    med = float(np.median(ms))
    print("%d frames, %.1f s: frame time median %.2f ms, p95 %.2f, worst %.2f" % (
        len(ms), sum(ms) / 1000, med, np.percentile(ms, 95), ms.max()))
    if swap.any():
        hitch = float(np.mean(ms[swap]) - np.mean(ms[~swap]))
        print("walk/idle swaps in %d frames: %+.2f ms on those frames -> %s" % (
            swap.sum(), hitch, "PASS" if hitch < 1 else "MED" if hitch < 4 else "HIGH"))
    else:
        print("no walk/idle swaps recorded")
    print("pops: %d -> %s" % (len(pops), "PASS" if not pops else "HIGH"), pops[:8])
    print("closest moving car to someone on a road crossing: %s -> %s" % (
        "none seen" if near_car == math.inf else "%.1f m" % near_car,
        "PASS" if near_car > 2.5 else "HIGH"))


if __name__ == "__main__":
    main()
