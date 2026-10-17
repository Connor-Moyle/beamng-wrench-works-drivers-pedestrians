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
  local r = {holds = {}, rest = {}, mine = {}, all = {}, cid = {}}
  for cid, name in pairs(byName) do r.rest[name] = {cid = cid, pos = vec3(v.data.nodes[cid].pos)} r.cid[name] = cid end
  for bcid, b in pairs(v.data.beams) do if b.partOrigin == 'slrr_ragdoll' then r.all[#r.all + 1] = bcid end end   -- (for the health log)
  local isJoint = {}
  for _, j in ipairs(JOINTS) do isJoint[j] = true end
  for bcid, b in pairs(v.data.beams) do
    local a, c = byName[b.id1], byName[b.id2]
    -- only our own beams are ever resized: both ends are driver nodes, plain type, our part, no break group
    if a and c and b.beamSpring == 150000 and b.partOrigin == 'slrr_ragdoll' and (b.beamType or 0) == 0 and not b.breakGroup then
      local joint, torso = a, c
      if not isJoint[a] then joint, torso = c, a end
      if isJoint[joint] and not isJoint[torso] then
        r.holds[joint] = r.holds[joint] or {}
        table.insert(r.holds[joint], {bcid = bcid, torso = r.rest[torso].pos, tcid = r.rest[torso].cid, rest = b.beamLength or r.rest[torso].pos:distance(r.rest[joint].pos)})
        r.mine[bcid] = true
      end
    end
  end
  local nh = 0
  for _ in pairs(r.holds) do nh = nh + 1 end
  log('I', 'slrrDriverFeed', 'flex skeleton: ' .. tableSize(r.rest) .. ' nodes, ' .. nh .. ' held joints, ' .. tableSize(r.mine) .. ' own beams')
  return r
end

local function pose(t)    -- t: 27 numbers, three per joint in JOINTS order, seat frame
  if rig == nil then rig = findRig() end
  if not rig or not camNode or type(t) ~= 'table' then return end
  for i = 1, #JOINTS * 3 do   -- a bad frame (NaN, inf, absent) is dropped whole
    local x = t[i]
    if type(x) ~= 'number' or x ~= x or math.abs(x) > 5 then return end
  end
  local cam = v.data.nodes[camNode].pos
  for i, j in ipairs(JOINTS) do
    local k = (i - 1) * 3
    target[j] = vec3(cam.x - t[k + 1], cam.y - t[k + 2], cam.z + t[k + 3])   -- seat frame -> jbeam (x left, y back)
  end
end

-- each joint stays a bone's length from the joint before it (the bone beams are stiff: a target a little off would make the
-- truss and the bones fight, with big forces on light nodes)
local CHAINS = {{'r_el', 'r_sh'}, {'r_wr', 'r_el'}, {'l_el', 'l_sh'}, {'l_wr', 'l_el'},
                {'r_kn', 'r_hip'}, {'r_an', 'r_kn'}, {'l_kn', 'l_hip'}, {'l_an', 'l_kn'}, {'head', 'neck'}}
local function fitBones()
  for _, ch in ipairs(CHAINS) do
    local j, p = ch[1], ch[2]
    local jr, pr = rig.rest[j], rig.rest[p]
    local from = now[p] or (pr and pr.pos)
    if now[j] and jr and pr and from then
      local d = now[j] - from
      local len = jr.pos:distance(pr.pos)
      if d:length() > 1e-6 then now[j] = from + d:normalized() * len end
    end
  end
end

local stats = {calls = 0, skipped = 0, t = 0}
local function movePose(dt)
  if not rig then return end
  local k = math.min(1, dt * 40)
  for j, tg in pairs(target) do
    local c = now[j]
    c = c and (c + (tg - c) * k) or tg
    now[j] = c
  end
  fitBones()
  stats.t = stats.t + dt
  if stats.t > 5 and stats.calls + stats.skipped > 0 then
    -- health: how many of the driver's beams broke, and how far head / shoulder / wrist sit from the eye now against at rest (m)
    local okh, err = pcall(function()
    local broken = 0
    for _, bcid in ipairs(rig.all) do if obj:beamIsBroken(bcid) then broken = broken + 1 end end
    local function dist(name)
      local n, e = rig.cid[name], v.data.nodes[camNode]
      if not (n and e) then return 0 end
      return obj:getNodePosition(n):distance(obj:getNodePosition(camNode)) - rig.rest[name].pos:distance(vec3(e.pos))
    end
    log('I', 'slrrDriverFeed', string.format('flex pose: %d beams set, %d skipped in %.0f s; %d of %d beams broken; drift from the eye: head %.2f l_sh %.2f r_wr %.2f',
      stats.calls, stats.skipped, stats.t, broken, #rig.all, dist('head'), dist('l_sh'), dist('r_wr')))
    end)
    if not okh then log('W', 'slrrDriverFeed', 'health log failed: ' .. tostring(err)) end
    stats.calls, stats.skipped, stats.t = 0, 0, 0
  end
  -- the torso sinks a little under the driver's weight (the seat is soft): each length is measured to where the torso node is
  -- now, with the target placed from the eye in the car's own axes (world), so the joint lands on its target and not as far off as
  -- the torso is. Without the engine's vectors (or a bad one) it is the rest place, as before.
  local E, fwd, up, right
  local okv = pcall(function()
    E, fwd, up = obj:getNodePosition(camNode), obj:getDirectionVector(), obj:getDirectionVectorUp()
    right = fwd:cross(up):normalized()
    up = right:cross(fwd)
  end)
  if not (okv and E and right and right.x == right.x) then E = nil end
  local cam = v.data.nodes[camNode].pos
  for j, c in pairs(now) do
    local tw = E and (E + right * (cam.x - c.x) + fwd * (cam.y - c.y) + up * (c.z - cam.z))
    for _, h in ipairs(rig.holds[j] or {}) do
      local len
      if tw then
        local okn, tp = pcall(obj.getNodePosition, obj, h.tcid)
        len = okn and tp and tw:distance(tp) or c:distance(h.torso)
      else len = c:distance(h.torso) end
      -- never a car's beam (dent crashes), and never a length that is not a number or far from the rest length
      if rig.mine[h.bcid] and len == len and len < h.rest * 1.5 + 0.3 then obj:setBeamLength(h.bcid, len) stats.calls = stats.calls + 1
      else stats.skipped = stats.skipped + 1 end
    end
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
