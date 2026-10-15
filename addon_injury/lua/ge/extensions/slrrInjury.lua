-- slrrInjury: driver injuries from crash forces, an optional add-on to Wrench Works: Drivers.
--
-- Each tracked driver (the player's, and AI drivers near the camera) has seven body regions scored 0..1 from
-- the forces they take: head, chest, pelvis, arms (l/r), legs (l/r). Levels: bruised, broken (an arm steers
-- one-handed, a leg can't give full pedal), unconscious (inputs cut, wakes later), fatal. Death is deliberate:
-- the head over 200 g or the chest over 150 g sustained for 25 ms, never in the 3 s after a spawn, reset,
-- teleport or switch, and never on a step where the body jumps (a physics glitch).
--
-- Input: feed(vehId, sample) with sample = {dt, head, chest, pelvis, larm, rarm, lleg, rleg (g each), jump (m),
-- speed (m/s)}. Until the ragdoll driver exposes its body nodes, a stub derives the sample from the car's own
-- motion each frame (sampleFromCar); the ragdoll will call feed() from the vehicle at physics rate instead.
--
-- Hooks fired (agreed with the career): onSlrrDriverInjured(vehId, injuries) once per crash that hurts, after
-- the car settles; onSlrrDriverDied(vehId, cause, detail) once. The vehicle and driver are left as they are.
-- API: setMode('off'|'injuries'|'full') (saved), getMode(), getState([vehId]), heal([vehId]).

local M = {}

local SETTINGS = '/settings/slrr_injury.json'
local MODES = {off = true, injuries = true, full = true}
local G = 9.81
-- per region: the force (g) where it starts to hurt and where the scale tops out
local SCALE = {head = {25, 150}, chest = {30, 100}, pelvis = {35, 120},
               larm = {30, 110}, rarm = {30, 110}, lleg = {30, 110}, rleg = {30, 110}}
local REGIONS = {'head', 'chest', 'pelvis', 'larm', 'rarm', 'lleg', 'rleg'}
local BRUISED, BROKEN = 0.15, 0.9
local OUT_HEAD, OUT_CHEST = 0.7, 0.8         -- unconscious
local DEATH_HEAD, DEATH_CHEST, DEATH_TIME = 200, 150, 0.025   -- beyond what restrained drivers survive
local GRACE = 3            -- seconds ignored after a spawn, reset, teleport or vehicle switch
local JUMP = 2             -- metres: a body moving this much more than its speed explains in one step = a glitch
local SETTLE, DIE_SETTLE = 1.5, 2
local TRACK_DIST = 150     -- AI drivers farther than this from the camera aren't tracked
local RECOVER = {bruised = 0, broken = 600, unconscious = 300}   -- real seconds (per broken region for broken)
local RANK = {none = 0, bruised = 1, broken = 2, unconscious = 3, fatal = 4}
local VOICE_GAP = 2        -- seconds between clips per driver
local VOICE_DIR = '/art/sounds/slrr_injury/'
local BLOCK = {'accelerate', 'brake', 'accelerate_brake', 'steer_left', 'steer_right', 'steering', 'clutch',
               'parkingbrake', 'parkingbrake_toggle'}

local mode = 'injuries'
local state = {}           -- vehId -> per-driver state
local now = 0
local clips                -- {hurt = {...}, angry = {...}, wake = {...}}

local function clamp01(x) return math.max(0, math.min(1, x)) end

local function newState()
  local parts = {}
  for _, r in ipairs(REGIONS) do parts[r] = 0 end
  return {parts = parts, level = 'none', reported = 0, conscious = true, grace = GRACE, hotHead = 0, hotChest = 0,
          peakG = 0, speed = 0, recovery = 0, voiceAt = -math.huge}
end

local function get(vehId)
  state[vehId] = state[vehId] or newState()
  return state[vehId]
end

local function levelOf(st)
  if st.dead or st.dying then return 'fatal' end
  local p = st.parts
  if p.head >= OUT_HEAD or p.chest >= OUT_CHEST then return 'unconscious' end
  for _, r in ipairs({'larm', 'rarm', 'lleg', 'rleg'}) do if p[r] >= BROKEN then return 'broken' end end
  for _, r in ipairs(REGIONS) do if p[r] >= BRUISED then return 'bruised' end end
  return 'none'
end

local function broken(st)
  local out = {}
  for _, r in ipairs({'larm', 'rarm', 'lleg', 'rleg'}) do if st.parts[r] >= BROKEN then table.insert(out, r) end end
  return out
end

local function isPlayer(vehId)
  return be and be.getPlayerVehicleID and be:getPlayerVehicleID(0) == vehId
end

-- the table the career reads (agreed fields; extras ignored there)
local function injuries(vehId, st)
  local p = st.parts
  local sev = 0
  for _, r in ipairs(REGIONS) do sev = math.max(sev, p[r]) end
  local br = broken(st)
  local legBroken = p.lleg >= BROKEN or p.rleg >= BROKEN
  return {severity = sev, parts = {head = p.head, chest = p.chest, arms = math.max(p.larm, p.rarm),
          legs = math.max(p.lleg, p.rleg)}, recoverySeconds = st.recovery,
          limits = {noDriving = legBroken or not st.conscious, slowWalk = legBroken},
          level = st.level, broken = br, conscious = st.conscious, player = isPlayer(vehId) or false,
          injured = st.level ~= 'none'}
end

-- player controls while unconscious: blocked, and the pedals released
local function setControls(vehId, on)
  if not isPlayer(vehId) or not core_input_actionFilter then return end
  core_input_actionFilter.setGroup('slrrInjuryOut', BLOCK)
  core_input_actionFilter.addAction(0, 'slrrInjuryOut', not on)
  local v = be:getObjectByID(vehId)
  if v and not on then v:queueLuaCommand("input.event('throttle', 0, 1) input.event('steering', 0, 1)") end
end

-- driving with a broken limb: the vehicle's own input is capped (one hand: less lock; right leg: 70 % pedal)
local function setLimits(vehId, st)
  local v = be and be.getObjectByID and be:getObjectByID(vehId)
  if not v then return end
  local steer = (st.parts.larm >= BROKEN or st.parts.rarm >= BROKEN) and 0.6 or 1
  local pedal = st.parts.rleg >= BROKEN and 0.7 or 1
  v:queueLuaCommand(string.format([[
    if not slrrInjuryEvent then
      slrrInjuryEvent = input.event
      input.event = function(t, v, ...)
        local c = slrrInjuryCaps or {}
        if (t == 'throttle' or t == 'brake') and c.pedal then v = math.min(v, c.pedal)
        elseif t == 'steering' and c.steer then v = math.max(-c.steer, math.min(c.steer, v)) end
        return slrrInjuryEvent(t, v, ...)
      end
    end
    slrrInjuryCaps = {steer = %g, pedal = %g}]], steer, pedal))
end

local function loadClips()
  clips = {hurt = {}, angry = {}, wake = {}}
  for _, f in ipairs(FS and FS:findFiles(VOICE_DIR, '*.ogg', -1, true, false) or {}) do
    local kind = f:match('/([a-z]+)_[^/]*%.ogg$')
    if clips[kind] then table.insert(clips[kind], f) end
  end
end

-- a voice clip at the driver's head, at most one per VOICE_GAP s per driver
local function say(vehId, st, kind)
  if not clips then loadClips() end
  local list = clips[kind]
  if not list or #list == 0 or now - st.voiceAt < VOICE_GAP then return end
  local v = be and be.getObjectByID and be:getObjectByID(vehId)
  if not v then return end
  st.voiceAt = now
  v:queueLuaCommand(string.format("obj:playSFXOnce(%q, 0, 1, 1)", list[math.random(#list)]))
end

-- blood on the injured parts ("full" only), through the driver's overlay layer when it exists
local function overlays(vehId, st)
  if mode ~= 'full' or not (slrrDrivers and slrrDrivers.setPartOverlay) then return end
  local map = {head = {'head'}, chest = {'body'}, larm = {'l_upperarm', 'l_forearm'}, rarm = {'r_upperarm', 'r_forearm'},
               lleg = {'l_thigh', 'l_calf'}, rleg = {'r_thigh', 'r_calf'}}
  for r, parts in pairs(map) do
    local lvl = st.parts[r] >= BROKEN and 2 or st.parts[r] >= 0.4 and 1 or 0
    for _, part in ipairs(parts) do slrrDrivers.setPartOverlay(vehId, part, lvl) end
  end
end

-- one step of forces for a driver
local function feed(vehId, s)
  if mode == 'off' then return end
  local st = get(vehId)
  if st.dead then return end
  if st.grace > 0 then return end
  if (s.jump or 0) > JUMP then st.grace = GRACE return end   -- teleported or glitched: ignore, and a while after
  local hit = false
  st.prev = st.prev or {}
  for _, r in ipairs(REGIONS) do
    -- a force counts only when it lasts two steps: a one-step spike (a glitch) never hurts anyone
    local g, sc = math.min(s[r] or 0, st.prev[r] or 0), SCALE[r]
    st.prev[r] = s[r] or 0
    if g > sc[1] then
      hit = true
      st.parts[r] = math.max(st.parts[r], clamp01((g - sc[1]) / (sc[2] - sc[1])))
    end
  end
  if hit then
    st.lastHit, st.peakG, st.speed = now, math.max(st.peakG, s.head or 0, s.chest or 0), math.max(st.speed, s.speed or 0)
  end
  -- death only on forces sustained past DEATH_TIME, never a single spike
  st.hotHead = (s.head or 0) > DEATH_HEAD and st.hotHead + s.dt or 0
  st.hotChest = (s.chest or 0) > DEATH_CHEST and st.hotChest + s.dt or 0
  if not st.dying and (st.hotHead >= DEATH_TIME or st.hotChest >= DEATH_TIME) then
    st.dying = {at = now, kind = st.hotHead >= DEATH_TIME and 'head' or 'chest'}
  end
  local nBroken = #broken(st)
  if nBroken ~= (st.nBroken or 0) then      -- a limb newly broken: its driving limits, whatever the level
    st.nBroken = nBroken
    setLimits(vehId, st)
  end
  local lvl = levelOf(st)
  if RANK[lvl] > RANK[st.level] then
    st.level = lvl
    if lvl == 'unconscious' or lvl == 'fatal' then
      if st.conscious then
        st.conscious = false
        setControls(vehId, false)
      end
      st.wakeAt = lvl == 'unconscious' and now + 5 + 25 * clamp01(math.max(st.parts.head, st.parts.chest)) or nil
    end
    if lvl ~= 'fatal' then say(vehId, st, 'hurt') end
    overlays(vehId, st)
  end
end

-- another car hit the player's: the player's driver shouts (contacts from the map's collision tracking)
local touching = {}
local function checkContacts()
  local p = be and be:getPlayerVehicleID(0)
  local o = p and map and map.objects and map.objects[p]
  local now_ = {}
  for other, c in pairs(o and o.objectCollisions or {}) do
    if c == 1 then
      now_[other] = true
      if not touching[other] and be:getObjectByID(other) then say(p, get(p), 'angry') end
    end
  end
  touching = now_
end

-- the stub input: the car's own acceleration, from its velocity each frame, shared out to the body
local last = {}
local function sampleFromCar(v, dt)
  local id = v:getId()
  local pos, vel = vec3(v:getPosition()), vec3(v:getVelocity())
  local l = last[id]
  last[id] = {pos = pos, vel = vel}
  if not l or dt <= 0 then return nil end
  local a = (vel - l.vel) / dt
  local fwd = vec3(v:getDirectionVector()):normalized()
  local up = vec3(v:getDirectionVectorUp()):normalized()
  local right = fwd:cross(up)
  local along, side = a:dot(fwd) / G, a:dot(right) / G
  local g = a:length() / G
  local jump = (pos - (l.pos + l.vel * dt)):length()
  return {dt = dt, head = g * 1.2, chest = g, pelvis = g * 0.9,
          larm = math.abs(side) + 0.3 * math.abs(along), rarm = math.abs(side) + 0.3 * math.abs(along),
          lleg = math.max(0, -along) * 1.1, rleg = math.max(0, -along) * 1.1,
          jump = jump, speed = l.vel:length()}
end

local function onUpdate(dtReal, dtSim)
  now = now + dtReal
  if mode == 'off' then return end
  local dt = dtSim or dtReal
  local cam = core_camera and core_camera.getPosition()
  -- stub feed: the player's car and drivers' cars near the camera
  for i = 0, (be and be:getObjectCount() or 0) - 1 do
    local v = be:getObject(i)
    local id = v:getId()
    local tracked = isPlayer(id) or (slrrDrivers and slrrDrivers.getDriver and slrrDrivers.getDriver(id)
                    and cam and vec3(v:getPosition()):distance(cam) < TRACK_DIST)
    if tracked and not M.externalFeed then
      local s = sampleFromCar(v, dt)
      if s then feed(id, s) end
    end
  end
  checkContacts()
  for id, st in pairs(state) do
    if st.grace > 0 then st.grace = st.grace - dtReal end
    if st.recovery > 0 then st.recovery = math.max(0, st.recovery - dtReal) end
    -- report once the car has settled
    if RANK[st.level] > st.reported and st.level ~= 'fatal' and st.lastHit and now - st.lastHit >= SETTLE then
      st.reported = RANK[st.level]
      local add = (st.level == 'broken' and 0 or RECOVER[st.level] or 0) + RECOVER.broken * #broken(st)
      st.recovery = st.recovery + add
      extensions.hook('onSlrrDriverInjured', id, injuries(id, st))
    end
    if st.dying and not st.dead and now - st.dying.at >= DIE_SETTLE then
      st.dead = true
      extensions.hook('onSlrrDriverDied', id, 'crash',
                      {kind = st.dying.kind, peakG = st.peakG, speed = st.speed, player = isPlayer(id) or false})
    end
    if not st.conscious and not st.dead and st.wakeAt and now >= st.wakeAt then
      st.conscious = true
      setControls(id, true)
      say(id, st, 'wake')
    end
  end
end

local function heal(vehId)
  vehId = vehId or (be and be:getPlayerVehicleID(0))
  local st = state[vehId]
  if not st then return end
  if not st.conscious then setControls(vehId, true) end
  state[vehId] = newState()
  state[vehId].grace = 0
  local v = be and be.getObjectByID and be:getObjectByID(vehId)
  if v then v:queueLuaCommand('slrrInjuryCaps = nil') end
  overlays(vehId, state[vehId])
end


M.feed = feed
M.sampleFromCar = sampleFromCar
M.onUpdate = onUpdate
M.heal = heal
M.getState = function(vehId)
  vehId = vehId or (be and be:getPlayerVehicleID(0))
  local st = state[vehId]
  if not st then return {injured = false, severity = 0, recoverySeconds = 0, level = 'none',
                         limits = {noDriving = false, slowWalk = false}, parts = {head = 0, chest = 0, arms = 0, legs = 0}} end
  return injuries(vehId, st)
end
M.setMode = function(m)
  if not MODES[m] then return end
  mode = m
  jsonWriteFile(SETTINGS, {mode = mode}, true)
  if mode == 'off' then for id in pairs(state) do heal(id) end end
end
M.getMode = function() return mode end
M.onExtensionLoaded = function()
  local s = jsonReadFile(SETTINGS)
  if s and MODES[s.mode] then mode = s.mode end
end
-- a fresh car, a reset, a teleport or a switch: ignore the jolt; outside a career a reset also heals
M.onVehicleSpawned = function(id) state[id] = newState() last[id] = nil end
M.onVehicleResetted = function(id)
  last[id] = nil
  if not (sl_career and sl_career.isActive and sl_career.isActive()) then heal(id) end
  get(id).grace = GRACE
end
M.onVehicleSwitched = function(old, new)
  if old and state[old] then state[old].grace = GRACE end
  if new then get(new).grace = GRACE end
end
M.onVehicleDestroyed = function(id) state[id], last[id] = nil, nil end
M.onClientEndMission = function() state, last = {}, {} end
M._state = function(id) return state[id] end

return M
