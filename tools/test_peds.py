"""Offline check of slrrPedestrians.lua: runs the real file in LuaJIT (lupa) with a fake BeamNG around Valo City's
first signalled junction, using the real sidewalks, ped.json files and the map's signals.json.

    python test_peds.py [MAP_DIR]

Checks: walkers move at their shape's speed (no foot slide), nobody starts a signalled crossing unless the traffic
they cross is red until they're over, nobody steps into a moving car's path, standing and waiting both happen, pedestrians keep apart, and the count drops when frames are slow and
comes back when they are fast, and areas are weighted (downtown and the beachfront busiest). MAP_DIR defaults to C:/Dev/SLRR map for beam ng.
"""
import json
import math
import os
import sys

from lupa.luajit21 import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.join(HERE, "..", "mod")
MAP = sys.argv[1] if len(sys.argv) > 1 else r"C:\Dev\SLRR map for beam ng"
SIGNALS = json.load(open(os.path.join(MAP, "mod", "levels", "slrr_valo_city", "signals.json")))["instances"]

FAKE = r"""
local mod, clock = ...
time = 0
function getMissionFilename() return '/levels/slrr_valo_city/main.level.json' end
function jsonReadFile(p) return py_json(p) end
function jsonWriteFile() end
function loadJsonMaterialsFile() end
FS = {findFiles = function(self, root, pat, depth, a, b) return py_find(root, pat) end}
function castRayStatic(from, dir, len) return 2 end
objects = {}
local Obj = {}
Obj.__index = Obj
function Obj:setField(k, i, v) self[k] = v end
function Obj:registerObject() end
function Obj:addObject() end
function Obj:setTransform(m) self.m = m self.pos = m:getPosition() self.fwd = m:getColumn(1) end
function Obj:getTransform() return self.m end
function Obj:delete() self.dead = true end
function createObject(cls) local o = setmetatable({cls = cls}, Obj) table.insert(objects, o) return o end
function simObjectExists(o) return o and not o.dead end
scenetree = {findObject = function() return nil end, MissionGroup = setmetatable({}, Obj)}
camPos = vec3(-340, 210, 7)
core_camera = {getPosition = function() return camPos end}
-- one car driving through junction_0 at 12 m/s along +x, from 260 m before it to 240 m past, then round again
car = {}
function car:getPosition() return vec3(-600 + (time * 12) % 500, 210, 7) end
function car:getVelocity() return vec3(12, 0, 0) end
be = {getObjectCount = function() return 1 end, getObject = function() return car end}
-- signals as signals.json runs them: phase 1 then phase 2 (each 10 s green, 4 s yellow, 1.5 s red), then a 7 s
-- walk phase with every approach red; phase = controllerId
local Sig = {}
Sig.__index = Sig
local function stateAt(phase, t)
  local c = t % 38
  local mine = phase == 1 and c or c - 15.5
  if mine >= 0 and mine < 10 then return 'greenTrafficLight' elseif mine >= 10 and mine < 14 then return 'yellowTrafficLight' end
  return 'redTrafficLight'
end
function Sig:getState() return stateAt(self.controllerId, time) end
function Sig:getStateAfterTime(s) return stateAt(self.controllerId, time + s) end
local sigs = {}
for _, d in ipairs(py_signals()) do
  table.insert(sigs, setmetatable({name = d.name, group = d.group, controllerId = d.controllerId,
    pos = vec3(d.pos[1], d.pos[2], d.pos[3]), dir = vec3(d.dir[1], d.dir[2], d.dir[3])}, Sig))
end
core_trafficSignals = {getSignals = function() return sigs end}
"""


def to_lua(lua, v):
    if isinstance(v, dict):
        t = lua.table()
        for k, x in v.items():
            t[k] = to_lua(lua, x)
        return t
    if isinstance(v, list):
        return lua.table(*[to_lua(lua, x) for x in v])
    return v


