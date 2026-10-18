"""Offline check of the injury add-on (addon_injury/lua/ge/extensions/slrrInjury.lua) in LuaJIT (lupa):

    python test_injury.py

Normal driving and kerb hits hurt nobody; a crash matrix into a wall (10/20/40/60/80/100 m/s, the car stopping in
60 ms) gives levels in order up to fatal only at the extreme; a one-step glitch spike, a teleport and the jolt of
a spawn hurt nobody; the career hooks fire once each with the agreed fields; unconscious blocks the controls and
wakes; heal resets; mode off does nothing. Prints "ok".
"""
import os

from lupa.luajit21 import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "addon_injury", "lua", "ge", "extensions", "slrrInjury.lua")
STEP = 1 / 60

FAKE = r"""
hooks = {}
extensions = {hook = function(name, ...) table.insert(hooks, {name, ...}) end}
function jsonReadFile() return nil end
function jsonWriteFile() end
blocked = false
core_input_actionFilter = {setGroup = function() end, addAction = function(_, _, on) blocked = on end}
commands = {}
veh = {}
function veh:queueLuaCommand(c) table.insert(commands, c) end
function veh:getId() return 7 end
slumps = {}
slrrDrivers = {setSlump = function(_, on) table.insert(slumps, on) end}
PLAYER, JB = 7, 'covet'
function veh:getJBeamFilename() return JB end
be = {getPlayerVehicleID = function() return PLAYER end, getObjectByID = function(_, id) return (id == 7 or id == 9) and veh or nil end,
      getObjectCount = function() return 0 end}
rects, audio = {}, 0
function ColorF(r, g, b, a) return {a = a} end
scenetree = {ScreenBlurFX = {obj = {addFrameBlurRect = function(self, x0, y0, x1, y1, c) rects[#rects + 1] = c.a end}}}
core_sounds = {setAudioBlur = function(v) audio = v end}
"""


def lua_env():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    lua.execute(FAKE)
    lua.execute("function log() end")
    M = lua.execute(open(SRC).read())
    M.onExtensionLoaded()
    return lua, M


def run(lua, M, samples, settle=4.0):
    """Feed samples (dicts of g per region) to vehicle 7 a step each, then let time pass."""
    for s in samples:
        M.feed(7, lua.table_from(dict(s, dt=STEP)))
        M.onUpdate(STEP, STEP)
    for _ in range(int(settle / STEP)):
        M.onUpdate(STEP, STEP)


def body(g, legs=None, arms=None):
    return {"head": g * 1.2, "chest": g, "pelvis": g * 0.9, "larm": arms or g * 0.3, "rarm": arms or g * 0.3,
            "lleg": legs if legs is not None else g * 1.1, "rleg": legs if legs is not None else g * 1.1, "speed": 20}


def crash(speed, stop=0.06):
    g = speed / stop / 9.81
    return [body(1)] * 30 + [body(g)] * int(round(stop / STEP)) + [body(0)] * 10



