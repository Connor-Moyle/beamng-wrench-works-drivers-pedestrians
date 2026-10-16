-- SLRR Drivers: the driver as part of the car. At every vehicle spawn (BeamNG's onJbeamLoadingPhase1 hook,
-- after node ids are assigned) this adds
--   * props: the driver's 14 parts as vehicle props (meshes <skin>_<part> from vehicles/common), so
--     the car draws them in its own render transform (exactly seat-locked, proper motion vectors);
--     slrrDrivers poses them (every car but the player's is drawn this way, W9), and in three cars in
--     ten a passenger's 14 parts too, in another skin, at the seat beside the driver;
--   * a ragdoll (prototype, behind a flag): ~16 physics nodes at the seated joints, stiff bones, joint
--     limits, soft posture beams and tension-only seat belts that break in a huge crash.
-- Nothing here breaks a spawn: any error only logs.
local M = {}

local jbeamUtils = require('jbeam/utils')

local SETTINGS = '/settings/slrr_drivers_mount.json'
-- (the props are always on since W9; an old "props" key is ignored). noCamera: props on cars without a driver
-- camera (the pooled simple traffic, their seat guessed); passengers: the passenger props. Both for bisecting a
-- crash in game: slrrDriverMount.setFlags({noCamera = false})
local flags = {ragdoll = false, selfCollision = false, noCamera = true, passengers = true}
local ragdollNext = false          -- one-shot: the next vehicle with a driver camera gets the ragdoll
local ragdolls = {}                -- objID -> {nodes = {name = cid}, belts = {cid...}}
local mounts = {}                  -- objID -> {driver = skin, passenger = skin, passengerAt = {x, y, z} (jbeam)}: what the car was given
local PASSENGER_SHARE = 0.3
-- models that never get a passenger: the Truck shop's midtruck pickup (28 props, a passenger) was the car the engine died on
-- 0.8 s after (WCUSA 2026-10-17 06:06, access violation); the cause is not found, so the second figure is refused there
local NO_PASSENGER = {midtruck = true}

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

local function driverInfo(objID)   -- the car's driver (chosen for it, else the default): model and skin
  local id = slrrDrivers and ((slrrDrivers.getDriver and objID and slrrDrivers.getDriver(objID))
    or (slrrDrivers.getDefaultDriver and slrrDrivers.getDefaultDriver())) or 'slrr_mitch'
  local d = jsonReadFile('/art/slrr_drivers/' .. id .. '/driver.json')
  return d and d.model or 'vin', d and d.skin or id
end
local function driverModel(objID) return (driverInfo(objID)) end

local function onPanel(n)
  local part = string.lower(tostring(n.partOrigin or ''))
  for _, w in ipairs(PANEL) do if part:find(w) then return true end end
  return false
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

local function hasMeshes(skin) return FS:fileExists('/vehicles/common/slrr_drivers/' .. skin .. '_body.dae') end

-- the skins with prop meshes (tools/prop_meshes.py), for the passengers
local propSkins
local function skinsWithProps()
  if propSkins then return propSkins end
  propSkins = {}
  for _, d in ipairs(slrrDrivers and slrrDrivers.getDrivers and slrrDrivers.getDrivers() or {}) do
    local info = jsonReadFile('/art/slrr_drivers/' .. d.id .. '/driver.json')
    local skin = info and info.skin or d.id
    if hasMeshes(skin) then propSkins[#propSkins + 1] = skin end
  end
  table.sort(propSkins)
  return propSkins
end

-- the seat beside the driver: his eye mirrored across the car's middle, when the car has nodes (a seat)
-- there and the driver does not sit in the middle
local function passengerCam(vehicle, cam)
  local minx, maxx = math.huge, -math.huge
  for _, n in pairs(vehicle.nodes) do
    if type(n) == 'table' and n.pos and not onPanel(n) then minx, maxx = math.min(minx, n.pos.x), math.max(maxx, n.pos.x) end
  end
  if minx > maxx then return nil end
  local p = {x = minx + maxx - cam.x, y = cam.y, z = cam.z}
  if math.abs(p.x - cam.x) < 0.5 then return nil end
  local seat = 0
  for _, n in pairs(vehicle.nodes) do
    if type(n) == 'table' and n.pos and not onPanel(n) and math.abs(n.pos.x - p.x) < 0.45 and math.abs(n.pos.y - p.y) < 0.5
       and n.pos.z > p.z - 0.9 and n.pos.z < p.z + 0.2 then seat = seat + 1 end
  end
  return seat >= 3 and p or nil
end

-- string keys on purpose: the vehicle's props.lua walks only the array part, so it never pushes its own
-- visibility over these (hiding from the GE side works) and never animates them
local function addParts(vehicle, key, skin, sp, at)
  for _, part in ipairs(PARTS) do
    vehicle.props[key .. part] = {
      mesh = skin .. '_' .. part, func = 'slrr_driver', idRef = sp.idRef, idX = sp.idX, idY = sp.idY,
      translation = {x = 0, y = 0, z = 0}, rotation = {x = 0, y = 0, z = 0},
      baseTranslationGlobal = {x = at.x, y = at.y, z = at.z},
      cid = jbeamUtils.increaseMax(vehicle, 'props'), slrrPart = part}
  end
end

-- a node reference as the jbeam phase has it: a cid, or still the node's name
local function nodeCid(vehicle, ref)
  if tonumber(ref) then return tonumber(ref) end
  for _, n in pairs(vehicle.nodes) do
    if type(n) == 'table' and n.cid and (n.name == ref or n.id == ref) then return n.cid end
  end
end

local function steeringProp(vehicle)
  for _, p in pairs(vehicle.props or {}) do
    if type(p) == 'table' and p.func == 'steering' then
      local r, x, y = nodeCid(vehicle, p.idRef), nodeCid(vehicle, p.idX), nodeCid(vehicle, p.idY)
      if r and x and y then return {idRef = r, idX = x, idY = y, baseTranslationGlobal = p.baseTranslationGlobal} end
    end
  end
end

-- the eye from the car's own extents when the wheel's hub is not in the jbeam: a third of the way across from
-- the left (jbeam +x), a little ahead of the middle, a third of a metre under the roof
local function seatFromExtents(vehicle)
  local lo, hi
  for _, n in pairs(vehicle.nodes) do
    if type(n) == 'table' and n.pos and not onPanel(n) then
      local p = vec3(n.pos)
      lo = lo and vec3(math.min(lo.x, p.x), math.min(lo.y, p.y), math.min(lo.z, p.z)) or p
      hi = hi and vec3(math.max(hi.x, p.x), math.max(hi.y, p.y), math.max(hi.z, p.z)) or p
    end
  end
  if not lo then return nil end
  return vec3(lo.x + (hi.x - lo.x) * 0.7, lo.y + (hi.y - lo.y) * 0.45, hi.z - 0.33)
end

-- a car with no driver camera (the pooled simple traffic): the eye is where a driver sits behind the steering
-- wheel's hub (slrrDrivers' WHEEL_CENTER: the wheel 0.56 m ahead of and 0.30 m below the eyes), kept as an
-- offset from the nearest car node so slrrDrivers can follow it
local function seatGuess(vehicle, sp)
  local hub = sp and sp.baseTranslationGlobal
  local cam = hub and tonumber(hub.x) and tonumber(hub.y) and tonumber(hub.z) and vec3(hub.x, hub.y + 0.56, hub.z + 0.30) or seatFromExtents(vehicle)
  if not cam then return nil end
  local cid = nearestNode(vehicle, cam, {})
  local n = cid and byCid(vehicle)[cid]
  if not n then return nil end
  local p = vec3(n.pos)
  return cam, {node = cid, offset = {x = cam.x - p.x, y = cam.y - p.y, z = cam.z - p.z}}
end

local function addProps(objID, vehicle, camCid)
  -- meshes per skin, with the skin's material named in the dae (tools/prop_meshes.py): a material override
  -- on a prop at runtime crashes the engine
  local _, skin = driverInfo(objID)
  if not hasMeshes(skin) then log('W', 'slrrDriverMount', objID .. ': no prop meshes for skin ' .. tostring(skin)) return 0 end
  local sp = steeringProp(vehicle)
  if not sp then log('W', 'slrrDriverMount', objID .. ': no steering prop with three nodes, no props') return 0 end
  local cam, seat = camCid and byCid(vehicle)[camCid].pos or nil, nil
  if not cam and not flags.noCamera then log('I', 'slrrDriverMount', objID .. ': no driver camera and noCamera is off, no props') return 0 end
  if not cam then cam, seat = seatGuess(vehicle, sp) end
  if not cam then log('W', 'slrrDriverMount', objID .. ': no driver camera and no seat could be guessed, no props') return 0 end
  vehicle.props = vehicle.props or {}
  addParts(vehicle, 'slrr_driver_', skin, sp, cam)
  local mount = {driver = skin, seat = seat}
  -- a passenger in some cars (W9), in another skin
  local wantPassenger = flags.passengers and objID % 100 < PASSENGER_SHARE * 100
  local model = tostring(vehicle.vehicleDirectory or vehicle.model or ''):match('([%w_]+)/?$')
  if wantPassenger and model and NO_PASSENGER[model] then
    log('I', 'slrrDriverMount', objID .. ': no passenger in a ' .. model)
    wantPassenger = false
  end
  local pcam = wantPassenger and passengerCam(vehicle, cam)
  local skins = pcam and skinsWithProps() or {}
  if #skins > 1 then
    local other = skins[objID % #skins + 1]
    if other == skin then other = skins[(objID + 1) % #skins + 1] end
    addParts(vehicle, 'slrr_pass_', other, sp, pcam)
    mount.passenger, mount.passengerAt = other, {x = pcam.x, y = pcam.y, z = pcam.z}
  end
  mounts[objID] = mount
  return #PARTS + (mount.passenger and #PARTS or 0)
end


local function addRagdoll(objID, vehicle, camCid)
  local rig = jsonReadFile('/art/slrr_drivers/models/' .. driverModel(objID) .. '/rig.json')
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

-- The career's own cars nobody drives with AI (a lot's display cars, the player's fleet) are spawned after
-- noPropsNext(): the next vehicle to load, and every rebuild of it, gets no props at all (the player's driver is a full one,
-- not a prop). Armed for 5 s; whatever loads first takes it.
local skipUntil, noProps = 0, {}
M.noPropsNext = function() skipUntil = os.clock() + 5 end

local function onJbeamLoadingPhase1(progress, objID, vehicle)
  if not noProps[objID] and os.clock() < skipUntil then skipUntil = 0 noProps[objID] = true end
  if noProps[objID] then log('I', 'slrrDriverMount', 'no props for ' .. tostring(objID) .. ': a car nobody drives') return end
  local ok, err = pcall(function()
    local camCid = driverCamera(vehicle)
    if camCid and not byCid(vehicle)[camCid] then camCid = nil end
    log('I', 'slrrDriverMount', 'props for ' .. tostring(objID) .. ': ' .. addProps(objID, vehicle, camCid))   -- (no camera: a seat guessed from the wheel)
    if not camCid then return end
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
-- {ragdoll = bool, selfCollision = bool} (saved). Applies to vehicles spawned afterwards.
M.setFlags = function(t)
  for k in pairs(flags) do if t[k] ~= nil then flags[k] = t[k] and true or false end end
  jsonWriteFile(SETTINGS, flags, true)
end
M.getFlags = function() return flags end
M.getMount = function(objID) return mounts[objID] end   -- {driver = skin, passenger = skin, passengerAt} for slrrDrivers
M.ragdollNextSpawn = function() ragdollNext = true end
M.getRagdoll = function(objID) return ragdolls[objID] end
M.onVehicleDestroyed = function(objID) ragdolls[objID] = nil mounts[objID] = nil noProps[objID] = nil end
return M
