-- SLRR Drivers, vehicle side: streams what the driver's arms need to the GE extension every frame,
-- and puts the driver's weight into the car's physics.
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

local function setDriverMass(camCid, kg)
  removeMass()
  local cam = v.data.nodes[camCid] and v.data.nodes[camCid].pos
  if not cam or not kg or kg <= 0 then return end
  local seat = vec3(cam.x, cam.y + 0.1, cam.z - 0.55)   -- hips: below and a little behind the eye (car faces -y)
  local picked, total
  for _, radius in ipairs({0.45, 0.7, 1.0, 1.5}) do
    picked, total = {}, 0
    for _, n in pairs(v.data.nodes) do
      if n.cid and n.pos and vec3(n.pos):distance(seat) < radius then
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

local function updateGFX(dt)
  local e = electrics.values
  obj:queueGameEngineLua(fmt('if slrrDrivers then slrrDrivers.feed(%d,%.2f,%.0f,%.0f,%d,%.2f,%.2f,%.2f) end',
    objectId, e.steering or 0, e.rpm or 0, e.maxrpm or 0, e.gearIndex or 0, e.throttle or 0, e.brake or 0, e.clutch or 0))
  keepMass(dt)
end

-- the driver's body hit this node: push it (world-space force, newtons, for t seconds)
local function hit(cid, fx, fy, fz, t)
  if v.data.nodes[cid] then obj:applyForceVectorTime(cid, vec3(fx, fy, fz), t) end
end

M.updateGFX = updateGFX
M.hit = hit
M.setDriverMass = setDriverMass
M.onReset = function() checkTimer = 1 end   -- re-check straight away
M.onExtensionUnloaded = removeMass
M.addedMass = function() local s = 0 for _, kg in pairs(extra) do s = s + kg end return s end
return M
