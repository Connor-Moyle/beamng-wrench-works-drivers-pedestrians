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
import numpy as np
import math
import os
import sys

from lupa.luajit21 import LuaRuntime   # BeamNG runs LuaJIT 2.1

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.join(HERE, "..", "mod")
BODY_LIMIT = 0.075       # m the body may move from its seated place (QA gate J2)
HAND_JUMP = 0.05         # m a hand or foot may move in one 60 Hz frame (QA gate J1)
DT = 1 / 60


def run(animated, record_to=None, look=None, props=False):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    g = lua.globals()
    g.SHIM_PROPS = props          # the parts as vehicle props, drawn by the car (slrrDriverMount)
    lua.execute(open(os.path.join(HERE, "bng_shim_game.lua")).read())
    g.SHIM_MOD = MOD.replace("\\", "/")
    g.SHIM_RIG = json.dumps(json.load(open(os.path.join(MOD, "art/slrr_drivers/models/%s/rig.json" % os.environ.get("SLRR_RIG_MODEL", "vin")))))
    lua.execute("shim_setup()")
    lua_src = os.environ.get("SLRR_DRIVERS_LUA") or os.path.join(MOD, "lua/ge/extensions/slrrDrivers.lua")
    M = lua.execute(open(lua_src).read())     # SLRR_DRIVERS_LUA: run an older version for before/after renders
    g.M = M
    lua.execute("shim_start(M)")
    M.setAnimated(animated)
    assert bool(M.getState(7).drawnByCar) == props, "drawn by the car: %s" % M.getState(7).drawnByCar
    worst_prop = 0.0
    if look:
        M.setAppearance(None, lua.table_from(look, recursive=True))
        g.shim_step(DT, 0, 0, 0, 0, 1000, 1, 0, 0, 0)      # the driver is rebuilt with the new look
    if record_to:
        M.startRecording(7)
    worst = {"body": 0.0, "jump": 0.0, "reach": 0.0}
    prev = {}
    t = 0.0
    speed, steer, prev_steer = 0.0, 0.0, 0.0
    base = None
    for frame in range(int(49 / DT)):
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
        if 38 <= t < 44:                                  # a crash: stopped dead, he holds his head
            speed, steer, acc = 0.0, 0.0, 0.0
        if t >= 44:                                       # backing up at walking pace: he looks out of the back
            speed, gear, steer, acc = 2.0, -1, 0.0, 0.0
        g.shim_step(DT, speed, acc, steer, kerb, rpm, gear,
                    1.0 if acc > 0 else 0.0, min(1.0, -acc / 11) if acc < 0 else 0.0, 0.0)
        worst["reach"] = max(worst["reach"], M.getState(7).reach or 0)
        worst["daze"] = max(worst.get("daze", 0), M.getState(7).dazeK or 0)
        if props:                             # the prop base transforms put every part where the TSStatic path did
            ep, ea = g.shim_prop_error()
            worst_prop = max(worst_prop, ep, ea)
            assert ep < 1e-6 and ea < 1e-6, ("prop transform off", round(t, 2), ep, ea)
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
    if animated:
        st = M.getState(7)
        assert st.revK > 0.99, "no look-back while reversing"
    if record_to:
        n, rec = M.stopRecording(7, None)
        save_recording(rec, record_to)
    worst["prop"] = worst_prop
    return worst


