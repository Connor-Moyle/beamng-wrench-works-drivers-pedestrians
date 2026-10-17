-- SLRR Pedestrians: SLRR's pedestrians walk the city's sidewalks around the camera, as in SLRR.
--
-- The walk cycle is baked into each shape (tools/convert_peds.py) and plays as the TSStatic's
-- ambient animation; this file only moves them. Each type's <name>/ped.json gives its walk shapes
-- (normal, slow, fast tempo) with the speed that keeps the feet planted, and its idle shape (SLRR's
-- *_jitter). Sidewalks come from SLRR's city.walk, converted to /art/slrr_pedestrians/walk_<level>.json
-- (polylines, x y z). Levels without that file get none.
--
-- At a sidewalk's end a pedestrian walks over to the nearest other sidewalk end (around the corner or
-- across the street), or turns back. Some stop at corners or along the way and stand a while. Across a
-- signalled junction they wait until the light for their direction is green long enough to get over.
-- They keep apart (keep right when meeting, pass on the free side), step round parked cars and jump out
-- of the way of fast ones. Fewer walk while the frame time is over budget. An optional
-- density_<level>.json weights areas (downtown busy, outskirts quiet): spawns favour busy spots, and the
-- count round the camera is the budget times the area's weight; an area's "types" says which kinds of
-- pedestrian walk there (ped.json "kind": worker, business, casual; tools/ped_variants.py makes them).
--
-- API: slrrPedestrians.setCount(n) (saved), slrrPedestrians.getCount()

local M = {}