def main():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    g = lua.globals()
    g.py_json = lambda p: to_lua(lua, json.load(open(os.path.join(MOD, p.lstrip("/"))))) \
        if os.path.exists(os.path.join(MOD, p.lstrip("/"))) else None
    root_abs = os.path.join(MOD, "art", "slrr_pedestrians")
    g.py_find = lambda root, pat: lua.table(*[
        "/art/slrr_pedestrians/" + os.path.relpath(os.path.join(dp, f), root_abs).replace("\\", "/")
        for dp, _, fs in os.walk(root_abs) for f in fs if f.endswith(pat.lstrip("*"))])
    g.py_signals = lambda: to_lua(lua, SIGNALS)
    lua.execute(FAKE)
    M = lua.execute(open(os.path.join(MOD, "lua", "ge", "extensions", "slrrPedestrians.lua")).read())
    M.onExtensionLoaded()
    M.onClientStartMission()
    M.setCount(40)
    M.setOptions(lua.table_from({"maxCount": 200}))

    dt = 1 / 30
    states, crossings, close, slides, steps = set(), {"crossed traffic red": 0, "green alongside": 0, "other": 0, "free": 0}, 0, [], 0
    seen = {}
    road_starts = car_conflicts = 0
    for frame in range(int(240 / dt)):
        g.time = frame * dt
        slow = 1800 <= frame < 2700          # 30 s of slow frames (40 ms) in the middle
        M.onUpdate(0.040 if slow else 1 / 90, dt)   # real frame time: 40 ms slow, 11 ms fast
        st = M.getState()
        peds = list(st.peds.values())
        if frame == 2699:
            slow_count = len(peds)
        for p in peds:
            states.add(p.state)
            c = p.cross
            if c is not None and c.t <= dt * p.speed / c.len + 1e-9 and seen.get(id(c)) is None:
                seen[id(c)] = True
                if c.road:
                    # K5: the car must not come within 3 m of the crossing before they're over (+2 s)
                    road_starts += 1
                    a, b = (c["from"].x, c["from"].y), (c.to.x, c.to.y)
                    mid, half = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2), math.dist(a, b) / 2 + 3
                    for k in range(int((c.len / p.speed + 2) / 0.1)):
                        g.time = frame * dt + k * 0.1
                        cp = g.car.getPosition(g.car)
                        if math.dist((cp.x, cp.y), mid) < half - 3 + 1.0:   # 1 m slack for the 0.1 s steps
                            car_conflicts += 1
                            break
                    g.time = frame * dt
                across = list(c.across.values()) if c.across else []
                if c.signal is None and not across:
                    crossings["free"] += 1
                elif across and all(o.getState(o) == "redTrafficLight" for o in across):
                    crossings["crossed traffic red"] += 1
                elif not across and c.signal.getState(c.signal) == "greenTrafficLight":
                    crossings["green alongside"] += 1
                else:
                    crossings["other"] += 1
            # along-path speed of walkers on a sidewalk (no sidestep or dodge running) vs their shape's speed
            key = (p.line, p.dir)
            if p.state == "walk" and c is None and p._last is not None and p._last[0] == key and abs(p.side) < 1e-6:
                slides.append(abs(abs(p.s - p._last[1]) / dt - p.speed))
            p._last = (key, p.s)
        walkers = [p for p in peds if p.pos is not None and p.state == "walk"]
        for i, a in enumerate(walkers):
            for b in walkers[i + 1:]:
                steps += 1
                if math.hypot(a.pos.x - b.pos.x, a.pos.y - b.pos.y) < 0.3:
                    close += 1
    end_state = M.getState()
    end_count, share = len(list(end_state.peds.values())), end_state.share
    print("states seen:", sorted(states))
    print("crossings started:", crossings)
    print("road crossings started: %d, into the car's path: %d" % (road_starts, car_conflicts))
    print("walking speed error: max %.4f m/s over %d steps" % (max(slides), len(slides)))
    print("walker pairs closer than 0.3 m: %d of %d pair-frames" % (close, steps))
    print("count: 40 set x area share %.2f, %d after 30 s of 40 ms frames, %d after 60 s of fast frames" % (
        share, slow_count, end_count))
    # density: downtown and the beachfront busiest, outskirts quietest
    w = {name: M.weightAt(x, y) for name, (x, y) in {"downtown": (0, 500), "beachfront": (0, 950), "south end": (0, -800),
                                                    "industrial": (1000, -300), "outskirts": (3000, 3000)}.items()}
    print("density weights:", w)
    assert states >= {"walk", "idle", "wait"}, states
    assert crossings["other"] == 0 and crossings["crossed traffic red"] > 0, crossings
    assert road_starts > 0 and car_conflicts == 0, (road_starts, car_conflicts)
    assert max(slides) < 0.01, max(slides)
    assert close < steps * 0.001, (close, steps)
    assert slow_count <= 10 and end_count >= round(40 * share) - 2, (slow_count, end_count, share)
    assert w["downtown"] == w["beachfront"] == 1 and w["outskirts"] < w["industrial"] < w["south end"] < 1, w

    # player options: no idling and no crossings, then a hard cap, then off
    M.setOptions(lua.table_from({"idling": False, "crossing": False, "amount": "high", "bogus": 1}))
    long_cross = idle = 0
    for frame in range(int(60 / dt)):
        g.time = 300 + frame * dt
        M.onUpdate(1 / 90, dt)
        for p in M.getState().peds.values():
            idle += p.state == "idle"
            long_cross += p.cross is not None and bool(p.cross.road) and p.cross.t < 0.05
    opts = M.getOptions()
    print("idling/crossing off: %d idle frames, %d road crossings started; options %s" % (
        idle, long_cross, dict(opts.items())))
    assert idle == 0 and long_cross == 0, (idle, long_cross)
    assert opts.amount == "high" and opts.bogus is None
    for setting, most in (({"maxCount": 10}, 10), ({"amount": "off"}, 0)):
        M.setOptions(lua.table_from(setting))
        for frame in range(120):
            M.onUpdate(1 / 90, dt)
        n = len(list(M.getState().peds.values()))
        print(setting, "->", n, "pedestrians")
        assert n <= most, (setting, n)
    print("ok")


