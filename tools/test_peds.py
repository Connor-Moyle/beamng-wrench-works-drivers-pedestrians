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

import numpy as np
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
function Obj:setHidden(h) self.hidden = h end
function createObject(cls) local o = setmetatable({cls = cls}, Obj) table.insert(objects, o) return o end
function simObjectExists(o) return o and not o.dead end
scenetree = {findObject = function() return nil end, MissionGroup = setmetatable({}, Obj)}
camPos = vec3(-340, 210, 7)
core_camera = {getPosition = function() return camPos end, getForward = function() return vec3(0, 0.6, 0.8) end}
-- one car driving through junction_0 at 12 m/s along +x, from 260 m before it to 240 m past, then round again
car = {}
function car:getPosition() return vec3(-600 + (time * 12) % 500, 210, 7) end
function car:getVelocity() return vec3(crashed and 0 or 12, 0, 0) end
function car:getId() return 1 end
crashed = false
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
map = {getMap = function() return {nodes = py_roads()} end}
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
    seed = int(os.environ.get("PEDS_SEED") or int.from_bytes(os.urandom(3), "big"))   # replay a failing run: PEDS_SEED=<printed>
    print("seed %d" % seed, flush=True)
    lua.execute("math.randomseed(%d)" % seed)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    lua.execute("os.clock = function() return time or 0 end")   # simulated time, not the wall clock: machine load changed the run
    g = lua.globals()
    g.py_json = lambda p: to_lua(lua, json.load(open(os.path.join(MOD, p.lstrip("/"))))) \
        if os.path.exists(os.path.join(MOD, p.lstrip("/"))) else None
    root_abs = os.path.join(MOD, "art", "slrr_pedestrians")
    g.py_find = lambda root, pat: lua.table(*[
        "/art/slrr_pedestrians/" + os.path.relpath(os.path.join(dp, f), root_abs).replace("\\", "/")
        for dp, _, fs in os.walk(root_abs) for f in fs if f.endswith(pat.lstrip("*"))])
    g.py_signals = lambda: to_lua(lua, SIGNALS)
    # roads for T51: under every road crossing of the walk file, a road across the middle of the link, 0.9 m narrower than the link each
    # side (the sidewalk ends stand just off it); the offline check of 'nobody stops on a carriageway' uses the same
    walk0 = json.load(open(os.path.join(MOD, "art", "slrr_pedestrians", "walk_slrr_valo_city.json")))
    lines0 = walk0["lines"]
    road_segs, road_nodes = [], {}
    for i, k in enumerate(walk0["links"]):
        if not k[4]:
            continue
        la, lb = lines0[k[0]], lines0[k[2]]
        a = la[0] if k[1] else la[-1]
        b = lb[0] if k[3] else lb[-1]
        ln = math.dist(a[:2], b[:2])
        if ln < 5:
            continue
        mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
        dx, dy = (b[0] - a[0]) / ln, (b[1] - a[1]) / ln
        px, py_ = -dy, dx                        # along the road: perpendicular to the crossing
        half = max(1.0, ln / 2 - 0.9)
        n1, n2 = (mx - px * 10, my - py_ * 10, a[2]), (mx + px * 10, my + py_ * 10, a[2])
        road_nodes["r%da" % i] = {"pos": {"x": n1[0], "y": n1[1], "z": n1[2]}, "radius": half, "links": {"r%db" % i: {"drivability": 1}}}
        road_nodes["r%db" % i] = {"pos": {"x": n2[0], "y": n2[1], "z": n2[2]}, "radius": half, "links": {"r%da" % i: {"drivability": 1}}}
        road_segs.append((n1[0], n1[1], n2[0], n2[1], half - 0.2))
    g.py_roads = lambda: to_lua(lua, road_nodes)
    seg = np.array(road_segs)

    def on_road(x, y):
        ax, ay, bx, by, r = seg[:, 0], seg[:, 1], seg[:, 2], seg[:, 3], seg[:, 4]
        dx, dy = bx - ax, by - ay
        tt = np.clip(((x - ax) * dx + (y - ay) * dy) / np.maximum(dx * dx + dy * dy, 1e-9), 0, 1)
        return bool(np.any(np.hypot(x - (ax + dx * tt), y - (ay + dy * tt)) < r))
    lua.execute(FAKE)
    M = lua.execute(open(os.path.join(MOD, "lua", "ge", "extensions", "slrrPedestrians.lua")).read())
    M.onExtensionLoaded()
    M.onClientStartMission()
    M.setCount(40)
    M.setOptions(lua.table_from({"maxCount": 200}))

    dt = 1 / 30
    states, crossings, close, slides, steps = set(), {"crossed traffic red": 0, "green alongside": 0, "other": 0, "free": 0}, 0, [], 0
    seen = {}
    walk = json.load(open(os.path.join(MOD, "art", "slrr_pedestrians", "walk_slrr_valo_city.json")))
    rooms = walk.get("room") if isinstance(walk, dict) else None
    plines = [np.array(l) for l in (walk["lines"] if isinstance(walk, dict) else walk)]
    cums = [np.concatenate([[0], np.cumsum(np.linalg.norm(
        np.diff(l[:, :2], axis=0), axis=1))]) for l in plines]

    def point_at(i, d):
        l, c = plines[i], cums[i]
        k = min(max(int(np.searchsorted(c, d, side="right")) - 1, 0), len(l) - 2)
        t = (d - c[k]) / max(c[k + 1] - c[k], 1e-6)
        return l[k] + (l[k + 1] - l[k]) * t
    walk_frames, longest_stand = [0, 0], [0.0, '']
    worst_side = 0.0
    spawns = in_view_spawns = 0
    road_starts = car_conflicts = 0
    road_stops = cross_stops = cross_frames = forced_starts = 0
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
            # how much of the time they walk, and the longest any one stands (T35)
            walk_frames[0] += p.state == "walk"
            walk_frames[1] += 1
            p._still = (p._still or 0) + dt if p.state != "walk" else 0
            if p._still > longest_stand[0]:
                longest_stand[0], longest_stand[1] = p._still, p.state
            c = p.cross
            # T51: nobody is stopped, waiting or looking round on a carriageway, and a crossing is never interrupted
            if c is not None:
                cross_frames += 1
                cross_stops += p.state != "walk"
            if p.state != "walk" and p.pos is not None and on_road(p.pos.x, p.pos.y):
                road_stops += 1
                print("on a road: frame", frame, p.state, "line", p.line, "s %.1f" % p.s, "link", p.link is not None, "shelter", bool(p.sheltered), "face", p.face, "timer", p.timer, "hurry", p.hurry is not None)
            if c is not None and c.t <= dt * p.speed / c.len + 1e-9 and seen.get(id(c)) is None:
                seen[id(c)] = True
                if c.forced:
                    forced_starts += 1
                    continue
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
                v = abs(p.s - p._last[1]) / dt   # a hurry starting this frame moves from the next one
                err = min(abs(v - p.speed), abs(v - p.hurry.speed) if p.hurry else 9)
                slides.append(err)
            p._last = (key, p.s)
            if p._born is None:
                p._born = 1
                spawns += 1
                if p.pos is not None:
                    d = (p.pos.x - g.camPos.x, p.pos.y - g.camPos.y, p.pos.z - g.camPos.z)
                    l = math.sqrt(sum(x * x for x in d)) or 1
                    in_view_spawns += (0.6 * d[1] + 0.8 * d[2]) / l > 0.5
            # never off the pavement: sideways from the line within the room measured beside it
            if c is None and p.pos is not None and rooms:
                q = point_at(p.line - 1, p.s)
                lat = math.hypot(p.pos.x - q[0], p.pos.y - q[1])
                worst_side = max(worst_side, lat - max(rooms[p.line - 1]))
        walkers = [p for p in peds if p.pos is not None and p.state == "walk"]
        for i, a in enumerate(walkers):
            for b in walkers[i + 1:]:
                steps += 1
                if math.hypot(a.pos.x - b.pos.x, a.pos.y - b.pos.y) < 0.3:
                    close += 1
    end_state = M.getState()
    end_count, share = len(list(end_state.peds.values())), end_state.share
    print("walking %.1f%% of the time; longest standing %.0f s (%s)" % (100 * walk_frames[0] / max(1, walk_frames[1]), longest_stand[0], longest_stand[1]))
    assert walk_frames[0] / walk_frames[1] > 0.92, "pedestrians stand about too much: walking only %.1f%% of the time" % (100 * walk_frames[0] / walk_frames[1])
    assert longest_stand[0] <= 30, "somebody stood still for %.0f s (%s)" % (longest_stand[0], longest_stand[1])
    print("T51: %d frames in a crossing, %d of them not walking; %d frames stopped on a road; %d crossings begun because they stood on a road" % (cross_frames, cross_stops, road_stops, forced_starts))
    assert cross_frames > 1000, "too few crossings seen to say anything (%d frames)" % cross_frames
    assert cross_stops == 0, "a pedestrian stopped mid-crossing in %d frames" % cross_stops
    assert road_stops == 0, "a pedestrian stood, waited or looked round on a road in %d frames" % road_stops
    print("states seen:", sorted(states))
    print("crossings started:", crossings)
    print("furthest beyond the pavement room beside the line: %.3f m" % worst_side)
    print("spawned in view: %d of %d" % (in_view_spawns, spawns))
    print("road crossings started: %d, into the car's path: %d" % (road_starts, car_conflicts))
    print("walking speed error: max %.4f m/s over %d steps" % (max(slides), len(slides)))
    print("walker pairs closer than 0.3 m: %d of %d pair-frames" % (close, steps))
    print("count: 40 set x area share %.2f, %d after 30 s of 40 ms frames, %d after 60 s of fast frames" % (
        share, slow_count, end_count))
    # density: downtown and the beachfront busiest, outskirts quietest
    w = {name: M.weightAt(x, y) for name, (x, y) in {"downtown": (0, 500), "beachfront": (0, 950), "south end": (0, -800),
                                                    "industrial": (1000, -300), "outskirts": (3000, 3000)}.items()}
    print("density weights:", w)
    # types per area (W8): an area's "types" picks among the pedestrian kinds; elsewhere the level's, else any
    kinds = sorted({t.kind for t in list(M.getTypes().values())})
    M.setDensity(to_lua(lua, {"default": 1, "types": ["casual"], "areas": [{"box": [0, 0, 100, 100], "weight": 1, "types": ["worker", "business"]}]}))
    picked = {M.pickType(50, 50).kind for _ in range(200)}
    assert picked and picked <= {"worker", "business"} and len(picked) == len({"worker", "business"} & set(kinds)), ("area types", picked, kinds)
    assert {M.pickType(500, 500).kind for _ in range(100)} == {"casual"}, "outside the area the level's types"
    M.setDensity(None)
    print("types per area ok:", sorted(picked))
    assert states >= {"walk", "idle"}, states
    if "wait" not in states:
        print("note: nobody happened to wait at a signal in this run")
    # nobody ever crosses against the traffic; that somebody crossed on a red in these 240 s depends on where the random pedestrians happen to walk
    # (about half the runs), so it is reported, not required
    assert crossings["other"] == 0, crossings
    if crossings["crossed traffic red"] == 0:
        print("note: nobody happened to cross a signalled road in this run", crossings)
    assert car_conflicts == 0, (road_starts, car_conflicts)
    if road_starts == 0:
        print("note: nobody happened to cross a road in this run")
    assert worst_side < 0.01, worst_side
    assert in_view_spawns == 0, (in_view_spawns, spawns)

    # X33: the car crashes (stops dead) at the junction: the nearest react, the closest hurry away
    g.time = 300
    g.camPos = g.vec3(-340, 210, 7)
    for frame in range(int(20 / dt)):
        g.time = 300 + frame * dt
        M.onUpdate(1 / 90, dt)
    p0 = [p for p in M.getState().peds.values() if p.pos is not None and not p.cross][0]
    lua.execute("crashAt = vec3(%f, %f, %f)" % (p0.pos.x + 6, p0.pos.y, p0.pos.z))
    lua.execute("""local get = car.getPosition
      function car:getPosition() if crashed then return crashAt end return get(self) end
      crashed = true""")
    M.onUpdate(1 / 90, dt)
    peds = list(M.getState().peds.values())
    watching = sum(1 for p in peds if p.face is not None)
    fleeing = sum(1 for p in peds if p.hurryTime is not None and p.hurryTime > 5)
    print("crash: %d stop and look, %d hurry away (of %d walking nearby)" % (watching, fleeing, len(peds)))
    assert 0 < watching + fleeing <= 12, (watching, fleeing)
    lua.execute("crashed = false")
    assert max(slides) < 0.01, max(slides)
    assert close < steps * 0.001, (close, steps)
    assert slow_count <= round(40 * share * 0.5) + 2 and end_count >= round(40 * share) - 2, (slow_count, end_count, share)
    assert w["downtown"] == w["beachfront"] == 1 and w["outskirts"] < w["industrial"] < w["south end"] < 1, w

    # player options: no idling and no crossings, then a hard cap, then off
    M.setOptions(lua.table_from({"idling": False, "crossing": False, "amount": "high", "bogus": 1}))
    long_cross = idle = 0
    for frame in range(int(60 / dt)):
        g.time = 300 + frame * dt
        M.onUpdate(1 / 90, dt)
        for p in M.getState().peds.values():
            idle += p.state == "idle"
            long_cross += p.cross is not None and bool(p.cross.road) and not p.cross.forced and p.cross.t < 0.05   # (a forced one: they stood on a road, crossing option or not)
    opts = M.getOptions()
    print("idling/crossing off: %d idle frames, %d road crossings started; options %s" % (
        idle, long_cross, dict(opts.items())))
    assert idle == 0 and long_cross == 0, (idle, long_cross)
    assert opts.amount == "high" and opts.bogus is None
    # the Mods menu page: one tab, fields stored through getOptions/setOptions and getCount/setCount
    tab, fields = M.settingsSchema()
    by_id = {f.id: f for f in fields.values()}
    assert tab.id == "pedestrians" and all(f.tab == "pedestrians" for f in by_id.values())
    assert {"amount", "maxCount", "count", "autoReduce", "targetFps", "idling", "crossing", "busyAreas", "rainReact", "rainShelter", "rainThin", "limp", "limpPace"} == set(by_id), set(by_id)
    assert all(f.label and f.tooltip and f.store.get and f.store.set for f in by_id.values())
    assert by_id["amount"].store.get() == "high" and by_id["idling"].store.get() is False, "the schema reads the live options"
    by_id["maxCount"].store.set(77)
    by_id["count"].store.set(30)
    assert M.getOptions().maxCount == 77 and M.getCount() == 30 and by_id["count"].store.get() == 30
    by_id["maxCount"].store.set(60)
    by_id["count"].store.set(48)
    print("settings schema ok")
    for setting, most in (({"maxCount": 10}, 10), ({"amount": "off"}, 0)):
        M.setOptions(lua.table_from(setting))
        for frame in range(120):
            M.onUpdate(1 / 90, dt)
        n = len(list(M.getState().peds.values()))
        print(setting, "->", n, "pedestrians")
        assert n <= most, (setting, n)
    print("ok")

    # rain: faster walks and runners, the crowd thins, some stand under a roof until it stops
    M.setOptions(lua.table_from({"amount": "medium", "maxCount": 200, "idling": True, "crossing": True, "rainReact": True, "rainShelter": True, "rainThin": 40}))
    M.setCount(40)

    most_sheltered = [0]

    def run(seconds, start):
        for frame in range(int(seconds / dt)):
            g.time = start + frame * dt
            M.onUpdate(1 / 90, dt)
            if frame % 15 == 0:
                most_sheltered[0] = max(most_sheltered[0], sum(1 for p in M.getState().peds.values() if p.sheltered))
        return list(M.getState().peds.values())
    peds = run(40, 400)
    n_dry = len(peds)
    assert not any(p.sheltered for p in peds) and M.getRain() == 0, "dry: nobody under cover"
    lua.execute("castRayStatic = function(from, dir, len) if dir.z > 0 then return len * 0.4 end return 2 end")      # a roof over every pavement
    M.setRain(1.0)
    peds = run(120, 500)
    n_wet = len(peds)
    switched = [p for p in peds if p.state == "walk" and p.shape != p.walk.shape]
    sheltered = [p for p in peds if p.sheltered]
    print("rain: %d pedestrians dry, %d wet; %d walking a faster shape, %d under a roof now, %d at most" % (n_dry, n_wet, len(switched), len(sheltered), most_sheltered[0]))
    assert n_wet <= n_dry * 0.8 + 1, (n_dry, n_wet)
    assert switched, "in the rain some walk a faster shape"
    assert most_sheltered[0] >= 3 and all(p.state == "idle" for p in sheltered), "some stand under a roof"
    M.setRain(0)
    peds = run(15, 700)
    assert not any(p.sheltered for p in peds), "the rain stopped: they are on their way"
    assert not [p for p in peds if p.state == "walk" and p.shape != p.walk.shape and p.hurry is None], "the usual walks again"
    M.setOptions(lua.table_from({"rainReact": False}))
    M.setRain(1.0)
    peds = run(30, 800)
    assert not any(p.sheltered for p in peds) and not [p for p in peds if p.state == "walk" and p.shape != p.walk.shape and p.hurry is None], "react to rain off: no difference"
    M.setOptions(lua.table_from({"rainReact": True}))
    M.setRain(None)
    lua.execute("castRayStatic = function(from, dir, len) return 2 end")
    print("rain ok")


