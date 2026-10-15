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
-- of the way of fast ones. Fewer walk while the frame time is over budget.
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
local DEFAULT_SPEED = 1.3   -- walk speed for a shape without ped.json (MODDING.md: loops about once a second)
local LANE = 0.4            -- each pedestrian walks up to this far either side of the sidewalk line
local PERSONAL = 0.7        -- sideways room kept from another pedestrian
local PED_AHEAD = 2.0       -- metres ahead another pedestrian is noticed
local MAX_SIDE = 1.5        -- furthest a pedestrian strays from its line
local IDLE_MIN, IDLE_MAX = 4, 15         -- seconds standing at a corner or along the way
local STOP_RATE = 1 / 90                 -- chance per second (times the pedestrian's idle chance) to stop mid-walk
local SPAWN_STANDING = 0.15              -- share spawned standing
local CROSS_MIN = 5         -- a link this long or more crosses a road
local JUNCTION_REACH = 35   -- a crossing this close to a signalled junction's centre obeys its lights
local GREEN = 'greenTrafficLight'
local FRAME_BUDGET = 1 / 55 -- seconds; over it, pedestrians are shed
local FRAME_TAU = 2         -- seconds of frame-time smoothing
local MIN_CAP = 6

local count = 30
local types = {}            -- {walks = {{shape, speed}}, idle = shape or nil}
local lines, ends, grid
local peds = {}
local group
local loadedMaterials = false
local junctions             -- {{c = centre, signals = {SignalInstance}}}, from core_trafficSignals
local frameAvg, cap, capTimer = 1 / 60, nil, 0

local function loadSettings()
  local s = jsonReadFile(SETTINGS)
  if s and tonumber(s.count) then count = tonumber(s.count) end
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
      local t = {walks = {}, idle = info.idle and dir .. info.idle}
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
  if not data then return end
  loadTypes()
  if #types == 0 then return end
  if not loadedMaterials then
    for _, f in ipairs(FS:findFiles(ROOT, '*.materials.json', -1, true, false)) do loadJsonMaterialsFile(f) end
    loadedMaterials = true
  end
  lines, ends, grid = {}, {}, {}
  for i, l in ipairs(data) do
    local pts, len = {}, {0}
    for k, p in ipairs(l) do
      pts[k] = vec3(p[1], p[2], p[3])
      if k > 1 then len[k] = len[k - 1] + pts[k]:distance(pts[k - 1]) end
    end
    lines[i] = {pts = pts, len = len, total = len[#len]}
    for k, p in ipairs(pts) do
      local key = math.floor(p.x / CELL) .. ',' .. math.floor(p.y / CELL)
      grid[key] = grid[key] or {}
      table.insert(grid[key], {line = i, k = k})
    end
    table.insert(ends, {line = i, atStart = true, p = pts[1]})
    table.insert(ends, {line = i, atStart = false, p = pts[#pts]})
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
  if not junctions or len < CROSS_MIN then return end
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
  local sig, bestDot = nil, 0.7
  for _, s in ipairs(best.signals) do
    local arm = vec3(s.pos.x - best.c.x, s.pos.y - best.c.y, 0)
    if arm:length() > 3 then arm = arm:normalized() else arm = vec3(s.dir.x, s.dir.y, 0) end
    local d = math.abs(c.x * arm.x + c.y * arm.y)
    if d > bestDot then sig, bestDot = s, d end
  end
  return sig
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
  if fwd:length() < 1e-3 then fwd = vec3(0, 1, 0) end
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

-- stand still (idle animation) for `time` seconds, or until a signal lets them go when `time` is nil
local function stand(p, time)
  p.state, p.timer = time and 'idle' or 'wait', time
  setShape(p, p.type.idle or p.walk.shape)
end

local function walkOn(p)
  p.state = 'walk'
  setShape(p, p.walk.shape)
end

local function spawnNear(cam)
  -- a random sidewalk point in a ring around the camera
  for _ = 1, 20 do
    local a, r = math.random() * 2 * math.pi, SPAWN_MIN + math.random() * (SPAWN_MAX - SPAWN_MIN)
    local q = cam + vec3(math.cos(a) * r, math.sin(a) * r, 0)
    local bucket = grid[math.floor(q.x / CELL) .. ',' .. math.floor(q.y / CELL)]
    if bucket and #bucket > 0 then
      local pick = bucket[math.random(#bucket)]
      local t = types[math.random(#types)]
      local w = t.walks[math.random(#t.walks)]
      local p = {type = t, walk = w, speed = w.speed, line = pick.line, s = lines[pick.line].len[pick.k],
                 dir = math.random() < 0.5 and 1 or -1, lane = (math.random() * 2 - 1) * LANE, side = 0,
                 idleChance = t.idle and math.random() * 0.6 or 0, zTimer = 0, dodge = vec3(0, 0, 0)}
      if t.idle and math.random() < SPAWN_STANDING then stand(p, IDLE_MIN + math.random() * 2 * IDLE_MAX) else walkOn(p) end
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

local function startLink(p)
  local e, o, signal = p.link.from, p.link.to, p.link.signal
  p.link = nil
  p.cross = {from = e.p, to = o.p, t = 0, len = math.max(0.5, e.p:distance(o.p)), signal = signal}
  p.line, p.dir = o.line, o.atStart and 1 or -1
  p.s = o.atStart and 0 or lines[o.line].total
end

-- may p start its crossing now: no signal, or green now and still green when they reach the far side
local function mayCross(p)
  local s = p.link.signal
  if not s then return true end
  local now = s:getState()
  if now == 'none' then return true end   -- signal system not running
  return now == GREEN and s:getStateAfterTime(p.link.len / p.speed + 1) == GREEN
end

-- at a sidewalk's end: pick the next sidewalk, maybe stand a while, then go (or wait for the light)
local function reachEnd(p)
  local line = lines[p.line]
  local e = p.dir > 0 and line.endEnd or line.startEnd
  local choices = e and e.links or {}
  if #choices == 0 then p.dir = -p.dir return end
  local o = choices[math.random(#choices)]
  p.link = {from = e, to = o, len = e.p:distance(o.p), signal = signalFor(e.p, o.p)}
  if math.random() < p.idleChance then stand(p, IDLE_MIN + math.random() * (IDLE_MAX - IDLE_MIN))
  elseif not mayCross(p) then stand(p)
  else startLink(p) end
end

local function updateStanding(p, dt)
  if p.state == 'idle' then
    p.timer = p.timer - dt
    if p.timer > 0 then return end
    if p.link and not mayCross(p) then stand(p) return end
  elseif not mayCross(p) then
    return
  end
  if p.link then startLink(p) end
  walkOn(p)
end

local function updatePed(p, dt, vehicles, near)
  local pos, fwd
  if p.state ~= 'walk' then
    updateStanding(p, dt)
  elseif not p.cross and p.idleChance > 0 and math.random() < STOP_RATE * p.idleChance * dt then
    stand(p, IDLE_MIN + math.random() * (IDLE_MAX - IDLE_MIN))
  end
  local moving = p.state == 'walk'
  if p.cross then
    if moving then p.cross.t = p.cross.t + dt * p.speed / p.cross.len end
    if p.cross.t >= 1 then p.cross = nil end
  end
  if p.cross then
    pos = lerp(p.cross.from, p.cross.to, p.cross.t)
    fwd = p.cross.to - p.cross.from
  else
    local line = lines[p.line]
    if moving then p.s = p.s + p.dir * p.speed * dt end
    if p.s < 0 or p.s > line.total then
      p.s = clamp(p.s, 0, line.total)
      reachEnd(p)
      line = lines[p.line]
    end
    local d
    pos, d = pointAt(line, p.s)
    fwd = d * p.dir
    if p.link then fwd = p.link.to.p - p.link.from.p end   -- waiting: face the way across
  end
  fwd = vec3(fwd.x, fwd.y, 0)
  if fwd:length() > 1e-3 then fwd = fwd:normalized() end
  local side = vec3(fwd.y, -fwd.x, 0)   -- right of fwd
  local base = pos + side * p.lane

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
  want = clamp(want, -MAX_SIDE, MAX_SIDE)
  p.side = p.side + clamp(want - p.side, -SIDESTEP_SPEED * dt, SIDESTEP_SPEED * dt)
  pos = base + side * p.side

  -- jump clear of fast cars coming at them
  for _, v in ipairs(vehicles) do
    local rel = pos + p.dodge - v.pos
    if rel:length() < DODGE_DIST and v.vel:length() > DODGE_SPEED and v.vel:dot(rel) > 0 then
      local away = v.vel:cross(vec3(0, 0, 1)):normalized()
      if away:dot(rel) < 0 then away = -away end
      p.dodge = p.dodge + away * (dt * 6)
    end
  end
  p.dodge = p.dodge * math.max(0, 1 - dt * 0.3)
  if p.dodge:length() > 3 then p.dodge = p.dodge:normalized() * 3 end
  pos = pos + p.dodge
  p.zTimer = p.zTimer - dt
  if not p.z or p.zTimer <= 0 then p.z, p.zTimer = groundZ(pos), 0.3 end
  place(p.obj, vec3(pos.x, pos.y, p.z), fwd)
  p.pos, p.fwd = pos, fwd
  return pos
end

-- how many may walk: the setting, lowered while the smoothed frame time is over budget
local function target(dtReal)
  cap = cap or count
  frameAvg = frameAvg + (dtReal - frameAvg) * math.min(1, dtReal / FRAME_TAU)
  capTimer = capTimer + dtReal
  if capTimer > 0.5 then
    capTimer = 0
    if frameAvg > FRAME_BUDGET then cap = math.max(math.min(MIN_CAP, count), cap - 2)
    elseif frameAvg < FRAME_BUDGET * 0.85 then cap = math.min(count, cap + 1) end
  end
  return math.min(count, cap)
end

local function onUpdate(dtReal, dtSim)
  if not lines or count <= 0 then return end
  local cam = core_camera.getPosition()
  local dt = dtSim or dtReal
  local vehicles = {}
  for i = 0, be:getObjectCount() - 1 do
    local v = be:getObject(i)
    local vp = v:getPosition()
    if vp and vec3(vp):distance(cam) < DESPAWN then
      local car = {pos = vec3(vp), vel = vec3(v:getVelocity())}
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
  local n = target(dtReal)
  if #peds < n then
    local p = spawnNear(cam)
    if p then table.insert(peds, p) end
  elseif #peds > n then
    -- over the cap: drop the one farthest from the camera, one a frame
    local far, fd = nil, -1
    for i, p in ipairs(peds) do
      local d = p.pos and p.pos:distance(cam) or 0
      if d > fd then far, fd = i, d end
    end
    despawn(table.remove(peds, far))
  end
end

local function clear()
  for _, p in ipairs(peds) do despawn(p) end
  peds = {}
end

M.setCount = function(n)
  count = math.max(0, math.floor(tonumber(n) or 0))
  cap = count
  jsonWriteFile(SETTINGS, {count = count}, true)
  while #peds > count do despawn(table.remove(peds)) end
end
M.getCount = function() return count end
M.getState = function()   -- internal state, for debugging
  return {peds = peds, cap = cap, frameMs = frameAvg * 1000, junctions = junctions and #junctions}
end
M.onUpdate = onUpdate
M.onExtensionLoaded = function() loadSettings() loadWalks() end
M.onExtensionUnloaded = clear
M.onClientStartMission = function() group = nil peds = {} loadWalks() end
M.onClientEndMission = function() group = nil peds = {} lines = nil junctions = nil end

return M
