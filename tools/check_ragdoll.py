"""Summarise a ragdoll crash recording (slrrDriverMount.stopRagdollRec): how far the body was thrown from
its seated pose, whether it settled back (belted) or left the seat, and whether the physics stayed sane.

    python tools/check_ragdoll.py <slrr_ragdoll_*.json>

Per node: the largest excursion from its first-frame position, and where it ends up. Flags: a node moving
more than 0.5 m in one frame (the physics exploded), or the pelvis ending more than 0.3 m from the seat
(left the seat / ejected), or NaN.
"""
import json
import math
import sys


def main(path):
    rec = json.load(open(path))
    frames = rec["frames"]
    if not frames:
        print("no frames")
        return 1
    rest = frames[0]["nodes"]
    worst, jump, bad = {}, 0.0, False
    prev = rest
    for fr in frames:
        for name, p in fr["nodes"].items():
            if any(c != c for c in p):
                bad = True
                continue
            worst[name] = max(worst.get(name, 0.0), math.dist(p, rest[name]))
            jump = max(jump, math.dist(p, prev[name]))
        prev = fr["nodes"]
    end = frames[-1]["nodes"]
    peak = max(f["speed"] for f in frames)
    print("%s: %d frames, top speed %.1f m/s" % (path, len(frames), peak))
    for name in ("head", "chest", "pelvis", "r_wr", "l_wr", "r_an", "l_an"):
        if name in worst:
            print("  %-6s thrown %.2f m, ends %.2f m from its seat position" % (name, worst[name], math.dist(end[name], rest[name])))
    verdict = []
    if bad:
        verdict.append("NaN positions")
    if jump > 0.5:
        verdict.append("a node jumped %.2f m in one frame (unstable)" % jump)
    if math.dist(end["pelvis"], rest["pelvis"]) > 0.3:
        verdict.append("the pelvis left the seat")
    print("  " + ("; ".join(verdict) if verdict else "stable, stayed in the seat"))
    return 1 if bad or jump > 0.5 else 0


if __name__ == "__main__":
    sys.exit(max(main(p) for p in sys.argv[1:]))
