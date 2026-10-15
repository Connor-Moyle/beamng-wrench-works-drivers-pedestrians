"""Offline check of slrrWalkGen (sidewalks made from a map's road graph, X34) in LuaJIT (lupa):

    python test_walkgen.py

A fake town: a 4 x 4 grid of streets 100 m apart (8 m wide, a bend node in each street), a highway through it
(30 m/s) and an offroad track. Checks: sidewalks on both sides of every street, none on the highway or the track,
no point on any road, lines ending only at junction mouths or dead ends (so crossings are never mid-block), the
work done in slices, the cache written, and slrrPedestrians walking on the result. Prints "ok".
"""
import math
import os

from lupa.luajit21 import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
EXT = os.path.join(HERE, "..", "mod", "lua", "ge", "extensions")

FAKE = r"""
written = {}
function jsonWriteFile(path, data) written[path] = data end
function jsonReadFile(path) return written[path] end
function log() end
function castRayStatic(from, dir, len) return 2 end   -- flat ground at z = 0 everywhere
nodes = {}
local function node(name, x, y, r) nodes[name] = {pos = vec3(x, y, 0), radius = r, links = {}} end
local function link(a, b, data)
  data = data or {drivability = 1, speedLimit = 14}
  nodes[a].links[b] = data
  nodes[b].links[a] = data
end
for i = 0, 3 do for j = 0, 3 do node('j' .. i .. j, i * 100, j * 100, 4) end end
for i = 0, 3 do for j = 0, 3 do
  if i < 3 then node('m' .. i .. j .. 'x', i * 100 + 50, j * 100 + 3, 4) link('j' .. i .. j, 'm' .. i .. j .. 'x') link('m' .. i .. j .. 'x', 'j' .. (i + 1) .. j) end
  if j < 3 then node('m' .. i .. j .. 'y', i * 100 + 3, j * 100 + 50, 4) link('j' .. i .. j, 'm' .. i .. j .. 'y') link('m' .. i .. j .. 'y', 'j' .. i .. (j + 1)) end
end end
node('h1', -200, 150, 6) node('h2', 500, 150, 6) link('h1', 'h2', {drivability = 1, speedLimit = 30})
node('o1', 400, 400, 3) node('o2', 450, 600, 3) link('o1', 'o2', {drivability = 0.3, speedLimit = 8})
"""


def main():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    lua.execute(FAKE)
    g = lua.globals()
    G = lua.execute(open(os.path.join(EXT, "slrrWalkGen.lua")).read())
    done = []
    G.start("town", g.nodes, lambda path: done.append(path))
    slices = 0
    while G.busy() and slices < 100000:
        G.onUpdate()
        slices += 1
    assert done == ["/settings/slrr_pedestrians/walk_town.json"], done
    data = g.written[done[0]]
    lines = [[(p[1], p[2], p[3]) for p in l.values()] for l in data.lines.values()]
    print("%d sidewalks, %d points, made in %d slices" % (len(lines), sum(len(l) for l in lines), slices))
    assert slices > 1, "not sliced"

    streets = []
    for i in range(4):
        for j in range(4):
            if i < 3:
                streets += [((i * 100, j * 100), (i * 100 + 50, j * 100 + 3)), ((i * 100 + 50, j * 100 + 3), (i * 100 + 100, j * 100))]
            if j < 3:
                streets += [((i * 100, j * 100), (i * 100 + 3, j * 100 + 50)), ((i * 100 + 3, j * 100 + 50), (i * 100, j * 100 + 100))]

    def dist(p, a, b):
        ax, ay = a
        bx, by = b
        dx, dy = bx - ax, by - ay
        t = max(0, min(1, ((p[0] - ax) * dx + (p[1] - ay) * dy) / (dx * dx + dy * dy)))
        return math.hypot(p[0] - ax - dx * t, p[1] - ay - dy * t)
    pts = [p for l in lines for p in l]
    on_road = sum(1 for p in pts if min(dist(p, a, b) for a, b in streets) < 4.3)
    near_highway = sum(1 for p in pts if dist(p, (-200, 150), (500, 150)) < 6.3)
    near_track = sum(1 for p in pts if dist(p, (400, 400), (450, 600)) < 3.3)
    print("points on a street: %d, on the highway: %d, on the track: %d" % (on_road, near_highway, near_track))
    assert on_road == 0 and near_highway == 0 and near_track == 0
    # both sides of every street have pavement
    for a, b in streets:
        mid = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
        sides = {1 if (p[0] - mid[0]) * (b[1] - a[1]) - (p[1] - mid[1]) * (b[0] - a[0]) > 0 else -1
                 for p in pts if math.hypot(p[0] - mid[0], p[1] - mid[1]) < 10}
        assert sides == {1, -1}, (a, b, sides)
    # lines end only near junctions (degree 3+), dead ends or a road they can't take, never at a street's middle bend
    junctions = [(i * 100, j * 100) for i in range(4) for j in range(4)]
    for l in lines:
        for e in (l[0], l[-1]):
            # a junction mouth, or where a road it can't take (the highway crossing at grade) cuts it
            assert min(math.hypot(e[0] - x, e[1] - y) for x, y in junctions) < 4 + 3 + 1.5 + 3 + 6                 or dist(e, (-200, 150), (500, 150)) < 6.3 + 3.5, e
    integration()
    print("ok")


def integration():
    """slrrPedestrians on a map with no walk file: makes the sidewalks once, caches them, walks on them."""
    import json
    import test_peds as T
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    g = lua.globals()
    g.py_json = lambda p: T.to_lua(lua, json.load(open(os.path.join(T.MOD, p.lstrip("/")))))         if os.path.exists(os.path.join(T.MOD, p.lstrip("/"))) else None
    root_abs = os.path.join(T.MOD, "art", "slrr_pedestrians")
    g.py_find = lambda root, pat: lua.table(*[
        "/art/slrr_pedestrians/" + os.path.relpath(os.path.join(dp, f), root_abs).replace("\\", "/")
        for dp, _, fs in os.walk(root_abs) for f in fs if f.endswith(pat.lstrip("*"))])
    g.py_signals = lambda: lua.table()
    lua.execute(T.FAKE)
    lua.execute(FAKE.replace("function jsonReadFile(path) return written[path] end",
                             "local real = jsonReadFile; function jsonReadFile(path) return written[path] or real(path) end"))
    lua.execute("""
      function getMissionFilename() return '/levels/town/main.level.json' end
      map = {getMap = function() return {nodes = nodes} end}
      camPos = vec3(150, 120, 2)
      extensions = extensions or {}
      extensions.load = function(name) _G[name] = loadstring(walkgen_src)() end""")
    g.walkgen_src = open(os.path.join(EXT, "slrrWalkGen.lua")).read()
    M = lua.execute(open(os.path.join(EXT, "slrrPedestrians.lua")).read())
    M.onExtensionLoaded()
    M.onClientStartMission()
    M.setCount(20)
    for f in range(int(30 * 30)):
        g.time = f / 30
        M.onUpdate(1 / 90, 1 / 30)
        if g.slrrWalkGen is not None:          # the game runs every loaded extension's onUpdate
            g.slrrWalkGen.onUpdate()
    peds = list(M.getState().peds.values())
    cached = g.written["/settings/slrr_pedestrians/walk_town.json"]
    print("other map: sidewalks made and cached (%d), %d pedestrians walking" % (len(list(cached.lines.values())), len(peds)))
    assert cached and len(peds) >= 10, len(peds)


if __name__ == "__main__":
    main()