def check_far():
    """Drawn by the car: beyond ANIM_DIST, or in 'still' mode, the props keep their base transforms and the
    update costs nothing; back in range he animates again."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    g = lua.globals()
    g.SHIM_PROPS = True
    lua.execute(open(os.path.join(HERE, "bng_shim_game.lua")).read())
    g.SHIM_RIG = json.dumps(json.load(open(os.path.join(MOD, "art/slrr_drivers/models/%s/rig.json" % os.environ.get("SLRR_RIG_MODEL", "vin")))))
    M = lua.execute(open(os.path.join(MOD, "lua/ge/extensions/slrrDrivers.lua")).read())
    g.M = M
    lua.execute("shim_start(M)")

    def drive(frames, steer):
        hand = M.getState(7).parts.r_hand.prop
        moved, t0 = 0.0, (hand.t.x, hand.t.y, hand.t.z)
        for _ in range(frames):
            g.shim_step(DT, 20, 0, steer, 0, 3000, 3, 0.5, 0, 0)
            moved = max(moved, math.dist(t0, (hand.t.x, hand.t.y, hand.t.z)))
        return moved
    assert drive(60, 0) >= 0, "warm up"
    lua.execute("core_camera.getPosition = function() local v = be:getObjectByID(7) return v:getPosition() - v:getDirectionVector() * 60 + vec3(0, 0, 2) end")
    # B47: the player's own car never goes by the camera distance (it is stale in the driver camera)
    assert drive(60, 300) > 0.05, "the player's driver froze with the camera reported 60 m away"
    lua.execute("be.getPlayerVehicleID = function() return -1 end M.onAiModeChange(7, 'traffic')")
    lua.execute("shim_step(1 / 60, 20, 0, 0, 0, 3000, 3, 0.5, 0, 0)")
    assert drive(120, 300) == 0, "a driver 60 m away kept animating"
    assert M.getPerf()[0] < 0.02, "a driver 60 m away still costs %.3f ms" % M.getPerf()[0]
    lua.execute("core_camera.getPosition = function() local v = be:getObjectByID(7) return v:getPosition() - v:getDirectionVector() * 5 + vec3(0, 0, 2) end")
    assert drive(60, 300) > 0.05, "back in range, the hands did not turn the wheel"
    M.setDisplayMode("still")
    drive(5, 0)
    assert drive(60, 300) == 0, "a still driver drawn by the car was updated"
    M.setDisplayMode("full")
    print("far ok: props untouched beyond 40 m and when still, animated again in range")


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
    g.SHIM_RIG = json.dumps(json.load(open(os.path.join(MOD, "art/slrr_drivers/models/%s/rig.json" % os.environ.get("SLRR_RIG_MODEL", "vin")))))
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


def check_presence():
    """A driver only while the car is driven: the player's car, or one whose AI is on."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    lua.execute(open(os.path.join(HERE, "bng_shim_game.lua")).read())
    g = lua.globals()
    g.SHIM_RIG = json.dumps(json.load(open(os.path.join(MOD, "art/slrr_drivers/models/%s/rig.json" % os.environ.get("SLRR_RIG_MODEL", "vin")))))
    M = lua.execute(open(os.path.join(MOD, "lua/ge/extensions/slrrDrivers.lua")).read())
    g.M = M
    lua.execute("shim_start(M)")

    def driver():
        g.shim_step(DT, 10, 0, 0, 0, 2000, 2, 0.3, 0, 0)
        return M.getState(7) is not None
    assert driver(), "the player's car has no driver"
    lua.execute("be.getPlayerVehicleID = function() return -1 end M.onVehicleSwitched(7, -1)")
    assert not driver(), "a car the player left, AI off, kept its driver"
    M.onAiModeChange(7, "traffic")
    assert driver(), "a traffic car has no driver"
    M.onAiModeChange(7, "disabled")
    assert not driver(), "a car whose AI was turned off kept its driver"
    # 'stop': he stays while the car brakes; the car is asked again (ai.lua flips to 'disabled' silently)
    M.onAiModeChange(7, "stop")
    assert driver(), "a car braking to a stop lost its driver"
    asks = lambda: sum("ai.mode" in c for c in g.SHIM_CMDS.values())   # noqa: E731
    n = asks()
    for _ in range(int(2.5 / DT)):
        g.shim_step(DT, 1, 0, 0, 0, 1000, 1, 0, 0, 0)
    assert asks() == n + 1, "a stopping car was asked %d times in 2.5 s, want 1" % (asks() - n)
    M.onAiModeChange(7, "disabled")
    assert not driver(), "a car that came to a stop kept its driver"
    # B48: a pooled traffic car whose driver-camera data comes late (after the 5 s of fast retries) still gets him
    lua.execute("core_camera.getDriverDataById = function() return nil end")
    M.onAiModeChange(7, "traffic")
    for _ in range(400):
        g.shim_step(DT, 10, 0, 0, 0, 2000, 2, 0.3, 0, 0)
    assert not driver(), "a car without camera data got a driver"
    lua.execute("core_camera.getDriverDataById = function() return 1, false end")
    for _ in range(130):
        g.shim_step(DT, 10, 0, 0, 0, 2000, 2, 0.3, 0, 0)
    assert driver(), "a car whose camera data came late never got its driver"
    print("presence ok")


