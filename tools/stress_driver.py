"""Stress test for the driver, without the game: runs the real slrrDrivers.lua in LuaJIT (lupa) inside a
fake BeamNG (tools/bng_shim.lua), on a car that accelerates hard, brakes hard, steers lock to lock and
hits kerbs at speed.

    python tools/stress_driver.py

Checks every frame:
  - every part is a finite number (no NaN / inf),
  - the body stays within a few cm of its seated place in the car (it never slides off or vanishes),
  - hands and feet don't jump between frames (no pops),
and repeats the run with animation off, where nothing may move at all relative to the seat.
"""
import json
import math
import os
import sys

from lupa.luajit21 import LuaRuntime   # BeamNG runs LuaJIT 2.1

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.join(HERE, "..", "mod")
BODY_LIMIT = 0.075       # m the body may move from its seated place (QA gate J2)
HAND_JUMP = 0.05         # m a hand or foot may move in one 60 Hz frame (QA gate J1)
DT = 1 / 60


def run(animated, record_to=None):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    lua.execute(open(os.path.join(HERE, "bng_shim_game.lua")).read())
    g = lua.globals()
    g.SHIM_MOD = MOD.replace("\\", "/")
    g.SHIM_RIG = json.dumps(json.load(open(os.path.join(MOD, "art/slrr_drivers/models/vin/rig.json"))))
    lua.execute("shim_setup()")
    lua_src = os.environ.get("SLRR_DRIVERS_LUA") or os.path.join(MOD, "lua/ge/extensions/slrrDrivers.lua")
    M = lua.execute(open(lua_src).read())     # SLRR_DRIVERS_LUA: run an older version for before/after renders
    g.M = M
    lua.execute("shim_start(M)")
    M.setAnimated(animated)
    if record_to:
        M.startRecording(7)
    worst = {"body": 0.0, "jump": 0.0, "reach": 0.0}
    prev = {}
    t = 0.0
    speed, steer, prev_steer = 0.0, 0.0, 0.0
    base = None
    for frame in range(int(40 / DT)):
        t += DT
        # driving script: launch, top speed with kerb hits, hard braking, lock-to-lock at speed, a spin
        if t < 8:
            acc = 9.0
        elif t < 14:
            acc = 0.0
        elif t < 18:
            acc = -11.0
        elif t < 30:
            acc = 1.0
        else:
            acc = -6.0
        speed = max(0.0, speed + acc * DT)
        # what a driver does: full lock only at walking pace, a fraction of it at speed (wheel deg)
        cap = 470 if speed < 8 else max(60, 470 * 8 / speed)
        if 18 <= t < 30:
            steer = cap * math.sin((t - 18) * 1.7)        # weaving, as far as the speed allows
        elif t >= 30:
            steer = (cap if int(t) % 2 else -cap) * min(1, (t % 1) * 3)   # quick turns, built up over 0.3 s
        else:
            steer = 0.0
        # the wheel turns at most 600 deg/s (BeamNG's own steering filter is slower than that)
        steer = prev_steer + max(-600 * DT, min(600 * DT, steer - prev_steer))
        prev_steer = steer
        kerb = 25.0 if (10 < t < 14 and frame % 37 == 0) else 0.0   # sharp vertical/lateral hits
        rpm = 1000 + (speed % 15) * 400
        gear = 1 + int(speed // 15)
        g.shim_step(DT, speed, acc, steer, kerb, rpm, gear,
                    1.0 if acc > 0 else 0.0, min(1.0, -acc / 11) if acc < 0 else 0.0, 0.0)
        worst["reach"] = max(worst["reach"], M.getState(7).reach or 0)
        parts = g.shim_parts_local()          # part -> {x, y, z} in the seat frame
        for name in parts:
            p = parts[name]
            v = (p.x, p.y, p.z)
            assert all(math.isfinite(c) for c in v), ("non-finite", name, t, v)
            if name == "body":
                if base is None:
                    base = v
                worst["body"] = max(worst["body"], math.dist(v, base))
                assert math.dist(v, base) < BODY_LIMIT, ("body left the seat", t, v, base)
            if name.endswith(("hand", "foot")) and name in prev:
                jump = math.dist(v, prev[name])
                worst["jump"] = max(worst["jump"], jump)
                assert jump < HAND_JUMP, ("pop", name, round(t, 2), round(jump, 3))
            if not animated and name in prev:
                assert math.dist(v, prev[name]) < 1e-4, ("moved while animation is off", name, t)
            prev[name] = v
    assert worst["reach"] == 0, "an automatic reached for the gear lever"
    if record_to:
        n, rec = M.stopRecording(7, None)
        save_recording(rec, record_to)
    return worst


def lua_to_py(t):
    """A Lua table from lupa as plain Python lists / dicts."""
    if not hasattr(t, "keys"):
        return t
    keys = list(t.keys())
    if keys and all(isinstance(k, int) for k in keys):
        return [lua_to_py(t[k]) for k in sorted(keys)]
    return {k: lua_to_py(t[k]) for k in keys}


def save_recording(rec, path):
    json.dump(lua_to_py(rec), open(path, "w"))


def check_modes():
    """hidden hides everything, hideFirstPerson only in the player's driver camera, still/static
    keep the driver drawn; per-car modes override the global one."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    lua.execute(open(os.path.join(HERE, "bng_shim_game.lua")).read())
    g = lua.globals()
    g.SHIM_RIG = json.dumps(json.load(open(os.path.join(MOD, "art/slrr_drivers/models/vin/rig.json"))))
    M = lua.execute(open(os.path.join(MOD, "lua/ge/extensions/slrrDrivers.lua")).read())
    g.M = M
    lua.execute("shim_start(M)")

    def hidden(cam="orbit"):
        lua.execute("core_camera.getActiveCamName = function() return '%s' end" % cam)
        g.shim_step(DT, 10, 0, 0, 0, 2000, 2, 0.3, 0, 0)
        parts = M.getState(7).parts
        return all(parts[k].hidden for k in parts), any(parts[k].hidden for k in parts)
    M.setDisplayMode("hidden")
    assert hidden() == (True, True)
    M.setDisplayMode("hideFirstPerson")
    assert hidden("orbit") == (False, False) and hidden("driver") == (True, True)
    M.setDisplayMode("static")
    assert M.getDisplayMode() == "still" and hidden("orbit") == (False, False)
    M.setDisplayMode("full")
    M.setDisplayMode("hidden", 7)
    assert hidden() == (True, True) and M.getDisplayMode() == "full"
    M.setDisplayMode(None, 7)
    assert hidden() == (False, False)
    # setting the same mode again must not reset the animation (callers set it on every spawn)
    M.getState(7).hands.marker = True
    M.setDisplayMode("full")
    assert M.getState(7).hands is not None and M.getState(7).hands.marker, "same mode reset the animation"
    print("display modes ok")


def check_shift():
    """An H-pattern car: on a gear change the shifting hand ends on the lever knob and the clutch goes down."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    g = lua.globals()
    g.SHIM_HPATTERN = True
    lua.execute(open(os.path.join(HERE, "bng_shim_game.lua")).read())
    g.SHIM_RIG = json.dumps(json.load(open(os.path.join(MOD, "art/slrr_drivers/models/vin/rig.json"))))
    M = lua.execute(open(os.path.join(MOD, "lua/ge/extensions/slrrDrivers.lua")).read())
    g.M = M
    lua.execute("shim_start(M)")
    c = M.getState(7)
    assert c.knobNode == 50 and c.hasClutch, "lever or clutch not found"
    for _ in range(60):
        g.shim_step(DT, 10, 0, 0, 0, 3000, 2, 0.3, 0, 0)
    g.shim_step(DT, 10, 0, 0, 0, 3000, 3, 0.0, 0, 0)          # gear 2 -> 3
    best, clutch = 9.0, 0.0
    for _ in range(20):                                     # about a third of a second into the shift
        g.shim_step(DT, 10, 0, 0, 0, 3000, 3, 0.0, 0, 0)
        p = g.shim_parts_local()["r_hand"]
        k = g.shim_node_seat(50)
        best = min(best, math.dist((p.x, p.y, p.z), (k.x, k.y - 0.02, k.z + 0.05)))
        clutch = max(clutch, c.press.clutch)
    assert best < 0.12, ("hand never reached the knob", best)
    assert clutch > 0.9, ("clutch not pressed during the shift", clutch)
    print("shift ok: hand within %.3f m of the knob, clutch %.2f" % (best, clutch))


if __name__ == "__main__":
    check_shift()
    if "--record" in sys.argv:
        run(True, sys.argv[sys.argv.index("--record") + 1])
        print("recorded"); sys.exit()
    check_modes()
    for animated in (True, False):
        w = run(animated)
        print("animated=%s  body moved at most %.3f m  largest hand/foot step %.3f m per frame"
              % (animated, w["body"], w["jump"]))
    print("ok")