def player():
    """X31b: the on-foot walker follows a vehicle, picks the walk nearest its speed, stands when slow, and goes."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    lua.execute("os.clock = function() return time or 0 end")   # simulated time, not the wall clock: machine load changed the run
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
      be.getPlayerVehicleID = function() return 7 end
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
    # the limp: slrrInjury's slowWalk (or setLimp) cuts the walker's speed once, and puts it back when it ends
    lua.execute("""
      cmds = {}
      function uni:queueLuaCommand(c) table.insert(cmds, c) end
      injured = false
      slrrInjury = {getState = function(id) return {limits = {slowWalk = injured}} end}""")

    def frames(n):
        for _ in range(n):
            M.onUpdate(1 / 30, 1 / 30)
    frames(40)
    assert len(list(g.cmds.values())) == 0, "no injury: no command"
    g.injured = True
    frames(40)
    cmds = list(g.cmds.values())
    assert len(cmds) == 1 and "local k = 0.550" in cmds[0], cmds
    frames(60)
    assert len(list(g.cmds.values())) == 1, "once, not every check"
    g.injured = False
    frames(40)
    assert list(g.cmds.values())[-1].startswith("local k = nil"), "healed: the speeds go back"
    M.setLimp(True)
    frames(40)
    assert "local k = 0.550" in list(g.cmds.values())[-1], "setLimp(true) limps without an injury"
    M.setLimp(None)
    frames(40)
    assert list(g.cmds.values())[-1].startswith("local k = nil")
    M.setOptions(lua.table_from({"limp": False}))
    M.setLimp(True)
    n = len(list(g.cmds.values()))
    frames(40)
    assert len(list(g.cmds.values())) == n, "the option off: no limp"
    M.setOptions(lua.table_from({"limp": True}))
    M.setLimp(None)
    # the command itself, run against a stand-in for the game's playerController: the two speed locals are upvalues of updateFixedStep
    lua.execute("""
      do
        local movementSpeedNormal, movementSpeedSprint = 1.8, 5
        local pc = {updateFixedStep = function() return movementSpeedNormal, movementSpeedSprint end}
        controller = {getController = function() return pc end}
        readSpeeds = function() return pc.updateFixedStep() end
      end""")
    run_cmd = lua.eval("function(c) assert(loadstring(c))() return readSpeeds() end")
    a, b = run_cmd(M.limpCommand(0.55))
    assert abs(a - 0.99) < 1e-6 and abs(b - 0.99) < 1e-6, (a, b)
    a, b = run_cmd(M.limpCommand(0.55))
    assert abs(a - 0.99) < 1e-6, "twice does not compound"
    a, b = run_cmd(M.limpCommand(None))
    assert abs(a - 1.8) < 1e-6 and abs(b - 5) < 1e-6, (a, b)
    # the game rebuilt the controller table (the originals are gone) while the speeds were still cut: the next command must not take 0.99 as the original
    run_cmd(M.limpCommand(0.55))
    lua.execute("""
      do
        local movementSpeedNormal, movementSpeedSprint = 0.99, 0.99
        local pc = {updateFixedStep = function() return movementSpeedNormal, movementSpeedSprint end}
        controller = {getController = function() return pc end}
        readSpeeds = function() return pc.updateFixedStep() end
      end""")
    a, b = run_cmd(M.limpCommand(0.55))
    assert abs(a - 0.99) < 1e-6, (a, b)
    a, b = run_cmd(M.limpCommand(None))
    assert abs(a - 1.8) < 1e-6 and abs(b - 5) < 1e-6, ("rebuilt controller: back to the defaults", a, b)
    print("limp ok")
    assert [x[1] for x in seen] == ["idle.dae", "walk.dae", "walk_fast.dae", "idle.dae"] and all(x[2] == 1 for x in seen), seen
    # T52: in a career the snowman (the unicycle's own mesh) goes while the walker is shown, and the walker has no body in first person
    lua.execute("alphaCalls = {}; function uni:setMeshAlpha(a, name, flag) table.insert(alphaCalls, a) end")
    g.career_career = None
    M.onPreRender()
    assert len(list(g.alphaCalls.values())) == 0, "no career: the snowman is left alone"
    g.career_career = lua.eval("{isActive = function() return true end}")
    M.onPreRender()
    calls = list(g.alphaCalls.values())
    assert calls == [0], "career: the unicycle mesh is hidden every frame (%s)" % calls
    g.career_career = None
    g.sl_career = lua.eval("{isActive = function() return true end}")
    M.onPreRender()
    assert list(g.alphaCalls.values()) == [0, 0], "Street Legal's career counts as a career too"
    g.sl_career = None
    live = [o for o in g.objects.values() if not o.dead and o.cls == "TSStatic"]
    M.onUpdate(1 / 30, 1 / 30)
    assert live[-1].hidden is False, "camera far away: the walker shows"
    g.camPos = lua.eval("vec3(10, 20.4, 6.3)")      # in his head, first person
    M.onUpdate(1 / 30, 1 / 30)
    live = [o for o in g.objects.values() if not o.dead and o.cls == "TSStatic"]
    assert live[-1].hidden is True, "first person: no body"
    g.camPos = lua.eval("vec3(10, 26, 7)")
    M.onUpdate(1 / 30, 1 / 30)
    live = [o for o in g.objects.values() if not o.dead and o.cls == "TSStatic"]
    assert live[-1].hidden is False, "camera back out: the body shows"
    print("T52: snowman hidden in a career only, walker hidden in first person")
    M.followPlayer(None)
    g.career_career = lua.eval("{isActive = function() return true end}")
    M.onPreRender()
    assert list(g.alphaCalls.values()) == [0, 0], "no walker: the snowman stays (nobody would be seen)"
    M.followPlayer(7, "/art/slrr_drivers/slrr_mitch/walker")
    g.uni.gone = True
    M.onUpdate(1 / 30, 1 / 30)
    assert not [o for o in g.objects.values() if not o.dead and o.cls == "TSStatic"], "walker left behind"


def spectators():
    """X32: a crowd fills the meet near the camera out of view within the budget, cheers at a fast car and a race
    finish, and goes when the camera leaves."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    lua.execute("os.clock = function() return time or 0 end")   # simulated time, not the wall clock: machine load changed the run
    g = lua.globals()
    g.py_json = lambda p: to_lua(lua, json.load(open(os.path.join(MOD, p.lstrip("/")))))         if os.path.exists(os.path.join(MOD, p.lstrip("/"))) else None
    root_abs = os.path.join(MOD, "art", "slrr_pedestrians")
    g.py_find = lambda root, pat: lua.table(*[
        "/art/slrr_pedestrians/" + os.path.relpath(os.path.join(dp, f), root_abs).replace("\\", "/")
        for dp, _, fs in os.walk(root_abs) for f in fs if f.endswith(pat.lstrip("*"))])
    g.py_signals = lambda: to_lua(lua, SIGNALS)
    lua.execute(FAKE)
    zones = json.load(open(os.path.join(root_abs, "spectators_slrr_valo_city.json")))["zones"]
    z = [z for z in zones if z["id"] == "slrr_poi_meet_central"][0]
    lua.execute("""
      function car:getPosition() return vec3(%f, %f + (time * 20) %% 200 - 100, %f) end
      function car:getVelocity() return vec3(0, self.moving and 20 or 0, 0) end
      car.moving = false""" % (z["c"][0], z["c"][1], z["c"][2]))
    M = lua.execute(open(os.path.join(MOD, "lua", "ge", "extensions", "slrrPedestrians.lua")).read())
    M.onExtensionLoaded()
    M.onClientStartMission()
    M.setCount(30)
    M.setOptions(lua.table_from({"maxCount": 60, "amount": "medium", "idling": True, "crossing": True, "autoReduce": True}))
    dt = 1 / 30

    def run(seconds, t0):
        for f in range(int(seconds / dt)):
            g.time = t0 + f * dt
            M.onUpdate(1 / 90, dt)
        st = M.getState()
        sp = list(st.spectators.values())
        return st, sp, sum(1 for x in sp if x.shape == x.type.cheer)
    lua.execute("camPos = vec3(%f, %f, %f)" % (z["c"][0], z["c"][1] - 120, z["c"][2] + 5))   # arriving
    run(30, 0)
    lua.execute("camPos = vec3(%f, %f, %f)" % (z["c"][0], z["c"][1] - 40, z["c"][2] + 5))
    st, sp, cheering = run(10, 30)
    look = (0, 0.6, 0.8)
    in_view = 0
    for x in sp:
        d = (x.spot[1] - g.camPos.x, x.spot[2] - g.camPos.y, x.spot[3] - g.camPos.z)
        l = math.sqrt(sum(c * c for c in d)) or 1
        in_view += (d[0] * look[0] + d[1] * look[1] + d[2] * look[2]) / l > 0.5
    print("spectators at %s: %d of %d spots (budget 30, a meet's share 9), %d pedestrians, cheering %d, Lua %.0f KB" % (
        st.specZone, len(sp), len(z["spots"]), len(list(st.peds.values())), cheering, st.luaKB))
    assert st.specZone == "slrr_poi_meet_central" and 0 < len(sp) <= 9 and cheering == 0, (st.specZone, len(sp))
    assert len(sp) + len(list(st.peds.values())) <= 30
    lua.execute("car.moving = true")
    st, sp, cheering = run(6, 40)
    print("a car past at 20 m/s: %d cheering" % cheering)
    assert cheering > 0
    lua.execute("car.moving = false")
    run(10, 46)
    M.onSlrrRaceFinished()
    st, sp, cheering = run(3, 56)
    print("race finished: %d of %d cheering" % (cheering, len(sp)))
    assert cheering >= len(sp) * 0.8, (cheering, len(sp))
    lua.execute("camPos = vec3(5000, 5000, 5)")
    st, sp, _ = run(3, 60)
    print("camera gone: %d spectators" % len(sp))
    assert len(sp) == 0