def check_damage():
    """A steering column pushed in by a crash brings the rim, and the hands, closer: live, without a pop."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    lua.execute(open(os.path.join(HERE, "bng_shim_game.lua")).read())
    g = lua.globals()
    g.SHIM_RIG = json.dumps(json.load(open(os.path.join(MOD, "art/slrr_drivers/models/%s/rig.json" % os.environ.get("SLRR_RIG_MODEL", "vin")))))
    M = lua.execute(open(os.path.join(MOD, "lua/ge/extensions/slrrDrivers.lua")).read())
    g.M = M
    lua.execute("shim_start(M)")

    def hands(frames):
        prev, jump = None, 0.0
        for _ in range(frames):
            g.shim_step(DT, 0, 0, 0, 0, 1000, 1, 0, 0, 0)
            p = g.shim_parts_local()
            h = np.array([[p[k].x, p[k].y, p[k].z] for k in ("r_hand", "l_hand")])
            if prev is not None:
                jump = max(jump, float(np.abs(h - prev).max()))
            prev = h
        return h, jump
    before, _ = hands(120)
    # the hub (node 2) 15 cm toward the driver: jbeam cars face -y, so +y
    lua.execute("local n = core_vehicle_manager.getVehicleData().vdata.nodes[2] n.pos = n.pos + vec3(0, 0.15, 0)")
    after, jump = hands(120)
    moved = before[:, 1].mean() - after[:, 1].mean()
    assert 0.08 < moved < 0.2, "hands moved %.3f m toward him for a hub pushed 0.15 m" % moved
    assert jump < 0.05, "a hand popped %.3f m in a frame" % jump
    print("damage ok: hub pushed 0.15 m, hands came %.3f m closer, largest step %.3f m" % (moved, jump))


def check_look():
    """Third person: the player's driver turns toward the camera's look, within limits, smoothly; eases
    back to forward when the camera looks behind him; weighted down at speed."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    lua.execute(open(os.path.join(HERE, "bng_shim_game.lua")).read())
    g = lua.globals()
    g.SHIM_RIG = json.dumps(json.load(open(os.path.join(MOD, "art/slrr_drivers/models/%s/rig.json" % os.environ.get("SLRR_RIG_MODEL", "vin")))))
    M = lua.execute(open(os.path.join(MOD, "lua/ge/extensions/slrrDrivers.lua")).read())
    g.M = M
    lua.execute("shim_start(M)")

    def look(x, y, z, speed, secs):
        # the camera's view direction: x to the car's left, y forward, z up (in the car's frame)
        lua.execute("core_camera.getQuat = function() return setmetatable({}, {__mul = function() "
                    "local f = be:getObjectByID(7):getDirectionVector() local u = vec3(0, 0, 1) "
                    "return u:cross(f) * %g + f * %g + u * %g end}) end" % (x, y, z))
        prev, step = None, 0.0
        for _ in range(int(secs / DT)):
            g.shim_step(DT, speed, 0, 0, 0, 1000, 1, 0, 0, 0)
            p = g.shim_parts_local()["head"]
            if prev is not None:
                step = max(step, math.dist(prev, (p.x, p.y, p.z)))
            prev = (p.x, p.y, p.z)
        return math.degrees(M.getState(7).lookYaw), step
    yaw, step = look(1, 0, 0, 0, 1.5)        # camera looks to his left
    assert 85 < yaw < 95 and step < 0.05, ("left", yaw, step)
    yaw, step = look(0.05, -1, 0, 0, 1.5)    # camera looks back past him: forward again, no flip
    assert abs(yaw) < 5 and step < 0.05, ("behind", yaw, step)
    yaw, step = look(1, 0, 0, 30, 1.5)       # at speed: mostly on the road
    assert 20 < yaw < 35 and step < 0.05, ("speed", yaw, step)
    print("look ok: left 90 deg, behind -> forward, 30 m/s -> %.0f deg, head step %.3f m" % (yaw, step))


def check_shift():
    """An H-pattern car: on a gear change the shifting hand ends on the lever knob and the clutch goes down."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    g = lua.globals()
    g.SHIM_HPATTERN = True
    lua.execute(open(os.path.join(HERE, "bng_shim_game.lua")).read())
    g.SHIM_RIG = json.dumps(json.load(open(os.path.join(MOD, "art/slrr_drivers/models/%s/rig.json" % os.environ.get("SLRR_RIG_MODEL", "vin")))))
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


def check_tints():
    """Twelve different clothing colours in a row: never more than 8 tinted materials kept."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    lua.execute(open(os.path.join(HERE, "bng_shim_game.lua")).read())
    g = lua.globals()
    g.SHIM_RIG = json.dumps(json.load(open(os.path.join(MOD, "art/slrr_drivers/models/%s/rig.json" % os.environ.get("SLRR_RIG_MODEL", "vin")))))
    M = lua.execute(open(os.path.join(MOD, "lua/ge/extensions/slrrDrivers.lua")).read())
    g.M = M
    lua.execute("shim_start(M)")
    most = 0
    for k in range(12):
        M.setAppearance(7, lua.table_from({"shirt": [k / 12, 0.5, 0.2]}, recursive=True))
        g.shim_step(DT, 0, 0, 0, 0, 1000, 1, 0, 0, 0)
        most = max(most, M.getTintCount())
    assert most <= 8, most
    print("tints ok: at most %d clothing colours loaded" % most)


