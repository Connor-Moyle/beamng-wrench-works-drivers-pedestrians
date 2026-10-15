-- SLRR Pedestrians: SLRR's pedestrians walk the city's sidewalks around the camera, as in SLRR.
--
-- The walk cycle is baked into each shape (tools/convert_peds.py) and plays as the TSStatic's
-- ambient animation; this file only moves them. Sidewalks come from SLRR's city.walk, converted to
-- /art/slrr_pedestrians/walk_<level>.json (polylines, x y z). Levels without that file get none.
--
-- At a sidewalk's end a pedestrian walks over to the nearest other sidewalk end (around the corner or
-- across the street), or turns back. Fast cars coming at them make them jump aside.
--
-- API: slrrPedestrians.setCount(n) (saved), slrrPedestrians.getCount()

local M = {}

local ROOT = '/art/slrr_pedestrians/'
local SETTINGS = '/settings/slrr_pedestrians.json'
local types = {}           -- shape paths: every /art/slrr_pedestrians/<name>/<name>.dae
local SPAWN_MIN, SPAWN_MAX, DESPAWN = 25, 110, 150   -- metres from the camera
local LINK_DIST = 14        -- sidewalk ends closer than this connect (corners, crossings)
local CELL = 50
local DODGE_DIST, DODGE_SPEED = 6, 4
local CAR_MARGIN = 0.45     -- room kept around a car's box when walking round it
local LOOK_AHEAD = 2.5      -- metres ahead a pedestrian starts to step round a car
local SIDESTEP_SPEED = 1.2

local count = 30
local lines, ends, grid
local peds = {}
local group
local loadedMaterials = false

local function loadSettings()
  local s = jsonReadFile(SETTINGS)
  if s and tonumber(s.count) then count = tonumber(s.count) end
end

local function levelName()
  local f = getMissionFilename and getMissionFilename() or ''
  return f:match('/levels/([^/]+)/')
end

local function loadWalks()
  lines, ends, grid = nil, nil, nil
  local lvl = levelName()
  local data = lvl and jsonReadFile(ROOT .. 'walk_' .. lvl .. '.json')
  if not data then return end
  types = {}
  for _, f in ipairs(FS:findFiles(ROOT, '*.dae', -1, true, false)) do
    local folder, stem = f:match('/([^/]+)/([^/]+)%.dae$')
    if folder and folder:lower() == stem:lower() then table.insert(types, f) end
  end
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

local function spawnNear(cam)
  -- a random sidewalk point in a ring around the camera
  for _ = 1, 20 do
    local a, r = math.random() * 2 * math.pi, SPAWN_MIN + math.random() * (SPAWN_MAX - SPAWN_MIN)
    local q = cam + vec3(math.cos(a) * r, math.sin(a) * r, 0)
    local bucket = grid[math.floor(q.x / CELL) .. ',' .. math.floor(q.y / CELL)]
    if bucket and #bucket > 0 then
      local pick = bucket[math.random(#bucket)]
      local line = lines[pick.line]
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
      o:setField('shapeName', 0, types[math.random(#types)])
      o:setField('collisionType', 0, 'None')
      o:setField('decalType', 0, 'None')
      o:setField('playAmbient', 0, '1')
      o.canSave = false
      o:registerObject('')
      group:addObject(o)
      return {obj = o, line = pick.line, s = line.len[pick.k], dir = math.random() < 0.5 and 1 or -1,
              speed = 1.15 + math.random() * 0.35, z = nil, zTimer = 0, dodge = vec3(0, 0, 0)}
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

-- walking from a sidewalk end to a linked one
local function nextLine(p)
  local line = lines[p.line]
  local e = p.dir > 0 and line.endEnd or line.startEnd
  local choices = e and e.links or {}
  if #choices == 0 then p.dir = -p.dir return end
  local o = choices[math.random(#choices)]
  p.cross = {from = e.p, to = o.p, t = 0, len = math.max(0.5, e.p:distance(o.p))}
  p.line = o.line
  p.dir = o.atStart and 1 or -1
  p.s = o.atStart and 0 or lines[o.line].total
end

local function updatePed(p, dt, vehicles)
  local pos, fwd
  if p.cross then
    p.cross.t = p.cross.t + dt * p.speed / p.cross.len
    if p.cross.t >= 1 then p.cross = nil end
  end
  if p.cross then
    pos = lerp(p.cross.from, p.cross.to, p.cross.t)
    fwd = p.cross.to - p.cross.from
  else
    local line = lines[p.line]
    p.s = p.s + p.dir * p.speed * dt
    if p.s < 0 or p.s > line.total then
      p.s = clamp(p.s, 0, line.total)
      nextLine(p)
      line = lines[p.line]
    end
    local d
    pos, d = pointAt(line, p.s)
    fwd = d * p.dir
  end
  -- walk round cars standing in the way: step sideways until the path ahead clears the car's box
  local side = vec3(fwd.y, -fwd.x, 0)
  if side:length() > 1e-3 then side = side:normalized() end
  local want = 0
  for _, v in ipairs(vehicles) do
    if v.hx and v.center:distance(pos) < v.hy + LOOK_AHEAD + 2 then
      for _, ahead in ipairs({0, LOOK_AHEAD * 0.5, LOOK_AHEAD}) do
        local st = stepOut(pos + fwd:normalized() * ahead, side, v)
        if math.abs(st) > math.abs(want) then want = st end
      end
    end
  end
  p.side = p.side or 0
  p.side = p.side + clamp(want - p.side, -SIDESTEP_SPEED * dt, SIDESTEP_SPEED * dt)
  pos = pos + side * p.side

  -- jump clear of fast cars coming at them
  for _, v in ipairs(vehicles) do
    local rel = pos + p.dodge - v.pos
    if rel:length() < DODGE_DIST and v.vel:length() > DODGE_SPEED and v.vel:dot(rel) > 0 then
      local side = v.vel:cross(vec3(0, 0, 1)):normalized()
      if side:dot(rel) < 0 then side = -side end
      p.dodge = p.dodge + side * (dt * 6)
    end
  end
  p.dodge = p.dodge * math.max(0, 1 - dt * 0.3)
  if p.dodge:length() > 3 then p.dodge = p.dodge:normalized() * 3 end
  pos = pos + p.dodge
  p.zTimer = p.zTimer - dt
  if not p.z or p.zTimer <= 0 then p.z, p.zTimer = groundZ(pos), 0.3 end
  place(p.obj, vec3(pos.x, pos.y, p.z), fwd)
  return pos
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
  for i = #peds, 1, -1 do
    local p = peds[i]
    if not simObjectExists(p.obj) then
      table.remove(peds, i)
    else
      local pos = updatePed(p, dt, vehicles)
      if pos:distance(cam) > DESPAWN then despawn(p) table.remove(peds, i) end
    end
  end
  if #peds < count then
    local p = spawnNear(cam)
    if p then table.insert(peds, p) end
  end
end

local function clear()
  for _, p in ipairs(peds) do despawn(p) end
  peds = {}
end

M.setCount = function(n)
  count = math.max(0, math.floor(tonumber(n) or 0))
  jsonWriteFile(SETTINGS, {count = count}, true)
  while #peds > count do despawn(table.remove(peds)) end
end
M.getCount = function() return count end
M.onUpdate = onUpdate
M.onExtensionLoaded = function() loadSettings() loadWalks() end
M.onExtensionUnloaded = clear
M.onClientStartMission = function() group = nil peds = {} loadWalks() end
M.onClientEndMission = function() group = nil peds = {} lines = nil end

return M