def extra_spectators():
    """#40: a mod's zones (Street Legal's drag strip on West Coast USA) fill like the level's own: out of view within the budget, cheering at a race
    finish, and gone when the camera leaves; the same id replaces a zone."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    lua.execute("os.clock = function() return time or 0 end")   # simulated time, not the wall clock: machine load changed the run
    g = lua.globals()
    g.py_json = lambda p: to_lua(lua, json.load(open(os.path.join(MOD, p.lstrip("/")))))         if os.path.exists(os.path.join(MOD, p.lstrip("/"))) else None
    root_abs = os.path.join(MOD, "art", "slrr_pedestrians")
    g.py_find = lambda root, pat: lua.table(*[
        "/art/slrr_pedestrians/" + os.path.relpath(os.path.join(dp, f), root_abs).replace("\\", "/")
        for dp, _, fs in os.walk(root_abs) for f in fs if f.endswith(pat.lstrip("*"))])
    g.py_signals = lambda: to_lua(lua, SIGNALS)
    lua.execute(FAKE)
    M = lua.execute(open(os.path.join(MOD, "lua", "ge", "extensions", "slrrPedestrians.lua")).read())
    M.onExtensionLoaded()
    M.onClientStartMission()
    spots = [[100 + i * 1.3, 200, 50, 0, 1] for i in range(30)]
    zone = {"id": "wcusa_drag", "kind": "race", "c": [120, 200, 50], "r": 30, "spots": spots, "ground": True}
    M.addSpectatorZones(lua.table_from([lua.table_from(zone, recursive=True)], recursive=True))
    M.addSpectatorZones(lua.table_from([lua.table_from(dict(zone, r=31), recursive=True)], recursive=True))     # the same id replaces
    M.setCount(30)
    M.setOptions(lua.table_from({"maxCount": 60, "amount": "medium", "idling": True, "crossing": True, "autoReduce": True}))
    lua.execute("function car:getPosition() return vec3(120, 500, 50) end function car:getVelocity() return vec3(0, 0, 0) end")
    lua.execute("camPos = vec3(120, 20, 55)")           # arriving: the crowd is there before you (no spectator appears in view nearer than 90 m)
    dt = 1 / 30
    for f in range(int(30 / dt)):
        g.time = f * dt
        M.onUpdate(1 / 90, dt)
    lua.execute("camPos = vec3(120, 120, 55)")
    for f in range(int(10 / dt)):
        g.time = 30 + f * dt
        M.onUpdate(1 / 90, dt)
    st = M.getState()
    sp = list(st.spectators.values())
    print("mod zone %s: %d spectators of %d spots" % (st.specZone, len(sp), len(spots)))
    assert st.specZone == "wcusa_drag" and 0 < len(sp) <= 30, (st.specZone, len(sp))
    M.onSlrrRaceFinished()
    for f in range(int(3 / dt)):
        g.time = 60 + f * dt
        M.onUpdate(1 / 90, dt)
    sp = list(M.getState().spectators.values())
    cheering = sum(1 for x in sp if x.shape == x.type.cheer)
    assert cheering >= len(sp) * 0.8, (cheering, len(sp))
    lua.execute("camPos = vec3(5000, 5000, 5)")
    for f in range(int(3 / dt)):
        g.time = 70 + f * dt
        M.onUpdate(1 / 90, dt)
    assert len(list(M.getState().spectators.values())) == 0
    M.clearSpectatorZones()
    print("extra spectators ok")


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


def actor():
    """#36: a scripted walker (the garage arrival scene) follows its points at the walk speed, stands where it waits and at the end, and goes."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    lua.execute("os.clock = function() return time or 0 end")   # simulated time, not the wall clock: machine load changed the run
    g = lua.globals()
    g.py_json = lambda p: to_lua(lua, json.load(open(os.path.join(MOD, p.lstrip("/")))))         if os.path.exists(os.path.join(MOD, p.lstrip("/"))) else None
    g.py_find = lambda root, pat: lua.table()
    g.py_signals = lambda: lua.table()
    lua.execute(FAKE)
    lua.execute("function log() end")
    M = lua.execute(open(os.path.join(MOD, "lua", "ge", "extensions", "slrrPedestrians.lua")).read())
    assert M.playActor("/art/slrr_drivers/nobody/walker", lua.eval("{vec3(0,0,0)}")) is None, "no walker shapes: no actor"
    pts = lua.eval("{vec3(0,0,0), {pos = vec3(0,3,0), wait = 1.0}, vec3(3,3,0)}")
    aid = M.playActor("/art/slrr_drivers/hd_eric/walker", pts)
    assert aid and not M.actorDone(aid)
    ped = json.load(open(os.path.join(MOD, "art", "slrr_drivers", "hd_eric", "walker", "ped.json")))
    speed = ped["walks"]["walk.dae"]
    shapes, t, at_wait = [], 0.0, None
    while t < 20 and not M.actorDone(aid):
        M.onUpdate(1 / 30, 1 / 30)
        t += 1 / 30
        live = [o for o in g.objects.values() if not o.dead and o.cls == "TSStatic"]
        assert len(live) == 1, "one body at a time"
        shapes.append(live[-1].shapeName.rsplit("/", 1)[-1])
        p = M.actorPos(aid)
        if at_wait is None and abs(p.y - 3) < 1e-6 and p.x == 0:
            at_wait = t
    walked = 6.0 / speed + 1.0
    print("actor: 6 m + a 1 s wait took %.1f s (expected about %.1f at %.2f m/s); shapes %s" % (t, walked, speed, sorted(set(shapes))))
    assert abs(t - walked) < 0.5, (t, walked)
    assert shapes[0] == "idle.dae" or shapes[0] == "walk.dae"
    assert {"walk.dae", "idle.dae"} <= set(shapes), "walks between the points and stands at the wait"
    p = M.actorPos(aid)
    assert abs(p.x - 3) < 1e-6 and abs(p.y - 3) < 1e-6, "it ends on the last point"
    M.onUpdate(1 / 30, 1 / 30)
    assert [o for o in g.objects.values() if not o.dead and o.cls == "TSStatic"][-1].shapeName.endswith("idle.dae"), "standing at the end"
    M.stopActor(aid)
    assert not [o for o in g.objects.values() if not o.dead and o.cls == "TSStatic"], "stopped: nobody left"
    assert M.actorDone(aid) and M.actorPos(aid) is None
    print("actor ok")


if __name__ == "__main__":
    main()
    player()
    actor()
    spectators()
    extra_spectators()
    footpaths()
    print("all ok")
