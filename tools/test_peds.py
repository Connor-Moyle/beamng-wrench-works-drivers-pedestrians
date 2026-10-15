"""Offline check of slrrPedestrians.lua: runs the real file in LuaJIT (lupa) with a fake BeamNG around Valo City's
first signalled junction, using the real sidewalks, ped.json files and the map's signals.json.

    python test_peds.py [MAP_DIR]

Checks: walkers move at their shape's speed (no foot slide), nobody starts a signalled crossing on anything but
green, standing and waiting both happen, pedestrians keep apart, and the count drops when frames are slow and
comes back when they are fast. MAP_DIR defaults to C:/Dev/SLRR map for beam ng.
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
be = {getObjectCount = function() return 0 end}
-- signals: two phases alternating 10 s green, 4 s yellow, 1.5 s all red (signals.py), phase = controllerId
local Sig = {}
Sig.__index = Sig
local function stateAt(phase, t)
  local c = t % 31
  local mine = phase == 1 and c or (c + 15.5) % 31
  if mine < 10 then return 'greenTrafficLight' elseif mine < 14 then return 'yellowTrafficLight' end
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

    dt = 1 / 30
    states, crossings, close, slides, steps = set(), {"green": 0, "other": 0, "free": 0}, 0, [], 0
    seen = {}
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
                if c.signal is None:
                    crossings["free"] += 1
                else:
                    crossings["green" if c.signal.getState(c.signal) == "greenTrafficLight" else "other"] += 1
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
    end_count = len(list(M.getState().peds.values()))
    print("states seen:", sorted(states))
    print("crossings started:", crossings)
    print("walking speed error: max %.4f m/s over %d steps" % (max(slides), len(slides)))
    print("walker pairs closer than 0.3 m: %d of %d pair-frames" % (close, steps))
    print("count: 40 set, %d after 30 s of 40 ms frames, %d after 60 s of fast frames" % (slow_count, end_count))
    assert states >= {"walk", "idle", "wait"}, states
    assert crossings["other"] == 0 and crossings["green"] > 0, crossings
    assert max(slides) < 0.01, max(slides)
    assert close < steps * 0.001, (close, steps)
    assert slow_count <= 10 and end_count >= 35, (slow_count, end_count)
    print("ok")


if __name__ == "__main__":
    main()
