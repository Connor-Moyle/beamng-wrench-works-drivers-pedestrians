-- SLRR Drivers: puts the Street Legal Racing Redline drivers in the driver's seat of any car.
--
-- Each driver is 8 rigid parts (body, head, upper arm / forearm / hand per side) baked from the
-- SLRR skinned meshes by tools/convert_drivers.py. Every frame the parts are placed in the seat
-- frame of the car (origin at the driver camera node = the eye, x right, y forward, z up): the
-- arms are solved with two-bone IK onto the steering wheel rim, and the shifting hand reaches for
-- the gear lever when the revs are high and runs through the H pattern on a gear change.
--
-- API (also used by Wrench Works / Street Legal):
--   slrrDrivers.getDrivers()           -> array of {id, name, preview}
--   slrrDrivers.setDriver(vehId, id)   id nil or "none" removes the driver from that car
--   slrrDrivers.getDriver(vehId)       -> id or nil
--   slrrDrivers.setDefaultDriver(id)   driver for cars with no choice of their own (saved)
--
-- Adding a driver: make /art/slrr_drivers/<id>/ with driver.json {"name", "model", "skin": "<id>"},
-- a main.materials.json defining material "<id>_driver", the skin texture and optionally preview.png.
-- "model" names a folder in /art/slrr_drivers/models/ (vin or police, or your own converted mesh).

local M = {}

local ROOT = '/art/slrr_drivers/'
local SETTINGS = '/settings/slrr_drivers.json'
local PARTS = {'body', 'head', 'r_upperarm', 'r_forearm', 'r_hand', 'l_upperarm', 'l_forearm', 'l_hand',
               'r_thigh', 'r_calf', 'r_foot', 'l_thigh', 'l_calf', 'l_foot'}

-- seat-frame wheel and shifter guesses; the same numbers as tools/convert_drivers.py
local WHEEL_CENTER = vec3(0, 0.56, -0.30)   -- used when the car has no steering prop
local WHEEL_HUB_TO_RIM = vec3(0, 0, 0.02)     -- prop node sits about at the rim plane, a touch low
local WHEEL_TILT = math.rad(25)
local WHEEL_RADIUS = 0.185
local GRIP_ANGLE = math.rad(10)
local WRIST_BACK = 0.07
local HAND_RANGE = math.rad(90)         -- how far a hand turns with the rim before it lets go (hand over hand)
local REGRIP_AHEAD = math.rad(50)       -- a hand that lets go grabs again this far past its home spot
local REGRIP_TIME = 0.22
local REGRIP_LIFT = 0.07                -- the hand comes off the rim toward the driver while it moves
local HAND_ROLL = 0.7                   -- share of the rim rotation the fist rolls with
local SHIFT_TIME = 0.45
local REACH_RPM = 0.82                  -- fraction of max rpm where the hand goes to the lever
local CULL_DIST = 150
-- pedals, seat frame, relative to the steering column (x) and the cabin floor (z)
local PEDAL_X = {throttle = 0.13, brake = -0.06, clutch = -0.24, rest = -0.33}
local PEDAL_Y = 0.95                    -- forward of the eyes; pulled in when the legs can't reach
local PEDAL_ABOVE_FLOOR = 0.13
local PEDAL_TRAVEL = vec3(0, 0.07, -0.025)   -- how the pad moves when pressed fully
local FOOT_MOVE_TIME = 0.18             -- moving the right foot between throttle and brake
local DRIVER_MASS = 90                  -- kg added to the car at the seat (driver.json "mass" overrides)
local SWAY_GAIN = 0.7                   -- the upper body is a damped spring on the hips, pushed by the car's acceleration
local SWAY_HZ = 1.6
local SWAY_DAMP = 0.45
local SEATBELT = 0.07                   -- hard limit: the head never travels more than this from where it sits
local SWAY_ACC_MAX = 12                 -- m/s^2; harder hits (kerbs, gear-change spikes) don't throw him further
local UPPER_BODY_SHARE = 0.5            -- share of the driver's mass that hits things
local HIT_MIN_SPEED = 1.0               -- m/s; slower contacts don't push on the car
local HIT_TIME = 0.05                   -- the impact force is spread over this long
local COLLIDE_DIST = 40                 -- only drivers this close to the camera collide (it costs node reads)
local LEAD_FRAMES = 1                   -- render lag of TSStatic transforms, in frames