def sampler_check():
    """The stub sampler: a crash is the speed lost over 0.1 s, however the frames split it."""
    def chests(vels, dts):
        lua, M = lua_env()
        lua.execute("""
        function fakeCar(vels)
          local i = 0
          return {getId = function() return 7 end, getPosition = function() return 0, 0, 0 end,
                  getVelocity = function() i = i + 1 return 0, vels[i], 0 end,
                  getDirectionVector = function() return 0, 1, 0 end, getDirectionVectorUp = function() return 0, 0, 1 end}
        end""")
        v = lua.eval("fakeCar")(lua.table_from(vels))
        return [(lambda o: o.chest if o else 0)(M.sampleFromCar(v, dt)) for dt in dts]
    # 13.9 m/s (50 km/h) lost in one step, in two, and in one step of a long (hitch) frame: the same ~85 g, for the whole window
    one = chests([13.9] * 3 + [0] * 8, [STEP] * 11)
    two = chests([13.9] * 3 + [7, 0] + [0] * 6, [STEP] * 11)
    hitch = chests([13.9] * 3 + [0] * 8, [STEP] * 3 + [0.4] + [STEP] * 7)
    for name, c in (("one step", one), ("two steps", two), ("hitch frame", hitch)):
        assert all(70 < x < 110 for x in c[4:6]), (name, c)
    assert all(x < 1 for x in chests([13.9] * 10, [STEP] * 10)), "steady speed scores nothing"
    # a car that stops short of where its speed would take it is a crash (jump 0); one that appears far away is a teleport
    lua, M = lua_env()
    lua.execute("""
    pp, vv, ci = {}, {}, 0
    car = {getId = function() return 7 end, getPosition = function() ci = ci + 1 return 0, pp[ci], 0 end,
      getVelocity = function() return 0, vv[ci], 0 end, getDirectionVector = function() return 0, 1, 0 end,
      getDirectionVectorUp = function() return 0, 0, 1 end}""")
    def jumps(pos, vel, dt):
        g = lua.globals()
        g.pp, g.vv, g.ci = lua.table_from(pos), lua.table_from(vel), 0
        return [M.sampleFromCar(lua.globals().car, dt) for _ in pos]
    stop = jumps([0, 0.2, 0.4, 0.45, 0.45], [13.9, 13.9, 13.9, 0, 0], 0.4)
    assert all(j is None or j.jump < 0.5 for j in stop), "a hard stop in a long frame is not a teleport"
    tele = jumps([0, 0.2, 50, 50.2, 50.4], [13.9] * 5, STEP)
    assert max(j.jump for j in tele if j) > 8, "a teleport is one"
    # quick travel / recovery while driving (50 m in one frame, speed gone): scores nothing, a real stop at the same speed does
    def level_after(pos, vel):
        lua, M = lua_env()
        lua.execute("""
        pp, vv, ci = {}, {}, 0
        car = {getId = function() return 7 end, getPosition = function() ci = ci + 1 return 0, pp[ci], 0 end,
          getVelocity = function() return 0, vv[ci], 0 end, getDirectionVector = function() return 0, 1, 0 end,
          getDirectionVectorUp = function() return 0, 0, 1 end}""")
        M.onVehicleSpawned(7)
        for _ in range(300):
            M.onUpdate(STEP, STEP)
        g = lua.globals()
        g.pp, g.vv, g.ci = lua.table_from(pos), lua.table_from(vel), 0
        for _ in pos:
            s = M.sampleFromCar(g.car, STEP)
            if s:
                M.feed(7, s)
            M.onUpdate(STEP, STEP)
        return M.getState(7).level
    vel = [13.9] * 20 + [0] * 20
    walk, x = [], 0
    for v in vel:
        x += v * STEP
        walk.append(x)
    teleport = [p if i < 20 else p + 50 for i, p in enumerate(walk)]
    assert level_after(walk, vel) == "bruised", "a real 50 km/h stop is a bruise"
    assert level_after(teleport, vel) == "none", "quick travel (50 m in a frame) never hurts"


