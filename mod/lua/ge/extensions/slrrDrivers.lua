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
local HAND_LENGTH = 0.07                -- wrist to the middle of the fist
local HAND_DOWN = math.rad(50)         -- how far below home a hand is carried before it grips again
local REGRIP_AHEAD = math.rad(50)       -- a hand that lets go grabs again this far past its home spot
local REGRIP_LIFT = 0.07                -- the hand comes off the rim toward the driver while it moves
local HAND_ROLL = 1.0                   -- share of the rim rotation the fist rolls with
local SHIFT_GAP = 1.0                  -- s: a shift this soon after another is left to the car (auto-shift chains)
local KNOB_GRIP = vec3(0, -0.02, 0.05)  -- the wrist relative to an H-pattern knob node (palm on top)
-- pedals, seat frame, relative to the steering column (x) and the cabin floor (z)
local PEDAL_X = {throttle = 0.13, brake = -0.06, clutch = -0.24, rest = -0.33}
local PEDAL_Y = 0.95                    -- forward of the eyes; pulled in when the legs can't reach
local PEDAL_ABOVE_FLOOR = 0.13
local PEDAL_TRAVEL = vec3(0, 0.07, -0.025)   -- how the pad moves when pressed fully
local FOOT_MOVE_TIME = 0.18             -- moving the right foot between throttle and brake
local PAD_FROM_WALL = 0.10              -- the pedal pads sit this far behind the firewall / toe board
local SOLE = 0.05                       -- the ankle and the ball of the foot stay this far above the floor
local WELL_REFRESH = 1.0                -- s between re-measuring the footwell (it can be crushed; rays cost)
local HUB_MOVE = 0.3                    -- m the steering hub may be pushed from where it started (crash damage)
local CRASH_LAG = 0.15                  -- (kerb taps change it ~1 m/s, 11 m/s^2 braking 1.7 m/s: no crash)
local DAZE_SPEED = 4                    -- m/s: only when stopped or slow, never at speed
local DAZE_IN, DAZE_OUT = 0.5, 0.7
-- gestures (a table: updateCar is at LuaJIT's limit of 60 upvalues): the wave out of the window (s to raise and lower the hand, the hand beside the window
-- a little ahead and above the head (x: toward the window), waves a second) and the slump over the wheel (rad of torso lean, rad of head pitch, s to get there)
local GEST = {waveIn = 0.45, waveHand = vec3(0.32, 0.20, 0.16), waveHz = 2.3, slumpTorso = 0.5, slumpHead = -0.75, slumpTime = 0.9}
local DAZE_HAND = vec3(0.08, 0.18, 0.0)  -- the wrist at the forehead, to the hand's own side (x: inward)
local SHOULDER_REACH = 0.05             -- m a shoulder comes forward into a long reach
local SEAT_SLIDE = 0.08                 -- m the seat may move toward a distant wheel before he leans
local BREATH_HZ = 0.25
local SEAT_BACK_REACH = vec3(0.5, -0.05, -0.12)   -- the hand on the passenger seat back (x toward the passenger)
local REVERSE_TWIST = math.rad(17)      -- torso twist when looking back
-- third person: the player's driver looks where the camera looks
local LOOK_TORSO = math.rad(15)   -- the turn, split between head and torso
local LOOK_GIVE_UP = math.rad(120)      -- a camera further round than this: he faces forward again
local LOOK_PITCH_UP, LOOK_PITCH_DOWN = math.rad(20), math.rad(30)
local LOOK_W = 13                       -- rad/s: critically damped spring, settles in about 0.3 s
local LEVEL_HEAD = 0.7                  -- share of the torso lean the head undoes
local LEAD_FRAMES = 0                   -- render lead (frames of velocity); 0 until the driver is drawn by the car itself (overshot in play)

-- what the Mods menu can change (setTune): the defaults; TUNE_RANGE and TUNE_SPEC below say how far and how it is offered
local T = {
  jointSpeed = 2.1,
  rollSpeed = 4,
  regripTime = 0.22,
  handRange = math.rad(60),
  reach = 0.85,
  shiftTime = 0.35,
  reachRpm = 0.82,
  breathAngle = math.rad(0.9),
  glanceTime = 1.1,
  lookHead = math.rad(80),
  lookSpeed = 3,
  reverseHead = math.rad(80),
  reverseLookSpeed = 4,
  swayGain = 0.7,
  swayHz = 1.6,
  swayDamp = 0.45,
  swayAccMax = 12,
  seatbelt = 0.055,
  cullDist = 150,
  animDist = 40,
  collideDist = 40,
  farSkip = 8,
  maxTints = 8,
  driverMass = 90,
  crashDv = 5,
  dazeWait = 5,
  dazeTime = 3.5,
  dazeShake = 0.22,
  stalkReach = 1,                 -- 1: he reaches for the wiper stalk, the light switch and the indicator when they change
  stalkTime = 0.7,                -- s the reach takes, out and back
  stalkSteerMax = math.rad(90),   -- the wheel angle past which he does not let go of it for a stalk (both hands stay on the wheel)
  rainLean = math.rad(3),         -- forward lean at low speed with the wipers on, to see through the wet windscreen (0 = none)
}