local drivers = {}      -- id -> {id, name, model, skin, preview}
local driverList = {}
local rigs = {}         -- model -> rig.json
local cars = {}         -- vehId -> state
local choice = {}       -- vehId -> id or false (none)
local defaultDriver = 'slrr_mitch'
-- display mode, global and per car: "full" (animated), "still" (seated pose, no animation),
-- "hideFirstPerson" (animated, but not drawn in the player's own driver camera), "hidden" (never drawn)
local MODES = {full = true, still = true, hideFirstPerson = true, hidden = true}
local displayMode = 'full'
local carMode = {}       -- vehId -> mode
local animated = true    -- set per car each frame from its mode
local group

local loadedMaterials = {}

local function loadDrivers()
  drivers, driverList = {}, {}
  -- /art is not scanned for materials, so the skins are loaded here (driver mods included)
  for _, f in ipairs(FS:findFiles(ROOT, '*.materials.json', -1, true, false)) do
    if not loadedMaterials[f] then loadJsonMaterialsFile(f) loadedMaterials[f] = true end
  end
  for _, f in ipairs(FS:findFiles(ROOT, 'driver.json', 1, true, false)) do
    local id = f:match('/([^/]+)/driver%.json$')
    local d = jsonReadFile(f)
    if id and d and d.model and id ~= 'models' then
      local preview = ROOT .. id .. '/preview.png'
      drivers[id] = {id = id, name = d.name or id, model = d.model, skin = d.skin or id, mass = tonumber(d.mass) or DRIVER_MASS,
                     preview = FS:fileExists(preview) and preview or nil}
      table.insert(driverList, drivers[id])
    end
  end
  table.sort(driverList, function(a, b) return a.name < b.name end)
  local s = jsonReadFile(SETTINGS)
  if s and s.default then defaultDriver = s.default end
  if s and MODES[s.displayMode] then displayMode = s.displayMode end
end

local function getRig(model)
  if rigs[model] == nil then
    local r = jsonReadFile(ROOT .. 'models/' .. model .. '/rig.json')
    if r then
      local function v(t) return vec3(t[1], t[2], t[3]) end
      for k, p in pairs(r.parts) do r.parts[k] = v(p) end
      r.pelvis = r.pelvis and v(r.pelvis) or vec3(0, -0.1, -0.6)
      for _, leg in pairs(r.legs or {}) do
        for k, p in pairs(leg) do leg[k] = v(p) end
        leg.lt = (leg.knee - leg.hip):length()
        leg.lc = (leg.ankle - leg.knee):length()
        leg.foot0 = leg.ball - leg.ankle
      end
      for _, arm in pairs(r.arms) do
        for k, p in pairs(arm) do arm[k] = v(p) end
        arm.la = (arm.elbow - arm.shoulder):length()
        arm.lb = (arm.wrist - arm.elbow):length()
      end
    end
    rigs[model] = r or false
  end
  return rigs[model] or nil
end

-- small rotation helpers: a rotation is {x, y, z} column vectors
local function basis(dir, up)
  local y = dir:normalized()
  local x = y:cross(up):normalized()
  return {x = x, y = y, z = x:cross(y)}
end
local function rotate(R, v) return R.x * v.x + R.y * v.y + R.z * v.z end
local function delta(F1, F0)   -- F1 * F0^T
  return {x = rotate(F1, vec3(F0.x.x, F0.y.x, F0.z.x)),
          y = rotate(F1, vec3(F0.x.y, F0.y.y, F0.z.y)),
          z = rotate(F1, vec3(F0.x.z, F0.y.z, F0.z.z))}
end
local IDENT = {x = vec3(1, 0, 0), y = vec3(0, 1, 0), z = vec3(0, 0, 1)}
local function compose(A, B) return {x = rotate(A, B.x), y = rotate(A, B.y), z = rotate(A, B.z)} end
local function rotX(a) local c, s = math.cos(a), math.sin(a) return {x = vec3(1, 0, 0), y = vec3(0, c, s), z = vec3(0, -s, c)} end
local function rotY(a) local c, s = math.cos(a), math.sin(a) return {x = vec3(c, 0, -s), y = vec3(0, 1, 0), z = vec3(s, 0, c)} end

local function ik(S, T, la, lb, pole)
  local d = T - S
  local dist = math.min(d:length(), (la + lb) * 0.999)
  d = d:normalized()
  local a = math.acos(clamp((la * la + dist * dist - lb * lb) / (2 * la * dist), -1, 1))
  local bend = (pole - d * pole:dot(d)):normalized()
  return S + (d * math.cos(a) + bend * math.sin(a)) * la, S + d * dist
end

local wheelX = vec3(1, 0, 0)
local wheelN = vec3(0, -math.cos(WHEEL_TILT), math.sin(WHEEL_TILT))
local wheelUp = wheelN:cross(wheelX):normalized()
local HOME = {r = GRIP_ANGLE, l = math.pi - GRIP_ANGLE}
local function wrapAngle(a) return (a + math.pi) % (2 * math.pi) - math.pi end
local function rimPoint(center, a, lift)
  return center + (wheelX * math.cos(a) + wheelUp * math.sin(a)) * WHEEL_RADIUS + wheelN * (WRIST_BACK + lift)
end

-- Hand over hand: each hand holds the rim at angle g (measured on the wheel) and turns with it. When it
-- has turned HAND_RANGE from home it lets go and grabs again past home, while the other hand holds on.
-- Once the wheel settles near the centre, a hand far from home moves back to it. Returns rim angle and lift per side.
local function updateHands(c, turn, dt)
  local h = c.hands
  if not h then
    h = {r = {g = HOME.r}, l = {g = HOME.l}}
    c.hands, c.lastTurn = h, turn
  end
  local speed = (turn - c.lastTurn) / math.max(dt, 1e-3)
  c.lastTurn = turn
  -- one hand off the rim at a time; the next may go once the other is nearly back on
  local busy = (h.r.t and h.r.t < 0.7) or (h.l.t and h.l.t < 0.7)
  for side, s in pairs(h) do
    local home = HOME[side]
    if s.t then
      s.t = s.t + dt / REGRIP_TIME
      if s.t >= 1 then s.g, s.t = s.g1, nil end
    elseif side == c.shiftSide and c.reach > 0.3 then
      s.g = wrapAngle(home - turn)   -- off at the lever: comes back to its home spot
    elseif not busy then
      local off = wrapAngle(s.g + turn - home)
      -- the hand climbing toward the top of the rim lets go sooner, so the two never run out together
      local climbing = math.cos(s.g + turn) * speed > 0
      if math.abs(off) > HAND_RANGE * (climbing and 0.6 or 1) then
        s.g0, s.t = s.g, 0
        s.g1 = s.g + wrapAngle(home - turn - sign(off) * REGRIP_AHEAD - s.g)   -- the short way round
        busy = true
      elseif math.abs(speed) < math.rad(20) and math.abs(wrapAngle(turn)) < math.rad(30) and math.abs(off) > math.rad(30) then
        s.g0, s.t = s.g, 0
        s.g1 = s.g + wrapAngle(home - turn - s.g)
        busy = true
      end
    end
  end
  local out = {}
  for side, s in pairs(h) do
    if s.t then
      local k = smootheststep(s.t)
      out[side] = {a = s.g0 + (s.g1 - s.g0) * k + turn, lift = REGRIP_LIFT * math.sin(math.pi * s.t)}
    else
      out[side] = {a = s.g + turn, lift = 0}
    end
  end
  return out
end

-- rotation R turned by angle th about unit axis k (seat frame)
local function rotAbout(R, k, th)
  local cs, sn = math.cos(th), math.sin(th)
  local function r(v) return v * cs + k:cross(v) * sn + k * (k:dot(v) * (1 - cs)) end
  return {x = r(R.x), y = r(R.y), z = r(R.z)}
end

-- H pattern slot of a gear on the lever, seat frame offset from neutral
local function gearSlot(g)
  if g == 0 then return vec3(0, 0, 0) end
  if g < 0 then return vec3(-0.07, 0.045, 0) end
  local col = math.floor((g - 1) / 2) - 1
  return vec3(col * 0.035, (g % 2 == 1) and 0.045 or -0.045, 0)
end

local function nodeGroups(n)
  local g = n.group
  if type(g) == 'string' then return g end
  if type(g) == 'table' then return table.concat(g, ' ') end
  return ''
end

-- TSStatic ignores the "skin" field, so each driver gets its own copy of the part shapes with the
-- material renamed from base_driver to <skin>_driver, written once to /temp/.
local function skinnedShape(d, part)
  local src = ROOT .. 'models/' .. d.model .. '/' .. part .. '.dae'
  local text = readFile(src)
  if not text then return src end
  -- the size in the name makes a re-converted mesh a new shape instead of the cached old one
  local dst = '/temp/slrr_drivers/' .. d.skin .. '/' .. d.model .. '_' .. part .. '_' .. #text .. '.dae'
  if not FS:fileExists(dst) then writeFile(dst, (text:gsub('base_driver', d.skin .. '_driver'))) end
  return dst
end

local function removeCar(vid)
  local c = cars[vid]
  if not c then return end
  for _, o in pairs(c.parts) do if o and simObjectExists and simObjectExists(o) then o:delete() end end
  cars[vid] = nil
  local veh = be:getObjectByID(vid)
  if veh then veh:queueLuaCommand('extensions.unload("slrrDriverFeed")') end
end

-- traffic parked cars stay empty (as in SLRR) unless the player is in them or a driver was chosen
local function isParked(vid)
  if not gameplay_parking or vid == be:getPlayerVehicleID(0) then return false end
  return gameplay_parking.getParkedCarsData()[vid] ~= nil
end

local function wantedDriver(vid)
  local id = choice[vid]
  if id == false then return nil end
  local veh = be:getObjectByID(vid)
  if veh and veh:getJBeamFilename() == 'unicycle' then return nil end   -- the on-foot player
  if id == nil and isParked(vid) then return nil end
  return drivers[id or defaultDriver] and (id or defaultDriver) or nil
end

local function rotBetween(a, b)
  a, b = a:normalized(), b:normalized()
  local k = a:cross(b)
  local sn = k:length()
  if sn < 1e-6 then return IDENT end
  return rotAbout(IDENT, k / sn, math.atan2(sn, a:dot(b)))
end

-- Collision spheres (seat frame, sitting pose) and the car nodes around the driver they can hit.
local function setupCollision(c, vid)
  local rig = c.rig
  c.head0 = rig.parts.head + vec3(0, 0.04, 0.12)
  c.spheres = {
    {p = c.head0, r = 0.11},
    {p = rig.pelvis + vec3(0, 0.02, 0.38), r = 0.17},
    {p = rig.arms.r.shoulder, r = 0.08},
    {p = rig.arms.l.shoulder, r = 0.08},
  }
  c.colNodes = {}
  local vd = core_vehicle_manager.getVehicleData(vid)
  local nodes = vd and vd.vdata and vd.vdata.nodes
  local cam = nodes and nodes[c.camNode] and nodes[c.camNode].pos
  if not cam then return end
  for cid, n in pairs(nodes) do
    if type(cid) == 'number' and n.pos and cid ~= c.camNode then
      -- jbeam axes: the car faces -y and +x is its left
      local l = vec3(cam.x - n.pos.x, cam.y - n.pos.y, n.pos.z - cam.z)
      if math.abs(l.x) < 0.75 and l.y > -0.35 and l.y < 0.95 and l.z > -0.7 and l.z < 0.35 then
        table.insert(c.colNodes, cid)
      end
    end
  end
end

-- Upper body: a spring-damper point (the head) on the hips, thrown around by the car's acceleration,
-- held by a seatbelt, and stopped by the car's nodes. Hard contacts push back on the car.
-- Returns the lean rotation about the pelvis.
local function bodyPhysics(veh, c, dtSim, Rnow, eyeNow, camPos)
  local b = c.body
  if not b then b = {d = vec3(0, 0, 0), v = vec3(0, 0, 0)} c.body = b end
  local rig = c.rig
  if dtSim > 0 then
    local vel = vec3(veh:getVelocity())
    local acc = c.prevVel and (vel - c.prevVel) / dtSim or vec3(0, 0, 0)
    c.prevVel = vel
    if acc:length() > 2000 then acc = vec3(0, 0, 0) end   -- teleport or reset, not a crash
    c.acc = c.acc and lerp(c.acc, acc, math.min(1, dtSim * 6)) or acc   -- physics accel is noisy frame to frame
    local a = vec3(c.acc:dot(Rnow.x), c.acc:dot(Rnow.y), 0)
    if a:length() > SWAY_ACC_MAX then a = a:normalized() * SWAY_ACC_MAX end
    local w = 2 * math.pi * SWAY_HZ
    local steps = math.max(1, math.ceil(dtSim / 0.01))
    local h = dtSim / steps
    for _ = 1, steps do
      b.v = b.v + (-a * SWAY_GAIN - b.d * (w * w) - b.v * (2 * SWAY_DAMP * w)) * h
      b.d = b.d + b.v * h
      b.d.z = 0
      if b.d:length() > SEATBELT then
        local n = b.d:normalized()
        b.d = n * SEATBELT
        local into = b.v:dot(n)
        if into > 0 then b.v = b.v - n * into end
      end
    end
  end
  -- never let a bad frame (NaN, inf) stick: start again from sitting still
  local function finite(v) return v.x == v.x and v.y == v.y and math.abs(v.x) < 10 and math.abs(v.y) < 10 end
  if not (finite(b.d) and finite(b.v)) then b.d, b.v = vec3(0, 0, 0), vec3(0, 0, 0) end
  local function leanOf(d) return rotBetween(c.head0 - rig.pelvis, c.head0 + d - rig.pelvis) end
  local L = leanOf(b.d)

  if c.colNodes and #c.colNodes > 0 and eyeNow:distance(camPos) < COLLIDE_DIST then
    local vpos = veh:getPosition()
    local pts = {}
    for i, cid in ipairs(c.colNodes) do
      local d = vec3(vpos) + vec3(veh:getNodePositionXYZ(cid)) - eyeNow
      pts[i] = vec3(d:dot(Rnow.x), d:dot(Rnow.y), d:dot(Rnow.z))
    end
    if not c.ignore then   -- nodes a sphere already touches when sitting normally (seat, headrest) never count
      c.ignore = {}
      for si, sp in ipairs(c.spheres) do
        c.ignore[si] = {}
        for i, p in ipairs(pts) do
          if p:distance(sp.p) < sp.r + 0.10 then c.ignore[si][i] = true end
        end
      end
    end
    for _ = 1, 2 do
      for si, sp in ipairs(c.spheres) do
        local center = rig.pelvis + rotate(L, sp.p - rig.pelvis)
        local lever = (c.head0 - rig.pelvis):length() / math.max(0.1, (sp.p - rig.pelvis):length())
        for i, p in ipairs(pts) do
          if not c.ignore[si][i] then
            local off = center - p
            local dist = off:length()
            if dist < sp.r and dist > 1e-4 then
              local n = off / dist
              n.z = 0
              if n:length() > 1e-3 then
                n = n:normalized()
                -- half a correction per pass: nodes on both sides (seat bolsters) must not bat him back and forth
                local push = math.min((sp.r - dist) * math.min(lever, 1.5) * 0.5, 0.03)
                b.d = b.d + n * push
                local into = -b.v:dot(n)
                if into > 0 then
                  b.v = b.v + n * into
                  if into > HIT_MIN_SPEED and dtSim > 0 then
                    -- push the node with the upper body's momentum, in world space
                    local J = into * c.mass * UPPER_BODY_SHARE
                    local f = rotate(Rnow, -n) * (J / HIT_TIME)
                    veh:queueLuaCommand(string.format(
                      'if slrrDriverFeed then slrrDriverFeed.hit(%d,%.1f,%.1f,%.1f,%g) end',
                      c.colNodes[i], f.x, f.y, f.z, HIT_TIME))
                  end
                end
                L = leanOf(b.d)
                center = rig.pelvis + rotate(L, sp.p - rig.pelvis)
              end
            end
          end
        end
      end
    end
  end
  if not (finite(b.d) and finite(b.v)) then b.d, b.v = vec3(0, 0, 0), vec3(0, 0, 0) return IDENT end
  return L
end

local function attach(vid)
  local id = wantedDriver(vid)
  if not id then removeCar(vid) return true end
  local veh = be:getObjectByID(vid)
  if not veh then return true end
  local camNode, rhd = core_camera.getDriverDataById(vid)
  if not camNode then return false end   -- camera data not ready yet, or a trailer / prop
  local d = drivers[id]
  local rig = getRig(d.model)
  if not rig then log('E', 'slrrDrivers', 'missing rig for model ' .. tostring(d.model)) return true end
  removeCar(vid)

  if not group or not simObjectExists(group) then
    group = scenetree.findObject('slrrDriversGroup')
    if not group then
      group = createObject('SimGroup')
      group.canSave = false
      group:registerObject('slrrDriversGroup')
      scenetree.MissionGroup:addObject(group)
    end
  end
  local c = {id = id, rig = rig, camNode = camNode, rhd = rhd or false, parts = {},
             e = {steer = 0, rpm = 0, maxrpm = 0, gear = 0, throttle = 0, brake = 0, clutch = 0}, reach = 0}
  for _, p in ipairs(PARTS) do
    local o = createObject('TSStatic')
    o:setField('shapeName', 0, skinnedShape(d, p))
    o:setField('collisionType', 0, 'None')
    o:setField('decalType', 0, 'None')
    o.canSave = false
    o:registerObject('')
    group:addObject(o)
    c.parts[p] = o
  end
  -- gear lever: the highest node of any "shifter" group, if the car has one
  local vdata = core_vehicle_manager.getVehicleData(vid)
  local best
  if vdata and vdata.vdata and vdata.vdata.nodes then
    for cid, n in pairs(vdata.vdata.nodes) do
      if type(cid) == 'number' and n.pos and nodeGroups(n):lower():find('shifter') and (not best or n.pos.z > best.z) then
        best = {cid = cid, z = n.pos.z}
      end
    end
  end
  c.shifterNode = best and best.cid
  -- otherwise the anchor node of a gear-driven prop (shifter, column lever, gear indicator)
  if not c.shifterNode and vdata and vdata.vdata and vdata.vdata.props then
    for _, p in pairs(vdata.vdata.props) do
      local f = type(p) == 'table' and tostring(p.func or ''):lower() or ''
      if (f:find('gear') or f:find('shift')) and tonumber(p.idRef) then c.shifterNode = tonumber(p.idRef) break end
    end
  end
  -- steering wheel hub: the anchor node of the steering prop
  if vdata and vdata.vdata and vdata.vdata.props then
    for _, p in pairs(vdata.vdata.props) do
      if type(p) == 'table' and p.func == 'steering' and tonumber(p.idRef) then c.wheelNode = tonumber(p.idRef) break end
    end
  end
  -- pedals: which ones the car animates (props driven by throttle / brake / clutch) and how far they swing;
  -- their height from the cabin floor in front of the seat
  c.pedalAngle = {throttle = math.rad(20), brake = math.rad(20)}
  if vdata and vdata.vdata and vdata.vdata.props then
    for _, p in pairs(vdata.vdata.props) do
      local f = type(p) == 'table' and tostring(p.func or '') or ''
      if f == 'throttle' or f == 'brake' or f == 'clutch' then
        -- by now the jbeam rotation is a vec3 in radians (degrees in the file)
        local r = p.rotation
        local a = r and math.max(math.abs(r.x or 0), math.abs(r.y or 0), math.abs(r.z or 0)) or 0
        if a > math.pi then a = math.rad(a) end
        c.pedalAngle[f] = a > 0 and clamp(a, math.rad(5), math.rad(35)) or math.rad(20)
      end
    end
  end
  c.hasClutch = c.pedalAngle.clutch ~= nil
  local floorZ
  local nodes = vdata and vdata.vdata and vdata.vdata.nodes
  local cam0 = nodes and nodes[camNode] and nodes[camNode].pos
  if cam0 then
    for cid, n in pairs(nodes) do
      if type(cid) == 'number' and n.pos then
        local l = vec3(cam0.x - n.pos.x, cam0.y - n.pos.y, n.pos.z - cam0.z)   -- jbeam: car faces -y, +x is left
        if math.abs(l.x) < 0.45 and l.y > 0.6 and l.y < 1.3 and l.z > -1.5 and l.z < -0.6 then
          floorZ = math.min(floorZ or l.z, l.z)
        end
      end
    end
  end
  -- the lowest node in the footwell can be chassis under the floor: keep pedals where cars have them
  c.pedalZ = clamp(floorZ and (floorZ + PEDAL_ABOVE_FLOOR) or -0.97, -1.08, -0.85)
  for side, leg in pairs(rig.legs or {}) do
    local sx = side == 'r' and 1 or -1
    leg.pole = vec3(0.15 * sx, 0.5, 1)   -- knees bend up and a little out
    local n = (leg.knee - leg.hip):cross(leg.ankle - leg.hip)
    leg.F0t = basis(leg.knee - leg.hip, n)
    leg.F0c = basis(leg.ankle - leg.knee, n)
  end
  c.feet = {r = {pedal = 'throttle'}, l = {pedal = c.hasClutch and 'clutch' or 'rest'}}
  -- the hand nearest the middle of the car shifts
  c.shiftSide = c.rhd and 'l' or 'r'
  c.inward = c.rhd and -1 or 1
  for side, arm in pairs(rig.arms) do
    local sx = side == 'r' and 1 or -1
    arm.pole = vec3(0.6 * sx, -0.2, -1)
    arm.F0u = basis(arm.elbow - arm.shoulder, (arm.elbow - arm.shoulder):cross(arm.wrist - arm.shoulder))
    arm.F0f = basis(arm.wrist - arm.elbow, (arm.elbow - arm.shoulder):cross(arm.wrist - arm.shoulder))
  end
  c.mass = d.mass
  setupCollision(c, vid)
  cars[vid] = c
  veh:queueLuaCommand(string.format('extensions.load("slrrDriverFeed") slrrDriverFeed.setDriverMass(%d, %g)', camNode, d.mass))
  return true
end

local pending = {}
local function markAll()
  for i = 0, be:getObjectCount() - 1 do
    local v = be:getObject(i)
    if v then pending[v:getId()] = 0 end
  end
end

local function place(o, pos, R, axes)
  local m = MatrixF(true)
  m:setColumn(0, rotate(R, axes.x))
  m:setColumn(1, rotate(R, axes.y))
  m:setColumn(2, rotate(R, axes.z))
  m:setPosition(pos)
  o:setTransform(m)
end

-- A joint target that moves smoothly: a low-pass that never moves faster than maxSpeed (m/s), and
-- snaps straight there after a jump (respawn, reset) so the driver never trails off.
local function follow(c, key, target, dt, maxSpeed)
  c.smooth = c.smooth or {}
  local p = c.smooth[key]
  if not p or p:distance(target) > 0.5 or dt <= 0 then c.smooth[key] = target return target end
  local step = (target - p) * math.min(1, dt * 30)
  if step:length() > maxSpeed * dt then step = step:normalized() * (maxSpeed * dt) end
  p = p + step
  c.smooth[key] = p
  return p
end

-- Feet on the pedals: the right foot works the throttle and moves to the brake when braking, the left
-- works the clutch (or rests left of the pedals). Each pad is pressed in as far as its pedal, the foot
-- pivots at the ankle to the pedal angle, and two-bone IK places hip -> knee -> ankle.
local function updateLegs(c, wheel, world, R, dt)
  local rig, e = c.rig, c.e
  -- pedal travel as the feet see it: keyboard pedals jump 0 -> 1 in a frame, a foot takes about 0.12 s
  c.press = c.press or {throttle = 0, brake = 0, clutch = 0, rest = 0}
  local press = c.press
  for _, k in ipairs({'throttle', 'brake', 'clutch'}) do
    local want = animated and (e[k] or 0) or 0
    press[k] = press[k] + clamp(want - press[k], -dt * 8, dt * 8)
  end
  local right = c.feet.r
  local wantR = (press.brake > 0.02 and press.brake >= press.throttle) and 'brake' or 'throttle'
  if wantR ~= right.pedal and not right.t then right.from, right.pedal, right.t = right.pedal, wantR, 0 end
  c.feet.l.pedal = c.hasClutch and 'clutch' or 'rest'
  local function pad(name)
    local p = vec3(wheel.x + PEDAL_X[name], PEDAL_Y, c.pedalZ)
    if name == 'rest' then p = p + vec3(0, -0.08, 0.02) end
    return p + PEDAL_TRAVEL * press[name]
  end
  for side, leg in pairs(rig.legs) do
    local f = c.feet[side]
    local target, angle
    if f.t then
      f.t = f.t + dt / FOOT_MOVE_TIME
      local k = smootheststep(math.min(1, f.t))
      target = lerp(pad(f.from), pad(f.pedal), k) + vec3(0, -0.03, 0.05) * math.sin(math.pi * math.min(1, f.t))
      angle = lerp((c.pedalAngle[f.from] or 0) * press[f.from], (c.pedalAngle[f.pedal] or 0) * press[f.pedal], k)
      if f.t >= 1 then f.t = nil end
    else
      target = pad(f.pedal)
      angle = (c.pedalAngle[f.pedal] or 0) * press[f.pedal]
    end
    -- the ball of the foot goes on the pad; the foot pivots toes-down with the pedal
    local footRot = rotX(-angle)
    target = follow(c, side .. 'Foot', target, dt, 3)
    local ankleTarget = target - rotate(footRot, leg.foot0)
    -- legs that cannot reach pull the pedals in toward the seat
    local reach = (leg.lt + leg.lc) * 0.92   -- the knee always stays a little bent
    local d = ankleTarget - leg.hip
    if d:length() > reach then ankleTarget = leg.hip + d:normalized() * reach end
    local knee, ankle = ik(leg.hip, ankleTarget, leg.lt, leg.lc, leg.pole)
    local n = (knee - leg.hip):cross(ankle - leg.hip)
    place(c.parts[side .. '_thigh'], world(leg.hip), R, delta(basis(knee - leg.hip, n), leg.F0t))
    place(c.parts[side .. '_calf'], world(knee), R, delta(basis(ankle - knee, n), leg.F0c))
    place(c.parts[side .. '_foot'], world(ankle), R, footRot)
  end
end

local function updateCar(vid, c, dt, dtSim, camPos, fpVid)
  local veh = be:getObjectByID(vid)
  if not veh then removeCar(vid) return end
  local vpos = veh:getPosition()
  local eye = vec3(vpos) + vec3(veh:getNodePositionXYZ(c.camNode))
  local mode = carMode[vid] or displayMode
  animated = mode == 'full' or mode == 'hideFirstPerson'
  local fpView = vid == fpVid
  local off = eye:distance(camPos) > CULL_DIST or mode == 'hidden' or (mode == 'hideFirstPerson' and fpView)
  if off ~= c.hidden then
    for _, o in pairs(c.parts) do o:setHidden(off) end
    c.hidden, c.headHidden = off, off
  end
  if off then return end
  local fwd = vec3(veh:getDirectionVector()):normalized()
  local up = vec3(veh:getDirectionVectorUp())
  local eyeNow, Rnow = eye, basis(fwd, up)   -- for measuring the car's own nodes
  -- TSStatic transforms show up one frame late, so the driver is placed where the car will be
  -- when this frame is drawn: one step of its velocity and turn rate ahead
  if dtSim > 0 then
    -- the frame time is averaged (a jumpy dt made the driver jitter at speed); rotation isn't led, the
    -- car's direction vectors are too noisy for it
    c.dtAvg = c.dtAvg and lerp(c.dtAvg, dtSim, 0.05) or dtSim
    local lead = vec3(veh:getVelocity()) * (c.dtAvg * LEAD_FRAMES)
    if lead:length() < 1.5 then eye = eye + lead end
  end
  local R = basis(fwd, up)   -- seat frame -> world
  local function world(p) return eye + rotate(R, p) end
  local rig, e = c.rig, c.e

  local L = animated and bodyPhysics(veh, c, dtSim, Rnow, eyeNow, camPos) or IDENT
  if c.reachLean then L = compose(L, c.reachLean) end
  local function lean(p) return rig.pelvis + rotate(L, p - rig.pelvis) end

  -- shifting hand: reach for the lever at high revs, run the H pattern while a shift is on
  local function toSeat(cid)
    local d = vec3(vpos) + vec3(veh:getNodePositionXYZ(cid)) - eyeNow
    return vec3(d:dot(Rnow.x), d:dot(Rnow.y), d:dot(Rnow.z))
  end
  local lever = vec3(0.32 * c.inward, 0.30, -0.52)
  if c.shifterNode then
    local l = toSeat(c.shifterNode)
    if math.abs(l.x) < 0.75 and l.y > -0.3 and l.y < 0.65 and l.z > -1.0 and l.z < 0 then lever = l end
  end
  local knob = gearSlot(e.gear)
  if c.shiftT then
    c.shiftT = c.shiftT + dt
    local t = c.shiftT / SHIFT_TIME
    local a, b = gearSlot(c.fromGear), gearSlot(e.gear)
    local na, nb = vec3(a.x, 0, 0), vec3(b.x, 0, 0)
    if t < 1 / 3 then knob = lerp(a, na, t * 3)
    elseif t < 2 / 3 then knob = lerp(na, nb, t * 3 - 1)
    else knob = lerp(nb, b, math.min(1, t * 3 - 2)) end
    if c.shiftT > SHIFT_TIME + 0.15 then c.shiftT = nil end
  end
  -- no reaching for the lever while the wheel is turned well over (both hands are busy steering)
  local revsHigh = e.maxrpm > 0 and e.rpm / e.maxrpm > REACH_RPM and e.gear > 0 and math.abs(e.steer) < 70
  local want = (animated and (c.shiftT or revsHigh)) and 1 or 0
  c.reach = c.reach + clamp(want - c.reach, -dt * 3, dt * (c.shiftT and 12 or 4))
  local leverTarget = lever + knob + vec3(0, -0.03, 0.07)

  local wheel = WHEEL_CENTER
  if c.wheelNode then
    local l = toSeat(c.wheelNode)
    if math.abs(l.x) < 0.25 and l.y > 0.3 and l.y < 0.85 and l.z > -0.6 and l.z < -0.1 then wheel = l + WHEEL_HUB_TO_RIM end
  end
  -- a wheel beyond arm's reach: lean forward from the hips (a fixed lean, worked out once) instead of
  -- the arms locking straight and the hands sliding off the rim
  if not c.reachLean then
    local need = 0
    for side, arm in pairs(rig.arms) do
      local d = rimPoint(wheel, HOME[side], 0):distance(arm.shoulder) - (arm.la + arm.lb) * 0.95
      need = math.max(need, d)
    end
    local lever = (rig.parts.head - rig.pelvis):length()
    c.reachLean = need > 0 and rotX(-clamp(need / lever, 0, 0.35)) or IDENT
  end
  local turn = animated and math.rad(e.steer) or 0
  local grips = updateHands(c, turn, dt)
  for side, arm in pairs(rig.arms) do
    local grip = grips[side]
    local target = rimPoint(wheel, grip.a, grip.lift)
    if side == c.shiftSide and c.reach > 0 then target = lerp(target, leverTarget, c.reach) end
    local shoulder = lean(arm.shoulder)
    target = follow(c, side .. 'Hand', target, dt, 4)
    local elbow, wrist = ik(shoulder, target, arm.la, arm.lb, arm.pole)
    local n = (elbow - shoulder):cross(wrist - shoulder)
    local Du = delta(basis(elbow - shoulder, n), arm.F0u)
    local Df = delta(basis(wrist - elbow, n), arm.F0f)
    place(c.parts[side .. '_upperarm'], world(shoulder), R, Du)
    place(c.parts[side .. '_forearm'], world(elbow), R, Df)
    local roll = clamp(wrapAngle(grip.a - HOME[side]) * HAND_ROLL, -math.rad(60), math.rad(60)) * (1 - c.reach * (side == c.shiftSide and 1 or 0))
    place(c.parts[side .. '_hand'], world(wrist), R, rotAbout(Df, wheelN, roll))
  end
  place(c.parts.body, world(lean(vec3(0, 0, 0))), R, L)
  if rig.legs and rig.legs.r then updateLegs(c, wheel, world, R, dt) end

  -- head: in the player's own driver camera it turns with the view and the camera sits inside it, so it
  -- never draws into the view (the inside of a model is not drawn) yet shows in the mirrors. It is only
  -- hidden when the camera leaves the head (leaning out to look back).
  local yaw, pitch = clamp(turn * 0.12, -0.4, 0.4), 0
  local fp = vid == fpVid
  if fp and animated then
    local q = core_camera.getQuat()
    local look = q and (q * vec3(0, 1, 0)) or R.y
    local lx, ly, lz = look:dot(R.x), look:dot(R.y), look:dot(R.z)
    yaw = clamp(math.atan2(-lx, ly), -1.4, 1.4)
    pitch = clamp(math.atan2(lz, math.sqrt(lx * lx + ly * ly)), -0.6, 0.5)
  end
  local hideHead = fp and core_camera.getPosition():distance(eye) > 0.1
  if hideHead ~= c.headHidden then c.parts.head:setHidden(hideHead) c.headHidden = hideHead end
  if not hideHead then
    c.headYaw = c.headYaw and (c.headYaw + clamp(yaw - c.headYaw, -dt * 6, dt * 6)) or yaw   -- no snapping
    c.headPitch = c.headPitch and (c.headPitch + clamp(pitch - c.headPitch, -dt * 4, dt * 4)) or pitch
    yaw, pitch = c.headYaw, c.headPitch
    local cy, sy = math.cos(yaw), math.sin(yaw)
    local turnHead = compose({x = vec3(cy, sy, 0), y = vec3(-sy, cy, 0), z = vec3(0, 0, 1)}, rotX(pitch))
    place(c.parts.head, world(lean(rig.parts.head)), R, compose(L, turnHead))
  end
end

local function onPreRender(dt, dtSim)
  for vid, tries in pairs(pending) do
    if attach(vid) or tries > 300 then pending[vid] = nil else pending[vid] = tries + 1 end
  end
  if not next(cars) then return end
  local camPos = core_camera.getPosition()
  local fpVid = core_camera.getActiveCamName(0) == 'driver' and be:getPlayerVehicleID(0) or nil
  for vid, c in pairs(cars) do updateCar(vid, c, dt, dtSim or dt, camPos, fpVid) end
end

-- called by slrrDriverFeed (vehicle Lua) every frame
local function feed(vid, steer, rpm, maxrpm, gear, throttle, brake, clutch)
  local c = cars[vid]
  if not c then return end
  local e = c.e
  if gear ~= e.gear and e.maxrpm > 0 then c.shiftT, c.fromGear = 0, e.gear end
  e.steer, e.rpm, e.maxrpm, e.gear, e.throttle = steer, rpm, maxrpm, gear, throttle
  e.brake, e.clutch = brake or 0, clutch or 0
end

local function saveSettings() jsonWriteFile(SETTINGS, {default = defaultDriver, displayMode = displayMode}, true) end

M.getDrivers = function()
  local out = {}
  for _, d in ipairs(driverList) do table.insert(out, {id = d.id, name = d.name, preview = d.preview}) end
  return out
end
M.setDriver = function(vid, id)
  if id == 'none' then id = nil end
  if id and not drivers[id] then log('W', 'slrrDrivers', 'unknown driver ' .. tostring(id)) return end
  choice[vid] = id or false
  pending[vid] = 0
end
M.getDriver = function(vid)
  if pending[vid] then return wantedDriver(vid) end   -- a setDriver not applied yet still reads back
  return cars[vid] and cars[vid].id or nil
end
M.setDefaultDriver = function(id)
  if id and not drivers[id] then return end
  defaultDriver = id
  saveSettings()
  markAll()
end
M.getDefaultDriver = function() return defaultDriver end
M.setDisplayMode = function(mode, vid)
  if mode == 'static' then mode = 'still' end
  if mode ~= nil and not MODES[mode] then log('W', 'slrrDrivers', 'unknown display mode ' .. tostring(mode)) return end
  -- unchanged: nothing to do (callers may set it on every spawn; no reset, no settings write)
  if (vid and carMode[vid] == mode) or (not vid and displayMode == (mode or 'full')) then return end
  if vid then carMode[vid] = mode else displayMode = mode or 'full' saveSettings() end
  -- start the animation state fresh, so switching never leaves a half-finished move behind
  for id, c in pairs(cars) do
    if not vid or id == vid then c.body, c.smooth, c.hands, c.shiftT, c.reach, c.headYaw, c.headPitch = nil, nil, nil, nil, 0, nil, nil end
  end
end
M.getDisplayMode = function(vid) return (vid and carMode[vid]) or displayMode end
-- shortcut kept from 1.2: true = "full", false = "still"
M.setAnimated = function(on) M.setDisplayMode(on and 'full' or 'still') end
M.getAnimated = function() return displayMode ~= 'still' end
M.feed = feed
M.getState = function(vid) return cars[vid] end   -- for debugging
M.reload = function() loadDrivers() rigs = {} for vid in pairs(cars) do pending[vid] = 0 end end

M.onExtensionLoaded = function() loadDrivers() markAll() end
M.onExtensionUnloaded = function() for vid in pairs(cars) do removeCar(vid) end end
M.onPreRender = onPreRender
M.onVehicleSpawned = function(vid) pending[vid] = 0 end   -- also fires after a part change rebuilds the car
M.onVehicleResetted = function(vid) if not cars[vid] then pending[vid] = 0 end end
M.onVehicleSwitched = function(old, new)   -- a parked car the player gets into gains a driver, and loses it again
  for _, vid in ipairs({old, new}) do
    if vid and vid ~= -1 and wantedDriver(vid) ~= M.getDriver(vid) then pending[vid] = 0 end
  end
end
M.onVehicleDestroyed = function(vid) removeCar(vid) pending[vid] = nil choice[vid] = nil carMode[vid] = nil end
M.onClientStartMission = function() group = nil cars = {} markAll() end
M.onClientEndMission = function() group = nil cars = {} pending = {} end

return M