def main():
    lua, M = lua_env()
    M.onVehicleSpawned(7)
    run(lua, M, [body(20)] * 30, settle=0.1)              # the spawn jolt: ignored for 3 s
    run(lua, M, [], settle=3)
    assert M.getState(7).level == "none", "spawn jolt hurt"
    # normal driving: 1-2 g, kerb strikes of 8 g for two steps
    run(lua, M, ([body(1.5)] * 20 + [body(8)] * 2) * 30)
    assert M.getState(7).level == "none", M.getState(7).level
    # a glitch: one step of 300 g, then a teleport step with huge g
    run(lua, M, [body(1), body(300), body(1)])
    run(lua, M, [dict(body(300), jump=50.0), body(300), body(1)])
    assert M.getState(7).level == "none", ("glitch hurt", M.getState(7).level)
    assert not any(h[1] == "onSlrrDriverDied" for h in lua.globals().hooks.values())

    rank = {"none": 0, "bruised": 1, "broken": 2, "unconscious": 3, "fatal": 4}
    levels = []
    for speed in (10, 20, 40, 60, 80, 100):
        lua, M = lua_env()
        M.setMode("full")                 # injuries and death: the worst crash kills
        M.onVehicleSpawned(7)
        run(lua, M, [], settle=3.5)
        run(lua, M, crash(speed))
        st = M.getState(7)
        hooks = [(h[1], h) for h in lua.globals().hooks.values()]
        levels.append((speed, st.level, round(st.severity, 2), [n for n, _ in hooks]))
        died = [h for n, h in hooks if n == "onSlrrDriverDied"]
        injured = [h for n, h in hooks if n == "onSlrrDriverInjured"]
        if st.level == "fatal":
            assert len(died) == 1 and died[0][3] == "crash" and died[0][4].player and died[0][4].kind in ("head", "chest"), died
        elif st.level != "none":
            assert len(injured) == 1, injured
            inj = injured[0][3]
            for k in ("severity", "parts", "recoverySeconds", "limits", "level", "broken", "conscious", "player"):
                assert inj[k] is not None, k
            assert inj.parts.head is not None and inj.limits.noDriving is not None
        if st.level == "unconscious":
            assert lua.globals().blocked or st.conscious, "controls not blocked"
    print("crash matrix (m/s, level, severity, hooks):", levels)
    ranks = [rank[l[1]] for l in levels]
    assert ranks == sorted(ranks), ranks
    assert levels[0][1] in ("none", "bruised") and levels[3][1] == "unconscious" and levels[4][1] != "fatal"         and levels[-1][1] == "fatal", levels

    # injuries without death: the worst crash only knocks him out (and he slumps, then wakes and sits up); a Hardcore career turns death on
    lua, M = lua_env()
    assert not M.getDeathAllowed()
    M.onVehicleSpawned(7)
    run(lua, M, [], settle=3.5)
    run(lua, M, crash(100), settle=1)
    st = M.getState(7)
    assert st.level == "unconscious", st.level
    assert not any(h[1] == "onSlrrDriverDied" for h in lua.globals().hooks.values()), "died without the setting"
    assert list(lua.globals().slumps.values()) == [True], list(lua.globals().slumps.values())
    run(lua, M, [], settle=40)
    assert list(lua.globals().slumps.values()) == [True, False], "did not sit up"
    lua, M = lua_env()
    M.setDeathOverride(True)
    assert M.getDeathAllowed()
    M.onVehicleSpawned(7)
    run(lua, M, [], settle=3.5)
    run(lua, M, crash(100))
    assert M.getState(7).level == "fatal" and any(h[1] == "onSlrrDriverDied" for h in lua.globals().hooks.values()), "hardcore: death did not count"

    # unconscious: controls blocked, then he wakes and they come back; a broken right leg caps the pedals
    lua, M = lua_env()
    M.onVehicleSpawned(7)
    run(lua, M, [], settle=3.5)
    run(lua, M, crash(60), settle=0.5)
    assert M.getState(7).level == "unconscious" and lua.globals().blocked, M.getState(7).level
    run(lua, M, [], settle=40)
    assert M.getState(7).conscious and not lua.globals().blocked, "never woke"
    run(lua, M, [body(1, legs=200)] * 10)
    assert "rleg" in list(M.getState(7).broken.values()) and M.getState(7).limits.noDriving
    assert any("slrrInjuryCaps = {steer = 1, pedal = 0.7}" in c for c in lua.globals().commands.values())
    M.heal(7)
    assert M.getState(7).level == "none" and M.getState(7).recoverySeconds == 0

    # mode off
    lua, M = lua_env()
    M.setMode("off")
    M.onVehicleSpawned(7)
    run(lua, M, [], settle=3.5)
    run(lua, M, crash(100))
    assert M.getState(7).level == "none" and not list(lua.globals().hooks.values())
    # the Mods menu: the Injury tab is offered to slrrDrivers, which registers the page; loading asks it to do so
    lua, M = lua_env()
    lua.execute("asked = 0 slrrDrivers.onSlrrSettingsReady = function() asked = asked + 1 end")
    M.onExtensionLoaded()
    assert lua.eval("asked") == 1, "the injury add-on did not ask slrrDrivers to register its tab"
    lua.execute("tab, fields = ...", *M.settingsSchema())
    assert lua.eval("tab.id") == "injury" and lua.eval("fields[1].id") == "injuryMode" and lua.eval("fields[1].tab") == "injury"
    lua.execute("fields[1].store.set('full')")
    assert M.getMode() == "full" and lua.eval("fields[1].store.get()") == "full"
    # the tunables: toughness changes what a crash does, values are clamped, unknown keys refused, only changes are saved, the schema's defaults match
    def level_after(tough):
        l2, M2 = lua_env()
        M2.setTune("toughness", tough)
        M2.onVehicleSpawned(7)
        run(l2, M2, [], settle=3.5)
        run(l2, M2, crash(40))
        return M2.getState(7).level
    assert level_after(2) == "none" and level_after(1) == "bruised" and level_after(0.5) in ("broken", "unconscious"), (level_after(2), level_after(1), level_after(0.5))
    assert M.setTune("toughness", 99) and M.getTune("toughness") == 2 and not M.setTune("nonsense", 1) and not M.setTune("grace", "x")
    lua.execute("written = nil jsonWriteFile = function(p, t) written = t end")
    M.setTune("recoverOut", 100)
    assert lua.eval("written.tune.recoverOut") == 100 and lua.eval("written.tune.grace") is None and lua.eval("written.mode") == "full"
    M.resetTune()
    assert lua.eval("written.tune") is None and M.getTune("toughness") == 1
    for i in range(1, int(lua.eval("#fields")) + 1):
        assert lua.eval("fields[%d].type == 'slider' or fields[%d].type == 'enum' or fields[%d].type == 'bool'" % (i, i, i)), i
        if lua.eval("fields[%d].type" % i) == "slider":
            assert lua.eval("fields[%d].min <= fields[%d].default and fields[%d].default <= fields[%d].max" % (i, i, i, i)), lua.eval("fields[%d].id" % i)
            assert abs(lua.eval("fields[%d].store.get()" % i) - lua.eval("fields[%d].default" % i)) < 1e-9
    assert lua.eval("#fields") == 17, lua.eval("#fields")
    # how injuries feel: blurry edges and muffled hearing after a hit that fade, a knock-out keeps them until he wakes, Reduce motion turns the
    # blur off, no sprinting on foot with a broken leg
    def hurt():
        l2, M2 = lua_env()
        M2.setMode("injuries")
        M2.onVehicleSpawned(7)
        run(l2, M2, [], settle=3.5)
        run(l2, M2, crash(60), settle=2.0)
        return l2, M2
    l2, M2 = hurt()
    assert M2.getState(7).level == "unconscious" and not M2.getState(7).conscious
    l2.execute("rects = {}")
    M2.onPreRender(1 / 60)
    assert l2.eval("#rects") == 4 and l2.eval("audio") > 0.3 and M2.getFeel().amount == 1, (l2.eval("#rects"), l2.eval("audio"))
    run(l2, M2, [], settle=400)           # he wakes up (300 s), the effects fade over 12 s
    assert M2.getState(7).conscious
    run(l2, M2, [], settle=14)
    l2.execute("rects = {}")
    M2.onPreRender(1 / 60)
    assert l2.eval("#rects") == 0 and l2.eval("audio") == 0 and M2.getFeel().amount == 0, "the effects did not fade after waking"
    l2, M2 = hurt()
    M2.setTune("reduceMotion", 1)
    l2.execute("rects = {}")
    M2.onPreRender(1 / 60)
    assert l2.eval("#rects") == 0 and l2.eval("audio") > 0, "Reduce motion: no blur, the sound still has its own switch"
    M2.setTune("fxMuffle", 0)
    M2.onPreRender(1 / 60)
    assert l2.eval("audio") == 0, "muffling switched off"
    # a broken leg, on foot: sprinting is switched off while it heals
    l3, M3 = lua_env()
    M3.setMode("injuries")
    M3.onVehicleSpawned(7)
    run(l3, M3, [], settle=3.5)
    st = M3._state(7)
    st["parts"]["lleg"] = 1.0
    st["recovery"] = 300
    l3.execute("PLAYER = 9 JB = 'unicycle' commands = {}")
    M3.onVehicleSwitched(7, 9)
    run(l3, M3, [], settle=1)
    assert M3.getFeel().limping and any("setSpeedCoef" in c for c in l3.globals().commands.values()), "no limp on foot with a broken leg"
    assert M3.getState(9).limits.slowWalk, "the pedestrian side reads slowWalk for the unicycle: the broken leg is not reported there"
    M3.setTune("limp", 0)
    l3.execute("commands = {}")
    run(l3, M3, [], settle=1)
    assert not list(l3.globals().commands.values()), "limp switched off still held him back"
    l3.execute("PLAYER = 7 JB = 'covet' commands = {}")
    M3.onVehicleSwitched(9, 7)
    assert not M3.getFeel().limping, "the leg followed him into a car"
    lua.execute("fields[1].store.set('nonsense')")
    assert M.getMode() == "full", "an unknown mode changed the setting"
    sampler_check()
    print("ok")


if __name__ == "__main__":
    main()
