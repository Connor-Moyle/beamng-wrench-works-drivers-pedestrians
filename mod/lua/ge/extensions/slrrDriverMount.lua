-- SLRR Drivers: the driver as part of the car. At every vehicle spawn (BeamNG's onJbeamLoadingPhase1 hook,
-- after node ids are assigned) this can add
--   * props: the driver's 14 parts as vehicle props (meshes slrr_<model>_<part> from vehicles/common), so
--     the car draws them in its own render transform (exactly seat-locked, proper motion vectors);
--     slrrDrivers poses them every frame;
--   * a ragdoll (prototype): ~16 physics nodes at the seated joints, stiff bones, joint limits, soft
--     posture beams and tension-only seat belts that break in a huge crash.
-- Both are behind flags (off by default) and never break a spawn: any error only logs.
local M = {}

local jbeamUtils = require('jbeam/utils')

local SETTINGS = '/settings/slrr_drivers_mount.json'
local flags = {props = false, ragdoll = false, selfCollision = false}
local ragdollNext = false          -- one-shot: the next vehicle with a driver camera gets the ragdoll
local ragdolls = {}                -- objID -> {nodes = {name = cid}, belts = {cid...}}

local PARTS = {'body', 'head', 'r_upperarm', 'r_forearm', 'r_hand', 'l_upperarm', 'l_forearm', 'l_hand',
               'r_thigh', 'r_calf', 'r_foot', 'l_thigh', 'l_calf', 'l_foot'}
local PANEL = {'door', 'hood', 'trunk', 'tailgate', 'hatch'}

-- seat frame (x right, y forward, z up, from the eye) -> jbeam (x left, y back, z up), at the camera node
local function J(cam, p) return vec3(cam.x - p[1], cam.y - p[2], cam.z + p[3]) end

-- nodes by physics id (cid), whatever the table's own keys are
local function byCid(vehicle)
  local t = {}
  for _, n in pairs(vehicle.nodes) do if type(n) == 'table' and n.cid then t[n.cid] = n end end
  return t
end

local function driverCamera(vehicle)
  for _, c in pairs(vehicle.cameras and vehicle.cameras.onboard or {}) do
    if type(c) == 'table' and c.name == 'driver' and c.camNodeID then return c.camNodeID end
  end
end

local function driverModel()
  local id = slrrDrivers and slrrDrivers.getDefaultDriver and slrrDrivers.getDefaultDriver() or 'slrr_mitch'
  local d = jsonReadFile('/art/slrr_drivers/' .. id .. '/driver.json')
  return d and d.model or 'vin'
end

local function onPanel(n)
  local part = string.lower(tostring(n.partOrigin or ''))
  for _, w in ipairs(PANEL) do if part:find(w) then return true end end
  return false
end

local function addProps(vehicle, camCid)
  local model = driverModel()
  local sp
  for _, p in pairs(vehicle.props or {}) do
    if type(p) == 'table' and p.func == 'steering' and tonumber(p.idRef) and tonumber(p.idX) and tonumber(p.idY) then sp = p break end
  end
  if not sp then return 0 end
  local cam = byCid(vehicle)[camCid].pos
  vehicle.props = vehicle.props or {}
  for _, part in ipairs(PARTS) do
    vehicle.props['slrr_driver_' .. part] = {
      mesh = 'slrr_' .. model .. '_' .. part, func = 'slrr_driver', idRef = sp.idRef, idX = sp.idX, idY = sp.idY,
      translation = {x = 0, y = 0, z = 0}, rotation = {x = 0, y = 0, z = 0},
      baseTranslationGlobal = {x = cam.x, y = cam.y, z = cam.z},
      cid = jbeamUtils.increaseMax(vehicle, 'props'), slrrPart = part}
  end
  return #PARTS
end

-- the nearest car node to a point (jbeam space), not on a moving panel and not one of ours
local function nearestNode(vehicle, p, skip)
  local best, bd
  for _, n in pairs(vehicle.nodes) do
    if type(n) == 'table' and n.cid and n.pos and not skip[n.cid] and not onPanel(n) then
      local d = vec3(n.pos):distance(p)
      if not bd or d < bd then best, bd = n.cid, d end
    end
  end
  return best, bd
end