local ROOT = '/art/slrr_pedestrians/'
local SETTINGS = '/settings/slrr_pedestrians.json'
local SPAWN_MIN, SPAWN_MAX, DESPAWN = 25, 110, 150   -- metres from the camera
local LINK_DIST = 14        -- sidewalk ends closer than this connect (corners, crossings)
local CELL = 50
local DODGE_DIST, DODGE_SPEED = 6, 4
local CAR_MARGIN = 0.45     -- room kept around a car's box when walking round it
local LOOK_AHEAD = 2.5      -- metres ahead a pedestrian starts to step round a car
local SIDESTEP_SPEED = 0.8  -- m/s sideways
local KERB_SPEED, KERB_DIST, KERB_STEP = 8, 4, 0.6   -- a car this fast passing this close: step this far away
local CRASH_DV = 8          -- m/s lost in one frame: a crash
local FLEE_DIST, WATCH_DIST, MAX_REACT = 12, 40, 12  -- walk away / stop and look; at most this many react
local DEFAULT_SPEED = 1.3   -- walk speed for a shape without ped.json (MODDING.md: loops about once a second)
local LANE = 0.4            -- each pedestrian walks up to this far either side of the sidewalk line
local PERSONAL = 0.7        -- sideways room kept from another pedestrian
local PED_AHEAD = 2.0       -- metres ahead another pedestrian is noticed
local MAX_SIDE = 1.5        -- furthest a pedestrian strays from its line
local IDLE_MIN, IDLE_MAX = 2, 7          -- seconds standing at a corner or along the way (a look round, not a pose)
local STOP_RATE = 1 / 120                -- chance per second (times the pedestrian's idle chance) to stop mid-walk
local SPAWN_STANDING = 0.05              -- share spawned standing (for a few seconds)
local WAIT_MAX = 20                      -- seconds at a kerb for a gap or a light; then they turn back along the pavement instead of standing on
local CROSS_MIN = 5         -- a link this long or more crosses a road
local ROAD_SHRINK = 0.2     -- metres: a spot counts as on a road only this far inside its edge (a kerb is not the road)
local CROSS_PACE = 1.15     -- on a carriageway they walk this much faster than on the pavement (a little hurry, never a stop)
local JUNCTION_REACH = 35   -- a crossing this close to a signalled junction's centre obeys its lights
local GREEN, RED = 'greenTrafficLight', 'redTrafficLight'
local GAP_MARGIN = 2        -- seconds: no crossing while a car would reach it before they're over plus this
local CAR_CLEAR = 3         -- metres: a car passing this close to the crossing counts as reaching it
local CAR_NEAR = 15         -- metres: a moving car this close to a crossing blocks it whichever way it heads
local FRAME_TAU = 2         -- seconds of frame-time smoothing
local MIN_CAP = 6
local MIN_SHARE = 0.15      -- the quietest area still gets this share of the count

local count = 30            -- the base count ('medium'); setCount changes it
local AMOUNT = {off = 0, low = 0.5, medium = 1, high = 1.5, veryhigh = 2}
-- player options (Wrench Works' settings call setOptions); defaults are the mod's own behaviour
local DEFAULTS = {amount = 'medium', maxCount = 60, autoReduce = true, targetFps = 55, idling = true, crossing = true,
                  busyAreas = true}
local opts = {}
for k, v in pairs(DEFAULTS) do opts[k] = v end
local types = {}            -- {walks = {{shape, speed}}, idle = shape or nil}
local lines, ends, grid
local peds = {}
local group
local loadedMaterials = false
local junctions             -- {{c = centre, signals = {SignalInstance}}}, from core_trafficSignals
local frameAvg, cap, capTimer = 1 / 60, nil, 0
local density               -- walk density by area (density_<level>.json), nil = even everywhere
local share, shareTimer = 1, 0
local cars = {}             -- this frame's vehicles near the camera, {pos, vel}
local retryTimer = 0
local lastVel = {}          -- vehicle id -> last frame's velocity, for spotting crashes
-- spectators (spectators_<level>.json, tools/spectators.py): crowds at the venues and meets, standing at fixed spots
local specZones             -- {{id, kind, c, r, spots = {{x, y, z, fx, fy}}}}
local spectators = {}       -- {obj, shape, type, spot, cheer = seconds left}
local specZone              -- the zone being filled, or nil
local specTimer = 0
local SPEC_REACH = 200      -- metres beyond a venue zone's radius at which it fills
local MEET_REACH, MEET_SHARE = 150, 0.3   -- a car meet is in town: a smaller crowd, so the streets keep their people
local SPEC_FAR = 90         -- in view, a spectator may appear only this far away (the crowd is there before you)
local CHEER_SPEED, CHEER_DIST = 15, 30   -- a car this fast this close sets them cheering
local SWAPS_PER_FRAME = 4   -- idle <-> cheer changes rebuild an object: at most this many a frame
local SPEC_SHARE = 0.6      -- the crowd takes at most this share of the budget; pedestrians keep the rest
local cheerAll              -- defined with the spectators below (react uses it)

-- take the known keys of t, type-checked and clamped; returns true if anything changed
local function applyOptions(t)
  local changed = false
  for k, v in pairs(t or {}) do
    local d = DEFAULTS[k]
    if k == 'amount' then v = AMOUNT[v] and v or nil
    elseif type(d) == 'number' then
      v = tonumber(v)
      if v then v = math.floor(clamp(v, k == 'maxCount' and 0 or 30, k == 'maxCount' and 200 or 144) + 0.5) end
    elseif type(d) == 'boolean' then
      if type(v) ~= 'boolean' then v = nil end   -- not `and v or nil`: that drops false
    else v = nil end
    if v ~= nil and opts[k] ~= v then opts[k], changed = v, true end
  end
  return changed
end

local function saveSettings()
  jsonWriteFile(SETTINGS, {count = count, options = opts}, true)
end

local function loadSettings()
  local s = jsonReadFile(SETTINGS)
  if s and tonumber(s.count) then count = tonumber(s.count) end
  if s then applyOptions(s.options) end
end

-- how many may walk before the frame-time cap and the area share
local function wanted()
  return math.min(opts.maxCount, math.floor(count * AMOUNT[opts.amount] + 0.5))
end

local function levelName()
  local f = getMissionFilename and getMissionFilename() or ''
  return f:match('/levels/([^/]+)/')
end

local function loadTypes()
  types = {}
  for _, f in ipairs(FS:findFiles(ROOT, '*.dae', -1, true, false)) do
    local dir, folder, stem = f:match('^(.*/([^/]+)/)([^/]+)%.dae$')
    if folder and folder:lower() == stem:lower() then
      local info = jsonReadFile(dir .. 'ped.json') or {}
      local t = {walks = {}, idle = info.idle and dir .. info.idle, cheer = info.cheer and dir .. info.cheer, kind = info.kind or 'casual'}
      for shape, speed in pairs(info.walks or {}) do table.insert(t.walks, {shape = dir .. shape, speed = speed}) end
      if #t.walks == 0 then t.walks[1] = {shape = f, speed = DEFAULT_SPEED} end
      table.insert(types, t)
    end
  end
end

local function loadWalks()
  lines, ends, grid, junctions = nil, nil, nil, nil
  local lvl = levelName()
  local data = lvl and jsonReadFile(ROOT .. 'walk_' .. lvl .. '.json')
  -- a map without sidewalks of its own: the ones made from its roads (slrrWalkGen), made once while pedestrians are on
  if lvl and not data then
    data = jsonReadFile('/settings/slrr_pedestrians/walk_' .. lvl .. '.json')
    if not data and wanted() > 0 and map and map.getMap and not (slrrWalkGen and slrrWalkGen.busy()) then
      local nodes = map.getMap().nodes
      if nodes and next(nodes) then
        extensions.load('slrrWalkGen')
        slrrWalkGen.start(lvl, nodes, function() loadWalks() end)
      end
    end
  end
  density = lvl and jsonReadFile(ROOT .. 'density_' .. lvl .. '.json')
  local sp = lvl and jsonReadFile(ROOT .. 'spectators_' .. lvl .. '.json')
  specZones = sp and sp.zones
  if not data then return end
  loadTypes()
  if #types == 0 then return end
  if not loadedMaterials then
    for _, f in ipairs(FS:findFiles(ROOT, '*.materials.json', -1, true, false)) do loadJsonMaterialsFile(f) end
    loadedMaterials = true
  end
  -- {lines, links} (links checked offline: tools/ped_paths.py) or a bare list of lines (linked by distance)
  local given = data.lines and data.links
  local rooms = data.room          -- per line {left, right} of pavement beside it (ped_paths.py)
  if data.lines then data = data.lines end
  lines, ends, grid = {}, {}, {}
  for i, l in ipairs(data) do
    local pts, len = {}, {0}
    for k, p in ipairs(l) do
      pts[k] = vec3(p[1], p[2], p[3])
      if k > 1 then len[k] = len[k - 1] + pts[k]:distance(pts[k - 1]) end
    end
    lines[i] = {pts = pts, len = len, total = len[#len], room = rooms and rooms[i]}
    for k, p in ipairs(pts) do
      local key = math.floor(p.x / CELL) .. ',' .. math.floor(p.y / CELL)
      grid[key] = grid[key] or {}
      table.insert(grid[key], {line = i, k = k})
    end
    table.insert(ends, {line = i, atStart = true, p = pts[1]})
    table.insert(ends, {line = i, atStart = false, p = pts[#pts]})
  end
  for _, e in ipairs(ends) do
    local l = lines[e.line]
    if e.atStart then l.startEnd = e else l.endEnd = e end
  end
  if given then
    for _, e in ipairs(ends) do e.links, e.crosses = {}, {} end
    for _, k in ipairs(given) do   -- [line, at start, line, at start, crosses a road], lines 0-based
      local a = k[2] and lines[k[1] + 1].startEnd or lines[k[1] + 1].endEnd
      local b = k[4] and lines[k[3] + 1].startEnd or lines[k[3] + 1].endEnd
      table.insert(a.links, b)
      table.insert(b.links, a)
      a.crosses[b], b.crosses[a] = k[5], k[5]
    end
    return
  end
  -- each end's neighbours: other sidewalk ends within reach
  local egrid = {}
  local function ekey(x, y) return math.floor(x / LINK_DIST) .. ',' .. math.floor(y / LINK_DIST) end
  for _, e in ipairs(ends) do
    local k = ekey(e.p.x, e.p.y)
    egrid[k] = egrid[k] or {}
    table.insert(egrid[k], e)
  end
  for _, e in ipairs(ends) do
    e.links = {}
    local cx, cy = math.floor(e.p.x / LINK_DIST), math.floor(e.p.y / LINK_DIST)
    for i = -1, 1 do
      for j = -1, 1 do
        for _, o in ipairs(egrid[(cx + i) .. ',' .. (cy + j)] or {}) do
          if o.line ~= e.line and o.p:distance(e.p) < LINK_DIST then table.insert(e.links, o) end
        end
      end
    end
  end
  for _, e in ipairs(ends) do
    local l = lines[e.line]
    if e.atStart then l.startEnd = e else l.endEnd = e end
  end
end

-- signalled junctions: the level's signal instances grouped by junction (signals.json "group")
local function loadJunctions()
  if junctions or not core_trafficSignals then return end
  local all = core_trafficSignals.getSignals()
  if not all or #all == 0 then return end
  junctions = {}
  local byGroup = {}
  for _, s in ipairs(all) do
    local key = s.group or s.name
    local j = byGroup[key]
    if not j then
      j = {c = vec3(0, 0, 0), signals = {}}
      byGroup[key] = j
      table.insert(junctions, j)
    end
    table.insert(j.signals, s)
    j.c = j.c + vec3(s.pos)
  end
  for _, j in ipairs(junctions) do j.c = j.c * (1 / #j.signals) end
end

-- The signal a crossing from a to b obeys: at the nearest signalled junction, the approach most parallel
-- to the crossing (walkers go with the traffic beside them). nil for corners and unsignalled streets.
local function signalFor(a, b)
  loadJunctions()
  local c = vec3(b.x - a.x, b.y - a.y, 0)
  local len = c:length()
  if not junctions or len < 1e-3 then return end   -- callers ask only for links that cross a road
  c = c * (1 / len)
  local mid = (a + b) * 0.5
  local best, bestD = nil, JUNCTION_REACH
  for _, j in ipairs(junctions) do
    local d = j.c:distance(mid)
    if d < bestD then best, bestD = j, d end
  end
  if not best then return end
  -- the approach's arm (its bearing from the centre), as the map's tools/signals.py phases them: curving
  -- lanes end up to 50 deg off their arm, so their heading picks the wrong phase
  local sig, bestDot, across = nil, 0.7, {}
  for _, s in ipairs(best.signals) do
    local arm = vec3(s.pos.x - best.c.x, s.pos.y - best.c.y, 0)
    if arm:length() > 3 then arm = arm:normalized() else arm = vec3(s.dir.x, s.dir.y, 0) end
    local d = math.abs(c.x * arm.x + c.y * arm.y)
    if d > bestDot then sig, bestDot = s, d end
    if d <= 0.7 then table.insert(across, s) end   -- traffic on the road they walk across
  end
  return sig, best, across
end

-- 0..1: how busy the sidewalks are here (the last matching box wins)
local function weightAt(x, y)
  if not density or not opts.busyAreas then return 1 end
  local w = density.default or 1
  for _, a in ipairs(density.areas or {}) do
    local b = a.box
    if x >= b[1] and x <= b[3] and y >= b[2] and y <= b[4] then w = a.weight end
  end
  return w
end

-- the kinds of pedestrian wanted here (the density file's "types", per area or for the level), nil = any
local function kindsAt(x, y)
  if not density or not opts.busyAreas then return nil end
  local kinds = density.types
  for _, a in ipairs(density.areas or {}) do
    local b = a.box
    if a.types and x >= b[1] and x <= b[3] and y >= b[2] and y <= b[4] then kinds = a.types end
  end
  return kinds
end

local function pickType(x, y)
  local kinds = kindsAt(x, y)
  if kinds then
    local list = {}
    for _, t in ipairs(types) do
      for _, k in ipairs(kinds) do if t.kind == k then list[#list + 1] = t break end end
    end
    if #list > 0 then return list[math.random(#list)] end
  end
  return types[math.random(#types)]
end

-- the share of the count for the area round the camera: mean weight on the spawn ring
local function localShare(cam)
  local sum, n = 0, 0
  for r = SPAWN_MIN, SPAWN_MAX, (SPAWN_MAX - SPAWN_MIN) / 2 do
    for k = 0, 7 do
      local a = k * math.pi / 4
      sum, n = sum + weightAt(cam.x + math.cos(a) * r, cam.y + math.sin(a) * r), n + 1
    end
  end
  return math.max(MIN_SHARE, sum / n)
end

local function pointAt(line, s)
  local pts, len = line.pts, line.len
  for k = 2, #pts do
    if s <= len[k] then
      local t = (s - len[k - 1]) / math.max(1e-3, len[k] - len[k - 1])
      return lerp(pts[k - 1], pts[k], t), (pts[k] - pts[k - 1]):normalized()
    end
  end
  return pts[#pts], (pts[#pts] - pts[#pts - 1]):normalized()
end

local function groundZ(p)
  local d = castRayStatic(p + vec3(0, 0, 2), vec3(0, 0, -1), 6)
  if d and d < 6 then return p.z + 2 - d end
  return p.z
end

local function place(o, pos, fwd)
  fwd = vec3(fwd.x, fwd.y, 0)
  if not (fwd.x == fwd.x and fwd.y == fwd.y) or fwd:length() < 1e-3 then fwd = vec3(0, 1, 0) end
  if not (pos.x == pos.x and pos.y == pos.y and pos.z == pos.z) then return end   -- (a NaN transform hangs the GPU)
  fwd = fwd:normalized()
  local m = MatrixF(true)
  m:setColumn(0, fwd:cross(vec3(0, 0, 1)))   -- shapes face +y
  m:setColumn(1, fwd)
  m:setColumn(2, vec3(0, 0, 1))
  m:setPosition(pos)
  o:setTransform(m)
end

local function despawn(p)
  if p.obj and simObjectExists(p.obj) then p.obj:delete() end
end

local function clear()
  for _, p in ipairs(peds) do despawn(p) end
  peds = {}
end

local function makeObj(shape, transform)
  if not group or not simObjectExists(group) then
    group = scenetree.findObject('slrrPedestriansGroup')
    if not group then
      group = createObject('SimGroup')
      group.canSave = false
      group:registerObject('slrrPedestriansGroup')
      scenetree.MissionGroup:addObject(group)
    end
  end
  local o = createObject('TSStatic')
  o:setField('shapeName', 0, shape)
  o:setField('collisionType', 0, 'None')
  o:setField('decalType', 0, 'None')
  o:setField('playAmbient', 0, '1')
  o.canSave = false
  o:registerObject('')
  group:addObject(o)
  if transform then o:setTransform(transform) end
  return o
end

-- shortcut: walk <-> idle replaces the object rather than changing a live TSStatic's shapeName; switch to
-- setField('shapeName') if the T1 game test shows that reloads the shape cleanly.
local function setShape(p, shape)
  if p.shape == shape then return end
  local m = p.obj and simObjectExists(p.obj) and p.obj:getTransform()
  despawn(p)
  p.obj, p.shape = makeObj(shape, m), shape
end

-- The roads (T51): public, drivable links of the navgraph in a grid, to tell whether a spot is on a carriageway. A pedestrian on one
-- never stands, waits or turns back: it goes on across to the far kerb. nil roads (no navgraph yet) = nowhere is a road.
local roadGrid, roadsTried
local ROAD_CELL = 20
local function buildRoads(nodes)
  roadGrid = {}
  for a, n in pairs(nodes) do
    for b, l in pairs(n.links or {}) do
      local o = nodes[b]
      if a < b and o and (l.drivability or 1) >= 0.9 and not l.hiddenInNavi and (l.type == nil or l.type == 'public') then
        local seg = {ax = n.pos.x, ay = n.pos.y, az = n.pos.z, bx = o.pos.x, by = o.pos.y, bz = o.pos.z, ra = n.radius or 2, rb = o.radius or 2}
        local x0, x1 = math.min(seg.ax, seg.bx), math.max(seg.ax, seg.bx)
        local y0, y1 = math.min(seg.ay, seg.by), math.max(seg.ay, seg.by)
        for cx = math.floor(x0 / ROAD_CELL) - 1, math.floor(x1 / ROAD_CELL) + 1 do
          for cy = math.floor(y0 / ROAD_CELL) - 1, math.floor(y1 / ROAD_CELL) + 1 do
            local k = cx .. ',' .. cy
            roadGrid[k] = roadGrid[k] or {}
            table.insert(roadGrid[k], seg)
          end
        end
      end
    end
  end
end
local function onRoad(pos)
  if not roadGrid then
    if roadsTried and os.clock() - roadsTried < 5 then return false end
    roadsTried = os.clock()
    local ok, nodes = pcall(function() return map.getMap().nodes end)
    if not (ok and type(nodes) == 'table' and next(nodes)) then return false end
    buildRoads(nodes)
  end
  for _, s in ipairs(roadGrid[math.floor(pos.x / ROAD_CELL) .. ',' .. math.floor(pos.y / ROAD_CELL)] or {}) do
    local dx, dy = s.bx - s.ax, s.by - s.ay
    local l2 = dx * dx + dy * dy
    local t = l2 > 0 and math.max(0, math.min(1, ((pos.x - s.ax) * dx + (pos.y - s.ay) * dy) / l2)) or 0
    local qx, qy = s.ax + dx * t, s.ay + dy * t
    local r = s.ra + (s.rb - s.ra) * t - ROAD_SHRINK
    if r > 0 and (pos.x - qx) ^ 2 + (pos.y - qy) ^ 2 < r * r and math.abs(pos.z - (s.az + (s.bz - s.az) * t)) < 3 then return true end
  end
  return false
end
-- may p stand (idle, wait, look at a crash) where it is: not on a road
local function mayStand(p)
  if not p.pos then return true end
  if onRoad(p.pos) then return false end
  return not (p.fwd and onRoad(p.pos + p.fwd * 0.4))        -- (and not a step ahead, where the walk is about to go)
end

-- stand still (idle animation) for `time` seconds, or until a signal lets them go when `time` is nil
local function stand(p, time)
  p.state, p.timer = time and 'idle' or 'wait', time
  if time then p.waited = nil end
  setShape(p, p.type.idle or p.walk.shape)
end

local function walkOn(p)
  p.state, p.face, p.waited = 'walk', nil, nil
  setShape(p, p.walk.shape)
end

-- the type's fastest walk, for getting out of a car's way mid-crossing (no faster SLRR animation exists)
local function fastest(t)
  local f = t.walks[1]
  for _, w in ipairs(t.walks) do if w.speed > f.speed then f = w end end
  return f
end

-- walk at their fastest for `time` seconds (or until off the crossing when nil)
local function hurry(p, time)
  if p.state ~= 'walk' then walkOn(p) end
  p.hurry, p.hurryTime = fastest(p.type), time
  setShape(p, p.hurry.shape)
end

-- how far they may stand to the left (negative) and right of their line, facing their way: the pavement
-- beside it as measured offline, else MAX_SIDE; on a crossing half a metre
local function sideRoom(p)
  if p.cross then return -0.5, 0.5 end
  local r = lines[p.line].room
  if not r then return -MAX_SIDE, MAX_SIDE end
  if p.dir > 0 then return -r[1], r[2] end
  return -r[2], r[1]
end

-- is p in front of the camera (within about 60 deg of where it looks): nobody appears or vanishes there
local function inView(p, cam, look)
  local d = p - cam
  local l = d:length()
  return l > 1e-3 and (d.x * look.x + d.y * look.y + d.z * look.z) / l > 0.5
end

local function spawnNear(cam)
  -- a random sidewalk point in a ring around the camera, out of its view
  local look = core_camera.getForward and vec3(core_camera.getForward()) or vec3(0, 0, 0)
  for _ = 1, 20 do
    local a, r = math.random() * 2 * math.pi, SPAWN_MIN + math.random() * (SPAWN_MAX - SPAWN_MIN)
    local q = cam + vec3(math.cos(a) * r, math.sin(a) * r, 0)
    if inView(q, cam, look) then q = cam - (q - cam) end   -- mirror it behind the camera
    local bucket = grid[math.floor(q.x / CELL) .. ',' .. math.floor(q.y / CELL)]
    local pick = bucket and #bucket > 0 and bucket[math.random(#bucket)]
    local at = pick and lines[pick.line].pts[pick.k]
    if at and not inView(at, cam, look) and at:distance(cam) > SPAWN_MIN
        and math.random() < weightAt(q.x, q.y) then   -- busier areas take more
      local t = pickType(at.x, at.y)
      local w = t.walks[math.random(#t.walks)]
      local p = {type = t, walk = w, speed = w.speed, line = pick.line, s = lines[pick.line].len[pick.k],
                 dir = math.random() < 0.5 and 1 or -1, lane = (math.random() * 2 - 1) * LANE, side = 0,
                 idleChance = t.idle and math.random() * 0.6 or 0, zTimer = 0, dodgeSide = 0}
      if t.idle and opts.idling and math.random() < SPAWN_STANDING and not onRoad(at) then stand(p, IDLE_MIN + math.random() * (IDLE_MAX - IDLE_MIN)) else walkOn(p) end
      return p
    end
  end
end

-- How far to step sideways (along `side`) to get point q out of a car's box; 0 if q is clear.
local function stepOut(q, side, car)
  local rel = q - car.center
  local best = 0
  for _, sgn in ipairs({1, -1}) do
    local dir = side * sgn
    local t = math.huge
    for _, ax in ipairs({{car.right, car.hx}, {car.fwd, car.hy}}) do
      local a, e = ax[1], ax[2] + CAR_MARGIN
      local qa, d = rel:dot(a), dir:dot(a)
      if math.abs(qa) > e then return 0 end   -- outside on this axis: not in the box
      if d > 1e-4 then t = math.min(t, (e - qa) / d) elseif d < -1e-4 then t = math.min(t, (-e - qa) / d) end
    end
    if best == 0 or math.abs(t) < math.abs(best) then best = t * sgn end
  end
  return best
end

-- does the link from end e to end o cross a road: as the walk file says, else guessed from its length
local function crossesRoad(e, o)
  if e.crosses then return e.crosses[o] == true end
  return e.p:distance(o.p) >= CROSS_MIN
end

local function startLink(p, forced)
  local l = p.link
  local e, o = l.from, l.to
  p.link = nil
  p.cross = {from = e.p, to = o.p, t = 0, len = math.max(0.5, e.p:distance(o.p)), signal = l.signal, across = l.across,
             road = l.cross, forced = forced}          -- (forced: begun because they stood on a road, light or not)
  p.line, p.dir = o.line, o.atStart and 1 or -1
  p.s = o.atStart and 0 or lines[o.line].total
end

-- could a moving car reach the crossing a-b within `time` seconds: one heading its way whose distance (less
-- CAR_CLEAR) over its speed is less, or any within CAR_NEAR m (cars turn; the AI can't see pedestrians)
local function carComing(a, b, time)
  local ab = vec3(b.x - a.x, b.y - a.y, 0)
  local l2 = math.max(ab:dot(ab), 1e-6)
  for _, v in ipairs(cars) do
    local sp = v.vel:length()
    if sp > 1 then
      local t = clamp(((v.pos.x - a.x) * ab.x + (v.pos.y - a.y) * ab.y) / l2, 0, 1)
      local qx, qy = a.x + ab.x * t - v.pos.x, a.y + ab.y * t - v.pos.y
      local d = math.sqrt(qx * qx + qy * qy) - CAR_CLEAR
      -- heading towards it (lanes bend, so not just straight at it), or close by whichever way (turning cars)
      if d < CAR_NEAR or (qx * v.vel.x + qy * v.vel.y > 0 and d / sp < time) then return true end
    end
  end
  return false
end

-- may p start its crossing now: no car on its way, and no signal or green now and still green when they're over
local function mayCross(p)
  local time = p.link.len / p.speed
  if p.link.cross and carComing(p.link.from.p, p.link.to.p, time + GAP_MARGIN) then return false end
  local s, across = p.link.signal, p.link.across or {}
  if not s and #across == 0 then return true end   -- no lights here
  local now = (s or across[1]):getState()
  if now == 'none' then return true end   -- signal system not running
  -- the traffic they walk across is red now and stays red until they're over (the parallel green, its yellow and
  -- the all-red, plus the map's walk phase); cars turning off the green road are the gap check's job
  if #across > 0 then
    for _, o in ipairs(across) do
      if o:getState() ~= RED or o:getStateAfterTime(time + 1) ~= RED then return false end
    end
    return true
  end
  return now == GREEN and s:getStateAfterTime(time + 1) == GREEN
end

-- at a sidewalk's end: pick the next sidewalk, maybe stand a while, then go (or wait for the light)
local function reachEnd(p)
  local line = lines[p.line]
  local e = p.dir > 0 and line.endEnd or line.startEnd
  local choices = e and e.links or {}
  if not opts.crossing then
    local corners = {}
    for _, o in ipairs(choices) do if not crossesRoad(e, o) then table.insert(corners, o) end end
    choices = corners
  end
  if #choices == 0 then p.dir = -p.dir return end
  local o = choices[math.random(#choices)]
  local cross = crossesRoad(e, o)
  local signal, junction, across
  if cross then signal, junction, across = signalFor(e.p, o.p) end
  p.link = {from = e, to = o, len = e.p:distance(o.p), cross = cross, signal = signal, junction = junction,
            across = across}
  local standable = mayStand(p) and not onRoad(e.p)        -- (a sidewalk end on a carriageway: no standing there, straight across)
  if standable and opts.idling and math.random() < p.idleChance then stand(p, IDLE_MIN + math.random() * (IDLE_MAX - IDLE_MIN))
  elseif standable and not mayCross(p) then stand(p)
  else startLink(p, not standable) end
end

local function updateStanding(p, dt)
  if p.link and not opts.crossing and p.link.cross then   -- crossing switched off: turn back
    p.link, p.dir = nil, -p.dir
  end
  if p.state == 'idle' then
    p.timer = opts.idling and p.timer - dt or 0
    if p.timer > 0 then return end
  end
  if p.state == 'wait' then
    -- nobody stands at a kerb for ever (a busy road, a light that never gives them a gap): after WAIT_MAX they turn back
    p.waited = (p.waited or 0) + dt
    if p.waited > WAIT_MAX then
      p.link, p.dir = nil, -p.dir
      walkOn(p)
      return
    end
  end
  if p.link and p.state == 'wait' then        -- waiting at the kerb: look again 4 times a second
    p.check = (p.check or 0) - dt
    if p.check > 0 then return end
    p.check = 0.25
  end
  if p.link and not mayCross(p) then
    if p.state ~= 'wait' then stand(p) end
    return
  end
  if p.link then startLink(p) end
  walkOn(p)
end

local function updatePed(p, dt, vehicles, near)
  local pos, fwd
  if p.cross and p.state ~= 'walk' then
    walkOn(p)                                     -- a crossing is never interrupted
  elseif p.state ~= 'walk' and not mayStand(p) then
    -- standing, waiting or looking where there is a road: not for a moment; across it, or on along the pavement
    if p.link then startLink(p, true) end
    walkOn(p)
  elseif p.state ~= 'walk' then
    updateStanding(p, dt)
  elseif opts.idling and not p.cross and p.idleChance > 0 and math.random() < STOP_RATE * p.idleChance * dt and mayStand(p) then
    stand(p, IDLE_MIN + math.random() * (IDLE_MAX - IDLE_MIN))
  end
  local moving = p.state == 'walk'
  if p.cross and moving and p.cross.road then
    p.hurryCheck = (p.hurryCheck or 0) - dt
    if p.hurryCheck <= 0 then
      p.hurryCheck = 0.25
      local left = (1 - p.cross.t) * p.cross.len
      if not p.hurry and carComing(lerp(p.cross.from, p.cross.to, p.cross.t), p.cross.to, left / p.speed + GAP_MARGIN) then
        hurry(p, nil)
      end
    end
  end
  if p.hurryTime then
    p.hurryTime = p.hurryTime - dt
    if p.hurryTime <= 0 then
      p.hurryTime = nil
      if not p.cross then p.hurry = nil setShape(p, p.walk.shape) end
    end
  end
  local speed = p.hurry and p.hurry.speed or p.speed
  local crossSpeed = (p.cross and p.cross.road and not p.hurry) and speed * CROSS_PACE or speed     -- a little faster over a carriageway
  if p.cross then
    if moving then p.cross.t = p.cross.t + dt * crossSpeed / p.cross.len end
    if p.cross.t >= 1 then
      p.cross = nil
      if p.hurry and not p.hurryTime then
        p.hurry, speed = nil, p.speed
        setShape(p, p.walk.shape)
      end
    end
  end
  if p.cross then
    pos = lerp(p.cross.from, p.cross.to, p.cross.t)
    fwd = p.cross.to - p.cross.from
  else
    local line = lines[p.line]
    if moving then p.s = p.s + p.dir * speed * dt end
    if p.s < 0 or p.s > line.total then
      p.s = clamp(p.s, 0, line.total)
      reachEnd(p)
      line = lines[p.line]
    end
    local d
    pos, d = pointAt(line, p.s)
    fwd = d * p.dir
    if p.link then fwd = p.link.to.p - p.link.from.p end   -- waiting: face the way across
    if p.face and not moving then fwd = p.face - pos end    -- looking at a crash
  end
  fwd = vec3(fwd.x, fwd.y, 0)
  if fwd:length() > 1e-3 then fwd = fwd:normalized() end
  local side = vec3(fwd.y, -fwd.x, 0)   -- right of fwd
  local lo, hi = sideRoom(p)
  local base = pos + side * clamp(p.lane, lo, hi)

  -- sideways: round cars standing in the way, and round other pedestrians (keep right when meeting)
  local want = 0
  if moving then
    for _, v in ipairs(vehicles) do
      if v.hx and v.center:distance(base) < v.hy + LOOK_AHEAD + 2 then
        for _, ahead in ipairs({0, LOOK_AHEAD * 0.5, LOOK_AHEAD}) do
          local st = stepOut(base + fwd * ahead, side, v)
          if math.abs(st) > math.abs(want) then want = st end
        end
      end
    end
    local me = base + side * p.side
    for _, q in ipairs(near) do
      if q ~= p and q.pos then
        local rel = q.pos - me
        local ahead, lat = rel:dot(fwd), rel:dot(side)
        if ahead > 0 and ahead < PED_AHEAD and math.abs(lat) < PERSONAL then
          local away
          if q.fwd and q.fwd:dot(fwd) < -0.5 then away = PERSONAL + lat              -- meeting: step right
          else away = (lat > 0 and -1 or 1) * (PERSONAL - math.abs(lat)) end      -- passing: the free side
          local st = p.side + away
          if math.abs(st) > math.abs(want) then want = st end
        end
      end
    end
  end
  -- step back from the kerb as a fast car passes close (walking or standing)
  local me = base + side * p.side
  for _, v in ipairs(vehicles) do
    if v.vel:length() > KERB_SPEED then
      local rel = v.pos - me
      local lat = rel:dot(side)
      if math.abs(lat) < KERB_DIST and math.abs(rel:dot(fwd)) < 8 then
        local st = p.side + (lat > 0 and -KERB_STEP or KERB_STEP)
        if math.abs(st) > math.abs(want) then want = st end
      end
    end
  end
  -- never off the pavement: every sideways move stays within the room beside the line
  local base_lane = clamp(p.lane, lo, hi)
  want = clamp(want, lo - base_lane, hi - base_lane)
  p.side = p.side + clamp(want - p.side, -SIDESTEP_SPEED * dt, SIDESTEP_SPEED * dt)

  -- a car heading at them: jump aside (within the room) and hurry on for a few seconds
  for _, v in ipairs(vehicles) do
    local rel = base + side * (p.side + p.dodgeSide) - v.pos
    if rel:length() < DODGE_DIST and v.vel:length() > DODGE_SPEED and v.vel:dot(rel) > 0 then
      p.dodgeSide = p.dodgeSide + (rel:dot(side) >= 0 and 1 or -1) * dt * 6
      if moving and not p.hurry then hurry(p, 3) end
    end
  end
  p.dodgeSide = clamp(p.dodgeSide * math.max(0, 1 - dt * 0.3), lo - base_lane - p.side, hi - base_lane - p.side)
  pos = pos + side * (base_lane + p.side + p.dodgeSide)
  p.zTimer = p.zTimer - dt
  if not p.z or p.zTimer <= 0 then p.z, p.zTimer = groundZ(pos), 0.3 end
  place(p.obj, vec3(pos.x, pos.y, p.z), fwd)
  p.pos, p.fwd = pos, fwd
  return pos
end

-- a crash at `at`: the nearest MAX_REACT pedestrians react; those within FLEE_DIST hurry away along their
-- sidewalk, the rest within WATCH_DIST stop and look for a few seconds
local function react(at)
  if specZone and #spectators > 0 and vec3(specZone.c[1], specZone.c[2], specZone.c[3]):distance(at) < specZone.r + 60 then
    cheerAll(4)
  end
  local near = {}
  for _, p in ipairs(peds) do
    if p.pos and p.pos:distance(at) < WATCH_DIST then table.insert(near, p) end
  end
  table.sort(near, function(a, b) return a.pos:distance(at) < b.pos:distance(at) end)
  for i = 1, math.min(#near, MAX_REACT) do
    local p = near[i]
    if not p.cross then
      if p.pos:distance(at) < FLEE_DIST then
        local _, d = pointAt(lines[p.line], p.s)
        if (d * p.dir):dot(p.pos - at) < 0 then p.dir = -p.dir end   -- the way along the path that leads away
        p.link = nil
        hurry(p, 6)
      elseif p.state == 'walk' and mayStand(p) then
        stand(p, 3 + math.random() * 5)
        p.face = at
      end
    end
  end
end

-- spectators ------------------------------------------------------------------------------------------------
local function specShape(sp, cheer)
  local t = sp.type
  return cheer and t.cheer or t.idle or t.walks[1].shape
end

local function specSet(sp, cheer)
  local shape = specShape(sp, cheer)
  if sp.shape == shape then return end
  if sp.obj and simObjectExists(sp.obj) then sp.obj:delete() end
  local m = MatrixF(true)
  local f = vec3(sp.spot[4], sp.spot[5], 0)
  m:setColumn(0, f:cross(vec3(0, 0, 1)))
  m:setColumn(1, f)
  m:setColumn(2, vec3(0, 0, 1))
  m:setPosition(vec3(sp.spot[1], sp.spot[2], sp.spot[3]))
  sp.obj, sp.shape = makeObj(shape, m), shape
end

local function clearSpectators()
  for _, sp in ipairs(spectators) do if sp.obj and simObjectExists(sp.obj) then sp.obj:delete() end end
  spectators, specZone = {}, nil
end

-- everyone in the crowd cheers for a few seconds (a race finish, a crash in front of them)
function cheerAll(seconds)
  for _, sp in ipairs(spectators) do sp.cheer = seconds * (0.7 + math.random() * 0.6) end
end

-- fill the zone near the camera (one at a time, out of view), empty it when the camera leaves, and cheer
local function updateSpectators(dt, cam, budget)
  specTimer = specTimer - dt
  if specTimer <= 0 then
    specTimer = 1
    local best, bd = nil, math.huge
    for _, z in ipairs(specZones or {}) do
      local d = cam:distance(vec3(z.c[1], z.c[2], z.c[3])) - z.r
      if d < (z.kind == 'meet' and MEET_REACH or SPEC_REACH) and d < bd then best, bd = z, d end
    end
    if best ~= specZone then clearSpectators() specZone = best end
  end
  if not specZone then return 0 end
  local want = math.min(#specZone.spots, math.floor(budget * (specZone.kind == 'meet' and MEET_SHARE or SPEC_SHARE)))
  local look = core_camera.getForward and vec3(core_camera.getForward()) or vec3(0, 0, 0)
  if #spectators < want then
    local used = {}
    for _, sp in ipairs(spectators) do used[sp.spot] = true end
    for _ = 1, 10 do
      local spot = specZone.spots[math.random(#specZone.spots)]
      local at = vec3(spot[1], spot[2], spot[3])
      if not used[spot] and (at:distance(cam) > SPEC_FAR or not inView(at, cam, look)) then
        local able = {}       -- a spectator needs a cheer shape (the clothing variants have none)
        for _, t in ipairs(types) do if t.cheer then able[#able + 1] = t end end
        local sp = {spot = spot, type = (#able > 0 and able or types)[math.random(#able > 0 and #able or #types)], cheer = 0}
        specSet(sp, false)
        table.insert(spectators, sp)
        break
      end
    end
  elseif #spectators > want then
    local k = #spectators            -- out of view first
    for i, sp in ipairs(spectators) do
      if not inView(vec3(sp.spot[1], sp.spot[2], sp.spot[3]), cam, look) then k = i break end
    end
    local sp = table.remove(spectators, k)
    if sp.obj and simObjectExists(sp.obj) then sp.obj:delete() end
  end
  -- cheering: a fast car close by; changes limited per frame
  local swaps = 0
  for _, sp in ipairs(spectators) do
    if sp.cheer <= 0 then
      for _, v in ipairs(cars) do
        if v.vel:length() > CHEER_SPEED and (v.pos.x - sp.spot[1]) ^ 2 + (v.pos.y - sp.spot[2]) ^ 2 < CHEER_DIST ^ 2 then
          sp.cheer = 2 + math.random() * 3
          break
        end
      end
    else
      sp.cheer = sp.cheer - dt
    end
    local cheering = sp.cheer > 0
    if (sp.shape == specShape(sp, true)) ~= cheering and swaps < SWAPS_PER_FRAME then
      specSet(sp, cheering)
      swaps = swaps + 1
    end
  end
  return #spectators
end

-- how many may walk: the setting, lowered while the smoothed frame time is over budget
local function target(dtReal)
  local want = wanted()
  cap = math.min(cap or want, want)
  frameAvg = frameAvg + (dtReal - frameAvg) * math.min(1, dtReal / FRAME_TAU)
  if not opts.autoReduce then cap = want return want end
  local budget = 1 / opts.targetFps
  capTimer = capTimer + dtReal
  if capTimer > 0.5 then
    capTimer = 0
    if frameAvg > budget then cap = math.max(math.min(MIN_CAP, want), cap - 2)
    elseif frameAvg < budget * 0.85 then cap = math.min(want, cap + 1) end
  end
  return cap
end

-- the on-foot player: a walker that follows a vehicle (BeamNG's invisible walking unicycle), with the shapes of a
-- folder in the pedestrian format (<dir>/ped.json: walks {shape: speed}, idle). slrrDrivers' walker shapes use it.
local player              -- {veh, walks, idle, obj, shape, switch}
local PLAYER_STAND = 0.3  -- m/s: slower than this the walker stands (idle)

local function followPlayer(vehId, dir)
  if player and player.obj and simObjectExists(player.obj) then player.obj:delete() end
  player = nil
  if not vehId then return end
  dir = dir:gsub('/*$', '/')
  local info = jsonReadFile(dir .. 'ped.json')
  if not info or not info.walks then log('E', 'slrrPedestrians', 'followPlayer: no ped.json in ' .. dir) return end
  local walks = {}
  for shape, speed in pairs(info.walks) do table.insert(walks, {shape = dir .. shape, speed = speed}) end
  table.sort(walks, function(a, b) return a.speed < b.speed end)
  player = {veh = vehId, walks = walks, idle = info.idle and dir .. info.idle or walks[1].shape, switch = 0}
end

local function updatePlayer(dt)
  local v = be:getObjectByID(player.veh)
  if not v then followPlayer(nil) return end
  local pos, fwd, sp = vec3(v:getPosition()), vec3(v:getDirectionVector()), vec3(v:getVelocity()):length()
  -- the walk whose speed is nearest (feet planted), or idle; changed at most twice a second
  local want = player.idle
  if sp >= PLAYER_STAND then
    local best = player.walks[1]
    for _, w in ipairs(player.walks) do if math.abs(w.speed - sp) < math.abs(best.speed - sp) then best = w end end
    want = best.shape
  end
  player.switch = player.switch - dt
  if want ~= player.shape and player.switch <= 0 then
    local m = player.obj and simObjectExists(player.obj) and player.obj:getTransform()
    if player.obj and simObjectExists(player.obj) then player.obj:delete() end
    player.obj, player.shape, player.switch = makeObj(want, m), want, 0.5
  end
  place(player.obj, vec3(pos.x, pos.y, groundZ(pos)), fwd)
end

-- recording for review (tools/ped_replay.py): every pedestrian's place and shape each frame
local rec

local function record(dtReal)
  rec.t = rec.t + dtReal
  local f = {t = rec.t, ms = dtReal * 1000, peds = {}, cars = {}}
  for _, v in ipairs(cars) do table.insert(f.cars, {x = v.pos.x, y = v.pos.y, z = v.pos.z, v = v.vel:length()}) end
  for _, p in ipairs(peds) do
    if p.pos and p.obj and simObjectExists(p.obj) then
      local q = p.obj:getPosition()
      table.insert(f.peds, {id = tostring(p):sub(-8), x = q.x, y = q.y, z = q.z, fx = p.fwd.x, fy = p.fwd.y,
                            shape = p.shape, state = p.state, cross = p.cross and true or false})
    end
  end
  table.insert(rec.frames, f)
  if rec.t >= rec.seconds then
    jsonWriteFile(rec.path, {frames = rec.frames}, false)
    log('I', 'slrrPedestrians', 'recording written: ' .. rec.path .. ' (' .. #rec.frames .. ' frames)')
    rec = nil
  end
end

local function onUpdate(dtReal, dtSim)
  if player then updatePlayer(dtSim or dtReal) end
  if rec then record(dtReal) end
  if not lines then
    -- no sidewalks yet: on a map without its own, look again now and then while pedestrians are wanted (the road
    -- graph may not be ready at mission start, or pedestrians were off then)
    if wanted() > 0 and not (slrrWalkGen and slrrWalkGen.busy()) then
      retryTimer = retryTimer - dtReal
      if retryTimer <= 0 then retryTimer = 5 loadWalks() end
    end
    return
  end
  if wanted() <= 0 then
    if #peds > 0 then clear() end
    if #spectators > 0 then clearSpectators() end
    return
  end
  local cam = core_camera.getPosition()
  local dt = dtSim or dtReal
  local vehicles = {}
  for i = 0, be:getObjectCount() - 1 do
    local v = be:getObject(i)
    local vp = v:getPosition()
    if vp and vec3(vp):distance(cam) < DESPAWN then
      local car = {pos = vec3(vp), vel = vec3(v:getVelocity())}
      local id = v:getId()
      if lastVel[id] and dt > 0 and (car.vel - lastVel[id]):length() > CRASH_DV then react(car.pos) end
      lastVel[id] = car.vel
      local box = v.getSpawnLocalAABB and v:getSpawnLocalAABB()
      if box then
        local mn, mx = box.minExtents, box.maxExtents
        local fwd = vec3(v:getDirectionVector()):normalized()
        local up = vec3(v:getDirectionVectorUp()):normalized()
        local right = fwd:cross(up):normalized()
        -- jbeam axes: x is the car's left, y its back
        local c = vec3((mn.x + mx.x) * 0.5, (mn.y + mx.y) * 0.5, 0)
        car.center = car.pos - right * c.x - fwd * c.y
        car.center.z = car.pos.z
        car.fwd, car.right = vec3(fwd.x, fwd.y, 0):normalized(), vec3(right.x, right.y, 0):normalized()
        car.hx, car.hy = (mx.x - mn.x) * 0.5, (mx.y - mn.y) * 0.5
      end
      table.insert(vehicles, car)
    end
  end
  cars = vehicles
  -- pedestrians by 2 m cell, from last frame's positions, for spacing
  local cells = {}
  for _, p in ipairs(peds) do
    if p.pos then
      local k = math.floor(p.pos.x / 2) .. ',' .. math.floor(p.pos.y / 2)
      cells[k] = cells[k] or {}
      table.insert(cells[k], p)
    end
  end
  for i = #peds, 1, -1 do
    local p = peds[i]
    if not simObjectExists(p.obj) then
      table.remove(peds, i)
    else
      local near = {}
      if p.pos then
        local cx, cy = math.floor(p.pos.x / 2), math.floor(p.pos.y / 2)
        for a = -1, 1 do
          for b = -1, 1 do
            for _, q in ipairs(cells[(cx + a) .. ',' .. (cy + b)] or {}) do table.insert(near, q) end
          end
        end
      end
      local pos = updatePed(p, dt, vehicles, near)
      if pos:distance(cam) > DESPAWN then despawn(p) table.remove(peds, i) end
    end
  end
  shareTimer = shareTimer - dtReal
  if shareTimer <= 0 then share, shareTimer = localShare(cam), 1 end
  -- the crowd at a venue comes out of the same budget: spectators first, pedestrians get the rest
  local total = target(dtReal)
  local nSpec = specZones and updateSpectators(dtReal, cam, total) or 0
  local n = math.max(0, math.floor((total - nSpec) * share + 0.5))
  if #peds < n and n > 0 then
    local p = spawnNear(cam)
    if p then table.insert(peds, p) end
  elseif #peds > n then
    -- over the cap: drop the one farthest from the camera, one a frame; out of view first
    local look = core_camera.getForward and vec3(core_camera.getForward()) or vec3(0, 0, 0)
    local far, fd = nil, -1
    for i, p in ipairs(peds) do
      local d = p.pos and p.pos:distance(cam) or 0
      if p.pos and not inView(p.pos, cam, look) then d = d + 1000 end
      if d > fd then far, fd = i, d end
    end
    despawn(table.remove(peds, far))
  end
end

M.setCount = function(n)
  count = math.max(0, math.floor(tonumber(n) or 0))
  cap = nil
  saveSettings()
end
M.getCount = function() return count end
-- options: amount 'off'|'low'|'medium'|'high'|'veryhigh' (x0 .. x2 of the count), maxCount 0..200, autoReduce,
-- targetFps 30..144, idling, crossing, busyAreas; only the keys given change; applied live and saved
M.setOptions = function(t)
  if applyOptions(t) then
    cap = nil
    saveSettings()
  end
end
M.getOptions = function()
  local t = {}
  for k, v in pairs(opts) do t[k] = v end
  return t
end
M.weightAt = weightAt
M.getState = function()   -- internal state, for debugging
  return {peds = peds, cap = cap, share = share, frameMs = frameAvg * 1000, junctions = junctions and #junctions,
          spectators = spectators, specZone = specZone and specZone.id, luaKB = collectgarbage('count')}
end
-- an error in a frame logs once and turns the pedestrians off until the next level (B46: a per-frame error
-- floods the log and kills the game's control server)
local broken = false
M.onUpdate = function(dtReal, dtSim)
  if broken then return end
  local ok, err = pcall(onUpdate, dtReal, dtSim)
  if not ok then
    broken = true
    log('E', 'slrrPedestrians', 'pedestrians stopped for this level: ' .. tostring(err))
    clear()
  end
end
M.pickType, M.kindsAt = pickType, kindsAt       -- (tests)
M.onRoad = onRoad
M.resetRoads = function() roadGrid, roadsTried = nil, nil end
M.getTypes = function() return types end
M.setDensity = function(d) density = d end      -- a density table in place of the level's file (tests, mod makers)
M.onExtensionLoaded = function() loadSettings() loadWalks() end
M.onExtensionUnloaded = function() clear() clearSpectators() followPlayer(nil) end
-- a race finishing (Valo City's races): the crowd cheers
M.onSlrrRaceFinished = function() cheerAll(6) end
-- slrrPedestrians.followPlayer(vehId, '/art/slrr_drivers/<id>/walker/') shows that walker on the vehicle; nil stops
M.followPlayer = followPlayer
-- slrrPedestrians.record(seconds, path): write every pedestrian's place and shape per frame to path (json)
M.record = function(seconds, path)
  rec = {t = 0, seconds = seconds or 20, path = path or '/temp/slrr_peds_rec.json', frames = {}}
end
M.onClientStartMission = function() broken = false group = nil peds = {} loadWalks() end
M.onClientEndMission = function()
  group, peds, lines, junctions, player, spectators, specZone, specZones = nil, {}, nil, nil, nil, {}, nil, nil
end

return M
