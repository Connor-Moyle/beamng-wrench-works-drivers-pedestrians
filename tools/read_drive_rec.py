"""Find the driver's visible snap backward in a drive recording (slrrDrivers.startRecording(vid) ... stopRecording(vid, 'settings/x.json')).

    python tools/read_drive_rec.py recording.json

Per frame the body's place relative to the eye (seat frame: x right, y forward, z up), the eye's and the car's world places, the frame time. A snap
is a frame where the body moves back (negative y) by more than STEP in one frame; for each it prints what else happened that frame: the frame time
against the average, the eye's step against the car's, the speed and the pedals, so the cause shows: a frame-time spike (render lag), the eye jumping
(the seat attach reading a frame late), the sway clamp (body at its limit), or none of these (the sway spring itself).
"""
import json
import math
import sys

STEP = 0.01   # m in one frame


def main(path):
    rec = json.load(open(path))
    fr = rec["frames"]
    body = [f["parts"]["body"][:3] for f in fr]
    dts = [f["dt"] for f in fr]
    avg = sum(dts) / len(dts)
    print("%d frames, mean dt %.1f ms (max %.1f ms), max speed %.1f m/s" % (len(fr), avg * 1000, max(dts) * 1000, max(f["speed"] for f in fr)))
    worst = []
    for i in range(1, len(fr)):
        dy = body[i][1] - body[i - 1][1]
        dist = math.dist(body[i], body[i - 1])
        if dy < -STEP or dist > 2 * STEP:
            eye = math.dist(fr[i]["eyeW"], fr[i - 1]["eyeW"]) if "eyeW" in fr[i] else float("nan")
            car = math.dist(fr[i]["carW"], fr[i - 1]["carW"]) if "carW" in fr[i] else float("nan")
            worst.append((dist, i, dy, dts[i], eye, car))
    worst.sort(reverse=True)
    print("%d frames where the body stepped back more than %.0f mm (or more than %.0f mm in any direction)" % (len(worst), STEP * 1000, STEP * 2000))
    for dist, i, dy, dt, eye, car in worst[:15]:
        y = [round(body[k][1], 3) for k in range(max(0, i - 2), min(len(fr), i + 3))]
        print("frame %5d: step %.1f mm (y %+.1f mm), dt %.1f ms (%.1fx mean), eye step %.1f mm, car step %.1f mm, speed %.1f, brake %.2f, body y %s" % (
            i, dist * 1000, dy * 1000, dt * 1000, dt / avg, eye * 1000, car * 1000, fr[i]["speed"], fr[i]["brake"], y))
    spikes = sum(1 for d in dts if d > 2 * avg)
    print("frame-time spikes (over 2x the mean): %d" % spikes)


if __name__ == "__main__":
    main(sys.argv[1])
