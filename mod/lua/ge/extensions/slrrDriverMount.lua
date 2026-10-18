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
-- driverRig: 'props' (default: rigid prop parts posed by slrrDrivers) or 'flex' (stage A of the rework: ragdoll nodes with
-- the driver's mesh as flexbodies bound to them; docs/DRIVER_REWORK.md). Only cars with a driver camera get the flex
-- driver; any other car keeps the props. optOut: model names (or objIDs) that never get it.
local driverRig = 'props'
local optOut = {}
-- which nodes the flexbodies bind to (setFlexBind): 'near' (default) = the 3-5 joint nodes around each part, 'all' = all 16 joint nodes for every
-- part (fine at rest, but a mesh's frame then follows moving limb nodes: the animated driver vanished), 'car' = the six car nodes nearest the seat
local flexBind = 'near'
local ragdollNext = false          -- one-shot: the next vehicle with a driver camera gets the ragdoll
local alphaDue = {}              -- objID -> seconds until the flexbodies are made visible (they start invisible)
local headHidden = {}          -- objID -> true while its head mesh is hidden (first person)
local flexSkin = {}            -- objID -> the skin its flex driver was built with
local checkedCar, checkAt
local switchedAt = -10          -- os.clock() of the last vehicle switch
local flexScale = {}           -- objID -> the size its flex driver was built at (setAppearance scale)
local flexMeshes = {}          -- objID -> mesh names of its flexbodies
local flex = {}                  -- objID -> flexbody count, for cars given the flex driver
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
-- avoid / allow: names (plain text, lower case) looked for in the node's part and name: none of avoid may occur, one of allow must
-- (when given). Returns the cid, the distance and the node.
local function nearestNode(vehicle, p, skip, avoid, allow)
  local best, bd, bn
  for _, n in pairs(vehicle.nodes) do
    if type(n) == 'table' and n.cid and n.pos and not skip[n.cid] and not onPanel(n) then
      local text = string.lower(tostring(n.partOrigin or '') .. ' ' .. tostring(n.name or ''))
      local ok = not allow
      for _, w in ipairs(allow or {}) do if text:find(w, 1, true) then ok = true end end
      for _, w in ipairs(avoid or {}) do if text:find(w, 1, true) then ok = false end end
      if ok then
        local d = vec3(n.pos):distance(p)
        if not bd or d < bd then best, bd, bn = n.cid, d, n end
      end
    end
  end
  return best, bd, bn
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

-- passengerOnly: a flex driver is drawn by flexbodies; the passenger (if the car gets one) is still the props figure
local function addProps(objID, vehicle, camCid, passengerOnly)
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
  if not passengerOnly then addParts(vehicle, 'slrr_driver_', skin, sp, cam) end
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
  return (passengerOnly and 0 or #PARTS) + (mount.passenger and #PARTS or 0)
end


M.driverMass = 69   -- kg: the sum of KG in addRagdoll, all of it in the seat (head to ankles), none added elsewhere
local function HAND_NODE(rig, side, thumb)
  local w = rig.arms[side].wrist
  local f = rig.fistMean and rig.fistMean[side] or rig.fist and rig.fist[side] or {0, 0.06, 0}   -- (the mesh's middle, not the hole of the grip)
  -- (the thumb node on the other side of the wrist from the fist, so the three nodes make a wide triangle: a left hand's fist is on the +x side)
  if thumb then return {w[1] + (f[1] > 0 and -0.10 or 0.10), w[2], w[3]} end
  return {w[1] + f[1] * 1.5, w[2] + f[2] * 1.5, w[3] + f[3] * 1.5}
end
local function addRagdoll(objID, vehicle, camCid, k)
  local rig = jsonReadFile('/art/slrr_drivers/models/' .. driverModel(objID) .. '/rig.json')
  if not rig then return 0 end
  local cam = vec3(byCid(vehicle)[camCid].pos)
  local sx = 1                                   -- seat frame x is right
  local sh, hp = rig.arms.r.shoulder, rig.legs.r.hip
  local P = {
    head = {rig.parts.head[1], rig.parts.head[2] + 0.04, rig.parts.head[3] + 0.12}, neck = rig.parts.head,
    face = {rig.parts.head[1], rig.parts.head[2] + 0.14, rig.parts.head[3] + 0.12},   -- ahead of the head: gives the head a facing, so it can turn
    chest = {0, (sh[2] + rig.pelvis[2]) / 2, (sh[3] + rig.pelvis[3]) / 2 + 0.05}, pelvis = rig.pelvis,
    r_sh = rig.arms.r.shoulder, l_sh = rig.arms.l.shoulder, r_el = rig.arms.r.elbow, l_el = rig.arms.l.elbow,
    r_wr = rig.arms.r.wrist, l_wr = rig.arms.l.wrist,
    -- two nodes round each wrist (the knuckles and the thumb side): one wrist node cannot say which way the palm faces
    r_hk = HAND_NODE(rig, 'r', false), l_hk = HAND_NODE(rig, 'l', false), r_ht = HAND_NODE(rig, 'r', true), l_ht = HAND_NODE(rig, 'l', true), r_hip = rig.legs.r.hip, l_hip = rig.legs.l.hip,
    r_kn = rig.legs.r.knee, l_kn = rig.legs.l.knee, r_an = rig.legs.r.ankle, l_an = rig.legs.l.ankle}
  if k ~= 1 then   -- a body of another size (setAppearance scale): every joint about the eye
    local Q = {}
    for name, p in pairs(P) do Q[name] = {p[1] * k, p[2] * k, p[3] * k} end
    P = Q
  end
  local KG = {head = 4.5, face = 1.0, neck = 1.5, chest = 12, pelvis = 8, r_hk = 1, l_hk = 1, r_ht = 1, l_ht = 1, r_sh = 4, l_sh = 4, r_el = 2, l_el = 2, r_wr = 1, l_wr = 1,
              r_hip = 6, l_hip = 6, r_kn = 4, l_kn = 4, r_an = 2, l_an = 2}
  local ids, ours = {}, {}
  for name, p in pairs(P) do
    local cid = jbeamUtils.addNodeWithOptions(vehicle, J(cam, p), 0, {
      nodeWeight = KG[name], collision = true, selfCollision = flags.selfCollision, frictionCoef = 0.8,
      group = {'slrr_ragdoll', 'slrr_rd_' .. name}, partOrigin = 'slrr_ragdoll', name = 'slrr_rd_' .. name})
    ids[name], ours[cid] = cid, true
  end
  local seen = {}   -- one beam per pair of nodes (the loader warns about duplicates)
  local function beam(a, b, opts)
    local key = math.min(a, b) .. ':' .. math.max(a, b)
    if seen[key] then return nil end
    seen[key] = true
    return jbeamUtils.addBeamWithOptions(vehicle, a, b, opts.beamType or 0, opts)
  end
  local BONE = {beamSpring = 400000, beamDamp = 60, beamDeform = math.huge, beamStrength = math.huge, partOrigin = 'slrr_ragdoll'}
  local SOFT = {beamSpring = 3000, beamDamp = 30, beamDeform = math.huge, beamStrength = math.huge, partOrigin = 'slrr_ragdoll'}
  -- bones, and a braced torso and pelvis (they don't bend in a car seat)
  for _, b in ipairs({{'r_wr', 'r_hk'}, {'r_wr', 'r_ht'}, {'r_hk', 'r_ht'}, {'l_wr', 'l_hk'}, {'l_wr', 'l_ht'}, {'l_hk', 'l_ht'}, {'head', 'neck'}, {'head', 'face'}, {'neck', 'face'}, {'neck', 'chest'}, {'chest', 'pelvis'}, {'neck', 'r_sh'}, {'neck', 'l_sh'},
                      {'r_sh', 'l_sh'}, {'r_sh', 'chest'}, {'l_sh', 'chest'}, {'r_hip', 'l_hip'}, {'pelvis', 'r_hip'},
                      {'pelvis', 'l_hip'}, {'chest', 'r_hip'}, {'chest', 'l_hip'}, {'r_sh', 'r_hip'}, {'l_sh', 'l_hip'},
                      {'r_sh', 'r_el'}, {'r_el', 'r_wr'}, {'l_sh', 'l_el'}, {'l_el', 'l_wr'},
                      {'r_hip', 'r_kn'}, {'r_kn', 'r_an'}, {'l_hip', 'l_kn'}, {'l_kn', 'l_an'}}) do
    beam(ids[b[1]], ids[b[2]], BONE)
  end
  -- flex driver: hold the seated pose. Every limb joint and the head is tied to its four nearest torso nodes by stiff
  -- beams (a rigid truss, so arms do not hang limp: in game the wrists fell 0.5 m below the wheel).
  -- Made before the soft beams so those do not take the pairs (one beam per pair): the head and knees stay driven
  if driverRig == 'flex' then
    local STIFF = {beamSpring = 150000, beamDamp = 300, beamDeform = math.huge, beamStrength = math.huge, partOrigin = 'slrr_ragdoll'}
    local TORSO = {'neck', 'chest', 'pelvis', 'r_sh', 'l_sh', 'r_hip', 'l_hip'}
    for _, j in ipairs({'head', 'face', 'r_hk', 'r_ht', 'l_hk', 'l_ht', 'r_el', 'l_el', 'r_wr', 'l_wr', 'r_kn', 'l_kn', 'r_an', 'l_an'}) do
      local near = {}
      for _, t in ipairs(TORSO) do
        near[#near + 1] = {t, math.sqrt((P[j][1] - P[t][1]) ^ 2 + (P[j][2] - P[t][2]) ^ 2 + (P[j][3] - P[t][3]) ^ 2)}
      end
      table.sort(near, function(x, y) return x[2] < y[2] end)
      for i = 1, 4 do beam(ids[j], ids[near[i][1]], STIFF) end
    end
    -- the torso nodes all lie in one plane (the body is flat from the side), so a hand or foot half a metre ahead of it has two
    -- places that fit its four beam lengths, in front of the plane and a mirror image behind it (in game: wrists behind the
    -- shoulders, 0.6 m off). Two car nodes ahead of the joint, within 0.12 to 0.8 m of its place, settle which one: stiff beams
    -- to them, the same sort of hold (slrrDriverFeed sets their lengths too)
    local anchored = {}
    local CARHOLD = {beamSpring = 20000, beamDamp = 60, beamDeform = math.huge, beamStrength = math.huge, partOrigin = 'slrr_ragdoll'}   -- (soft: 150000 cracked the car's windscreen and dash)
    for _, j in ipairs({'r_wr', 'l_wr', 'r_kn', 'l_kn', 'r_an', 'l_an'}) do
      local skip, got = {}, 0
      for cid in pairs(ours) do skip[cid] = true end
      for _ = 1, 8 do
        if got >= 2 then break end
        -- only the steering column and wheel and the seat and floor: never body panels, dash, glass, mirrors, wipers, roof
        local node, d, nd = nearestNode(vehicle, J(cam, P[j]), skip, {'glass', 'window', 'windshield', 'mirror', 'wiper', 'roof', 'dash'}, {'steer', 'seat', 'floor'})
        if not node or d > 0.8 then break end
        skip[node] = true
        if d >= 0.12 then
          beam(ids[j], node, CARHOLD) got = got + 1
          log('I', 'slrrDriverMount', string.format('  hold %s -> node %s (%s, part %s) %.2f m', j, tostring(node), tostring(nd.name), tostring(nd.partOrigin), d))
        end
      end
      anchored[#anchored + 1] = j .. ' ' .. got
    end
    log('I', 'slrrDriverMount', 'car-node holds for ' .. tostring(objID) .. ': ' .. table.concat(anchored, ', '))
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
  -- flex driver: three seat nodes each within 0.7 m (a big cab has no node within 0.4 m of the spot: the body hung from its belts
  -- and sank 0.4 m in a pickup), stiffer; the spring sag under 69 kg is then a few millimetres
  local SEATS, REACH = 1, 0.4
  if driverRig == 'flex' then SEATS, REACH, SEAT = 3, 0.7, {beamSpring = 60000, beamDamp = 1500, beamDeform = math.huge, beamStrength = 60000, breakGroup = 'slrr_belt', partOrigin = 'slrr_ragdoll'} end
  local seated = {}
  for _, a in ipairs({{'pelvis', off(P.pelvis, {0, -0.05, -0.15})}, {'chest', off(P.chest, {0, -0.2, 0})}}) do
    local skip = {}
    for cid in pairs(ours) do skip[cid] = true end
    for i = 1, SEATS do
      local node, d = nearestNode(vehicle, a[2], skip)
      if node and d < REACH then
        beam(ids[a[1]], node, SEAT)
        seated[#seated + 1] = string.format('%s %.2f', a[1], d)
        skip[node] = true
      end
    end
  end
  log('I', 'slrrDriverMount', 'seat beams for ' .. tostring(objID) .. ': ' .. (#seated > 0 and table.concat(seated, ', ') or 'none'))
  ragdolls[objID] = {nodes = ids, belts = #belts, cam = camCid, rest = P}
  return #belts, P
end

-- the 14 body parts as flexbodies, each bound to the joint nodes around it (three, so its orientation is defined).
-- Mesh origins are the joints (tools/prop_meshes.py), so pos is the joint's place in jbeam space; the meshes are in the
-- seat frame (x right, y forward), jbeam is x left, y back: a half turn about z.
-- (the arms carry the chest too: shoulder, elbow and wrist in a line, a straight arm, give the engine no plane to build the
-- mesh's frame from, and the arm vanished)
local BIND = {
  body = {'chest', 'r_hip', 'l_hip', 'r_sh', 'l_sh'}, head = {'head', 'neck', 'face'},
  r_upperarm = {'r_sh', 'r_el', 'chest'}, r_forearm = {'r_el', 'r_wr', 'r_sh', 'chest'}, r_hand = {'r_wr', 'r_hk', 'r_ht'},
  l_upperarm = {'l_sh', 'l_el', 'chest'}, l_forearm = {'l_el', 'l_wr', 'l_sh', 'chest'}, l_hand = {'l_wr', 'l_hk', 'l_ht'},
  r_thigh = {'r_hip', 'r_kn', 'r_an'}, r_calf = {'r_kn', 'r_an', 'r_hip'}, r_foot = {'r_an', 'r_kn', 'r_hip'},
  l_thigh = {'l_hip', 'l_kn', 'l_an'}, l_calf = {'l_kn', 'l_an', 'l_hip'}, l_foot = {'l_an', 'l_kn', 'l_hip'}}
local ORIGIN = {body = 'eye', head = 'neck', r_upperarm = 'r_sh', r_forearm = 'r_el', r_hand = 'r_wr', l_upperarm = 'l_sh',
                l_forearm = 'l_el', l_hand = 'l_wr', r_thigh = 'r_hip', r_calf = 'r_kn', r_foot = 'r_an',
                l_thigh = 'l_hip', l_calf = 'l_kn', l_foot = 'l_an'}

local ALL = {'r_hk', 'r_ht', 'l_hk', 'l_ht', 'head', 'face', 'neck', 'chest', 'pelvis', 'r_sh', 'l_sh', 'r_el', 'l_el', 'r_wr', 'l_wr', 'r_hip', 'l_hip', 'r_kn', 'l_kn', 'r_an', 'l_an'}

-- tag the car's own nodes nearest the seat with a group and return its name (flexBind 'car')
local function tagSeatNodes(vehicle, cam)
  local near = {}
  for _, n in pairs(vehicle.nodes) do
    if type(n) == 'table' and n.cid and n.pos and n.partOrigin ~= 'slrr_ragdoll' and not onPanel(n) then
      near[#near + 1] = {n = n, d = vec3(n.pos):distance(cam)}
    end
  end
  table.sort(near, function(a, b) return a.d < b.d end)
  for i = 1, math.min(6, #near) do
    local n, g = near[i].n, near[i].n.group
    if type(g) == 'string' then n.group = {g, 'slrr_fx_car'}
    elseif type(g) == 'table' then table.insert(g, 'slrr_fx_car')
    else n.group = {'slrr_fx_car'} end
  end
  return 'slrr_fx_car'
end

local function addFlexbodies(objID, vehicle, cam, P, skin, k, helmet)
  if not hasMeshes(skin) then log('W', 'slrrDriverMount', objID .. ': no meshes for skin ' .. tostring(skin) .. ', no flexbodies') return 0 end
  vehicle.flexbodies = vehicle.flexbodies or {}
  flexMeshes[objID] = {}
  local carGroup = flexBind == 'car' and tagSeatNodes(vehicle, cam) or nil
  local n = 0
  local parts = {}
  for _, part in ipairs(PARTS) do parts[#parts + 1] = part end
  if helmet then parts[#parts + 1] = 'helmet' end   -- bound like the head, same pivot
  for _, part in ipairs(parts) do
    local isHelmet = part == 'helmet'
    local mesh = isHelmet and helmet or skin .. '_' .. part
    -- (the hands of a rigged HD driver: the plain-fist meshes (..._handf), which the three nodes round each wrist were fitted to; the props use the gripping ones)
    if (part == 'r_hand' or part == 'l_hand') and FS:fileExists('/vehicles/common/slrr_drivers/' .. mesh .. 'f.dae') then mesh = mesh .. 'f' end
    local at = ORIGIN[part] == 'eye' and vec3(cam.x, cam.y, cam.z) or J(cam, P[ORIGIN[isHelmet and 'head' or part]])
    local groups = {}
    if flexBind == 'car' then groups = {carGroup}
    else
      for _, j in ipairs(flexBind == 'all' and ALL or BIND[isHelmet and 'head' or part]) do groups[#groups + 1] = 'slrr_rd_' .. j end
    end
    log('I', 'slrrDriverMount', string.format('  flexbody %s at jbeam (%.3f %.3f %.3f), seat node (%.3f %.3f %.3f), bound to %s', part, at.x, at.y, at.z, cam.x, cam.y, cam.z, table.concat(groups, ',')))
    flexMeshes[objID] = flexMeshes[objID] or {}
    if isHelmet then flexMeshes[objID].helmet = mesh else table.insert(flexMeshes[objID], mesh) end
    table.insert(vehicle.flexbodies, {
      mesh = mesh, pos = {x = at.x, y = at.y, z = at.z}, rot = {x = 0, y = 0, z = 180}, scale = {x = k, y = k, z = k},
      ['[group]:nodes'] = groups, partOrigin = 'slrr_driver'})
    n = n + 1
  end
  return n
end

-- The career's own cars nobody drives with AI (a lot's display cars, the player's fleet) are spawned after
-- noPropsNext(): the next vehicle to load, and every rebuild of it, gets no props at all (the player's driver is a full one,
-- not a prop). The spawner clears it with noPropsDone() when the spawn call returns (the hook runs inside the call), so a
-- traffic car loading later keeps its props; 5 s is only the backstop.
local skipUntil, noProps = 0, {}
M.noPropsNext = function() skipUntil = os.clock() + 5 end
M.noPropsDone = function() skipUntil = 0 end

-- The rigged driver is for the player's car only (traffic, parked and AI cars always get the props: the rig costs physics nodes and flexbodies
-- per car). A car is the player's when it spawns to be entered (autoEnterVehicle), when the career says so (playerCarNext, like noPropsNext
-- for the cars nobody drives: a spawn it will drive itself), or when it is the car he is in being rebuilt (a part change). Never a guess made
-- later: a swap into a traffic car keeps its props until it is respawned, and nothing respawns a car mid-drive.
local playerUntil, playerCars = 0, {}
M.playerCarNext = function() playerUntil = os.clock() + 5 end
M.playerCarDone = function() playerUntil = 0 end
local function playerBound(objID)
  if playerCars[objID] then return true end
  local obj = be and be.getObjectByID and be:getObjectByID(objID)
  local enters = obj and obj.getDynDataFieldbyName and obj:getDynDataFieldbyName('autoEnterVehicle', 0) == 'true'
  local told = os.clock() < playerUntil
  if told then playerUntil = 0 end
  if enters or told then playerCars[objID] = true return true end
  return be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) == objID or false
end

local function onJbeamLoadingPhase1(progress, objID, vehicle)
  if not noProps[objID] and os.clock() < skipUntil then skipUntil = 0 noProps[objID] = true end
  if noProps[objID] then log('I', 'slrrDriverMount', 'no props for ' .. tostring(objID) .. ': a car nobody drives') return end
  local ok, err = pcall(function()
    local camCid = driverCamera(vehicle)
    if camCid and not byCid(vehicle)[camCid] then camCid = nil end
    local model
    if driverRig == 'flex' then   -- (the model name is only needed to opt a car out)
      local obj = be:getObjectByID(objID)
      model = obj and obj:getJBeamFilename() or tostring(vehicle.vehicleDirectory or vehicle.model or ''):match('([%w_]+)/?$')
    end
    local mine = driverRig == 'flex' and playerBound(objID)
    local wantFlex = mine and camCid and not optOut[objID] and not (model and optOut[model])
    if driverRig == 'flex' and not mine then
      log('I', 'slrrDriverMount', tostring(objID) .. ' (' .. tostring(model) .. '): props (the rigged driver is for the player car only)')
    elseif driverRig == 'flex' and not wantFlex then
      log('W', 'slrrDriverMount', tostring(objID) .. ' (' .. tostring(model) .. '): no flex driver (' .. (camCid and 'opted out' or 'no seat found') .. '), props')
    end
    -- (no camera: a seat guessed from the wheel)
    log('I', 'slrrDriverMount', (wantFlex and 'passenger props' or 'props') .. ' for ' .. tostring(objID) .. ': ' .. addProps(objID, vehicle, camCid, wantFlex))
    if not camCid then return end
    if wantFlex or flags.ragdoll or ragdollNext then
      ragdollNext = false
      local look = wantFlex and slrrDrivers and slrrDrivers.getAppearance and slrrDrivers.getAppearance(objID) or {}
      local k = math.max(0.9, math.min(1.1, tonumber(look.scale) or 1))
      if wantFlex then flexScale[objID] = k end
      local t0 = os.clock()
      local belts, P = addRagdoll(objID, vehicle, camCid, k)
      log('I', 'slrrDriverMount', 'ragdoll for ' .. tostring(objID) .. ', belts: ' .. tostring(belts))
      if wantFlex and P then
        local dmodel, skin = driverInfo(objID)
        local hm = 'slrr_' .. tostring(dmodel) .. '_helmet'   -- (only the models with a helmet shape: police, vin)
        local helmet = look.helmet and FS:fileExists('/vehicles/common/slrr_drivers/' .. hm .. '.dae') and hm or nil
        alphaDue[objID] = 0.3
        flexSkin[objID] = skin
        flex[objID] = addFlexbodies(objID, vehicle, vec3(byCid(vehicle)[camCid].pos), P, skin, k, helmet)
        log('I', 'slrrDriverMount', 'flex driver for ' .. tostring(objID) .. ' (' .. tostring(model) .. '): ' .. flex[objID] .. ' flexbodies, 16 nodes, ' .. M.driverMass .. ' kg at the seat, built in ' .. string.format('%.0f', (os.clock() - t0) * 1000) .. ' ms')
      end
    end
  end)
  if not ok then log('E', 'slrrDriverMount', 'injection failed (spawn unaffected): ' .. tostring(err)) end
end

-- Ragdoll recorder (crash review): every frame, each ragdoll node in the seat frame (x right, y forward,
-- z up, from the driver camera node), and the car's speed
local recs = {}
-- every flex mesh of a car shown (a mesh whose material was switched is made visible again): how many the engine knew
M.showFlex = function(vid)
  local veh, shown = be:getObjectByID(vid), 0
  if not veh then return 0 end
  for _, name in ipairs(flexMeshes[vid] or {}) do if veh:setMeshAlpha(1, name, false) then shown = shown + 1 end end
  if flexMeshes[vid] and flexMeshes[vid].helmet and veh:setMeshAlpha(1, flexMeshes[vid].helmet, false) then shown = shown + 1 end
  return shown
end
-- cost probe: every flex mesh of a car (or only the ones whose name contains `only`) drawn at this alpha (0 hides them; timing the frame with and without says what the meshes cost)
M.setFlexAlpha = function(vid, alpha, only)
  local veh, n = be:getObjectByID(vid), 0
  if not veh then return 0 end
  headHidden[vid] = nil   -- (the head's state is unknown after this: the next frame sets it again)
  for _, name in ipairs(flexMeshes[vid] or {}) do if (not only or name:find(only, 1, true)) and veh:setMeshAlpha(alpha, name, false) then n = n + 1 end end
  return n
end
M.flexShown = function(vid) return flex[vid] ~= nil and alphaDue[vid] == nil end   -- (made visible once already)
M.setPassengerShare = function(share) PASSENGER_SHARE = math.max(0, math.min(1, tonumber(share) or PASSENGER_SHARE)) end   -- (not saved: 1 gives every car a passenger, for testing)
M.getFlexSkin = function(vid) return flexSkin[vid] end
M.onPreRender = function(dt)
  -- a player car that three seconds on has no driver mount: the jbeam hook did not run for it (seen once in a long session: say so in the log)
  local pv = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
  if pv ~= checkedCar then checkedCar, checkAt = pv, os.clock() + 3 end
  if checkAt and os.clock() >= checkAt then
    checkAt = nil
    local o = pv and be:getObjectByID(pv)
    if o and not mounts[pv] and not noProps[pv] and not (o.getJBeamFilename and o:getJBeamFilename() == 'unicycle') then
      log('W', 'slrrDriverMount', 'the player car ' .. tostring(pv) .. ' has no driver mount: the jbeam hook did not run for it (rig ' .. driverRig .. ')')
    end
  end
  -- injected flexbodies come up invisible (found in game: visible only after veh:setMeshAlpha(1, mesh) had been called, which
  -- flexReport and dumpFlex did): make them visible once the car exists in the engine
  for vid, t in pairs(alphaDue) do
    local veh = be:getObjectByID(vid)
    if not veh or not flex[vid] then alphaDue[vid] = nil
    elseif t > dt then alphaDue[vid] = t - dt
    else
      alphaDue[vid] = nil
      headHidden[vid] = nil
      -- dumpFlex and flexReport (what made the driver appear in game) both read the vehicle data first: do that too
      core_vehicle_manager.getVehicleData(vid)
      local shown = M.showFlex(vid)
      log('I', 'slrrDriverMount', 'flex meshes made visible for ' .. tostring(vid) .. ': ' .. shown .. ' of ' .. #(flexMeshes[vid] or {}))
    end
  end
  -- the head is not drawn from inside it: in the driver's own camera (as slrrDrivers does for its figure)
  -- (not within half a second of a vehicle switch: the engine is busy handing the player over, the crash of 2026-10-18 06:16 came
  -- in such a moment, with flex cars about)
  local fpVid = next(flex) and os.clock() - switchedAt > 0.5 and core_camera and core_camera.getActiveCamName(0) == 'driver' and be:getPlayerVehicleID(0) or nil
  for vid in pairs(flex) do
    local hide = vid == fpVid
    if headHidden[vid] ~= hide then
      local veh = be:getObjectByID(vid)
      local fm = flexMeshes[vid] or {}
      local done = veh and fm[2] and veh:setMeshAlpha(hide and 0 or 1, fm[2], false)
      if done and fm.helmet then done = veh:setMeshAlpha(hide and 0 or 1, fm.helmet, false) end
      if done then headHidden[vid] = hide end
    end
  end
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
      local c = slrrDrivers and slrrDrivers.getState and slrrDrivers.getState(vid)   -- what the flex driver was told (JOINTS order)
      if c and c.sent then
        fr.targets = {}
        for i, p in ipairs(c.sent) do fr.targets[i] = {p.x, p.y, p.z} end
      end
      table.insert(r.frames, fr)
    end
  end
end
M.startRagdollRec = function(vid)
  local cam = ragdolls[vid] and ragdolls[vid].cam or core_camera.getDriverDataById(vid)
  if ragdolls[vid] and cam then recs[vid] = {cam = cam, frames = {}} return true end
  log('W', 'slrrDriverMount', 'startRagdollRec: no ragdoll for ' .. tostring(vid))
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
  if type(s) == 'table' then
    for k in pairs(flags) do if s[k] ~= nil then flags[k] = s[k] and true or false end end
    -- (a saved driverRig is ignored: the rigged driver stays a per-session choice until it is stable)
  end
end
-- {ragdoll = bool, selfCollision = bool} (saved). Applies to vehicles spawned afterwards.
M.setFlags = function(t)
  for k in pairs(flags) do if t[k] ~= nil then flags[k] = t[k] and true or false end end
  local t = {}
  for k, v in pairs(flags) do t[k] = v end
  jsonWriteFile(SETTINGS, t, true)
end
M.getFlags = function() return flags end
M.getMount = function(objID) return mounts[objID] end   -- {driver = skin, passenger = skin, passengerAt} for slrrDrivers
M.ragdollNextSpawn = function() ragdollNext = true end
M.setDriverRig = function(mode)   -- this session only (not saved); applies to cars spawned afterwards
  if mode == 'props' or mode == 'flex' then driverRig = mode end
end
M.getDriverRig = function() return driverRig end
-- writes at once (no log buffering): where the ragdoll nodes are now (seat frame), what slrrDrivers asked of them, the wheel
M.flexSnapshot = function(objID, path)
  local rd, c = ragdolls[objID], slrrDrivers and slrrDrivers.getState and slrrDrivers.getState(objID)
  local veh = be:getObjectByID(objID)
  if not (rd and veh) then return false end
  local fwd = vec3(veh:getDirectionVector()):normalized()
  local up = vec3(veh:getDirectionVectorUp())
  local right = fwd:cross(up):normalized()
  up = right:cross(fwd)
  local cam = vec3(veh:getNodePositionXYZ(rd.cam))
  local out = {nodes = {}, targets = {}, rest = rd.rest, speed = vec3(veh:getVelocity()):length(),
               axes = {fwd = {fwd.x, fwd.y, fwd.z}, up = {up.x, up.y, up.z}}}   -- (rest: where the nodes were put, seat frame; axes: the car's, world)
  for name, cid in pairs(rd.nodes) do
    local d = vec3(veh:getNodePositionXYZ(cid)) - cam
    out.nodes[name] = {d:dot(right), d:dot(fwd), d:dot(up)}
  end
  if c and c.sent then for i, p in ipairs(c.sent) do out.targets[i] = {p.x, p.y, p.z} end end
  if c and c.wheelAt then out.wheel = {c.wheelAt.x, c.wheelAt.y, c.wheelAt.z} end
  if c and c.lastGrips then out.grips = {r = c.lastGrips.r and c.lastGrips.r.a, l = c.lastGrips.l and c.lastGrips.l.a} end
  jsonWriteFile(path, out, true)
  return true
end
-- where each ragdoll node is now, in the seat frame (x right, y forward, z up, from the driver camera node): to see whether
-- the skeleton holds its seated shape or collapses
M.ragdollPositions = function(objID)
  local veh, rd, cam = be:getObjectByID(objID), ragdolls[objID], core_camera.getDriverDataById(objID)
  if not (veh and rd and cam) then log('W', 'slrrDriverMount', 'ragdollPositions: no ragdoll / camera for ' .. tostring(objID)) return end
  local fwd = vec3(veh:getDirectionVector()):normalized()
  local up = vec3(veh:getDirectionVectorUp())
  local right = fwd:cross(up):normalized()
  up = right:cross(fwd)
  local c = vec3(veh:getNodePositionXYZ(cam))
  local t = {}
  for name, cid in pairs(rd.nodes) do
    local d = vec3(veh:getNodePositionXYZ(cid)) - c
    t[#t + 1] = string.format('%s (%.2f %.2f %.2f)', name, d:dot(right), d:dot(fwd), d:dot(up))
  end
  table.sort(t)
  log('I', 'slrrDriverMount', 'ragdoll nodes for ' .. tostring(objID) .. ': ' .. table.concat(t, ', '))
end
-- every field of two flexbody records as the loader holds them after the spawn: a stock one (the car's body) and ours,
-- to compare (node lists shown as counts)
M.dumpFlex = function(objID)
  local vd = core_vehicle_manager.getVehicleData(objID)
  local fbs = vd and vd.vdata and vd.vdata.flexbodies or {}
  local function show(tag, f)
    local t = {}
    for k, v in pairs(f) do
      t[#t + 1] = tostring(k) .. '=' .. (type(v) == 'table' and (k == '_group_nodes' and ('#' .. #v) or dumps(v):gsub('%s+', ' ')) or tostring(v))
    end
    table.sort(t)
    log('I', 'slrrDriverMount', tag .. ': ' .. table.concat(t, ' | '))
  end
  local stock, ours, total = nil, nil, 0
  for _, f in pairs(fbs) do
    if type(f) == 'table' then
      total = total + 1
      if f.partOrigin == 'slrr_driver' then ours = ours or f elseif not stock and f.pos then stock = f end
    end
  end
  log('I', 'slrrDriverMount', 'flexbodies in the loader: ' .. total)
  if stock then show('stock', stock) end
  if ours then show('ours', ours) end
end
-- what the engine made of the flexbodies (run after the spawn): per mesh, whether the vehicle knows the mesh name
-- (setMeshAlpha answers true only for a mesh it has; it also forces alpha 1) and the loader's own record of it
M.flexReport = function(objID)
  local veh = be:getObjectByID(objID)
  local vd = core_vehicle_manager.getVehicleData(objID)
  local fbs = vd and vd.vdata and vd.vdata.flexbodies or {}
  local _, skin = driverInfo(objID)
  for _, part in ipairs(PARTS) do
    local name = skin .. '_' .. part
    local rec
    for _, f in pairs(fbs) do if type(f) == 'table' and (f.mesh == name or f.originalMesh == name) then rec = f break end end
    log('I', 'slrrDriverMount', string.format('  %s: engine knows mesh=%s, loader record=%s fid=%s meshLoaded=%s nodes=%s', name,
      tostring(veh and veh:setMeshAlpha(1, name, false)), tostring(rec ~= nil), tostring(rec and rec.fid), tostring(rec and rec.meshLoaded),
      tostring(rec and rec['_group_nodes'] and #rec['_group_nodes'])))
  end
end
M.setFlexBind = function(mode) if mode == 'near' or mode == 'all' or mode == 'car' then flexBind = mode end end   -- cars spawned afterwards
M.setOptOut = function(key, on) optOut[key] = on or nil end   -- a model name or objID: no flex driver
M.hasFlexDriver = function(objID) return flex[objID] ~= nil end   -- slrrDrivers: no props, and the driver's mass is in the nodes
M.getRagdoll = function(objID) return ragdolls[objID] end
M.onVehicleResetted = function(objID) if flex[objID] then alphaDue[objID] = 0.3 end end
M.onVehicleSwitched = function() switchedAt = os.clock() end
M.getFlexMeshes = function(objID) return flexMeshes[objID] end
M.getFlexScale = function(objID) return flexScale[objID] end
M.onVehicleDestroyed = function(objID) flexSkin[objID] = nil flexScale[objID] = nil alphaDue[objID] = nil headHidden[objID] = nil flexMeshes[objID] = nil flex[objID] = nil ragdolls[objID] = nil mounts[objID] = nil noProps[objID] = nil playerCars[objID] = nil end
return M