local function addRagdoll(objID, vehicle, camCid)
  local rig = jsonReadFile('/art/slrr_drivers/models/' .. driverModel() .. '/rig.json')
  if not rig then return 0 end
  local cam = vec3(byCid(vehicle)[camCid].pos)
  local sx = 1                                   -- seat frame x is right
  local sh, hp = rig.arms.r.shoulder, rig.legs.r.hip
  local P = {
    head = {rig.parts.head[1], rig.parts.head[2] + 0.04, rig.parts.head[3] + 0.12}, neck = rig.parts.head,
    chest = {0, (sh[2] + rig.pelvis[2]) / 2, (sh[3] + rig.pelvis[3]) / 2 + 0.05}, pelvis = rig.pelvis,
    r_sh = rig.arms.r.shoulder, l_sh = rig.arms.l.shoulder, r_el = rig.arms.r.elbow, l_el = rig.arms.l.elbow,
    r_wr = rig.arms.r.wrist, l_wr = rig.arms.l.wrist, r_hip = rig.legs.r.hip, l_hip = rig.legs.l.hip,
    r_kn = rig.legs.r.knee, l_kn = rig.legs.l.knee, r_an = rig.legs.r.ankle, l_an = rig.legs.l.ankle}
  local KG = {head = 5.5, neck = 1.5, chest = 14, pelvis = 10, r_sh = 4, l_sh = 4, r_el = 2, l_el = 2, r_wr = 1, l_wr = 1,
              r_hip = 6, l_hip = 6, r_kn = 4, l_kn = 4, r_an = 2, l_an = 2}
  local ids, ours = {}, {}
  for name, p in pairs(P) do
    local cid = jbeamUtils.addNodeWithOptions(vehicle, J(cam, p), 0, {
      nodeWeight = KG[name], collision = true, selfCollision = flags.selfCollision, frictionCoef = 0.8,
      group = {'slrr_ragdoll'}, partOrigin = 'slrr_ragdoll', name = 'slrr_rd_' .. name})
    ids[name], ours[cid] = cid, true
  end
  local function beam(a, b, opts)
    return jbeamUtils.addBeamWithOptions(vehicle, a, b, opts.beamType or 0, opts)
  end
  local BONE = {beamSpring = 400000, beamDamp = 60, beamDeform = math.huge, beamStrength = math.huge, partOrigin = 'slrr_ragdoll'}
  local SOFT = {beamSpring = 3000, beamDamp = 30, beamDeform = math.huge, beamStrength = math.huge, partOrigin = 'slrr_ragdoll'}
  -- bones, and a braced torso and pelvis (they don't bend in a car seat)
  for _, b in ipairs({{'head', 'neck'}, {'neck', 'chest'}, {'chest', 'pelvis'}, {'neck', 'r_sh'}, {'neck', 'l_sh'},
                      {'r_sh', 'l_sh'}, {'r_sh', 'chest'}, {'l_sh', 'chest'}, {'r_hip', 'l_hip'}, {'pelvis', 'r_hip'},
                      {'pelvis', 'l_hip'}, {'chest', 'r_hip'}, {'chest', 'l_hip'}, {'r_sh', 'r_hip'}, {'l_sh', 'l_hip'},
                      {'r_sh', 'r_el'}, {'r_el', 'r_wr'}, {'l_sh', 'l_el'}, {'l_el', 'l_wr'},
                      {'r_hip', 'r_kn'}, {'r_kn', 'r_an'}, {'l_hip', 'l_kn'}, {'l_kn', 'l_an'}}) do
    beam(ids[b[1]], ids[b[2]], BONE)
  end
  -- the head holds its posture loosely; arms and legs hang in the seated pose (limp, but not folded flat)
  for _, b in ipairs({{'head', 'r_sh'}, {'head', 'l_sh'}, {'head', 'chest'}, {'r_el', 'chest'}, {'l_el', 'chest'},
                      {'r_wr', 'r_sh'}, {'l_wr', 'l_sh'}, {'r_kn', 'pelvis'}, {'l_kn', 'pelvis'}, {'r_an', 'r_hip'},
                      {'l_an', 'l_hip'}}) do
    beam(ids[b[1]], ids[b[2]], SOFT)
  end
  -- joint limits: an elbow or knee can't fold beyond ~35 % of its straight length
  local LIMIT = {beamType = 2, beamSpring = 0, beamDamp = 2, beamLimitSpring = 150000, beamLimitDamp = 60,
                 beamShortBound = 0.45, beamLongBound = math.huge, beamDeform = math.huge, beamStrength = math.huge,
                 partOrigin = 'slrr_ragdoll'}
  for _, b in ipairs({{'r_sh', 'r_wr'}, {'l_sh', 'l_wr'}, {'r_hip', 'r_an'}, {'l_hip', 'l_an'}}) do beam(ids[b[1]], ids[b[2]], LIMIT) end
  -- seat belt: lap and sash, tension only, to the nearest car nodes (never door / latch nodes); breaks together
  local BELT = {beamType = 2, beamSpring = 0, beamDamp = 1, beamLimitSpring = 60000, beamLimitDamp = 400,
                beamShortBound = 1, beamLongBound = 0.03, beamDeform = math.huge, beamStrength = 18000,
                breakGroup = 'slrr_belt', partOrigin = 'slrr_ragdoll'}
  local function off(p, d) return J(cam, {p[1] + d[1], p[2] + d[2], p[3] + d[3]}) end
  local out = sx * (rig.arms.r.shoulder[1] > 0 and 1 or -1)
  local belts = {}
  local anchors = {
    {'r_hip', off(P.r_hip, {0.18 * out, -0.05, -0.12})}, {'l_hip', off(P.l_hip, {-0.18 * out, -0.05, -0.12})},
    {'r_sh', off(P.r_sh, {0.12 * out, -0.18, 0.10})}, {'chest', off(P.l_hip, {-0.18 * out, -0.05, -0.12})}}
  for _, a in ipairs(anchors) do
    local node, d = nearestNode(vehicle, a[2], ours)
    if node and d < 0.35 then table.insert(belts, beam(ids[a[1]], node, BELT)) end
  end
  -- the seat: pelvis and chest rest on it (soft, so he settles into it)
  local SEAT = {beamSpring = 20000, beamDamp = 200, beamDeform = math.huge, beamStrength = 25000, breakGroup = 'slrr_belt',
                partOrigin = 'slrr_ragdoll'}
  for _, a in ipairs({{'pelvis', off(P.pelvis, {0, -0.05, -0.15})}, {'chest', off(P.chest, {0, -0.2, 0})}}) do
    local node, d = nearestNode(vehicle, a[2], ours)
    if node and d < 0.4 then beam(ids[a[1]], node, SEAT) end
  end
  ragdolls[objID] = {nodes = ids, belts = #belts}
  return #belts
end

local function onJbeamLoadingPhase1(progress, objID, vehicle)
  if not (flags.props or flags.ragdoll or ragdollNext) then return end
  local ok, err = pcall(function()
    local camCid = driverCamera(vehicle)
    if not camCid or not byCid(vehicle)[camCid] then return end
    if flags.props then
      log('I', 'slrrDriverMount', 'props for ' .. tostring(objID) .. ': ' .. addProps(vehicle, camCid))
    end
    if flags.ragdoll or ragdollNext then
      ragdollNext = false
      log('I', 'slrrDriverMount', 'ragdoll for ' .. tostring(objID) .. ', belts: ' .. addRagdoll(objID, vehicle, camCid))
    end
  end)
  if not ok then log('E', 'slrrDriverMount', 'injection failed (spawn unaffected): ' .. tostring(err)) end
end

-- Ragdoll recorder (crash review): every frame, each ragdoll node in the seat frame (x right, y forward,
-- z up, from the driver camera node), and the car's speed
local recs = {}
M.onPreRender = function(dt)
  for vid, r in pairs(recs) do
    local veh = be:getObjectByID(vid)
    local rd = ragdolls[vid]
    if not (veh and rd) then recs[vid] = nil else
      local fwd = vec3(veh:getDirectionVector()):normalized()
      local up = vec3(veh:getDirectionVectorUp())
      local right = fwd:cross(up):normalized()
      up = right:cross(fwd)
      local cam = vec3(veh:getNodePositionXYZ(r.cam))
      local fr = {dt = dt, speed = vec3(veh:getVelocity()):length(), nodes = {}}
      for name, cid in pairs(rd.nodes) do
        local d = vec3(veh:getNodePositionXYZ(cid)) - cam
        fr.nodes[name] = {d:dot(right), d:dot(fwd), d:dot(up)}
      end
      table.insert(r.frames, fr)
    end
  end
end
M.startRagdollRec = function(vid)
  local cam = core_camera.getDriverDataById(vid)
  if ragdolls[vid] and cam then recs[vid] = {cam = cam, frames = {}} return true end
  return false
end
M.stopRagdollRec = function(vid, path)
  local r = recs[vid]
  recs[vid] = nil
  if not r then return 0 end
  jsonWriteFile(path, {nodes = ragdolls[vid].nodes, frames = r.frames}, false)
  return #r.frames
end

M.onJbeamLoadingPhase1 = onJbeamLoadingPhase1
M.onExtensionLoaded = function()
  local s = jsonReadFile(SETTINGS)
  if type(s) == 'table' then for k in pairs(flags) do if s[k] ~= nil then flags[k] = s[k] and true or false end end end
end
-- {props = bool, ragdoll = bool, selfCollision = bool} (saved). Applies to vehicles spawned afterwards.
M.setFlags = function(t)
  for k in pairs(flags) do if t[k] ~= nil then flags[k] = t[k] and true or false end end
  jsonWriteFile(SETTINGS, flags, true)
end
M.getFlags = function() return flags end
M.ragdollNextSpawn = function() ragdollNext = true end
M.getRagdoll = function(objID) return ragdolls[objID] end
M.onVehicleDestroyed = function(objID) ragdolls[objID] = nil end
return M
