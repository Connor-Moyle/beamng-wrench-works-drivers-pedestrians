-- SLRR Drivers, vehicle side: streams what the driver's arms need to the GE extension every frame,
-- and puts the driver's weight into the car's physics. He applies no forces: his collision is visual.
local M = {}

local fmt = string.format

-- Driver mass: spread over the nodes around the seat in proportion to their own mass (so no light
-- node gets a big load and goes unstable). Others (the fuel tank, a reset) may rewrite node masses,
-- so it is checked once a second and put back.
local extra = {}        -- cid -> kg added
local checkTimer = 0

local function removeMass()
  for cid, kg in pairs(extra) do obj:setNodeMass(cid, math.max(0.01, obj:getNodeMass(cid) - kg)) end
  extra = {}
end

-- moving panels never carry him: weight on a door loads its latch and can pop it open
local function onPanel(n)
  local part = string.lower(tostring(n.partOrigin or ''))
  return part:find('door') or part:find('hood') or part:find('trunk') or part:find('tailgate') or part:find('hatch')
end

-- the nodes of the car's door latches and other couplers (advancedCouplerControl's couplerNodes): they
-- carry no extra mass either, or the latch breaks when the weight arrives (the driver's door hung open)
local function couplerCids()
  local out = {}
  local function add(name)
    local cid = type(name) == 'string' and beamstate.nodeNameMap[name]
    if cid then out[cid] = true end
  end
  for _, d in pairs(v.data) do
    if type(d) == 'table' and type(d.couplerNodes) == 'table' then
      for _, row in ipairs(tableFromHeaderTable(d.couplerNodes)) do
        add(row.cid1)
        add(row.forceCid1)
        for _, key in ipairs({'cid2', 'forceCid2'}) do
          if type(row[key]) == 'table' then for _, n in ipairs(row[key]) do add(n) end else add(row[key]) end
        end
      end
    end
  end
  return out
end

local camNode
local function setDriverMass(camCid, kg)
  camNode = camCid
  removeMass()
  local coupled = couplerCids()
  local cam = v.data.nodes[camCid] and v.data.nodes[camCid].pos
  if not cam or not kg or kg <= 0 then return end
  local seat = vec3(cam.x, cam.y + 0.1, cam.z - 0.55)   -- hips: below and a little behind the eye (car faces -y)
  local picked, total
  for _, radius in ipairs({0.45, 0.7, 1.0, 1.5}) do
    picked, total = {}, 0
    for _, n in pairs(v.data.nodes) do
      if n.cid and n.pos and not onPanel(n) and not coupled[n.cid] and vec3(n.pos):distance(seat) < radius then
        local m = obj:getNodeMass(n.cid)
        picked[n.cid] = m
        total = total + m
      end
    end
    if total >= 20 and tableSize(picked) >= 4 then break end
  end
  if total <= 0 then return end
  for cid, m in pairs(picked) do
    extra[cid] = kg * m / total
    obj:setNodeMass(cid, m + extra[cid])
  end
  M.expected = {}
  for cid in pairs(extra) do M.expected[cid] = obj:getNodeMass(cid) end
end

local function keepMass(dt)
  checkTimer = checkTimer + dt
  if checkTimer < 1 then return end
  checkTimer = 0
  for cid, kg in pairs(extra) do
    local m = obj:getNodeMass(cid)
    if m < M.expected[cid] - 0.01 then   -- someone set this node back to its own mass
      obj:setNodeMass(cid, m + kg)
      M.expected[cid] = m + kg
    end
  end
end

-- Flex driver (slrrDriverMount, driverRig 'flex'): the joints of his skeleton are nodes held by stiff beams to the torso.
-- slrrDrivers works out where each joint should be (seat frame: x right, y forward, z up, from the camera node) and
-- sends it with pose(); here every frame each target is eased toward and each holding beam is set to the distance
-- between the torso node and the target, which moves the joint. Torso nodes are taken at their rest places.
local JOINTS = {'r_el', 'l_el', 'r_wr', 'l_wr', 'r_kn', 'l_kn', 'r_an', 'l_an', 'head'}
local rig                      -- nil until looked up; false when this car has no flex skeleton
local target = {}              -- joint -> vec3, jbeam space
local now = {}

local function findRig()
  local byName = {}
  for cid, n in pairs(v.data.nodes) do
    local name = type(n) == 'table' and n.name
    if type(name) == 'string' and name:sub(1, 8) == 'slrr_rd_' then byName[cid] = name:sub(9) end
  end
  if not next(byName) then return false end
  local r = {holds = {}, rest = {}}
  for cid, name in pairs(byName) do r.rest[name] = {cid = cid, pos = vec3(v.data.nodes[cid].pos)} end
  local isJoint = {}
  for _, j in ipairs(JOINTS) do isJoint[j] = true end
  for bcid, b in pairs(v.data.beams) do
    local a, c = byName[b.id1], byName[b.id2]
    if a and c and b.beamSpring == 150000 then            -- the stiff pose beams
      local joint, torso = a, c
      if not isJoint[a] then joint, torso = c, a end
      if isJoint[joint] and not isJoint[torso] then
        r.holds[joint] = r.holds[joint] or {}
        table.insert(r.holds[joint], {bcid = bcid, torso = r.rest[torso].pos})
      end
    end
  end
  return r
end

local function pose(t)    -- t: 27 numbers, three per joint in JOINTS order, seat frame
  if rig == nil then rig = findRig() end
  if not rig or not camNode then return end
  local cam = v.data.nodes[camNode].pos
  for i, j in ipairs(JOINTS) do
    local k = (i - 1) * 3
    target[j] = vec3(cam.x - t[k + 1], cam.y - t[k + 2], cam.z + t[k + 3])   -- seat frame -> jbeam (x left, y back)
  end
end

local function movePose(dt)
  if not rig then return end
  local k = math.min(1, dt * 40)
  for j, tg in pairs(target) do
    local c = now[j]
    c = c and (c + (tg - c) * k) or tg
    now[j] = c
    for _, h in ipairs(rig.holds[j] or {}) do obj:setBeamLength(h.bcid, c:distance(h.torso)) end
  end
end

local function updateGFX(dt)
  movePose(dt)
  local e = electrics.values
  obj:queueGameEngineLua(fmt('if slrrDrivers then slrrDrivers.feed(%d,%.2f,%.0f,%.0f,%d,%.2f,%.2f,%.2f) end',
    objectId, e.steering or 0, e.rpm or 0, e.maxrpm or 0, e.gearIndex or 0, e.throttle or 0, e.brake or 0, e.clutch or 0))
  keepMass(dt)
end

M.updateGFX = updateGFX
M.pose = pose
M.setDriverMass = setDriverMass
M.onReset = function() checkTimer = 1 now = {} end   -- re-check straight away
M.onExtensionUnloaded = removeMass
M.addedMass = function() local s = 0 for _, kg in pairs(extra) do s = s + kg end return s end
return M