local drivers = {}      -- id -> {id, name, model, skin, preview}
local driverList = {}
local rigs = {}         -- model -> rig.json
local cars = {}         -- vehId -> state
local choice = {}       -- vehId -> id or false (none)
local defaultDriver = 'slrr_mitch'
local appearance = {}          -- setAppearance, global (saved)
local carAppearance = {}       -- setAppearance, vehId -> table
-- display mode, global and per car: "full" (animated), "still" (seated pose, no animation),
-- "hideFirstPerson" (animated, but not drawn in the player's own driver camera), "hidden" (never drawn)
local MODES = {full = true, still = true, hideFirstPerson = true, hidden = true}
local displayMode = 'full'
local carMode = {}       -- vehId -> mode
local animated = true    -- set per car each frame from its mode
local perfMs = 0         -- smoothed ms per frame spent placing all drivers (getPerf)
local prof = {on = false, body = 0, place = 0, total = 0, frames = 0}   -- where the frame goes (getProfile)
local stopAsk = 0        -- seconds since cars in 'stop' mode were last asked for their AI mode
local group

local loadedMaterials = {}

local function loadDrivers()
  drivers, driverList = {}, {}
  -- tinted materials from an earlier session are rebuilt on demand: drop their files
  for _, f in ipairs(FS:findFiles('/temp/slrr_drivers/', '*_driver.materials.json', 0, false, false) or {}) do
    if f:find('_t') and FS.removeFile then FS:removeFile(f) end
  end
  -- /art is not scanned for materials, so the skins are loaded here (driver mods included)
  for _, f in ipairs(FS:findFiles(ROOT, '*.materials.json', -1, true, false)) do
    if not loadedMaterials[f] then loadJsonMaterialsFile(f) loadedMaterials[f] = true end
  end
  for _, f in ipairs(FS:findFiles(ROOT, 'driver.json', 1, true, false)) do
    local id = f:match('/([^/]+)/driver%.json$')
    local d = jsonReadFile(f)
    if id and d and d.model and id ~= 'models' then
      local preview = ROOT .. id .. '/preview.png'
      drivers[id] = {id = id, name = d.name or id, model = d.model, skin = d.skin or id, mass = tonumber(d.mass),
                     preview = FS:fileExists(preview) and preview or nil}
      table.insert(driverList, drivers[id])
    end
  end
  table.sort(driverList, function(a, b) return a.name < b.name end)
  local s = jsonReadFile(SETTINGS)
  if s and s.default then defaultDriver = s.default end
  if s and MODES[s.displayMode] then displayMode = s.displayMode end
  if s and type(s.appearance) == 'table' then appearance = s.appearance end
  if s and type(s.tune) == 'table' then M.loadTune(s.tune) end
end

local function getRig(model)
  if rigs[model] == nil then
    local r = jsonReadFile(ROOT .. 'models/' .. model .. '/rig.json')
    if r then
      local function v(t) return vec3(t[1], t[2], t[3]) end
      for k, p in pairs(r.parts) do r.parts[k] = v(p) end
      r.pelvis = r.pelvis and v(r.pelvis) or vec3(0, -0.1, -0.6)
      if r.fist then for k, f in pairs(r.fist) do r.fist[k] = v(f) end end
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
local function rotZ(a) local c, s = math.cos(a), math.sin(a) return {x = vec3(c, s, 0), y = vec3(-s, c, 0), z = vec3(0, 0, 1)} end

local function ik(S, T, la, lb, pole)
  local d = T - S
  local dist = math.min(d:length(), (la + lb) * 0.999)
  d = d:normalized()
  local a = math.acos(clamp((la * la + dist * dist - lb * lb) / (2 * la * dist), -1, 1))
  local bend = (pole - d * pole:dot(d)):normalized()
  return S + (d * math.cos(a) + bend * math.sin(a)) * la, S + d * dist
end

local WHEEL_X0 = vec3(1, 0, 0)
local WHEEL_N0 = vec3(0, -math.cos(WHEEL_TILT), math.sin(WHEEL_TILT))
local WHEEL_UP0 = WHEEL_N0:cross(WHEEL_X0):normalized()
-- the rim's frame for the car being updated (set per car each frame: a damaged column tilts it)
local wheelX, wheelN, wheelUp = WHEEL_X0, WHEEL_N0, WHEEL_UP0

-- distance along o + d*t to triangle a b c (Moller-Trumbore), or nil
local function rayTri(o, d, a, b, c)
  local e1, e2 = b - a, c - a
  local pv = d:cross(e2)
  local det = e1:dot(pv)
  if math.abs(det) < 1e-9 then return nil end
  local tv = o - a
  local u = tv:dot(pv) / det
  if u < 0 or u > 1 then return nil end
  local qv = tv:cross(e1)
  local v = d:dot(qv) / det
  if v < 0 or u + v > 1 then return nil end
  local t = e2:dot(qv) / det
  return t >= 0 and t or nil
end
local HOME = {r = GRIP_ANGLE, l = math.pi - GRIP_ANGLE}
local function wrapAngle(a) return (a + math.pi) % (2 * math.pi) - math.pi end
local function rimPoint(center, a, lift)
  return center + (wheelX * math.cos(a) + wheelUp * math.sin(a)) * WHEEL_RADIUS + wheelN * (WRIST_BACK + lift)
end

-- Hand over hand: each hand holds the rim at angle g (measured on the wheel) and turns with it. When it
-- has turned T.handRange from home it lets go and grabs again past home, while the other hand holds on.
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
  -- the hand carried furthest past its limit goes first (a fixed order: `pairs` over the two hands gave a different one from run to run,
  -- so which hand let go first, and the whole motion after it, changed with the table's hash seed)
  local function pastLimit(side)
    local s = h[side]
    if s.t then return -math.huge end
    local up = side == 'r' and 1 or -1
    local off = wrapAngle(s.g + turn - HOME[side]) * up
    return math.max(off - T.handRange, -off - HAND_DOWN)
  end
  local order = pastLimit('l') > pastLimit('r') and {'l', 'r'} or {'r', 'l'}
  for _, side in ipairs(order) do
    local s = h[side]
    local home = HOME[side]
    if s.t then
      s.t = s.t + dt / T.regripTime
      if s.t >= 1 then s.g, s.t = wrapAngle(s.a1 - turn), nil end   -- lands on whatever part of the rim is there now
    elseif side == c.shiftSide and c.reach > 0.3 then
      s.g = wrapAngle(home - turn)   -- off at the lever: comes back to its home spot
    else
      -- off: how far the hand has been carried from home, positive toward the top of the rim (where the
      -- right and left zones meet). Hands go up to the top but only HAND_DOWN below home, as drivers
      -- keep their hands in the upper part of the wheel; past either limit the hand grips again.
      local up = side == 'r' and 1 or -1
      local off = wrapAngle(s.g + turn - home) * up
      local over = off > T.handRange or off < -HAND_DOWN
      if over and busy then
        -- the other hand is off the rim: this one holds its place and lets the rim slide through the palm
        -- (both letting go at once would swing both arms across the wheel)
        s.g = wrapAngle(home + up * clamp(off, -HAND_DOWN, T.handRange) - turn)
      elseif over then
        -- a re-grip aims at a place in front of the driver, not at a point on the turning rim (which can
        -- travel 100+ degrees during a fast turn and drag the hand out of its zone)
        local land = off > 0 and -REGRIP_AHEAD * 0.6 or REGRIP_AHEAD   -- from the top: a little below home; from below: above it
        s.a0, s.a1, s.t = s.g + turn, home + up * land, 0
        busy = true
      elseif not busy and math.abs(speed) < math.rad(20) and math.abs(wrapAngle(turn)) < math.rad(30) and math.abs(off) > math.rad(30) then
        s.a0, s.a1, s.t = s.g + turn, home, 0
        busy = true
      end
    end
  end
  local out = {}
  for _, side in ipairs({'r', 'l'}) do
    local s = h[side]
    if s.t then
      local k = smootheststep(s.t)
      out[side] = {a = s.a0 + wrapAngle(s.a1 - s.a0) * k, lift = REGRIP_LIFT * math.sin(math.pi * s.t)}
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
local function skinnedShape(model, part, material, base)
  local src = ROOT .. 'models/' .. model .. '/' .. part .. '.dae'
  local text = readFile(src)
  if not text then return src end
  -- the size in the name makes a re-converted mesh a new shape instead of the cached old one
  local dst = '/temp/slrr_drivers/' .. material .. '/' .. model .. '_' .. part .. '_' .. #text .. '.dae'
  if not FS:fileExists(dst) then writeFile(dst, (text:gsub(base or 'base_driver', material))) end
  return dst
end

-- Appearance (setAppearance): clothing tints, size and a helmet, global or per car.
local tints = {}               -- material name -> {users = n, order = k}: at most T.maxTints kept loaded
local tintOrder = 0

local function hex(c) return c and string.format('%02x%02x%02x', clamp(c[1] or c.r or 0, 0, 1) * 255, clamp(c[2] or c.g or 0, 0, 1) * 255, clamp(c[3] or c.b or 0, 0, 1) * 255) or nil end
local function rgb(c) return {clamp(c[1] or c.r or 0, 0, 1), clamp(c[2] or c.g or 0, 0, 1), clamp(c[3] or c.b or 0, 0, 1), 1} end

local function appearanceFor(vid)
  local a, o = {}, carAppearance[vid] or {}
  for k, v in pairs(appearance) do a[k] = v end
  for k, v in pairs(o) do a[k] = v end
  return a
end

-- A material for a driver with tinted shirt / trousers: the skin's own maps, then per garment a layer of
-- its grey shading times the colour, through the garment's mask. Written to /temp and loaded; identical
-- colours share one; at most T.maxTints are kept (an unused one is dropped for a new one).
-- Tinted colour map baked in Lua (the fallback when material layers don't blend): the skin's packed
-- <stem>_tint.bin (r, g, b, shade, shirt mask, trousers mask per pixel) mixed into one texture. Plain Lua
-- (no ffi: the mod repository doesn't allow it), so it runs as a job spread over frames, BAKE_ROWS rows
-- a frame; the driver attaches once his texture is ready.
local TINT_PX = 1024
local BAKE_ROWS = 32
local tintMode = 'layers'       -- 'layers' or 'bake' (setTintMode)
local bakeJobs = {}             -- material name -> coroutine
local bakeResults = {}          -- material name -> texture path, or false if it couldn't be made

local function bakeJob(d, a, name)
  return coroutine.create(function()
    local bins = FS:findFiles(ROOT .. d.id .. '/', '*_tint.bin', 0, false, false)
    local data = bins and bins[1] and readFile(bins[1])
    if not data or #data < TINT_PX * TINT_PX * 6 then return nil end
    local S = a.shirt and rgb(a.shirt) or {0, 0, 0}
    local T = a.trousers and rgb(a.trousers) or {0, 0, 0}
    local useS, useT = a.shirt and 1 or 0, a.trousers and 1 or 0
    local floor, min, max, byte, char = math.floor, math.min, math.max, string.byte, string.char
    local buf = require('string.buffer').new()
    local row = {}
    for y = 0, TINT_PX - 1 do
      local o = y * TINT_PX * 6
      for x = 0, TINT_PX - 1 do
        local r, g, b, shade, s8, t8 = byte(data, o + x * 6 + 1, o + x * 6 + 6)
        local ms, mt = s8 / 255 * useS, t8 / 255 * useT
        local keep = max(0, 1 - ms - mt)
        local k = x * 4
        row[k + 1] = min(255, floor(r * keep + shade * (S[1] * ms + T[1] * mt)))
        row[k + 2] = min(255, floor(g * keep + shade * (S[2] * ms + T[2] * mt)))
        row[k + 3] = min(255, floor(b * keep + shade * (S[3] * ms + T[3] * mt)))
        row[k + 4] = 255
      end
      for k = 1, TINT_PX * 4, 4096 do buf:put(char(unpack(row, k, min(k + 4095, TINT_PX * 4)))) end
      if y % BAKE_ROWS == BAKE_ROWS - 1 then coroutine.yield() end
    end
    local bmp = GBitmap()
    bmp:init(TINT_PX, TINT_PX, true)
    if not bmp:fromBuffer(buf) then return nil end
    local path = '/temp/slrr_drivers/' .. name .. '.color.png'
    bmp:saveFile(path)
    return path
  end)
end

-- the baked texture for a tint: its path once done, nil while the job runs (or if it can't be made)
local function bakeTint(d, a, name)
  local job = bakeJobs[name]
  if not job then
    job = bakeJob(d, a, name)
    bakeJobs[name] = job
  end
  if bakeResults[name] ~= nil then return bakeResults[name] or nil end
  return nil, 'baking'
end

local function runBakes()
  for name, job in pairs(bakeJobs) do
    if coroutine.status(job) ~= 'dead' then
      local ok, res = coroutine.resume(job)
      if not ok then log('E', 'slrrDrivers', 'tint bake failed: ' .. tostring(res)) end
      if coroutine.status(job) == 'dead' then bakeResults[name] = ok and res or false end
    end
  end
end

local function tintMaterial(d, a)
  if not a.shirt and not a.trousers then return d.skin .. '_driver' end
  local name = d.skin .. '_t' .. (hex(a.shirt) or 'x') .. (hex(a.trousers) or 'x') .. '_driver'
  if tints[name] and scenetree.findObject(name) then tintOrder = tintOrder + 1 tints[name].order = tintOrder return name end
  tints[name] = nil                      -- (a new level drops every material: one made in an earlier level is made again)
  local n, oldest = 0, nil
  for k, t in pairs(tints) do
    n = n + 1
    if t.users == 0 and (not oldest or t.order < tints[oldest].order) then oldest = k end
  end
  if n >= T.maxTints then
    if not oldest then log('W', 'slrrDrivers', 'too many clothing colours in use; this driver keeps his own') return d.skin .. '_driver' end
    local m = scenetree.findObject(oldest)
    if m then m:delete() end
    tints[oldest] = nil
  end
  local mats = jsonReadFile(ROOT .. d.id .. '/main.materials.json') or {}
  local _, base = next(mats)
  local stage0 = base and base.Stages and base.Stages[1] or {}
  local function file(pattern) local f = FS:findFiles(ROOT .. d.id .. '/', pattern, 0, false, false) return f and f[1] end
  local shade = file('*_shade.color.png')
  local stages = {stage0, {}, {}, {}}
  local baked, busy
  if tintMode == 'bake' then
    baked, busy = bakeTint(d, a, name)
    if busy then return nil end           -- not ready yet: the driver attaches when it is
  end
  if baked then
    local st = {}
    for k, v in pairs(stage0) do st[k] = v end
    st.baseColorMap = baked
    stages[1] = st
  end
  for i, g in ipairs(baked and {} or {'shirt', 'trousers'}) do
    local mask = file('*_' .. g .. '.data.png')
    if a[g] and shade and mask then
      stages[i + 1] = {baseColorMap = shade, baseColorFactor = rgb(a[g]), opacityMap = mask, roughnessFactor = 0.85, metallicFactor = 0}
    end
  end
  local path = '/temp/slrr_drivers/' .. name .. '.materials.json'
  jsonWriteFile(path, {[name] = {name = name, mapTo = name, class = 'Material', version = 1.5, materialTag0 = 'beamng', Stages = stages}}, true)
  loadJsonMaterialsFile(path)
  tintOrder = tintOrder + 1
  tints[name] = {users = 0, order = tintOrder}
  return name
end

local function helmetMaterial(a)
  local name = 'slrr_helmet_' .. (hex(a.helmetColor) or 'e6e6e6')
  if not scenetree.findObject(name) then
    local path = '/temp/slrr_drivers/' .. name .. '.materials.json'
    jsonWriteFile(path, {[name] = {name = name, mapTo = name, class = 'Material', version = 1.5, materialTag0 = 'beamng',
      Stages = {{baseColorFactor = a.helmetColor and rgb(a.helmetColor) or {0.9, 0.9, 0.9, 1}, roughnessFactor = 0.25, metallicFactor = 0, clearCoatFactor = 1}, {}, {}, {}}}}, true)
    loadJsonMaterialsFile(path)
  end
  return name
end

-- A flex driver's helmet colour, per car: the car's own helmet mesh is switched to a coloured material; the shared helmet
-- material stays as it is, so other cars keep theirs. Returns the skin's material, false while the car's meshes are not
-- known to the engine yet.
local flexSwitch = {}            -- vid -> switchable materials in use on its meshes
local flexTries = {}
local function flexLook(veh, vid, d, look)
  local fm = slrrDriverMount.getFlexMeshes and slrrDriverMount.getFlexMeshes(vid)
  if not fm then return d.skin .. '_driver' end
  if not slrrDriverMount.flexShown(vid) then return false end   -- (after the meshes were first shown: a switch before it left them invisible)
  local skinMat = d.skin .. '_driver'
  -- shirt and trousers: a switched tint showed no colour in game (flex driver stays in its own clothes), later item
  local used, want = {}, 0
  local function switch(from, to, mesh)
    want = want + 1
    local msc = veh:getSwitchableMaterial(from, from, mesh)
    if msc and msc >= 0 then veh:switchMaterial(msc, to) used[#used + 1] = msc end
  end
  local ok, err = pcall(function()
    for _, msc in ipairs(flexSwitch[vid] or {}) do veh:resetMaterials(msc) end
    flexSwitch[vid] = nil
    if fm.helmet and look.helmetColor then switch('base_helmet', helmetMaterial(look), fm.helmet) end
  end)
  if not ok then log('E', 'slrrDrivers', 'flex clothes failed: ' .. tostring(err)) end
  flexSwitch[vid] = used
  if #used > 0 then slrrDriverMount.showFlex(vid) end
  if #used < want then   -- the meshes are not in the engine yet: try again, for a while
    flexTries[vid] = (flexTries[vid] or 0) + 1
    if flexTries[vid] < 600 and ok then return false end
    log('W', 'slrrDrivers', 'flex clothes: ' .. #used .. ' of ' .. want .. ' meshes switched for ' .. tostring(vid))
  end
  flexTries[vid] = nil
  return skinMat
end

-- a body of another size: every joint and length scaled about the eyes (the seat frame's origin)
local function scaledRig(rig, k)
  local function sc(v) return v * k end
  local r = {model = rig.model, parts = {}, arms = {}, legs = {}, fist = {}, pelvis = sc(rig.pelvis)}
  for n, p in pairs(rig.parts) do r.parts[n] = sc(p) end
  for side, arm in pairs(rig.arms) do
    r.arms[side] = {shoulder = sc(arm.shoulder), elbow = sc(arm.elbow), wrist = sc(arm.wrist), la = arm.la * k, lb = arm.lb * k}
  end
  for side, leg in pairs(rig.legs or {}) do
    r.legs[side] = {hip = sc(leg.hip), knee = sc(leg.knee), ankle = sc(leg.ankle), ball = sc(leg.ball),
                    lt = leg.lt * k, lc = leg.lc * k, foot0 = sc(leg.foot0)}
  end
  for side, f in pairs(rig.fist or {}) do r.fist[side] = sc(f) end
  return r
end

local function removeCar(vid)
  local c = cars[vid]
  if not c then return end
  if c.material and tints[c.material] then tints[c.material].users = math.max(0, tints[c.material].users - 1) end
  for _, o in pairs(c.parts) do
    if type(o) == 'table' and o.isProp then o:delete()
    elseif o and simObjectExists and simObjectExists(o) then o:delete() end
  end
  cars[vid] = nil
  local veh = be:getObjectByID(vid)
  if veh then veh:queueLuaCommand('extensions.unload("slrrDriverFeed")') end
end

-- a car has a driver only while it's driven: the player is in it, or its AI is on (traffic, racers,
-- police). Parked, lot, garage and waiting cars and wrecks have AI off and stay empty.
local aiModes = {}      -- vehId -> AI mode, from the onAiModeChange hook (asked once for cars it predates)
local function askMode(vid)
  local veh = be:getObjectByID(vid)
  if veh then veh:queueLuaCommand('if ai then obj:queueGameEngineLua("slrrDrivers.onAiModeChange(" .. objectId .. ", \\"" .. tostring(ai.mode) .. "\\")") end') end
end
local function isDriven(vid)
  if vid == be:getPlayerVehicleID(0) then return true end
  local mode = aiModes[vid]
  if mode == nil then
    aiModes[vid] = false     -- asked: off until the car answers
    askMode(vid)
    return false
  end
  return mode ~= false and mode ~= 'disabled'
end

local function wantedDriver(vid)
  local id = choice[vid]
  if id == false then return nil end
  local veh = be:getObjectByID(vid)
  if veh and veh:getJBeamFilename() == 'unicycle' then return nil end   -- the on-foot player
  if not isDriven(vid) then return nil end
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
  local cam = c.cam0 or (nodes and nodes[c.camNode] and nodes[c.camNode].pos)
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
local function bodyPhysics(veh, c, dtSim, Rnow, eyeNow, camDist)
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
    if a:length() > T.swayAccMax then a = a:normalized() * T.swayAccMax end
    local w = 2 * math.pi * T.swayHz
    local steps = math.max(1, math.ceil(dtSim / 0.01))
    local h = dtSim / steps
    for _ = 1, steps do
      b.v = b.v + (-a * T.swayGain - b.d * (w * w) - b.v * (2 * T.swayDamp * w)) * h
      b.d = b.d + b.v * h
      b.d.z = 0
      if b.d:length() > T.seatbelt then
        local n = b.d:normalized()
        b.d = n * T.seatbelt
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

  if c.colNodes and #c.colNodes > 0 and camDist < T.collideDist then
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
                -- visual only: he stops against the car, the car never feels it (pushes popped door latches)
                if into > 0 then b.v = b.v + n * into end
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

-- The driver drawn by the car itself: slrrDriverMount adds his parts as vehicle props at spawn (meshes
-- <skin>_<part>). Each becomes an object with the calls slrrDrivers makes on a TSStatic; a pose is
-- turned into the car's own jbeam frame, so the car renders it with the seat, with no lag and no blur.
-- a vector with every component a finite number (a NaN or inf in a transform hangs the GPU: never written)
local function finite(v) return v.x == v.x and v.y == v.y and v.z == v.z and math.abs(v.x) < 1e6 and math.abs(v.y) < 1e6 and math.abs(v.z) < 1e6 end
local badWrites = 0           -- transforms refused (getPerf's third value, for QA)

local propConvention = 1   -- how a pose maps onto the prop's base transform (setPropConvention, for calibration)
local PROP_STILL = 0.0002  -- m (and per axis unit): a smaller move leaves the prop where it is
local function propPart(c, p)
  local o = {isProp = true, prop = p, hidden = false, m = MatrixF(true)}
  function o:setTransform(m)
    self.m = m
    local R, eye, cam = c.frameR, c.frameEye, c.cam0
    if not (R and eye and cam) then return end
    local t0 = prof.on and os.clock()
    local d = m:getPosition() - eye
    local function jb(v) return vec3(-v:dot(R.x), -v:dot(R.y), v:dot(R.z)) end   -- world -> seat -> jbeam axes
    local t, x, y = vec3(cam) + jb(d), jb(m:getColumn(0)), jb(m:getColumn(1))
    if not (finite(t) and finite(x) and finite(y)) then badWrites = badWrites + 1 return end
    -- the two engine calls only when the part moved: at a steady pose most parts sit still (J6)
    local last = self.last
    if last and last.t:distance(t) < PROP_STILL and last.x:distance(x) < PROP_STILL and last.y:distance(y) < PROP_STILL then return end
    self.last = {t = t, x = x, y = y}
    local mj = MatrixF(true)
    mj:setColumn(0, x)
    mj:setColumn(1, y)
    mj:setColumn(2, jb(m:getColumn(2)))
    if propConvention == 2 then mj:inverse() end
    p:setBaseTranslationGlobal(t)
    p:setBaseRotationGlobalQuat(mj:toQuatF())   -- a QuatF: quat() would make cdata, which the prop rejects (B20)
    if t0 then prof.place = prof.place + os.clock() - t0 end
  end
  function o:getTransform() return self.m end
  function o:setHidden(h) self.hidden = h p:setVisible(not h) end
  function o:isHidden() return self.hidden end
  function o:delete() p:setVisible(false) end
  return o
end

-- A flex driver (slrrDriverMount, driverRig 'flex') is drawn by the car from its own nodes: its parts here only record where
-- each joint should be (seat frame); flushFlex sends those to the car (slrrDriverFeed.pose), which moves the nodes.
local function flexPart(c)
  local o = {isProp = true, hidden = false, m = MatrixF(true)}   -- (isProp: removeCar calls delete)
  function o:setTransform(m)
    self.m = m
    local R, eye = c.frameR, c.frameEye
    if not (R and eye) then return end
    local function seat(v) return vec3(v:dot(R.x), v:dot(R.y), v:dot(R.z)) end
    local p = seat(m:getPosition() - eye)
    if finite(p) then self.p, self.y, self.z = p, seat(m:getColumn(1)), seat(m:getColumn(2)) end
  end
  function o:getTransform() return self.m end
  function o:setHidden(h) self.hidden = h end
  function o:isHidden() return self.hidden end
  function o:delete() end
  return o
end

local FLEX_JOINT = {{'r_forearm', 'r_el'}, {'l_forearm', 'l_el'}, {'r_hand', 'r_wr'}, {'l_hand', 'l_wr'},
                    {'r_calf', 'r_kn'}, {'l_calf', 'l_kn'}, {'r_foot', 'r_an'}, {'l_foot', 'l_an'}}
local FLEX_SEND = 1 / 30           -- the player's driver; other cars' every 1/20 s
local FLEX_SEND_OTHER = 1 / 20
local FLEX_FACE = vec3(0, 0.14, 0.12)   -- the face node, same frame
local FLEX_HEAD = vec3(0, 0.04, 0.12)   -- the head node from the neck, at rest (slrrDriverMount's ragdoll)
local function flushFlex(vid, c)
  if c.flexPause and c.flexPause > 0 then c.flexPause = c.flexPause - (c.lastDt or 0) return end
  local out = {}
  for _, j in ipairs(FLEX_JOINT) do
    local o = c.parts[j[1]]
    if not (o and o.p) then return end
    out[#out + 1] = o.p
  end
  local h = c.parts.head
  if not (h and h.p and h.y and h.z and finite(h.y) and finite(h.z)) then return end
  local ax = h.y:cross(h.z)   -- x = y cross z
  out[#out + 1] = h.p + ax * FLEX_HEAD.x + h.y * FLEX_HEAD.y + h.z * FLEX_HEAD.z
  out[#out + 1] = h.p + ax * FLEX_FACE.x + h.y * FLEX_FACE.y + h.z * FLEX_FACE.z
  for _, p in ipairs(out) do if not finite(p) then return end end   -- a NaN would reach the car as text and break its pose()
  c.sendWait = (c.sendWait or 0) + (c.lastDt or 0)
  if c.sent and c.sendWait < (vid == be:getPlayerVehicleID(0) and FLEX_SEND or FLEX_SEND_OTHER) then return end   -- at most 30 a second: the car eases between them
  local moved = not c.sent
  if c.sent then for i, p in ipairs(out) do if p:distance(c.sent[i]) > 0.0015 then moved = true break end end end
  if not moved then return end
  c.sent, c.sendWait = out, 0
  local veh = be:getObjectByID(vid)
  if not veh then return end
  local n = {}
  for _, p in ipairs(out) do n[#n + 1] = string.format('%.4f,%.4f,%.4f', p.x, p.y, p.z) end
  veh:queueLuaCommand('if slrrDriverFeed and slrrDriverFeed.pose then slrrDriverFeed.pose({' .. table.concat(n, ',') .. '}) end')
end

-- the props slrrDriverMount gave this car for a skin, part -> prop (nil unless all are there). Their
-- material is in the mesh: a material override on a prop crashes the engine, so clothing tints
-- (tinted materials) don't reach a driver drawn by the car
local function driverProps(veh, skin)
  local found, n = {}, 0
  local prefix = skin .. '_'
  for pid = 0, (veh.getPropCount and veh:getPropCount() or 0) - 1 do
    local p = veh:getProp(pid)
    local mesh = p and p:getMeshName() or ''
    if mesh:sub(1, #prefix) == prefix then found[mesh:sub(#prefix + 1)] = p n = n + 1 end
  end
  return n >= #PARTS and found or nil
end

local function driverBySkin(skin)
  for _, d in pairs(drivers) do if d.skin == skin then return d end end
end

-- a car with no driver camera (the pooled simple traffic): the eye 0.56 m behind and 0.30 m above the steering
-- wheel's hub, as an offset from the nearest car node (jbeam): the node id, then the offset
local function guessSeat(vid)
  local vd = core_vehicle_manager.getVehicleData(vid)
  local vdata = vd and vd.vdata
  if not (vdata and vdata.nodes and vdata.props) then return nil end
  local hub
  for _, p in pairs(vdata.props) do
    if type(p) == 'table' and p.func == 'steering' and type(p.baseTranslationGlobal) == 'table' then hub = p.baseTranslationGlobal break end
  end
  if not (hub and tonumber(hub.x)) then return nil end
  local cam = vec3(hub.x, hub.y + 0.56, hub.z + 0.30)
  local best, bd
  for cid, n in pairs(vdata.nodes) do
    if type(cid) == 'number' and n.pos then
      local d = vec3(n.pos):distance(cam)
      if not bd or d < bd then best, bd = cid, d end
    end
  end
  if not best then return nil end
  local p = vec3(vdata.nodes[best].pos)
  return best, {x = cam.x - p.x, y = cam.y - p.y, z = cam.z - p.z}
end

-- the parts slrrDriverMount gave a car sit at its driver's eye until they are posed: out of sight unless used
local function hideMount(vid)
  local veh = be:getObjectByID(vid)
  local mount = veh and slrrDriverMount and slrrDriverMount.getMount and slrrDriverMount.getMount(vid)
  for _, skin in ipairs({mount and mount.driver, mount and mount.passenger}) do
    for _, p in pairs(driverProps(veh, skin) or {}) do p:setVisible(false) end
  end
end

-- the joint frames and poles a rig needs for posing, set once per rig
local function prepRig(rig)
  if rig.prepped then return end
  rig.prepped = true
  for side, leg in pairs(rig.legs or {}) do
    local sx = side == 'r' and 1 or -1
    leg.pole = vec3(0.15 * sx, 0.5, 1)   -- knees bend up and a little out
    local n = (leg.knee - leg.hip):cross(leg.ankle - leg.hip)
    leg.F0t = basis(leg.knee - leg.hip, n)
    leg.F0c = basis(leg.ankle - leg.knee, n)
  end
  for side, arm in pairs(rig.arms) do
    local sx = side == 'r' and 1 or -1
    arm.pole = vec3(0.6 * sx, -0.2, -1)
    arm.F0u = basis(arm.elbow - arm.shoulder, (arm.elbow - arm.shoulder):cross(arm.wrist - arm.shoulder))
    arm.F0f = basis(arm.wrist - arm.elbow, (arm.elbow - arm.shoulder):cross(arm.wrist - arm.shoulder))
  end
end

-- slumped over the wheel (the injury add-on: knocked out, or dead): the torso leans forward from the pelvis, the head hangs
local slumped = {}

local function attach(vid)
  local id = wantedDriver(vid)
  if not id then removeCar(vid) hideMount(vid) return true end
  local veh = be:getObjectByID(vid)
  if not veh then return true end
  -- the player's car draws no props: hidden at once, not only when its camera data is ready (a car entered right after its spawn sat with
  -- the mount's unposed figure showing, on its roof, while the camera data came late)
  if vid == be:getPlayerVehicleID(0) then hideMount(vid) end
  local camNode, rhd = core_camera.getDriverDataById(vid)
  local mount = slrrDriverMount and slrrDriverMount.getMount and slrrDriverMount.getMount(vid)
  local seatOff            -- jbeam offset from camNode to the eye: a car with no driver camera (slrrDriverMount's guess)
  if not camNode and mount and mount.seat then camNode, seatOff = mount.seat.node, mount.seat.offset end
  if not camNode then camNode, seatOff = guessSeat(vid) end   -- (no mount seat either: from the wheel here, so the car is never left empty)
  if not camNode then return false end   -- camera data not ready yet, or a trailer / prop
  local d = drivers[id]
  -- every car but the player's is drawn by the car itself (W9): the prop driver slrrDriverMount gave it at
  -- spawn, in the skin it was given, with no body physics and no injuries. The player's car keeps the full
  -- driver (his own choice of skin), and its props stay hidden
  local player = vid == be:getPlayerVehicleID(0)
  local flex = slrrDriverMount and slrrDriverMount.hasFlexDriver and slrrDriverMount.hasFlexDriver(vid)
  local props
  if not player and not flex then
    local pd = mount and mount.driver and driverBySkin(mount.driver) or d
    props = driverProps(veh, pd.skin)
    if props then d = pd end
  end
  local flexSkin = flex and slrrDriverMount.getFlexSkin and slrrDriverMount.getFlexSkin(vid)
  if flexSkin and flexSkin ~= d.skin then d = driverBySkin(flexSkin) or d end   -- (the skin the car was built with, as the props)
  local rig = getRig(d.model)
  if not rig then log('E', 'slrrDrivers', 'missing rig for model ' .. tostring(d.model)) return true end
  local look = appearanceFor(vid)
  local size = clamp(tonumber(look.scale) or 1, 0.9, 1.1)
  if flex then size = slrrDriverMount.getFlexScale and slrrDriverMount.getFlexScale(vid) or 1 end   -- (the size it was built at)
  if math.abs(size - 1) > 1e-3 and not flex then rig = scaledRig(rig, size) props = nil end   -- (props can't be scaled)
  if flex and math.abs(size - 1) > 1e-3 then rig = scaledRig(rig, size) end
  local flexMat
  if flex then
    flexMat = flexLook(veh, vid, d, look)
    if not flexMat then return false end
  end
  local oldRec = cars[vid] and cars[vid].rec   -- (a recording goes on across a rebuild: an AI mode change or a part change rebuilds the driver)
  removeCar(vid)
  if not props then hideMount(vid) end

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
             e = {steer = 0, rpm = 0, maxrpm = 0, gear = 0, throttle = 0, brake = 0, clutch = 0}, reach = 0, slumped = slumped[vid],
             eyeOff = seatOff and vec3(-seatOff.x, -seatOff.y, seatOff.z) or nil}   -- (seat frame: x right, y forward)
  c.material = flex and flexMat or tintMaterial(d, look)
  if not c.material then return false end   -- a tint texture is still baking: try again next frame
  if tints[c.material] then tints[c.material].users = tints[c.material].users + 1 end
  local partList = {}
  for _, p in ipairs(PARTS) do table.insert(partList, p) end
  if look.helmet then table.insert(partList, 'helmet') end
  if props then
    local vd = core_vehicle_manager.getVehicleData(vid)
    local n = vd and vd.vdata and vd.vdata.nodes and vd.vdata.nodes[camNode]
    c.cam0 = n and (vec3(n.pos) + (seatOff and vec3(seatOff.x, seatOff.y, seatOff.z) or vec3(0, 0, 0)))
    if not c.cam0 then props = nil end
  end
  if flex then
    local vd = core_vehicle_manager.getVehicleData(vid)
    local n = vd and vd.vdata and vd.vdata.nodes and vd.vdata.nodes[camNode]
    if not n then return false end
    c.cam0, c.flex = vec3(n.pos), true
    c.head0 = rig.parts.head + vec3(0, 0.04, 0.12)   -- (the wave and the daze reach from it; the physics set-up, skipped for him, made it)
    partList = {}
    for _, p in ipairs(PARTS) do c.parts[p] = flexPart(c) end
  end
  for _, p in ipairs(partList) do
    if props and props[p] then
      local o = propPart(c, props[p])
      o:setHidden(false)
      c.parts[p] = o
      goto continue
    end
    local o = createObject('TSStatic')
    if p == 'helmet' then
      o:setField('shapeName', 0, skinnedShape(d.model, 'helmet', helmetMaterial(look), 'base_helmet'))
    else
      o:setField('shapeName', 0, skinnedShape(d.model, p, c.material))
    end
    if math.abs(size - 1) > 1e-3 then o.scale = vec3(size, size, size) end
    o:setField('collisionType', 0, 'None')
    o:setField('decalType', 0, 'None')
    o.canSave = false
    o:registerObject('')
    group:addObject(o)
    c.parts[p] = o
    ::continue::
  end
  c.drawnByCar = (props or flex) and true or false
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
  -- the gearbox: automatic, DCT and CVT cars keep both hands on the wheel
  c.manual = false
  if vdata and vdata.vdata and vdata.vdata.powertrain then
    for _, dev in pairs(vdata.vdata.powertrain) do
      local t = type(dev) == 'table' and tostring(dev.type or '') or ''
      if t == 'manualGearbox' or t == 'sequentialGearbox' then c.manual = true end
    end
  end
  -- H-pattern cars (BeamNG's propAnimation/hPattern): torsion hydros driven by hPatternAxisX/Y swing the
  -- lever, so their fourth node is the knob, moving through the gate on every shift
  if vdata and vdata.vdata and vdata.vdata.torsionHydros then
    for _, h in pairs(vdata.vdata.torsionHydros) do
      if type(h) == 'table' and (h.inputSource == 'hPatternAxisX' or h.inputSource == 'hPatternAxisY') and tonumber(h.id4) then
        c.knobNode = tonumber(h.id4)
        c.manual = true
        break
      end
    end
  end
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
      if type(p) == 'table' and p.func == 'steering' and tonumber(p.idRef) then
        c.wheelNode, c.wheelNodeX, c.wheelNodeY = tonumber(p.idRef), tonumber(p.idX), tonumber(p.idY)
        break
      end
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
  -- the car's mirrors (BeamNG's mirror list), for glances
  c.mirrors = {}
  if vdata and vdata.vdata and vdata.vdata.mirrors then
    for _, m in pairs(vdata.vdata.mirrors) do
      if type(m) == 'table' and tonumber(m.idRef) then table.insert(c.mirrors, tonumber(m.idRef)) end
    end
  end
  local floorZ
  local nodes = vdata and vdata.vdata and vdata.vdata.nodes
  local cam0 = nodes and nodes[camNode] and nodes[camNode].pos
  if cam0 and seatOff then cam0 = {x = cam0.x + seatOff.x, y = cam0.y + seatOff.y, z = cam0.z + seatOff.z} end
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
  -- which side of the car the seat is on: the eye against the car's reference node (jbeam +x is left)
  local refs = vdata and vdata.vdata and vdata.vdata.refNodes and vdata.vdata.refNodes[0]
  local centre = refs and nodes and nodes[refs.ref] and nodes[refs.ref].pos
  if cam0 and centre and math.abs(cam0.x - centre.x) > 0.05 then c.seatLeft = cam0.x > centre.x else c.seatLeft = not c.rhd end
  c.pedalZ = clamp(floorZ and (floorZ + PEDAL_ABOVE_FLOOR) or -0.97, -1.08, -0.85)   -- when nothing is measured
  -- the top edge of the passenger seat's back, for the arm he lays along it when reversing: the highest of the nodes of a seat part (a node group
  -- or part with 'seat' in its name, or a name like sf1l / sr2) on the passenger side of the car, behind and beside the eye. Nothing found: the old
  -- fixed place (SEAT_BACK_REACH) is used.
  if cam0 and nodes then
    local pside = c.seatLeft and 1 or -1
    local cand = {}
    for _, n in pairs(nodes) do
      if type(n) == 'table' and n.pos then
        local text = (nodeGroups(n) .. ' ' .. tostring(n.partOrigin or '')):lower()
        local nm = tostring(n.name or '')
        if (text:find('seat', 1, true) and not text:find('belt', 1, true)) or nm:match('^s[fr]%d') then
          local l = vec3(cam0.x - n.pos.x, cam0.y - n.pos.y, n.pos.z - cam0.z)
          if l.x * pside > 0.3 and l.x * pside < 1.2 and l.y > -0.6 and l.y < 0.5 and l.z > -0.8 and l.z < 0.2 then cand[#cand + 1] = l end
        end
      end
    end
    if #cand >= 3 then
      table.sort(cand, function(a, b) return a.z > b.z end)
      local top = {}
      for _, l in ipairs(cand) do if l.z > cand[1].z - 0.1 then top[#top + 1] = l end end   -- the top edge of the back
      table.sort(top, function(a, b) return math.abs(a.x) < math.abs(b.x) end)   -- the inner part of it, nearest him
      local n = math.min(2, #top)
      c.seatBack = (n == 2 and (top[1] + top[2]) / 2 or top[1]) + vec3(0, 0, 0.045)   -- (the wrist rests a little above the edge)
    end
  end
  -- the footwell's surfaces: the car's collision triangles in front of the seat (floor, toe board,
  -- firewall), which the feet measure with rays (the lowest node is often chassis under the floor)
  c.well = {}
  local tris = vdata and vdata.vdata and vdata.vdata.triangles
  if cam0 and tris then
    local function inWell(n)
      if not (n and n.pos) then return false end
      local l = vec3(cam0.x - n.pos.x, cam0.y - n.pos.y, n.pos.z - cam0.z)
      return math.abs(l.x) < 0.9 and l.y > 0.1 and l.y < 1.9 and l.z > -1.8 and l.z < -0.3
    end
    for _, t in pairs(tris) do
      if type(t) == 'table' then
        local a, b, cc = tonumber(t.id1), tonumber(t.id2), tonumber(t.id3)
        if a and b and cc and (inWell(nodes[a]) or inWell(nodes[b]) or inWell(nodes[cc])) then
          table.insert(c.well, {a, b, cc})
        end
      end
    end
  end
  prepRig(rig)
  c.feet = {r = {pedal = 'throttle'}, l = {pedal = c.hasClutch and 'clutch' or 'rest'}}
  -- the hand nearest the middle of the car shifts
  c.shiftSide = c.rhd and 'l' or 'r'
  c.inward = c.rhd and -1 or 1
  c.mass = d.mass or T.driverMass
  if not flex then setupCollision(c, vid) end
  if flex then
    local vd = core_vehicle_manager.getVehicleData(vid)
    local nd = vd and vd.vdata and vd.vdata.nodes
    local function at(cid)
      local n = cid and nd and nd[cid]
      return n and n.pos and string.format('(%.2f %.2f %.2f)', n.pos.x, n.pos.y, n.pos.z) or 'none'
    end
    log('I', 'slrrDrivers', string.format('flex driver in %s: eye node %s %s, steering hub %s, rhd %s, pedalZ %.2f, shifter %s, manual %s',
      tostring(veh:getJBeamFilename()), tostring(camNode), at(camNode), at(c.wheelNode), tostring(c.rhd), c.pedalZ or 0, tostring(c.shifterNode), tostring(c.manual)))
  end
  -- the passenger slrrDriverMount gave the car (W9): posed once beside the driver, then he rides with the car.
  -- Never in the player's car (it keeps the full driver, its props stay hidden): a car bought on a lot got its roll at spawn
  local pd = not player and mount and mount.passenger and mount.passengerAt and driverBySkin(mount.passenger)
  local pp = pd and driverProps(veh, pd.skin)
  local prig = pd and getRig(pd.model)
  if pp and prig and cam0 then
    local at = mount.passengerAt
    -- the passenger's eye from the driver's, in the seat frame (jbeam x is the car's left, y its back)
    local pc = {cam0 = vec3(at.x, at.y, at.z)}
    c.passenger = {ctx = pc, rig = prig, offset = vec3(cam0.x - at.x, cam0.y - at.y, at.z - cam0.z)}
    for _, p in ipairs(PARTS) do
      local o = propPart(pc, pp[p])
      o:setHidden(false)
      c.parts['pass_' .. p] = o
    end
  end
  c.rec = oldRec
  cars[vid] = c
  veh:queueLuaCommand(string.format('extensions.load("slrrDriverFeed") slrrDriverFeed.setDriverMass(%d, %g)', camNode,
    (slrrDriverMount and slrrDriverMount.hasFlexDriver and slrrDriverMount.hasFlexDriver(vid)) and 0 or c.mass))   -- (a flex driver's mass is its nodes')
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
  if not (finite(pos) and finite(axes.x) and finite(axes.y) and finite(axes.z)) then badWrites = badWrites + 1 return end
  local m = MatrixF(true)
  m:setColumn(0, rotate(R, axes.x))
  m:setColumn(1, rotate(R, axes.y))
  m:setColumn(2, rotate(R, axes.z))
  m:setPosition(pos)
  o:setTransform(m)
end

-- A joint target that moves smoothly: a low-pass that never moves faster than maxSpeed (m/s), and
-- snaps straight there after a jump (respawn, reset) so the driver never trails off.
local function follow(c, key, target, dt, maxSpeed, smooth)
  c.smooth = c.smooth or {}
  local p = c.smooth[key]
  if not p or p:distance(target) > 0.5 or dt <= 0 then c.smooth[key] = target return target end
  local step = (target - p) * math.min(1, dt * (smooth or 45))
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
    -- a manual shift: the clutch goes down with it (unless the car's own clutch input says more)
    if k == 'clutch' and animated and c.hasClutch and c.shiftT and c.shiftT < T.shiftTime * 0.8 then want = math.max(want, 1) end
    press[k] = press[k] + clamp(want - press[k], -dt * 8, dt * 8)
  end
  local right = c.feet.r
  local wantR = (press.brake > 0.02 and press.brake >= press.throttle) and 'brake' or 'throttle'
  if wantR ~= right.pedal and not right.t then right.from, right.pedal, right.t = right.pedal, wantR, 0 end
  c.feet.l.pedal = c.hasClutch and 'clutch' or 'rest'
  local function pad(name)
    local p = c.pads and c.pads[name] or vec3(wheel.x + PEDAL_X[name], PEDAL_Y, c.pedalZ)
    p = p - (c.seat or vec3(0, 0, 0))   -- in the driver's moved seat
    if name == 'rest' then p = p + vec3(0, -0.08, 0.02) end
    p = p + PEDAL_TRAVEL * press[name]
    -- a pressed pad never takes the foot through its measured firewall
    local w = c.wall and c.wall[name]
    if w then p.y = math.min(p.y, w - (c.seat and c.seat.y or 0) - 0.03) end
    return p
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
    target = follow(c, side .. 'Foot', target, dt, T.jointSpeed)
    local ankleTarget = target - rotate(footRot, leg.foot0)
    -- legs that cannot reach pull the pedals in toward the seat
    local reach = (leg.lt + leg.lc) * 0.92   -- the knee always stays a little bent
    local d = ankleTarget - leg.hip
    if d:length() > reach then ankleTarget = leg.hip + d:normalized() * reach end
    -- never through the floor: the ankle stays above it (the heel sits below the ankle)
    local fl = c.ankleFloor and math.max(c.ankleFloor[f.pedal] or -9, f.from and c.ankleFloor[f.from] or -9)
    if fl and fl > -9 and ankleTarget.z < fl + SOLE then ankleTarget.z = fl + SOLE end
    local knee, ankle = ik(leg.hip, ankleTarget, leg.lt, leg.lc, leg.pole)
    c.feetAt = c.feetAt or {}
    c.feetAt[side] = {ankle = ankle + (c.seat or vec3(0, 0, 0)), ball = target + (c.seat or vec3(0, 0, 0)), knee = knee + (c.seat or vec3(0, 0, 0))}
    local n = (knee - leg.hip):cross(ankle - leg.hip)
    place(c.parts[side .. '_thigh'], world(leg.hip), R, delta(basis(knee - leg.hip, n), leg.F0t))
    place(c.parts[side .. '_calf'], world(knee), R, delta(basis(ankle - knee, n), leg.F0c))
    place(c.parts[side .. '_foot'], world(ankle), R, footRot)
  end
end

-- Pose recorder (tools/render_pose.py turns a recording into a clip): every frame, each part's pose in
-- the seat frame (position, then its x y z axes), plus what the car was doing.
local function record(c, eye, R, dt, veh, wheel)
  local function loc(v) return {v:dot(R.x), v:dot(R.y), v:dot(R.z)} end
  local vp = veh:getPosition()
  local fr = {dt = dt, eyeW = {eye.x, eye.y, eye.z}, carW = {vp.x, vp.y, vp.z}, speed = vec3(veh:getVelocity()):length(), steer = c.e.steer, throttle = c.e.throttle,
              brake = c.e.brake, clutch = c.e.clutch, gear = c.e.gear, wheel = {wheel.x, wheel.y, wheel.z}, parts = {},
              reach = c.reach or 0, shiftSide = c.shiftSide, perfMs = perfMs,
              regrip = {r = c.hands and c.hands.r.t and 1 or 0, l = c.hands and c.hands.l.t and 1 or 0},
              revK = c.revK or 0, revHand = (c.seatLeft and 'r' or 'l'), daze = c.dazeK or 0,
              look = {w = c.lookW or 0, yaw = c.lookYaw or 0, pitch = c.lookPitch or 0},
              grip = c.lastGrips and {r = math.deg(c.lastGrips.r.a), l = math.deg(c.lastGrips.l.a)} or nil}
  -- the feet against the measured footwell (gate: above the floor, behind the firewall)
  if c.feetAt and c.ankleFloor then
    fr.feet = {}
    for side, f in pairs(c.feetAt) do
      local pedal, from = c.feet[side].pedal, c.feet[side].t and c.feet[side].from
      local fl, w = c.ankleFloor[pedal], c.wall[pedal]
      if from and c.wall[from] and (not w or c.wall[from] < w) then w = c.wall[from] end   -- moving between pedals
      fr.feet[side] = {floor = fl and (math.min(f.ankle.z, f.ball.z) - fl) or nil, wall = w and (w - f.ball.y) or nil}
    end
  end
  for name, o in pairs(c.parts) do
    local m = o:getTransform()
    local p = loc(m:getPosition() - eye)
    local x, y, z = loc(m:getColumn(0)), loc(m:getColumn(1)), loc(m:getColumn(2))
    fr.parts[name] = {p[1], p[2], p[3], x[1], x[2], x[3], y[1], y[2], y[3], z[1], z[2], z[3], o:isHidden() and 1 or 0}
  end
  table.insert(c.rec, fr)
  if #c.rec > 60 * 120 then table.remove(c.rec, 1) end   -- keep the last two minutes
end

-- The steering wheel, live (sets the rim frame for this car; see liveWheel's caller)
local function liveWheel(c, toSeat)
  -- the wheel, live: the hub must look like a wheel on the first frame; after that it is followed, so a
  -- column pushed in by a crash brings the rim (and the hands) closer and tilts it with the prop's nodes
  local wheel = WHEEL_CENTER
  wheelX, wheelN, wheelUp = WHEEL_X0, WHEEL_N0, WHEEL_UP0
  if c.wheelNode then
    local l = toSeat(c.wheelNode)
    local function frame()
      if not (c.wheelNodeX and c.wheelNodeY) then return nil end
      local ax, ay = toSeat(c.wheelNodeX) - l, toSeat(c.wheelNodeY) - l
      if ax:length() < 1e-3 or ay:length() < 1e-3 or ax:cross(ay):length() < 1e-4 * ax:length() * ay:length() then return nil end
      return basis(ay, ax)
    end
    if c.hub0 == nil then
      c.hub0 = (math.abs(l.x) < 0.25 and l.y > 0.3 and l.y < 0.85 and l.z > -0.6 and l.z < -0.1) and l or false
      c.hubF0 = c.hub0 and frame() or nil
    end
    if c.hub0 then
      local off = l - c.hub0
      if off:length() > HUB_MOVE then l = c.hub0 + off:normalized() * HUB_MOVE end
      wheel = l + WHEEL_HUB_TO_RIM
      local F = c.hubF0 and frame()
      if F then
        local D = delta(F, c.hubF0)
        if D.x.x + D.y.y + D.z.z > 1 + 2 * math.cos(0.6) then   -- bent less than ~35 degrees: believe it
          wheelX, wheelN, wheelUp = rotate(D, WHEEL_X0), rotate(D, WHEEL_N0), rotate(D, WHEEL_UP0)
        end
      end
    end
  end
  return wheel
end

local function measureWell(c, wheel, toSeat, dt)
  -- the footwell, measured with rays against the car's own triangles every WELL_REFRESH s (live: a crushed
  -- floor or firewall moves the pedals with it). The pads go a little behind the firewall / toe board and
  -- PEDAL_ABOVE_FLOOR over the floor under them; nothing measured keeps the fixed layout.
  if c.well and #c.well > 0 then
    c.wellT = (c.wellT or WELL_REFRESH) + dt
    if c.wellT >= WELL_REFRESH then
      c.wellT = 0
      local pts, tri = {}, {}
      local function P(cid) local q = pts[cid] if not q then q = toSeat(cid) pts[cid] = q end return q end
      for i, t in ipairs(c.well) do
        local a, b, cc = P(t[1]), P(t[2]), P(t[3])
        tri[i] = {a, b, cc, math.min(a.x, b.x, cc.x), math.max(a.x, b.x, cc.x), math.min(a.y, b.y, cc.y),
                  math.max(a.y, b.y, cc.y), math.min(a.z, b.z, cc.z), math.max(a.z, b.z, cc.z)}
      end
      -- the rays run along an axis (down or forward): a triangle whose box misses the ray's line is skipped
      local function cast(o, d, maxT)
        local best
        for _, t in ipairs(tri) do
          local h = o.x >= t[4] and o.x <= t[5]
            and (d.z ~= 0 and o.y >= t[6] and o.y <= t[7] or d.y ~= 0 and o.z >= t[8] and o.z <= t[9])
            and rayTri(o, d, t[1], t[2], t[3])
          if h and h <= maxT and (not best or h < best) then best = h end
        end
        return best
      end
      -- the floor: the first surface below hip height (the dash is above it, the chassis below)
      local function floorAt(x, y)
        local h = cast(vec3(x, y, -0.75), vec3(0, 0, -1), 0.8)
        return h and -0.75 - h or nil
      end
      c.pads, c.ankleFloor, c.wall = {}, {}, {}
      for name, px in pairs(PEDAL_X) do
        local x = wheel.x + px
        local f = floorAt(x, PEDAL_Y) or floorAt(x, PEDAL_Y - 0.2)
        if f then
          local w = cast(vec3(x, 0.2, f + SOLE + 0.04), vec3(0, 1, 0), 1.6)
          local y = w and math.min(PEDAL_Y, 0.2 + w - PAD_FROM_WALL) or PEDAL_Y
          local fp = floorAt(x, y) or f
          c.pads[name] = vec3(x, y, fp + PEDAL_ABOVE_FLOOR)
          c.ankleFloor[name] = (floorAt(x, y - 0.15) or fp) - (c.seat and c.seat.z or 0)
          c.wall[name] = w and 0.2 + w or nil
        end
      end
      if not next(c.pads) then c.pads, c.ankleFloor, c.wall = nil, nil, nil end
    end
  end
end

local function updateDaze(c, veh, R, dt, dtSim, fp)
  -- after a crash (a hard horizontal jolt) he holds his head for a moment, once the car has slowed down;
  -- never at speed, and not in the player's own first-person view
  local vel = vec3(veh:getVelocity())
  if c.lastVel and dtSim > 0 then
    local dv = vel - c.lastVel
    dv = dv - R.z * dv:dot(R.z)                 -- kerbs and landings jolt vertically: not a crash
    if dv:length() > T.crashDv then c.sinceCrash = 0 end
    c.lastVel = c.lastVel + (vel - c.lastVel) * math.min(1, dtSim / CRASH_LAG)
  else
    c.lastVel = vel
  end
  if c.sinceCrash then
    c.sinceCrash = c.sinceCrash + dt
    if c.sinceCrash > T.dazeWait then c.sinceCrash = nil end
  end
  local slow = vel:length() < DAZE_SPEED
  local reversing = (c.e.gear or 0) < 0
  if c.sinceCrash and slow and not c.daze and animated and not fp and not reversing then c.daze, c.sinceCrash = 0, nil end
  if c.daze then
    c.daze = c.daze + dt
    if not slow or fp or not animated or reversing then c.daze = math.max(c.daze, T.dazeTime - DAZE_OUT) end   -- back to the wheel now
    if c.daze >= T.dazeTime then c.daze = nil end
  end
  c.dazeK = c.daze and clamp(math.min(c.daze / DAZE_IN, (T.dazeTime - c.daze) / DAZE_OUT), 0, 1) or 0
  if c.wave then
    c.wave.t = c.wave.t + dt
    if c.wave.t >= c.wave.dur or not animated or fp then c.wave = nil end
  end
  c.waveK = c.wave and clamp(math.min(c.wave.t / GEST.waveIn, (c.wave.dur - c.wave.t) / GEST.waveIn), 0, 1) or 0

end

-- Third-person look: in the player's car, outside first person, the head (and a little of the torso)
-- turns toward where the camera looks; weighted down at speed, hard steering and braking (eyes on the
-- road). Sets c.lookYaw / c.lookPitch (total turn) and c.lookW (blend).
local function updateLook(c, vid, R, dt, fp, speed)
  local e = c.e
  local on = animated and not fp and vid == be:getPlayerVehicleID(0)
  c.lookW = (c.lookW or 0) + clamp((on and 1 or 0) - (c.lookW or 0), -dt * 2, dt * 2)
  local wantYaw, wantPitch = 0, 0
  local q = on and core_camera.getQuat()
  if q then
    local look = q * vec3(0, 1, 0)
    local lx, ly, lz = look:dot(R.x), look:dot(R.y), look:dot(R.z)
    local yaw = math.atan2(-lx, ly)
    local limit = T.lookHead + LOOK_TORSO
    if math.abs(yaw) > LOOK_GIVE_UP then yaw = 0 else yaw = clamp(yaw, -limit, limit) end
    local w = clamp(1 - (speed - 10) / 15 * 0.7, 0.3, 1)                  -- 30 % above 25 m/s
    w = w * (1 - clamp(math.abs(e.steer or 0) / 270, 0, 0.7)) * (1 - 0.6 * clamp(e.brake or 0, 0, 1))
    wantYaw = yaw * w
    wantPitch = clamp(math.atan2(lz, math.sqrt(lx * lx + ly * ly)) * 0.6, -LOOK_PITCH_DOWN, LOOK_PITCH_UP) * w
  end
  -- critically damped, speed limited
  c.lookYaw, c.lookPitch = c.lookYaw or 0, c.lookPitch or 0
  c.lookVy, c.lookVp = c.lookVy or 0, c.lookVp or 0
  c.lookVy = clamp(c.lookVy + (LOOK_W * LOOK_W * (wantYaw - c.lookYaw) - 2 * LOOK_W * c.lookVy) * dt, -T.lookSpeed, T.lookSpeed)
  c.lookVp = clamp(c.lookVp + (LOOK_W * LOOK_W * (wantPitch - c.lookPitch) - 2 * LOOK_W * c.lookVp) * dt, -T.lookSpeed, T.lookSpeed)
  c.lookYaw, c.lookPitch = c.lookYaw + c.lookVy * dt, c.lookPitch + c.lookVp * dt
end

-- the passenger: sat back, hands in the lap, feet on the floor; posed once, in the seat beside the driver
local function posePassenger(c, R, eye)
  local p = c.passenger
  local rig = p.rig
  prepRig(rig)
  p.ctx.frameR, p.ctx.frameEye = R, eye + rotate(R, p.offset)
  local function world(q) return p.ctx.frameEye + rotate(R, q) end
  local function part(name) return c.parts['pass_' .. name] end
  place(part('body'), world(vec3(0, 0, 0)), R, IDENT)
  place(part('head'), world(rig.parts.head), R, IDENT)
  for side, arm in pairs(rig.arms) do
    local sx = side == 'r' and 1 or -1
    local elbow, wrist = ik(arm.shoulder, vec3(0.14 * sx, 0.30, -0.42), arm.la, arm.lb, arm.pole)
    local n = (elbow - arm.shoulder):cross(wrist - arm.shoulder)
    local Df = delta(basis(wrist - elbow, n), arm.F0f)
    place(part(side .. '_upperarm'), world(arm.shoulder), R, delta(basis(elbow - arm.shoulder, n), arm.F0u))
    place(part(side .. '_forearm'), world(elbow), R, Df)
    place(part(side .. '_hand'), world(wrist), R, Df)
  end
  for side, leg in pairs(rig.legs or {}) do
    local sx = side == 'r' and 1 or -1
    local knee, ankle = ik(leg.hip, vec3(0.16 * sx, 0.55, c.pedalZ - 0.08), leg.lt, leg.lc, leg.pole)
    local n = (knee - leg.hip):cross(ankle - leg.hip)
    place(part(side .. '_thigh'), world(leg.hip), R, delta(basis(knee - leg.hip, n), leg.F0t))
    place(part(side .. '_calf'), world(knee), R, delta(basis(ankle - knee, n), leg.F0c))
    place(part(side .. '_foot'), world(ankle), R, IDENT)
  end
  p.posed = true
end

local FLEX_ANIM_DIST = 150   -- m
local function updateCar(vid, c, dt, dtSim, camPos, fpVid)
  -- a still, far driver is re-checked every T.farSkip frames (the vehicle queries below are most of his cost)
  if c.farWait and c.farWait > 0 then c.farWait = c.farWait - 1 return end
  local veh = be:getObjectByID(vid)
  if not veh then removeCar(vid) return end
  local vpos = veh:getPosition()
  local eye = vec3(vpos) + vec3(veh:getNodePositionXYZ(c.camNode))
  if c.eyeOff then eye = eye + rotate(basis(vec3(veh:getDirectionVector()):normalized(), vec3(veh:getDirectionVectorUp())), c.eyeOff) end
  local mode = carMode[vid] or displayMode
  animated = mode == 'full' or mode == 'hideFirstPerson'
  local fpView = vid == fpVid
  -- the player's own car is always near: in the driver camera core_camera.getPosition() stays where the
  -- camera was last placed, which culled and froze him after 40-150 m of driving (B47)
  local camDist = (fpView or vid == be:getPlayerVehicleID(0)) and 0 or eye:distance(camPos)
  local off = camDist > T.cullDist or mode == 'hidden' or (mode == 'hideFirstPerson' and fpView)
  if off ~= c.hidden then
    for _, o in pairs(c.parts) do o:setHidden(off) end
    c.hidden, c.headHidden = off, off
  end
  if off then return end
  -- drawn by the car and still, or further than T.animDist from the camera: his last pose rides with the car
  -- at no cost (the props keep their base transforms), which is what pays for 14 traffic drivers (J6)
  -- (a rigged driver is a real body in a car somebody watches, not one of 14 in traffic: animated up to FLEX_ANIM_DIST at least; the
  -- game log showed a flex driver in a car 40 m or more from the camera frozen for 200 s, the wheel never turned his hands)
  local animDist = c.flex and math.max(T.animDist, FLEX_ANIM_DIST) or T.animDist
  if c.drawnByCar and c.posed and (not animated or camDist > animDist) then
    c.farWait = camDist > animDist + 10 and T.farSkip or 0   -- (a car moves T.farSkip frames before it is looked at again)
    if c.flex and animated and (not c.frozenLog or os.clock() - c.frozenLog > 10) then
      c.frozenLog = os.clock()
      log('I', 'slrrDrivers', string.format('flex driver in %s not animated: %.0f m from the camera (limit %.0f m)', tostring(vid), camDist, animDist))
    end
    return
  end
  local fwd = vec3(veh:getDirectionVector()):normalized()
  local up = vec3(veh:getDirectionVectorUp())
  local eyeNow, Rnow = eye, basis(fwd, up)   -- for measuring the car's own nodes
  -- TSStatic transforms show up one frame late, so the driver is placed where the car will be
  -- when this frame is drawn: one step of its velocity and turn rate ahead
  if dtSim > 0 and not c.flex then
    -- the frame time is averaged (a jumpy dt made the driver jitter at speed); rotation isn't led, the
    -- car's direction vectors are too noisy for it
    -- the guard is on the frame time, not the distance: a distance cap dropped the lead at speed (50 m/s
    -- at 30 fps is 1.7 m a frame) and the driver jumped a frame back and forth around the cap
    c.dtAvg = c.dtAvg and lerp(c.dtAvg, math.min(dtSim, 0.1), 0.05) or math.min(dtSim, 0.1)
    eye = eye + vec3(veh:getVelocity()) * (c.dtAvg * LEAD_FRAMES)
  end
  local R = basis(fwd, up)   -- seat frame -> world
  c.frameR, c.frameEye = R, eye   -- parts drawn by the car are posed relative to these
  if c.passenger and not c.passenger.posed then posePassenger(c, R, eye) end
  local function world(p) return eye + rotate(R, c.seat and (p + c.seat) or p) end
  local rig, e = c.rig, c.e

  local t0 = prof.on and os.clock()
  -- no body physics for a driver drawn by the car (W9: the cheap driver); the player's full driver keeps it
  local L = animated and not c.drawnByCar and bodyPhysics(veh, c, dtSim, Rnow, eyeNow, camDist) or IDENT
  if t0 then prof.body = prof.body + os.clock() - t0 end
  -- reversing at walking pace: he twists round to look out of the back (not in the player's own view)
  local reversing = animated and vid ~= fpVid and (e.gear or 0) < 0 and vec3(veh:getVelocity()):length() < T.reverseLookSpeed
  c.revK = (c.revK or 0) + clamp((reversing and 1 or 0) - (c.revK or 0), -dt * 2, dt * 2)
  local back = c.seatLeft and -1 or 1   -- toward the passenger side (yaw is positive to the left)
  if c.revK > 0 then L = compose(L, rotZ(back * REVERSE_TWIST * smootheststep(c.revK))) end
  -- slow with the wipers on: he leans forward a little to see through the wet windscreen (not the rigged driver: his torso is fixed)
  if not c.flex then
    local wet = animated and c.wipersOn and T.rainLean > 0 and vec3(veh:getVelocity()):length() < 7
    c.rainK = (c.rainK or 0) + clamp((wet and 1 or 0) - (c.rainK or 0), -dt * 0.5, dt * 0.5)
    if c.rainK > 0 then L = compose(L, rotX(-T.rainLean * smootheststep(c.rainK))) end
  end
  updateLook(c, vid, R, dt, vid == fpVid, vec3(veh:getVelocity()):length())
  local lookTorso = c.lookW * c.lookYaw * LOOK_TORSO / (T.lookHead + LOOK_TORSO) * (1 - (c.revK or 0))
  if math.abs(lookTorso) > 1e-4 then L = compose(L, rotZ(lookTorso)) end
  if c.reachLean then L = compose(L, c.reachLean) end
  c.slumpK = clamp((c.slumpK or 0) + clamp((c.slumped and 1 or 0) - (c.slumpK or 0), -dt / GEST.slumpTime, dt / GEST.slumpTime), 0, 1)
  if c.slumpK > 0 and animated then L = compose(L, rotX(-GEST.slumpTorso * smootheststep(c.slumpK))) end
  -- idle: slow breathing in the chest (and so the shoulders), always on when animated
  c.clock = (c.clock or math.random() * 10) + dt
  if animated then L = compose(L, rotX(T.breathAngle * math.sin(2 * math.pi * BREATH_HZ * c.clock))) end
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
    local t = c.shiftT / T.shiftTime
    local a, b = gearSlot(c.fromGear), gearSlot(e.gear)
    local na, nb = vec3(a.x, 0, 0), vec3(b.x, 0, 0)
    if t < 1 / 3 then knob = lerp(a, na, t * 3)
    elseif t < 2 / 3 then knob = lerp(na, nb, t * 3 - 1)
    else knob = lerp(nb, b, math.min(1, t * 3 - 2)) end
    if c.shiftT > T.shiftTime + 0.15 then c.shiftT = nil end
  end
  -- no reaching for the lever while the wheel is turned well over (both hands are busy steering)
  local revsHigh = c.manual and e.maxrpm > 0 and e.rpm / e.maxrpm > T.reachRpm and e.gear > 0 and math.abs(e.steer) < 70
  local want = (animated and (c.shiftT or revsHigh)) and 1 or 0
  c.reach = c.reach + clamp(want - c.reach, -dt * 3, dt * (c.shiftT and 12 or 4))
  local leverTarget = lever + knob + vec3(0, -0.03, 0.07)
  if c.knobNode then
    local k = toSeat(c.knobNode)
    if math.abs(k.x) < 0.75 and k.y > -0.3 and k.y < 0.8 and k.z > -1.0 and k.z < 0 then
      leverTarget = k + KNOB_GRIP   -- palm on top of the knob, which the car moves through the gate itself
    end
  end

  local wheel = liveWheel(c, toSeat)
  c.wheelAt = wheel   -- (for slrrDriverMount.flexSnapshot)
  -- Reach (worked out once per car): drivers sit with the elbows bent, at about T.reach of full arm length.
  -- A wheel further away moves the seat forward (up to SEAT_SLIDE), then the rest is a lean from the
  -- hips, instead of the arms locking straight. Everything the driver reaches for is then measured from
  -- his moved seat, so the slide changes where he sits, not where the wheel and pedals are.
  if not c.reachLean then
    local need = 0
    for side, arm in pairs(rig.arms) do
      local d = rimPoint(wheel, HOME[side], 0):distance(arm.shoulder) - (arm.la + arm.lb) * T.reach
      need = math.max(need, d)
    end
    local slide = c.flex and 0 or clamp(need, 0, SEAT_SLIDE)   -- (a flex driver's torso is fixed: no slide, no lean)
    c.seat = vec3(0, slide, 0)
    local lever = (rig.parts.head - rig.pelvis):length()
    c.reachLean = need > slide and not c.flex and rotX(-clamp((need - slide) / lever, 0, 0.3)) or IDENT
  end
  measureWell(c, wheel, toSeat, dt)
  wheel = wheel - c.seat
  leverTarget = leverTarget - c.seat
  updateDaze(c, veh, R, dt, dtSim, vid == fpVid)
  local turn = animated and math.rad(e.steer) or 0
  local grips = updateHands(c, turn, dt)
  c.lastGrips = grips
  -- a reach for a stalk or switch (wipers, lights, indicators) with the hand on that side, out and back; never while the wheel is turned well
  -- over (both hands stay on it: a task waits up to 1.5 s for the wheel to come back, then is dropped) and it is cut short if the wheel
  -- is turned over during the reach
  local steerAbs = math.abs(e.steer or 0)
  local steerMax = math.deg(T.stalkSteerMax)
  if c.stalkQ and #c.stalkQ > 0 and not c.stalk then
    if not animated or T.stalkReach == 0 then c.stalkQ = {}
    elseif steerAbs < steerMax and not c.shiftT and c.reach < 0.1 then c.stalk = {side = table.remove(c.stalkQ, 1), t = 0} c.stalkWait = 0
    else
      c.stalkWait = (c.stalkWait or 0) + dt
      if c.stalkWait > 1.5 then c.stalkQ = {} c.stalkWait = 0 end
    end
  end
  c.stalkK = 0
  if c.stalk then
    local st = c.stalk
    if steerAbs > steerMax * 1.3 and st.t < 0.6 * T.stalkTime then st.t = 0.6 * T.stalkTime end   -- the wheel is turned over: back to it
    st.t = st.t + dt
    local u = st.t / T.stalkTime
    if u >= 1 then c.stalk = nil
    elseif u < 0.3 then c.stalkK = smootheststep(u / 0.3)
    elseif u < 0.6 then c.stalkK = 1
    else c.stalkK = smootheststep(1 - (u - 0.6) / 0.4) end
  end
  for side, arm in pairs(rig.arms) do
    local grip = grips[side]
    local target = rimPoint(wheel, grip.a, grip.lift) - wheelN * WRIST_BACK   -- the rim itself (+ the re-grip lift)
    if side == c.shiftSide and c.reach > 0 then target = lerp(target, leverTarget, c.reach) end
    if c.stalkK > 0 and c.stalk and side == c.stalk.side then target = lerp(target, target + vec3(0, 0, -0.06) + wheelN * 0.08, c.stalkK) end   -- the stalk: a little lower and toward the dash
    if c.revK > 0 then
      -- looking back: the passenger-side hand goes to the passenger seat back, the other steers from the top
      local k = smootheststep(c.revK)
      local passenger = back > 0 and 'l' or 'r'
      if side == passenger then target = lerp(target, c.seatBack and (c.seatBack - c.seat) or vec3(-back * SEAT_BACK_REACH.x, SEAT_BACK_REACH.y, SEAT_BACK_REACH.z), k)
      else target = lerp(target, rimPoint(wheel, math.pi / 2, 0) - wheelN * WRIST_BACK, k) end
    end
    if c.waveK > 0 and side ~= c.shiftSide then
      -- a wave out of the window with the hand that is not on the gear lever
      local sway = 0.07 * math.sin(2 * math.pi * GEST.waveHz * c.wave.t)
      target = lerp(target, lean(c.head0 + vec3(-GEST.waveHand.x * c.inward + sway, GEST.waveHand.y, GEST.waveHand.z)), smootheststep(c.waveK))
    end
    if c.dazeK > 0 and side == c.shiftSide then
      target = lerp(target, lean(c.head0 + vec3(DAZE_HAND.x * c.inward, DAZE_HAND.y, DAZE_HAND.z)), smootheststep(c.dazeK))
    end
    local shoulder = lean(arm.shoulder)
    local d = target - shoulder
    local over = d:length() - (arm.la + arm.lb) * T.reach
    if over > 0 then shoulder = shoulder + d:normalized() * math.min(over * 0.6, SHOULDER_REACH) end
    local fistAt = target                     -- where the middle of the fist belongs
    if side ~= c.shiftSide or c.reach < 1 then
      local back = (shoulder - target):normalized() * HAND_LENGTH   -- first guess: the wrist behind it along the arm
      target = side == c.shiftSide and lerp(target + back, target, c.reach) or target + back
    end
    local roll = wrapAngle(grip.a - HOME[side]) * HAND_ROLL * (1 - c.reach * (side == c.shiftSide and 1 or 0))
    -- the wrist turns at most T.rollSpeed (a fast re-grip or keyboard steering doesn't snap the fist round)
    c.roll = c.roll or {}
    local was = c.roll[side] or roll
    roll = was + clamp(wrapAngle(roll - was), -T.rollSpeed * dt, T.rollSpeed * dt)
    c.roll[side] = roll
    local function solve(t)
      local elbow, wrist = ik(shoulder, t, arm.la, arm.lb, arm.pole)
      local n = (elbow - shoulder):cross(wrist - shoulder)
      local Df = delta(basis(wrist - elbow, n), arm.F0f)
      -- the wrist turns about the forearm (the fist stays on the rim and rotates with it)
      return elbow, wrist, n, Df, rotAbout(Df, (wrist - elbow):normalized(), roll)
    end
    -- a hand holding the rim follows it exactly (the rim already moves smoothly; low-passing it put the
    -- hand centimetres behind in fast turns); re-grips and lever reaches are rounded off
    local holding = grip.lift == 0 and not (c.stalkK > 0.01 and c.stalk and side == c.stalk.side) and not (side == c.shiftSide and (c.reach > 0.01 or c.dazeK > 0.01)) and not (side ~= c.shiftSide and c.waveK > 0.01) and c.revK < 0.01
    if holding and rig.fist and rig.fist[side] then
      -- the fist's middle sits beside the forearm's line, not on it: place the wrist so that point is on the rim
      local _, _, _, _, handR = solve(target)
      target = fistAt - rotate(handR, rig.fist[side])
    end
    target = follow(c, side .. 'Hand', target, dt, T.jointSpeed, holding and 1e6 or 45)
    local elbow, wrist, n, Df, handR = solve(target)
    place(c.parts[side .. '_upperarm'], world(shoulder), R, delta(basis(elbow - shoulder, n), arm.F0u))
    place(c.parts[side .. '_forearm'], world(elbow), R, Df)
    place(c.parts[side .. '_hand'], world(wrist), R, handR)
  end
  place(c.parts.body, world(lean(vec3(0, 0, 0))), R, L)
  if rig.legs and rig.legs.r then updateLegs(c, wheel, world, R, dt) end

  -- head: in the player's own driver camera it turns with the view and the camera sits inside it, so it
  -- never draws into the view (the inside of a model is not drawn) yet shows in the mirrors. It is only
  -- hidden when the camera leaves the head (leaning out to look back).
  local yaw, pitch = clamp(turn * 0.12, -0.4, 0.4), 0
  local fp = vid == fpVid
  if animated and not fp then
    -- idle life: a slow drift of the head, and now and then a glance to a mirror or out of a window
    local t = c.clock
    yaw = yaw + 0.03 * math.sin(0.31 * t) + 0.02 * math.sin(0.73 * t + 1.3)
    pitch = pitch + 0.02 * math.sin(0.43 * t + 0.4)
    -- glances: at one of the car's mirrors (more often when moving), or aside when it has none
    local moving = vec3(veh:getVelocity()):length() > 3
    c.glanceIn = (c.glanceIn or (6 + math.random() * 8)) - dt
    if c.glanceIn <= 0 then
      local gy, gp = (math.random() < 0.5 and -1 or 1) * (0.35 + math.random() * 0.35), -0.05 + math.random() * 0.1
      if #c.mirrors > 0 then
        local m = toSeat(c.mirrors[math.random(#c.mirrors)])
        gy = clamp(math.atan2(-m.x, m.y), -1.3, 1.3)
        gp = clamp(math.atan2(m.z, math.sqrt(m.x * m.x + m.y * m.y)), -0.5, 0.5)
      end
      c.glance = {t = 0, yaw = gy, pitch = gp}
      c.glanceIn = moving and (3 + math.random() * 5) or (6 + math.random() * 8)
    end
    if c.glance then
      c.glance.t = c.glance.t + dt
      local k = math.sin(math.pi * math.min(1, c.glance.t / T.glanceTime))
      yaw, pitch = yaw + c.glance.yaw * k, pitch + c.glance.pitch * k
      if c.glance.t >= T.glanceTime then c.glance = nil end
    end
  end
  if c.waveK > 0 then
    yaw = yaw + smootheststep(c.waveK) * 0.55 * c.inward         -- he turns his head to who he waves at (yaw is positive to the left; the window is on the side away from the lever)
  end
  if c.dazeK > 0 then
    local k = smootheststep(c.dazeK)
    yaw = yaw + k * T.dazeShake * math.sin(2 * math.pi * 0.8 * c.daze)
    pitch = pitch - k * 0.18
  end
  if c.lookW and c.lookW > 0 and not fp then
    -- the camera's look overrides the idle glances; the head turns its share on top of the torso
    local k = smootheststep(c.lookW)
    if k > 0.5 then c.glance = nil end
    yaw = lerp(yaw, clamp(turn * 0.12, -0.4, 0.4) + c.lookYaw * T.lookHead / (T.lookHead + LOOK_TORSO), k)
    pitch = lerp(pitch, c.lookPitch, k)
  end
  if c.revK and c.revK > 0 then
    local k = smootheststep(c.revK)
    yaw, pitch = lerp(yaw, back * T.reverseHead, k), lerp(pitch, 0.08, k)
  end
  -- the head stays level when the body leans (eyes on the road): undo most of the torso pitch
  pitch = pitch - LEVEL_HEAD * math.asin(clamp(L.y.z, -1, 1))
  if c.slumpK and c.slumpK > 0 and animated and not fp then pitch = lerp(pitch, GEST.slumpHead, smootheststep(c.slumpK)) end
  if fp and animated then
    local q = core_camera.getQuat()
    local look = q and (q * vec3(0, 1, 0)) or R.y
    local lx, ly, lz = look:dot(R.x), look:dot(R.y), look:dot(R.z)
    yaw = clamp(math.atan2(-lx, ly), -1.4, 1.4)
    pitch = clamp(math.atan2(lz, math.sqrt(lx * lx + ly * ly)), -0.6, 0.5)
  end
  local hideHead = fp and core_camera.getPosition():distance(eyeNow) > 0.1   -- the camera sits on the unled eye
  if hideHead ~= c.headHidden then
    c.parts.head:setHidden(hideHead)
    if c.parts.helmet then c.parts.helmet:setHidden(hideHead) end
    c.headHidden = hideHead
  end
  if not hideHead then
    c.headYaw = c.headYaw and (c.headYaw + clamp(yaw - c.headYaw, -dt * 6, dt * 6)) or yaw   -- no snapping
    c.headPitch = c.headPitch and (c.headPitch + clamp(pitch - c.headPitch, -dt * 4, dt * 4)) or pitch
    yaw, pitch = c.headYaw, c.headPitch
    local cy, sy = math.cos(yaw), math.sin(yaw)
    local turnHead = compose({x = vec3(cy, sy, 0), y = vec3(-sy, cy, 0), z = vec3(0, 0, 1)}, rotX(pitch))
    place(c.parts.head, world(lean(rig.parts.head)), R, compose(L, turnHead))
    if c.parts.helmet then place(c.parts.helmet, world(lean(rig.parts.head)), R, compose(L, turnHead)) end
  end
  c.posed = true
  if c.flex then c.lastDt = dt flushFlex(vid, c) end
  if c.rec then record(c, eye, R, dt, veh, wheel + c.seat) end
end

local function onPreRender(dt, dtSim)
  if next(bakeJobs) then runBakes() end
  for vid, tries in pairs(pending) do
    -- every frame for 5 s, then once every 2 s: a pooled traffic car's camera data can come late, and a car
    -- given up on stayed empty for good (B48)
    if tries < 300 or tries % 120 == 0 then
      if attach(vid) then pending[vid] = nil else pending[vid] = tries + 1 end
    else
      pending[vid] = tries + 1
    end
  end
  -- a car told to 'stop' (traffic parked by the pool) brakes, then ai.lua sets itself 'disabled' without the
  -- hook: stopped cars are asked again every 2 s, so the driver leaves once it stands (B14). An empty car is
  -- asked again too: a mode change missed around its spawn left pooled traffic empty for good (B48)
  stopAsk = stopAsk + dt
  if stopAsk > 2 then
    stopAsk = 0
    for vid in pairs(cars) do if aiModes[vid] == 'stop' then askMode(vid) end end
    for i = 0, be:getObjectCount() - 1 do
      local v = be:getObject(i)
      local vid = v and v:getId()
      if vid and not cars[vid] and not pending[vid] and aiModes[vid] ~= nil then askMode(vid) end
    end
  end
  if not next(cars) then return end
  local camPos = core_camera.getPosition()
  local fpVid = core_camera.getActiveCamName(0) == 'driver' and be:getPlayerVehicleID(0) or nil
  local t0 = os.clock()
  for vid, c in pairs(cars) do
    local ok, err = pcall(updateCar, vid, c, dt, dtSim or dt, camPos, fpVid)
    if not ok then   -- one car's driver never takes the frame down: log it and let him go (B20)
      log('E', 'slrrDrivers', 'driver update failed for ' .. tostring(vid) .. ', driver removed: ' .. tostring(err))
      removeCar(vid)
    end
  end
  perfMs = perfMs + ((os.clock() - t0) * 1000 - perfMs) * 0.05   -- smoothed cost of all drivers per frame
  if prof.on then prof.total, prof.frames = prof.total + os.clock() - t0, prof.frames + 1 end
end

-- called by slrrDriverFeed (vehicle Lua) every frame
local function feed(vid, steer, rpm, maxrpm, gear, throttle, brake, clutch)
  local c = cars[vid]
  if not c then return end
  local e = c.e
  if gear ~= e.gear and e.maxrpm > 0 then
    local now = c.clock or 0
    if c.manual and math.abs(steer) < 70 and now - (c.lastShift or -10) > SHIFT_GAP then c.shiftT, c.fromGear = 0, e.gear end
    c.lastShift = now
  end
  e.steer, e.rpm, e.maxrpm, e.gear, e.throttle = steer, rpm, maxrpm, gear, throttle
  e.brake, e.clutch = brake or 0, clutch or 0
end

local saveTune   -- (defined with the tunables below)
local function saveSettings() jsonWriteFile(SETTINGS, {default = defaultDriver, displayMode = displayMode, appearance = appearance, tune = saveTune and saveTune() or nil}, true) end

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
-- Appearance, global (vid nil, saved) or per car: {skin = driverId, shirt = {r,g,b}, trousers = {r,g,b},
-- scale = 0.9..1.1, helmet = true/false, helmetColor = {r,g,b}} (colours 0..1). Fields left out keep their
-- current value; pass false to clear one. Applies at once (the driver is rebuilt).
M.setAppearance = function(vid, look)
  look = look or {}
  if look.skin ~= nil then
    if vid then M.setDriver(vid, look.skin or nil) else M.setDefaultDriver(look.skin) end
  end
  local t = vid and (carAppearance[vid] or {}) or appearance
  for _, k in ipairs({'shirt', 'trousers', 'scale', 'helmet', 'helmetColor'}) do
    if look[k] ~= nil then t[k] = look[k] ~= false and look[k] or nil end
  end
  if vid then carAppearance[vid] = t pending[vid] = 0 else saveSettings() markAll() end
end
-- how a tint is drawn: 'layers' (material layers, the default) or 'bake' (a baked colour map); for
-- testing which looks right, the drivers are rebuilt
M.setTintMode = function(mode)
  if mode ~= 'layers' and mode ~= 'bake' then return end
  tintMode = mode
  for name in pairs(tints) do local m = scenetree.findObject(name) if m then m:delete() end end
  tints, bakeJobs, bakeResults = {}, {}, {}
  markAll()
end
M.getTintCount = function() local n = 0 for _ in pairs(tints) do n = n + 1 end return n end   -- loaded clothing colours
M.getAppearance = function(vid)
  local a = vid and appearanceFor(vid) or appearance
  a.skin = vid and M.getDriver(vid) or defaultDriver
  return a
end
M.setDisplayMode = function(mode, vid)
  if mode == 'static' then mode = 'still' end
  if mode ~= nil and not MODES[mode] then log('W', 'slrrDrivers', 'unknown display mode ' .. tostring(mode)) return end
  -- unchanged: nothing to do (callers may set it on every spawn; no reset, no settings write)
  if (vid and carMode[vid] == mode) or (not vid and displayMode == (mode or 'full')) then return end
  if vid then carMode[vid] = mode else displayMode = mode or 'full' saveSettings() end
  -- start the animation state fresh, so switching never leaves a half-finished move behind
  for id, c in pairs(cars) do
    if not vid or id == vid then c.body, c.smooth, c.hands, c.shiftT, c.reach, c.headYaw, c.headPitch, c.posed = nil, nil, nil, nil, 0, nil, nil, nil end
  end
end
-- slrrDrivers.setSlump(vehId, true): the full driver slumps over the wheel (knocked out, dead); false sits him up
-- slrrDrivers.wave(vehId [, seconds]): the driver waves out of his window for a few seconds (a meet, a friend); not in first person, not for far drivers
M.wave = function(vid, seconds)
  local c = cars[vid]
  if c then c.wave = {t = 0, dur = clamp(tonumber(seconds) or 3, 1, 8)} end
end
M.setSlump = function(vid, on)
  slumped[vid] = on and true or nil
  if cars[vid] then cars[vid].slumped = on and true or nil end
end
M.getDisplayMode = function(vid) return (vid and carMode[vid]) or displayMode end
-- shortcut kept from 1.2: true = "full", false = "still"
M.setAnimated = function(on) M.setDisplayMode(on and 'full' or 'still') end
M.getAnimated = function() return displayMode ~= 'still' end
M.feed = feed
-- slrrDriverFeed (the car) reports a change of the wipers, the lights or the indicators: kind 'wiper', 'light' or 'signal', on = 1/0.
-- The hand on the stalk's side reaches for it: the indicator and the light switch are on the stalk on the door side of the wheel, the wipers on
-- the other (left and right swap in a right-hand-drive car). Wipers on also set him leaning a little at low speed.
M.control = function(vid, kind, on)
  local c = cars[vid]
  if not c then return end
  if kind == 'wiper' then c.wipersOn = on == 1 end
  local side = (kind == 'wiper') and (c.rhd and 'l' or 'r') or (c.rhd and 'r' or 'l')
  c.stalkQ = c.stalkQ or {}
  if #c.stalkQ < 2 then table.insert(c.stalkQ, side) end
end
M.getState = function(vid) return cars[vid] end   -- for debugging
M.getPerf = function() local n = 0 for _ in pairs(cars) do n = n + 1 end return perfMs, n, badWrites end   -- ms per frame, drivers, transforms refused
-- ms per frame by section since the last call (body physics, the prop calls, everything), then reset
M.getProfile = function()
  local f = math.max(1, prof.frames)
  local out = {body = prof.body / f * 1000, place = prof.place / f * 1000, total = prof.total / f * 1000, frames = prof.frames}
  prof.on, prof.body, prof.place, prof.total, prof.frames = true, 0, 0, 0, 0
  return out
end
-- every vehicle: its AI mode as known here, whether a driver is pending, which driver sits in it, and whether
-- the game has driver-camera data for it (B48: which step keeps a car empty)
M.getPresence = function()
  local out = {}
  for _, v in ipairs(getAllVehicles()) do
    local vid = v:getId()
    out[vid] = {jbeam = v:getJBeamFilename(), ai = aiModes[vid], pending = pending[vid], driver = cars[vid] and cars[vid].id or false,
                cam = core_camera.getDriverDataById(vid) ~= nil, player = vid == be:getPlayerVehicleID(0)}
  end
  return out
end
-- what could be drawn as a figure on or in a car (QA: a figure seen lying on a roof): the walker, the mount's props and the full driver. Logged and returned.
M.figures = function(vid)
  vid = vid or be:getPlayerVehicleID(0)
  local veh, c = be:getObjectByID(vid), cars[vid]
  local mount = slrrDriverMount and slrrDriverMount.getMount and slrrDriverMount.getMount(vid)
  local n = 0
  for _ in pairs(c and c.parts or {}) do n = n + 1 end
  local p = veh and veh:getPosition()
  local out = {vid = vid, jbeam = veh and veh:getJBeamFilename(), pos = p and {p.x, p.y, p.z}, player = vid == be:getPlayerVehicleID(0), playerVid = be:getPlayerVehicleID(0),
    walker = slrrPedestrians and slrrPedestrians.hasPlayerWalker and slrrPedestrians.hasPlayerWalker() or false,
    mount = mount and {driver = mount.driver, passenger = mount.passenger} or false, pending = pending[vid],
    full = c and {id = c.id, parts = n, hidden = c.hidden, posed = c.posed, drawnByCar = c.drawnByCar, passenger = c.passenger ~= nil} or false}
  log('I', 'slrrDrivers', 'figures ' .. dumps(out))
  return out
end
M.setLeadFrames = function(n) LEAD_FRAMES = n end   -- for measuring the render lag
M.setPropConvention = function(k) propConvention = k end   -- calibrating parts drawn by the car
-- pose recording for tools/render_pose.py
M.startRecording = function(vid) if cars[vid] then cars[vid].rec = {} end end
M.stopRecording = function(vid, path)
  local c = cars[vid]
  if not c or not c.rec then return 0 end
  local rec = {model = c.rig.model, skin = c.id, frames = c.rec}
  c.rec = nil
  if path then jsonWriteFile(path, rec, false) end
  return #rec.frames, rec
end
-- Tunables (the Mods menu): range in the code's units (T above), how each is offered. deg = the code holds radians, the menu shows degrees.
local T0 = {}
for k, v in pairs(T) do T0[k] = v end
local TUNE_SPEC = {
  -- Animation
  {key = 'jointSpeed', group = 'Animation', label = 'Hand and foot speed', min = 0.5, max = 5, step = 0.1, unit = 'm/s',
   tip = 'How fast his hands and feet move to a new place. Lower is smoother and lazier, higher is snappier.'},
  {key = 'regripTime', group = 'Animation', label = 'Hand-over-hand speed', min = 0.1, max = 0.6, step = 0.01, unit = 's',
   tip = 'How long a hand takes to let go of the wheel and grab it again further round when you turn it a lot. Lower is quicker.'},
  {key = 'handRange', group = 'Animation', label = 'Wheel turn before a hand lets go', min = math.rad(30), max = math.rad(120), step = 1, unit = 'deg', deg = true,
   tip = 'How far a hand rides round with the wheel before he lets go and grabs again. Higher means fewer re-grips.'},
  {key = 'reach', group = 'Animation', label = 'Arm stretch', min = 0.7, max = 0.98, step = 0.01, unit = '%', scale = 100,
   tip = 'How far his arms stretch to the wheel (100 % is straight). Lower bends his elbows more.'},
  {key = 'shiftTime', group = 'Animation', label = 'Time on the gear lever', min = 0.15, max = 1, step = 0.05, unit = 's',
   tip = 'How long his hand stays on the lever for a gear change in a manual car.'},
  {key = 'reachRpm', group = 'Animation', label = 'Revs where he reaches for the lever', min = 0.5, max = 1, step = 0.01, unit = '%', scale = 100, advanced = true,
   tip = 'The share of the engine\'s top revs at which his hand goes to the gear lever in a manual car.'},
  {key = 'stalkReach', group = 'Controls', bool = true, label = 'Reaches for stalks and switches', min = 0, max = 1,
   tip = 'He reaches for the wiper stalk, the light switch and the indicator when they change, then back to the wheel. He never lets go of the wheel when it is turned well over.'},
  {key = 'stalkTime', group = 'Controls', label = 'Time per reach', min = 0.3, max = 2, step = 0.05, unit = 's',
   tip = 'How long a reach for a stalk takes, out and back.'},
  {key = 'stalkSteerMax', group = 'Controls', label = 'Keeps both hands on the wheel past', min = math.rad(20), max = math.rad(180), step = 5, unit = 'deg', deg = true, advanced = true,
   tip = 'When the steering wheel is turned further than this he does not take a hand off it for a stalk.'},
  {key = 'rainLean', group = 'Controls', label = 'Leans forward in the rain', min = 0, max = math.rad(8), step = 0.5, unit = 'deg', deg = true,
   tip = 'At low speed with the wipers on he leans forward a little to see through the wet windscreen. 0 keeps him upright.'},
  {key = 'breathAngle', group = 'Animation', label = 'Breathing', min = 0, max = math.rad(3), step = 0.1, unit = 'deg', deg = true,
   tip = 'How much his chest moves as he breathes while he sits still. 0 is perfectly still.'},
  {key = 'rollSpeed', group = 'Animation', label = 'Wrist turning speed', min = 1, max = 12, step = 0.5, unit = 'rad/s', advanced = true,
   tip = 'Fastest his wrists turn when he re-grips or moves a hand.'},
  -- Looking
  {key = 'lookHead', group = 'Looking', label = 'Head turn when you look around', min = math.rad(20), max = math.rad(120), step = 1, unit = 'deg', deg = true,
   tip = 'How far he turns his head to follow the camera when you look around from outside the car.'},
  {key = 'lookSpeed', group = 'Looking', label = 'Head turn speed', min = 1, max = 8, step = 0.5, unit = 'rad/s',
   tip = 'Fastest he turns his head after the camera. Lower looks calmer.'},
  {key = 'glanceTime', group = 'Looking', label = 'Mirror glance', min = 0.5, max = 3, step = 0.1, unit = 's',
   tip = 'How long a glance at a mirror and back takes.'},
  {key = 'reverseHead', group = 'Looking', label = 'Head turn when reversing', min = math.rad(20), max = math.rad(120), step = 1, unit = 'deg', deg = true,
   tip = 'How far he turns his head to look out of the back window while reversing.'},
  {key = 'reverseLookSpeed', group = 'Looking', label = 'Looks back when reversing slower than', min = 1, max = 10, step = 0.5, unit = 'm/s',
   tip = 'Below this speed in reverse he looks over his shoulder; faster, he looks ahead again.'},
  -- Body sway
  {key = 'swayGain', group = 'Body sway', label = 'Body sway', min = 0, max = 1.5, step = 0.05, unit = 'x',
   tip = 'How much braking, accelerating and cornering throw his body around. 0 sits him still like a statue.'},
  {key = 'swayHz', group = 'Body sway', label = 'Sway springiness', min = 0.8, max = 3, step = 0.1, unit = 'Hz', advanced = true,
   tip = 'How quickly his body swings back after being pushed. Higher is stiffer.'},
  {key = 'swayDamp', group = 'Body sway', label = 'Sway damping', min = 0.2, max = 1, step = 0.05, unit = '', advanced = true,
   tip = 'How fast the swinging dies down. Higher settles quicker.'},
  {key = 'swayAccMax', group = 'Body sway', label = 'Strongest push that counts', min = 4, max = 30, step = 1, unit = 'm/s²', advanced = true,
   tip = 'Harder pushes (kerbs, gear-change jolts) are capped to this, so they do not throw him further.'},
  {key = 'seatbelt', group = 'Body sway', label = 'Belt give', min = 0.02, max = 0.15, step = 0.005, unit = 'cm', scale = 100, advanced = true,
   tip = 'The furthest his head can travel from where it sits, as if held by the belt.'},
  -- After a crash
  {key = 'crashDv', group = 'After a crash', label = 'Counts as a crash from', min = 2, max = 15, step = 0.5, unit = 'm/s',
   tip = 'A sudden change of speed this big counts as a crash; kerbs and hard braking do not.'},
  {key = 'dazeWait', group = 'After a crash', label = 'Time to slow down', min = 1, max = 15, step = 0.5, unit = 's',
   tip = 'After a crash the car has this long to slow down before he holds his head.'},
  {key = 'dazeTime', group = 'After a crash', label = 'Holds his head for', min = 1, max = 10, step = 0.5, unit = 's',
   tip = 'How long he holds his head after a crash, once the car has slowed down.'},
  {key = 'dazeShake', group = 'After a crash', label = 'Head shake', min = 0, max = 0.5, step = 0.02, unit = '', advanced = true,
   tip = 'How much he shakes his head, slowly, when he is dazed. 0 holds it still.'},
  -- Performance
  {key = 'cullDist', presets = {performance = 60, balanced = 150, quality = 200, max = 300}, group = 'Performance', label = 'Drivers drawn up to', min = 40, max = 400, step = 10, unit = 'm',
   tip = 'Drivers in cars farther from the camera than this are not drawn or updated. Lower saves frame time in traffic.'},
  {key = 'animDist', presets = {performance = 15, balanced = 40, quality = 60, max = 100}, group = 'Performance', label = 'Drivers animated up to', min = 10, max = 150, step = 5, unit = 'm',
   tip = 'Drivers in AI cars animate only this close to the camera; farther away they sit still.'},
  {key = 'collideDist', presets = {performance = 10, balanced = 40, quality = 60, max = 100}, group = 'Performance', label = 'Bodies react to the car up to', min = 10, max = 150, step = 5, unit = 'm', advanced = true,
   tip = 'Only drivers this close to the camera can bump against the car\'s parts (it costs work to read the car).'},
  {key = 'farSkip', presets = {performance = 16, balanced = 8, quality = 4, max = 2}, group = 'Performance', label = 'Far drivers updated every', min = 1, max = 30, step = 1, unit = 'frames', advanced = true,
   tip = 'A far driver in an AI car is updated only once in this many frames. Higher is cheaper and jerkier.'},
  {key = 'maxTints', group = 'Performance', label = 'Clothing colours kept loaded', min = 2, max = 16, step = 1, unit = '', advanced = true,
   tip = 'How many different shirt and trouser colours stay in video memory at once.'},
  {key = 'driverMass', group = 'Performance', label = 'Weight of the prop driver', min = 40, max = 140, step = 5, unit = 'kg', advanced = true,
   tip = 'Weight added to the car at his seat for the prop driver (a character\'s own weight in its file wins). Affects the car\'s handling a little.'},
}
local TUNE_BY_KEY = {}
for _, sp in ipairs(TUNE_SPEC) do TUNE_BY_KEY[sp.key] = sp end
saveTune = function()
  local tune = {}
  for k, v in pairs(T) do if v ~= T0[k] then tune[k] = v end end
  return next(tune) and tune or nil
end
-- M.setTune(key, value): in the code's own units (radians for the angles); clamped; false for an unknown key or a non-number
M.setTune = function(key, value)
  local sp = TUNE_BY_KEY[key]
  value = tonumber(value)
  if not (sp and value) or value ~= value then return false end
  T[key] = clamp(value, sp.min, sp.max)
  saveSettings()
  return true
end
M.getTune = function(key) return T[key] end
M.loadTune = function(t) for k, v in pairs(t) do local sp = TUNE_BY_KEY[k] if sp and tonumber(v) then T[k] = clamp(tonumber(v), sp.min, sp.max) end end end   -- (a settings file: unknown keys ignored, values clamped)
M.resetTune = function() for k, v in pairs(T0) do T[k] = v end saveSettings() end

-- The Mods menu (ESC > Mods, Wrench Works' slrr_settings registry): the Drivers tab. Registered only if the registry exists (without Wrench Works
-- the driver runs on its defaults and its settings file). A colour field has no empty state: the neutral grey means "no colour of his own".
local NEUTRAL = {r = 0.5, g = 0.5, b = 0.5}
local function rgbTable(c) return {r = c[1] or c.r or 0, g = c[2] or c.g or 0, b = c[3] or c.b or 0} end
local function isNeutral(c) c = rgbTable(c) return math.abs(c.r - 0.5) < 0.003 and math.abs(c.g - 0.5) < 0.003 and math.abs(c.b - 0.5) < 0.003 end
local function colourStore(key)
  return {kind = 'custom',
    get = function() local c = M.getAppearance(nil)[key] return c and rgbTable(c) or NEUTRAL end,
    set = function(v) M.setAppearance(nil, {[key] = (type(v) == 'table' and not isNeutral(v)) and rgbTable(v) or false}) end}
end
M.settingsSchema = function()
  local modes = {}
  for _, m in ipairs({{'full', 'Full'}, {'still', 'Still (no animation)'}, {'hideFirstPerson', 'Hidden in first person'}, {'hidden', 'Hidden'}}) do
    modes[#modes + 1] = {id = m[1], label = m[2]}
  end
  local people = {{id = 'none', label = 'Nobody'}}
  for _, d in ipairs(M.getDrivers()) do people[#people + 1] = {id = d.id, label = d.name or d.id} end
  local look = M.getAppearance
  local tuneFields = {}
  for _, sp in ipairs(TUNE_SPEC) do
    local k = (sp.deg and 180 / math.pi or 1)
    if sp.bool then
      tuneFields[#tuneFields + 1] = {id = sp.key, tab = 'drivers', group = sp.group, type = 'bool', label = sp.label, tooltip = sp.tip, advanced = sp.advanced,
        default = T0[sp.key] ~= 0, apply = 'live',
        store = {kind = 'custom', get = function() return T[sp.key] ~= 0 end, set = function(v) M.setTune(sp.key, v and 1 or 0) end}}
    else
      tuneFields[#tuneFields + 1] = {id = sp.key, tab = 'drivers', group = sp.group, type = 'slider', label = sp.label, tooltip = sp.tip, advanced = sp.advanced, presets = sp.presets,
        min = sp.min * k, max = sp.max * k, step = sp.step, unit = sp.unit, scale = sp.scale, default = T0[sp.key] * k, apply = 'live',
        store = {kind = 'custom', get = function() return T[sp.key] * k end, set = function(v) M.setTune(sp.key, v / k) end}}
    end
  end
  local fields = {
    {id = 'mode', tab = 'drivers', group = 'Driver', type = 'enum', label = 'Show the driver', default = 'full', apply = 'live', options = modes,
     presets = {performance = 'hideFirstPerson', balanced = 'full', quality = 'full', max = 'full'},
     tooltip = 'Full animates him; Still keeps him in the seat without moving; the other two hide him in first person or everywhere.',
     store = {kind = 'custom', get = function() return M.getDisplayMode() end, set = function(v) M.setDisplayMode(v) end}},
    {id = 'driver', tab = 'drivers', group = 'Driver', type = 'enum', label = 'Who drives', default = people[2] and people[2].id or 'none', apply = 'live', options = people,
     tooltip = 'The character behind the wheel of your cars.',
     store = {kind = 'custom', get = function() return M.getDefaultDriver() or 'none' end, set = function(v) M.setDefaultDriver(v ~= 'none' and v or nil) end}},
    {id = 'scale', tab = 'drivers', group = 'Look', type = 'slider', label = 'Size', min = 0.9, max = 1.1, step = 0.01, unit = 'x', default = 1, apply = 'live',
     tooltip = 'How tall he sits, 0.9 to 1.1 times. The rigged driver takes it for cars spawned afterwards.',
     store = {kind = 'custom', get = function() return tonumber(look(nil).scale) or 1 end, set = function(v) if math.abs(v - 1) < 0.005 then v = false end M.setAppearance(nil, {scale = v}) end}},
    {id = 'helmet', tab = 'drivers', group = 'Look', type = 'bool', label = 'Helmet', default = false, apply = 'live', presets = {performance = false},
     tooltip = 'A helmet on his head (the rigged driver: only the police officer and the racer have one).',
     store = {kind = 'custom', get = function() return look(nil).helmet == true end, set = function(v) M.setAppearance(nil, {helmet = v and true or false}) end}},
    {id = 'helmetColor', tab = 'drivers', group = 'Look', type = 'color', label = 'Helmet colour', default = NEUTRAL, apply = 'live', visibleIf = {field = 'helmet', equals = true},
     tooltip = 'Grey is the plain white helmet.', store = colourStore('helmetColor')},
    {id = 'shirt', tab = 'drivers', group = 'Look', type = 'color', label = 'Shirt colour', default = NEUTRAL, apply = 'live',
     tooltip = 'Recolours his shirt (the prop driver; the rigged driver has colour sets below). Grey leaves it as it is.', store = colourStore('shirt')},
    {id = 'trousers', tab = 'drivers', group = 'Look', type = 'color', label = 'Trousers colour', default = NEUTRAL, apply = 'live',
     tooltip = 'Recolours his trousers (the prop driver). Grey leaves them as they are.', store = colourStore('trousers')},
    {id = 'colourReset', tab = 'drivers', group = 'Look', type = 'button', label = 'Back to the default colours',
     action = function() M.setAppearance(nil, {shirt = false, trousers = false, helmetColor = false}) return 'Colours reset' end},
    {id = 'rigNote', tab = 'drivers', group = 'Rigged driver (experimental)', type = 'note', label = 'Not saved: after a restart it is Props again.'},
    {id = 'rig', tab = 'drivers', group = 'Rigged driver (experimental)', type = 'enum', label = 'Driver model', default = 'props', apply = 'spawn',
     options = {{id = 'props', label = 'Props (default)'}, {id = 'flex', label = 'Rigged (experimental)'}},
     tooltip = 'Experimental. The rigged driver is part of the car (skeleton, his weight in the seat); crashes at car switches were seen in tests. Applies to cars you spawn afterwards.',
     store = {kind = 'custom', get = function() return slrrDriverMount and slrrDriverMount.getDriverRig and slrrDriverMount.getDriverRig() or 'props' end,
              set = function(v) if slrrDriverMount and slrrDriverMount.setDriverRig then slrrDriverMount.setDriverRig(v) end end}},
  }
  -- the tunables go before the rigged-driver group
  local at = #fields
  for i, f in ipairs(fields) do if f.id == 'rigNote' then at = i - 1 break end end
  for i, f in ipairs(tuneFields) do table.insert(fields, at + i, f) end
  if M.getPresets then
    local opts = {{id = 'default', label = 'Default'}}
    local names = {}
    for name in pairs(M.getPresets().presets or {}) do names[#names + 1] = name end
    table.sort(names)
    for _, n in ipairs(names) do opts[#opts + 1] = {id = n, label = n:sub(1, 1):upper() .. n:sub(2)} end
    fields[#fields + 1] = {id = 'preset', tab = 'drivers', group = 'Rigged driver (experimental)', type = 'enum', label = 'Clothing colours', default = 'default', apply = 'spawn',
      options = opts, visibleIf = {field = 'rig', equals = 'flex'},
      tooltip = 'The colours of the rigged driver for the four SLRR characters (Mitch, the two opponents, the police officer).',
      store = {kind = 'custom', get = function() return look(nil).preset or 'default' end, set = function(v) M.setAppearance(nil, {preset = v ~= 'default' and v or false}) end}}
  end
  return {id = 'drivers', title = 'Drivers', description = 'Who sits at the wheel of your cars and how he looks.'}, fields
end
-- one page for Pedestrians and Drivers: the pedestrian extension offers its tab the same way (settingsSchema() -> tab, fields) and this one
-- registers both, because registering a mod again replaces its page
M.onSlrrSettingsReady = function()
  local S = rawget(_G, 'slrr_settings')
  if not (S and S.register) then return end
  local tabs, fields = {}, {}
  local ped = rawget(_G, 'slrrPedestrians')
  if ped and ped.settingsSchema then
    local ok, tab, f = pcall(ped.settingsSchema)
    if ok and tab then tabs[#tabs + 1] = tab for _, x in ipairs(f or {}) do fields[#fields + 1] = x end end
  end
  local tab, f = M.settingsSchema()
  tabs[#tabs + 1] = tab
  for _, x in ipairs(f) do fields[#fields + 1] = x end
  local inj = rawget(_G, 'slrrInjury')   -- the injury add-on, if installed: its tab last
  if inj and inj.settingsSchema then
    local ok, t2, f2 = pcall(inj.settingsSchema)
    if ok and t2 then tabs[#tabs + 1] = t2 for _, x in ipairs(f2 or {}) do fields[#fields + 1] = x end end
  end
  S.register({mod = 'slrr_drivers', title = 'Pedestrians & Drivers', icon = 'person', order = 35, tabs = tabs, fields = fields})
end
M.reload = function() loadDrivers() rigs = {} for vid in pairs(cars) do pending[vid] = 0 end end

M.onExtensionLoaded = function() loadDrivers() markAll() M.onSlrrSettingsReady() end
M.onExtensionUnloaded = function() for vid in pairs(cars) do removeCar(vid) end end
M.onPreRender = onPreRender
M.onVehicleSpawned = function(vid) pending[vid] = 0 end   -- also fires after a part change rebuilds the car
M.onVehicleResetted = function(vid)
  if not cars[vid] then pending[vid] = 0 return end
  local c = cars[vid]
  if c.flex then c.sent, c.flexPause = nil, 0.5 end   -- (the car forgot its pose in the reset: say it again once it is back)
  c.lastVel, c.sinceCrash, c.daze, c.hub0 = nil, nil, nil, nil   -- a reset is no crash; a repaired column is the new start
end
M.onVehicleSwitched = function(old, new)   -- a car the player gets into gains a driver; one he leaves loses it
  -- on foot (the unicycle) the driver who got out walks: slrrPedestrians draws his walker shapes
  local nv = new and new ~= -1 and be:getObjectByID(new)
  if slrrPedestrians and slrrPedestrians.followPlayer then
    if nv and nv:getJBeamFilename() == 'unicycle' then
      local id = (old and old ~= -1 and M.getDriver(old)) or defaultDriver
      if drivers[id] and FS:directoryExists(ROOT .. id .. '/walker/') then slrrPedestrians.followPlayer(new, ROOT .. id .. '/walker/') end
    else
      slrrPedestrians.followPlayer(nil)
    end
  end
  -- both cars are done again: the one left turns into a prop driver, the one entered gets the full one (W9)
  -- (a flex driver is the same in either case: it is not rebuilt, and its pose feed pauses for half a second while the engine
  -- hands the player over)
  for _, vid in ipairs({old, new}) do
    if vid and vid ~= -1 then
      local c = cars[vid]
      if c and c.flex then c.flexPause = 0.5 else pending[vid] = 0 end
    end
  end
end
M.onVehicleActiveChanged = function(vid, active) if active then pending[vid] = 0 end end   -- a pooled car back in use
M.onAiModeChange = function(vid, mode)
  local was = aiModes[vid]
  aiModes[vid] = mode
  if was ~= mode then pending[vid] = 0 end
end
M.onVehicleDestroyed = function(vid) flexSwitch[vid] = nil flexTries[vid] = nil slumped[vid] = nil aiModes[vid] = nil removeCar(vid) pending[vid] = nil choice[vid] = nil carMode[vid] = nil carAppearance[vid] = nil end
M.onClientStartMission = function() group = nil cars = {} loadedMaterials, tints = {}, {} loadDrivers() markAll() end   -- (a level load drops the materials: load them again)
M.onClientEndMission = function() group = nil cars = {} pending = {} end

return M