def player():
    """X31b: the on-foot walker follows a vehicle, picks the walk nearest its speed, stands when slow, and goes."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    g = lua.globals()
    g.py_json = lambda p: to_lua(lua, json.load(open(os.path.join(MOD, p.lstrip("/")))))         if os.path.exists(os.path.join(MOD, p.lstrip("/"))) else None
    g.py_find = lambda root, pat: lua.table()
    g.py_signals = lambda: lua.table()
    lua.execute(FAKE)
    lua.execute("""
      uni = {speed = 0, gone = false}
      function uni:getPosition() return vec3(10, 20, 5) end
      function uni:getDirectionVector() return vec3(0, 1, 0) end
      function uni:getVelocity() return vec3(0, self.speed, 0) end
      be.getObjectByID = function(self, id) if id == 7 and not uni.gone then return uni end end
      function log() end""")
    M = lua.execute(open(os.path.join(MOD, "lua", "ge", "extensions", "slrrPedestrians.lua")).read())
    M.followPlayer(7, "/art/slrr_drivers/slrr_mitch/walker")
    seen = []
    for speed in (0, 1.06, 1.2, 0.1):
        g.uni.speed = speed
        for _ in range(40):
            M.onUpdate(1 / 30, 1 / 30)
        live = [o for o in g.objects.values() if not o.dead and o.cls == "TSStatic"]
        seen.append((speed, live[-1].shapeName.rsplit("/", 1)[-1], len(live)))
    print("player walker:", seen)
    assert [x[1] for x in seen] == ["idle.dae", "walk.dae", "walk_fast.dae", "idle.dae"] and all(x[2] == 1 for x in seen), seen
    g.uni.gone = True
    M.onUpdate(1 / 30, 1 / 30)
    assert not [o for o in g.objects.values() if not o.dead and o.cls == "TSStatic"], "walker left behind"


def footpaths():
    """K1: every sidewalk sample on pavement (tools/ped_paths.py classifies against the map's collision meshes)."""
    if not os.path.isdir(MAP):
        print("footpaths: map not found, skipped")
        return
    import ped_paths
    data = json.load(open(ped_paths.WALK))
    cls = ped_paths.classify(data["lines"] if isinstance(data, dict) else data)[0]
    off = sum(1 for c in cls if c not in ped_paths.OK)
    print("footpaths: %d of %d samples off the pavement" % (off, len(cls)))
    assert off == 0, off


if __name__ == "__main__":
    main()
    player()
    footpaths()
    print("all ok")
