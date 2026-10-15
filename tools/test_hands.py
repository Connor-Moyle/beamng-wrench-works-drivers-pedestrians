"""Self-check of the hand-over-hand logic in slrrDrivers.lua, run in LuaJIT via lupa:
swing the wheel lock to lock and back and check each hand stays near its home spot."""
import math
import os
import re

from lupa.luajit21 import LuaRuntime

src = open(os.path.join(os.path.dirname(__file__), "..", "mod", "lua", "ge", "extensions", "slrrDrivers.lua")).read()
consts = "\n".join(l for l in src.splitlines() if re.match(r"local (GRIP_ANGLE|HAND_RANGE|HAND_DOWN|REGRIP_\w+) =", l))
fn = src[src.index("local HOME = {r ="):src.index("-- rotation R turned by angle")]
fn = re.sub(r"local function rimPoint.*?\nend\n", "", fn, flags=re.S)
lua = LuaRuntime()
lua.execute("""
function sign(x) return x > 0 and 1 or (x < 0 and -1 or 0) end
function clamp(v, lo, hi) return math.min(math.max(v, lo), hi) end
function smootheststep(x) return x*x*x*(x*(x*6-15)+10) end
""" + consts + "\n" + fn + "\nM_updateHands = updateHands")
update = lua.globals().M_updateHands
c = lua.table(shiftSide="r", reach=0)
dt, worst, regrips, t = 1 / 60, 0.0, 0, 0.0
home = {"r": math.radians(10), "l": math.pi - math.radians(10)}
state = {}
prev_a = {}
for target in (470, -470, 470, -470, 200, 0):
    for _ in range(int(3 / dt)):   # sweep at ~300 deg/s, then hold
        cur = math.degrees(c.lastTurn) if c.lastTurn is not None else 0
        step = max(-5, min(5, target - cur))
        out = update(c, math.radians(cur + step), dt)
        both = 0
        for side in ("r", "l"):
            g = out[side]
            signed = ((g.a - home[side] + math.pi) % (2 * math.pi) - math.pi) * (1 if side == "r" else -1)
            off = abs(signed)
            if g.lift == 0:
                worst_down = max(globals().get("worst_down", 0), -signed)
                globals()["worst_down"] = worst_down
            if g.lift > 0:   # a re-grip must take the short way: never sweep more than half a turn
                sweep = abs(out[side].a - prev_a.get(side, out[side].a))
                assert sweep < math.radians(60), ("hand jumped", side, math.degrees(sweep))
            prev_a[side] = g.a
            if g.lift == 0:
                worst = max(worst, off)
            else:
                both += 1
            if g.lift > 0 and not state.get(side):
                regrips += 1
            state[side] = g.lift > 0
        both_off = max(globals().get("both_off", 0), both)
print("both hands lifted at once at some point:", both_off == 2)
print("max held offset from home: %.0f deg (below home at most %.0f), regrips: %d" % (math.degrees(worst), math.degrees(worst_down), regrips))
assert math.degrees(worst_down) < 95, "a hand was carried down toward the lap"
assert math.degrees(worst) < 165, "a hand turned too far with the wheel"   # 160 happens for a moment on a 300 deg/s reversal while the other hand is off
for side in ("r", "l"):
    assert abs((out[side].a - home[side] + math.pi) % (2 * math.pi) - math.pi) <= math.radians(30), (side, math.degrees(out[side].a))
print("hands within 30 deg of home after centring: ok")
