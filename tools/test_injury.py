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
be = {getPlayerVehicleID = function() return 7 end, getObjectByID = function(_, id) return id == 7 and veh or nil end,
      getObjectCount = function() return 0 end}
"""


def lua_env():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    lua.execute(FAKE)
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
        assert lua.eval("fields[%d].type == 'slider' or fields[%d].type == 'enum'" % (i, i)), i
        if lua.eval("fields[%d].type" % i) == "slider":
            assert lua.eval("fields[%d].min <= fields[%d].default and fields[%d].default <= fields[%d].max" % (i, i, i, i)), lua.eval("fields[%d].id" % i)
            assert abs(lua.eval("fields[%d].store.get()" % i) - lua.eval("fields[%d].default" % i)) < 1e-9
    assert lua.eval("#fields") == 10, lua.eval("#fields")
    lua.execute("fields[1].store.set('nonsense')")
    assert M.getMode() == "full", "an unknown mode changed the setting"
    print("ok")


if __name__ == "__main__":
    main()