def check_bake():
    """The baked-tint fallback: shirt pixels become shade x colour, everything else stays the skin."""
    import numpy as np
    lua = LuaRuntime(unpack_returned_tuples=True, encoding=None)   # bytes in and out: the bake is binary
    rd = lambda name: open(os.path.join(HERE, name), "rb").read()   # noqa: E731
    lua.execute(rd("bng_shim.lua"))
    lua.execute(rd("bng_shim_game.lua"))
    g = lua.globals()
    g[b"SHIM_MOD"] = MOD.replace("\\", "/").encode()
    g[b"SHIM_RIG"] = json.dumps(json.load(open(os.path.join(MOD, "art/slrr_drivers/models/%s/rig.json" % os.environ.get("SLRR_RIG_MODEL", "vin"))))).encode()
    M = lua.execute(open(os.path.join(MOD, "lua/ge/extensions/slrrDrivers.lua"), "rb").read())
    g[b"M"] = M
    lua.execute(b"shim_start(M)")
    M[b"setTintMode"](b"bake")
    lua.execute(b"M.setAppearance(7, {shirt = {1, 0, 0}})")
    for _ in range(60):          # the bake runs a few dozen rows a frame
        g[b"shim_step"](DT, 0, 0, 0, 0, 1000, 1, 0, 0, 0)
    st = M[b"getState"](7)
    assert st is not None and st[b"material"] and b"_t" in st[b"material"], "the baked tint wasn't applied"
    saved = list(g[b"SHIM_SAVED"].values())
    assert saved, "nothing baked"
    out = np.frombuffer(saved[0], np.uint8).reshape(1024, 1024, 4)
    src = np.frombuffer(open(os.path.join(MOD, "art/slrr_drivers/slrr_mitch/mitch_whole_tint.bin"), "rb").read(), np.uint8).reshape(1024, 1024, 6).astype(float)
    ms = src[..., 4] / 255
    want_r = np.minimum(255, src[..., 0] * np.maximum(0, 1 - ms) + src[..., 3] * ms)
    assert np.abs(out[..., 0].astype(float) - want_r).max() <= 1.5, "red channel off"
    shirt, bare = ms > 0.99, ms < 0.01
    assert out[..., 1][shirt].max() <= 1, "shirt not pure red"
    none = ms == 0
    assert (out[..., :3][none] == src[..., :3][none]).all(), "skin outside the shirt changed"
    assert np.abs(out[..., :3][bare].astype(float) - src[..., :3][bare]).max() <= 2, "skin at the shirt's edge changed"
    print("bake ok: %d shirt pixels red, the rest unchanged" % shirt.sum())


def check_sizes():
    """The hard drive at both ends of the size range, with tinted clothes and a helmet: J1/J2 must pass."""
    import tempfile
    import check_recording
    for size in (0.9, 1.1):
        path = os.path.join(tempfile.gettempdir(), "slrr_size_%s.json" % size)
        run(True, path, {"scale": size, "shirt": [0.8, 0.1, 0.1], "trousers": [0.1, 0.1, 0.3], "helmet": True})
        r = check_recording.check(json.load(open(path)))
        assert not r["high"], ("size %s" % size, r["high"])
        print("size %.1f: body %.3f m, rim worst %.3f m, pops %d, clips %d, MED %d" % (
            size, r["seat_worst"], r["rim_worst"], len(r["pops"]), r["clips"], len(r["med"])))


if __name__ == "__main__":
    check_shift()
    if "--record" in sys.argv:
        run(True, sys.argv[sys.argv.index("--record") + 1])
        print("recorded"); sys.exit()
    check_modes()
    check_presence()
    check_far()
    check_damage()
    check_look()
    check_tints()
    check_bake()
    check_sizes()
    w = run(True, props=True)
    print("drawn by the car: body moved at most %.3f m, largest step %.3f m, prop transforms within %.1e m" % (w["body"], w["jump"], w["prop"]))
    for animated in (True, False):
        w = run(animated)
        print("animated=%s  body moved at most %.3f m  largest hand/foot step %.3f m per frame"
              % (animated, w["body"], w["jump"]))
    print("ok")
