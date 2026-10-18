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
-- what the Mods menu can change (setTune): the lines above and below are the defaults
local T = {toughness = 1,              -- times the forces in SCALE: below 1 he is more fragile, above 1 tougher
           bruiseAt = 0.15, brokenAt = 0.9,        -- a region's score where it counts as bruised / broken
           outHead = 0.7, outChest = 0.8,          -- head or chest score where he is knocked out
           recoverBroken = 600, recoverOut = 300,  -- real seconds: per broken region, and after a knock-out
           grace = 3,                              -- seconds ignored after a spawn, reset, teleport or vehicle switch
           voiceGap = 2,                           -- seconds between voice clips per driver
           -- how injuries feel (the player's own driver): 1 = on, 0 = off for the switches
           reduceMotion = 0,                       -- 1: none of the screen effects below (blur), for motion sickness
           fxBlur = 1, fxBlurStrength = 0.4,       -- the screen edges go blurry after a hit, fading away
           fxMuffle = 1, fxMuffleStrength = 0.5,   -- his hearing is muffled for a while after a hit
           fxSeconds = 12,                         -- how long the effects take to fade (a knock-out keeps them until he wakes)
           limp = 1}                               -- on foot with a broken leg: no sprinting
local TUNE_RANGE = {toughness = {0.5, 2}, bruiseAt = {0.05, 0.5}, brokenAt = {0.5, 1}, outHead = {0.4, 1}, outChest = {0.4, 1},
                    recoverBroken = {0, 3600}, recoverOut = {0, 1800}, grace = {1, 10}, voiceGap = {0, 10},
                    reduceMotion = {0, 1}, fxBlur = {0, 1}, fxBlurStrength = {0, 1}, fxMuffle = {0, 1}, fxMuffleStrength = {0, 1}, fxSeconds = {3, 60}, limp = {0, 1}}
local T0 = {}
for k, v in pairs(T) do T0[k] = v end
local DEATH_HEAD, DEATH_CHEST, DEATH_TIME = 200, 150, 0.025   -- beyond what restrained drivers survive
local JUMP = 2             -- metres: a body moving this much more than its speed explains in one step = a glitch
local SETTLE, DIE_SETTLE = 1.5, 2
local TRACK_DIST = 150     -- AI drivers farther than this from the camera aren't tracked
local RANK = {none = 0, bruised = 1, broken = 2, unconscious = 3, fatal = 4}
local VOICE_DIR = '/art/sounds/slrr_injury/'
local BLOCK = {'accelerate', 'brake', 'accelerate_brake', 'steer_left', 'steer_right', 'steering', 'clutch',
               'parkingbrake', 'parkingbrake_toggle'}

local mode = 'injuries'
local deathOverride = false     -- a Hardcore career: death counts whatever the setting (the career sets it, it is not saved)
local state = {}           -- vehId -> per-driver state
local now = 0
local clips                -- {hurt = {...}, angry = {...}, wake = {...}}

local function clamp01(x) return math.max(0, math.min(1, x)) end

local function newState()
  local parts = {}
  for _, r in ipairs(REGIONS) do parts[r] = 0 end
  return {parts = parts, level = 'none', reported = 0, conscious = true, grace = T.grace, hotHead = 0, hotChest = 0,
          peakG = 0, speed = 0, recovery = 0, voiceAt = -math.huge}
end

local function get(vehId)
  state[vehId] = state[vehId] or newState()
  return state[vehId]
end

local function levelOf(st)
  if st.dead or st.dying then return 'fatal' end
  local p = st.parts
  if p.head >= T.outHead or p.chest >= T.outChest then return 'unconscious' end
  for _, r in ipairs({'larm', 'rarm', 'lleg', 'rleg'}) do if p[r] >= T.brokenAt then return 'broken' end end
  for _, r in ipairs(REGIONS) do if p[r] >= T.bruiseAt then return 'bruised' end end
  return 'none'
end

local function broken(st)
  local out = {}
  for _, r in ipairs({'larm', 'rarm', 'lleg', 'rleg'}) do if st.parts[r] >= T.brokenAt then table.insert(out, r) end end
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
  local legBroken = p.lleg >= T.brokenAt or p.rleg >= T.brokenAt
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

-- the player's driver slumps over the wheel while he is out (SLRR Drivers draws it)
local function slump(vehId, on)
  if isPlayer(vehId) and slrrDrivers and slrrDrivers.setSlump then slrrDrivers.setSlump(vehId, on) end
end

-- driving with a broken limb: the vehicle's own input is capped (one hand: less lock; right leg: 70 % pedal)
local function setLimits(vehId, st)
  local v = be and be.getObjectByID and be:getObjectByID(vehId)
  if not v then return end
  local steer = (st.parts.larm >= T.brokenAt or st.parts.rarm >= T.brokenAt) and 0.6 or 1
  local pedal = st.parts.rleg >= T.brokenAt and 0.7 or 1
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

-- a voice clip at the driver's head, at most one per T.voiceGap s per driver
local function say(vehId, st, kind)
  if not clips then loadClips() end
  local list = clips[kind]
  if not list or #list == 0 or now - st.voiceAt < T.voiceGap then return end
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
    local lvl = st.parts[r] >= T.brokenAt and 2 or st.parts[r] >= 0.4 and 1 or 0
    for _, part in ipairs(parts) do slrrDrivers.setPartOverlay(vehId, part, lvl) end
  end
end

-- one step of forces for a driver
local function feed(vehId, s)
  if mode == 'off' then return end
  local st = get(vehId)
  if st.dead then return end
  if st.grace > 0 then return end
  if (s.jump or 0) > JUMP then st.grace = T.grace return end   -- teleported or glitched: ignore, and a while after
  local hit = false
  st.prev = st.prev or {}
  -- what the player's crashes actually measure (a hard hit that scores nothing shows here): one line per jolt over 8 g, 0.5 s apart
  if isPlayer(vehId) and math.max(s.head or 0, s.chest or 0) > 8 and now - (st.logAt or -1) > 0.5 then
    st.logAt = now
    log('I', 'slrrInjury', string.format('jolt %.0f g head, %.0f g chest, %.0f g legs at %.0f km/h (hurts from %.0f g head, %.0f g chest)',
      s.head or 0, s.chest or 0, math.max(s.lleg or 0, s.rleg or 0), (s.speed or 0) * 3.6, SCALE.head[1] * T.toughness, SCALE.chest[1] * T.toughness))
  end
  for _, r in ipairs(REGIONS) do
    -- a force counts only when it lasts two steps: a one-step spike (a glitch) never hurts anyone
    local lo, hi = math.min(s[r] or 0, st.prev[r] or 0), math.max(s[r] or 0, st.prev[r] or 0)
    local sc = {SCALE[r][1] * T.toughness, SCALE[r][2] * T.toughness}
    local g = lo > sc[1] and (lo + hi) / 2 or 0   -- both steps over the hurt line: the crash counts at the mean of the two (the stop is one hard step and a softer one)
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
  -- (death is a setting: 'Injuries and death' (mode full), or a Hardcore career; otherwise the worst a crash does is knock him out)
  local mortal = mode == 'full' or deathOverride
  st.hotHead = (s.head or 0) > DEATH_HEAD and st.hotHead + s.dt or 0
  st.hotChest = (s.chest or 0) > DEATH_CHEST and st.hotChest + s.dt or 0
  if mortal and not st.dying and (st.hotHead >= DEATH_TIME or st.hotChest >= DEATH_TIME) then
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
    if isPlayer(vehId) then
      log('I', 'slrrInjury', string.format('level %s: head %.2f chest %.2f arms %.2f legs %.2f', lvl, st.parts.head, st.parts.chest,
        math.max(st.parts.larm, st.parts.rarm), math.max(st.parts.lleg, st.parts.rleg)))
    end
    if lvl == 'unconscious' or lvl == 'fatal' then
      if st.conscious then
        st.conscious = false
        setControls(vehId, false)
        slump(vehId, true)                 -- he slumps over the wheel
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
  last[id] = {pos = pos, vel = vel, vel2 = l and l.vel}
  if not l or dt <= 0 then return nil end
  local dvLen = (vel - l.vel):length()
  local a = (vel - l.vel) / dt
  local fwd = vec3(v:getDirectionVector()):normalized()
  local up = vec3(v:getDirectionVectorUp()):normalized()
  local right = fwd:cross(up)
  local along, side = a:dot(fwd) / G, a:dot(right) / G
  local g = a:length() / G
  local jump = (pos - (l.pos + l.vel * dt)):length()
  local out = {dt = dt, head = g * 1.2, chest = g, pelvis = g * 0.9,
          larm = math.abs(side) + 0.3 * math.abs(along), rarm = math.abs(side) + 0.3 * math.abs(along),
          lleg = math.max(0, -along) * 1.1, rleg = math.max(0, -along) * 1.1,
          jump = jump, speed = l.vel:length()}
  -- a crash stops the car in one step, but feed counts a force only when it lasts two steps: a hard step is repeated once while the speed
  -- it took off stays off
  local sv = last[id]
  sv.dvLen, sv.out = dvLen, out
  if l.out and l.dvLen and l.vel2 and l.out.chest > 8 and (vel - l.vel2):length() >= 0.5 * l.dvLen then return l.out end
  return out
end

-- How injuries feel (the player's own driver): blurry screen edges and muffled hearing after a hit, fading over T.fxSeconds (a knock-out keeps
-- them until he wakes), no sprinting on foot with a broken leg. The game offers no camera shake we could use, and no screen darkening
-- without shipping a shader, so these are the effects there are: ScreenBlurFX rects, core_sounds.setAudioBlur, playerController.setSpeedCoef.
local fx = {peak = 0, left = 0, dur = 1, muffled = false}
local FX_LEVEL = {bruised = 0.35, broken = 0.7, unconscious = 1, fatal = 1}
local walkState                -- the car state of the driver who got out onto the unicycle (his leg)
local footTimer = 0
local NO_SPRINT = "local c = controller and controller.getController('playerController') if c and c.setSpeedCoef then c.setSpeedCoef(0) end"
local function fxAmount()
  local pid = be and be:getPlayerVehicleID(0)
  local st = pid and state[pid]
  if st and (st.dead or not st.conscious) then return 1 end
  return fx.peak * math.max(0, math.min(1, fx.left / fx.dur))
end
local function fxStart(level)
  local p = FX_LEVEL[level]
  if p and p >= fxAmount() then fx.peak, fx.left, fx.dur = p, T.fxSeconds, T.fxSeconds end
end
local function isUnicycle(v) return v and v.getJBeamFilename and v:getJBeamFilename() == 'unicycle' end
local function limping()
  return walkState and walkState.recovery > 0 and injuries(-1, walkState).limits.slowWalk
end

local function onUpdate(dtReal, dtSim)
  now = now + dtReal
  fx.left = math.max(0, fx.left - dtReal)
  footTimer = footTimer - dtReal
  if footTimer <= 0 then   -- on foot with a broken leg: sprinting is switched off, a few times a second
    footTimer = 0.25
    local pv = be and be:getObjectByID(be:getPlayerVehicleID(0))
    if T.limp ~= 0 and mode ~= 'off' and isUnicycle(pv) and limping() then pv:queueLuaCommand(NO_SPRINT) end
  end
  if mode == 'off' then return end
  local dt = dtSim or dtReal
  local cam = core_camera and core_camera.getPosition()
  -- stub feed: the player's car only (W9: the other cars' drivers are props, nobody else gets hurt)
  for i = 0, (be and be:getObjectCount() or 0) - 1 do
    local v = be:getObject(i)
    local id = v:getId()
    local tracked = isPlayer(id)
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
      local add = (st.level == 'unconscious' and T.recoverOut or 0) + T.recoverBroken * #broken(st)
      st.recovery = st.recovery + add
      extensions.hook('onSlrrDriverInjured', id, injuries(id, st))
      if isPlayer(id) then fxStart(st.level) end
    end
    if st.dying and not st.dead and now - st.dying.at >= DIE_SETTLE then
      st.dead = true
      extensions.hook('onSlrrDriverDied', id, 'crash',
                      {kind = st.dying.kind, peakG = st.peakG, speed = st.speed, player = isPlayer(id) or false})
    end
    if not st.conscious and not st.dead and st.wakeAt and now >= st.wakeAt then
      st.conscious = true
      setControls(id, true)
      slump(id, false)
      say(id, st, 'wake')
    end
  end
end

local function heal(vehId)
  vehId = vehId or (be and be:getPlayerVehicleID(0))
  local st = state[vehId]
  if not st then return end
  if not st.conscious then setControls(vehId, true) end
  slump(vehId, false)
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
  -- on foot (the unicycle) with the leg he broke in the car: the pedestrian side reads limits.slowWalk from here
  if (not st or st.level == 'none') and walkState and walkState.recovery > 0 and isUnicycle(be and be.getObjectByID and be:getObjectByID(vehId)) then return injuries(vehId, walkState) end
  if not st then return {injured = false, severity = 0, recoverySeconds = 0, level = 'none',
                         limits = {noDriving = false, slowWalk = false}, parts = {head = 0, chest = 0, arms = 0, legs = 0}} end
  return injuries(vehId, st)
end
M.setMode = function(m)
  if not MODES[m] then return end
  mode = m
  M.saveSettings()
  if mode == 'off' then for id in pairs(state) do heal(id) end end
end
M.getMode = function() return mode end
M.setDeathOverride = function(on) deathOverride = on == true end          -- a Hardcore career (not saved)
M.getDeathAllowed = function() return mode == 'full' or deathOverride end
-- settings file: the mode and the tunables that differ from the defaults
M.saveSettings = function()
  local tune = {}
  for k, v in pairs(T) do if v ~= T0[k] then tune[k] = v end end
  jsonWriteFile(SETTINGS, {mode = mode, tune = next(tune) and tune or nil}, true)
end
M.getTune = function(key) return T[key] end
M.setTune = function(key, value)   -- clamped to its range; unknown keys and non-numbers are refused
  local r = TUNE_RANGE[key]
  value = tonumber(value)
  if not (r and value) or value ~= value then return false end
  T[key] = math.max(r[1], math.min(r[2], value))
  M.saveSettings()
  return true
end
M.resetTune = function() for k, v in pairs(T0) do T[k] = v end M.saveSettings() end
-- label, plain tooltip, shown scale: what the Injury tab offers beyond the mode
local SPEC = {
  {key = 'toughness', group = 'Crashes', label = 'Toughness', tip = 'How hard a crash has to be before he is hurt. Below 1x he is more fragile, above 1x tougher.', step = 0.05, unit = 'x'},
  {key = 'recoverBroken', group = 'Recovery', label = 'Broken arm or leg heals in', tip = 'Real seconds a broken arm or leg takes to heal, for each one broken. 0 heals them at once.', step = 30, unit = 's'},
  {key = 'recoverOut', group = 'Recovery', label = 'Knocked out for', tip = 'Real seconds he stays down after being knocked out.', step = 15, unit = 's'},
  {key = 'voiceGap', group = 'Voice', label = 'Time between his shouts', tip = 'At least this many seconds between his cries of pain or anger. 0 lets him shout every time.', step = 0.5, unit = 's'},
  {key = 'reduceMotion', group = 'How injuries feel', bool = true, label = 'Reduce motion', tip = 'Turns off the screen effects (blur) for people who get motion sick. Sound and walking effects keep their own switches.'},
  {key = 'fxBlur', group = 'How injuries feel', bool = true, label = 'Blurry edges after a hit', tip = 'The edges of the screen go blurry after a hard hit and clear up again as he recovers.'},
  {key = 'fxBlurStrength', group = 'How injuries feel', label = 'Blur strength', tip = 'How blurry the edges get (0 to 100 %). Modest is the default.', step = 0.05, unit = '%', scale = 100, showIf = 'fxBlur'},
  {key = 'fxMuffle', group = 'How injuries feel', bool = true, label = 'Muffled hearing after a hit', tip = 'The sound is dulled for a while after a hard hit, as if his ears were ringing.'},
  {key = 'fxMuffleStrength', group = 'How injuries feel', label = 'Muffling strength', tip = 'How dull the sound gets (0 to 100 %).', step = 0.05, unit = '%', scale = 100, showIf = 'fxMuffle'},
  {key = 'fxSeconds', group = 'How injuries feel', label = 'Effects fade over', tip = 'Seconds the blur and the muffled hearing take to go away. A knock-out keeps them until he wakes up.', step = 1, unit = 's'},
  {key = 'limp', group = 'How injuries feel', bool = true, label = 'Limp with a broken leg', tip = 'On foot with a broken leg he cannot sprint (he walks at the normal pace) until the leg has healed.'},
  {key = 'bruiseAt', group = 'Thresholds', advanced = true, label = 'Bruised from', tip = 'How hurt a body part is (0 to 100 %) before it counts as bruised.', step = 0.01, unit = '%', scale = 100},
  {key = 'brokenAt', group = 'Thresholds', advanced = true, label = 'Broken from', tip = 'How hurt an arm or leg is (0 to 100 %) before it counts as broken: a broken arm steers worse, a broken leg slows his walk and his pedals.', step = 0.01, unit = '%', scale = 100},
  {key = 'outHead', group = 'Thresholds', advanced = true, label = 'Knocked out by a head injury from', tip = 'How hurt his head is (0 to 100 %) before he is knocked out.', step = 0.01, unit = '%', scale = 100},
  {key = 'outChest', group = 'Thresholds', advanced = true, label = 'Knocked out by a chest injury from', tip = 'How hurt his chest is (0 to 100 %) before he is knocked out.', step = 0.01, unit = '%', scale = 100},
  {key = 'grace', group = 'Thresholds', advanced = true, label = 'Ignore knocks after a spawn for', tip = 'Seconds after a spawn, reset, teleport or car switch in which nothing hurts him (the jolt of the game placing the car).', step = 0.5, unit = 's'},
}
-- The Mods menu (ESC > Mods): the Injury tab, offered to slrrDrivers, which registers the 'Pedestrians & Drivers' page (a page is registered
-- by one extension: the registry replaces it on every register). Returns the tab and its fields. Field ids must be unique inside the whole mod page
-- (the registry drops a second one): the tunables are 'inj_<key>' so they cannot meet a pedestrian or driver field.
M.settingsSchema = function()
  local fields = {
    {id = 'injuryMode', tab = 'injury', group = 'Crashes', type = 'enum', label = 'Injuries', default = 'injuries', apply = 'live',
     options = {{id = 'off', label = 'Off'}, {id = 'injuries', label = 'Injuries'}, {id = 'full', label = 'Injuries and death'}},
     tooltip = 'Off: crashes hurt nobody. Injuries: bruises, broken arms and legs, being knocked out. Injuries and death: a hard enough crash can also kill the driver.',
     store = {kind = 'custom', get = function() return mode end, set = function(v) M.setMode(v) end}}}
  for _, sp in ipairs(SPEC) do
    local r = TUNE_RANGE[sp.key]
    if sp.bool then
      fields[#fields + 1] = {id = 'inj_' .. sp.key, tab = 'injury', group = sp.group, type = 'bool', label = sp.label, tooltip = sp.tip, advanced = sp.advanced,
        default = T0[sp.key] ~= 0, apply = 'live',
        store = {kind = 'custom', get = function() return T[sp.key] ~= 0 end, set = function(v) M.setTune(sp.key, v and 1 or 0) end}}
    else
      fields[#fields + 1] = {id = 'inj_' .. sp.key, tab = 'injury', group = sp.group, type = 'slider', label = sp.label, tooltip = sp.tip, advanced = sp.advanced,
        min = r[1], max = r[2], step = sp.step, unit = sp.unit, scale = sp.scale, default = T0[sp.key], apply = 'live',
        visibleIf = sp.showIf and {field = 'inj_' .. sp.showIf, equals = true} or nil,
        store = {kind = 'custom', get = function() return T[sp.key] end, set = function(v) M.setTune(sp.key, v) end}}
    end
  end
  return {id = 'injury', title = 'Injury', description = 'What a crash does to the driver.'}, fields
end
M.onExtensionLoaded = function()
  local s = jsonReadFile(SETTINGS)
  if s and MODES[s.mode] then mode = s.mode end
  if s and type(s.tune) == 'table' then for k, v in pairs(s.tune) do local r = TUNE_RANGE[k] if r and tonumber(v) then T[k] = math.max(r[1], math.min(r[2], tonumber(v))) end end end
  -- (the page is registered by slrrDrivers: ask it to do it again with this tab in, whichever of the two loaded first)
  local d = rawget(_G, 'slrrDrivers')
  if d and d.onSlrrSettingsReady then pcall(d.onSlrrSettingsReady) end
end
-- a fresh car, a reset, a teleport or a switch: ignore the jolt; outside a career a reset also heals
M.onVehicleSpawned = function(id) state[id] = newState() last[id] = nil end
M.onVehicleResetted = function(id)
  last[id] = nil
  if not (sl_career and sl_career.isActive and sl_career.isActive()) then heal(id) end
  get(id).grace = T.grace
end
M.onVehicleSwitched = function(old, new)
  if old and state[old] then state[old].grace = T.grace end
  if new then get(new).grace = T.grace end
  local nv = new and new >= 0 and be and be:getObjectByID(new)
  walkState = (isUnicycle(nv) and old and state[old]) or nil   -- (his leg goes with him out of the car; into a car it is a car's again)
end
-- every frame: the effects of the moment (none if the mode is off or the player is not hurt)
M.onPreRender = function(dtReal)
  local a = (mode ~= 'off') and fxAmount() or 0
  if a > 0 and T.fxBlur ~= 0 and T.reduceMotion == 0 and ColorF and scenetree and scenetree.ScreenBlurFX and scenetree.ScreenBlurFX.obj then
    local alpha = math.min(1, a * T.fxBlurStrength)
    local o = scenetree.ScreenBlurFX.obj
    for _, r in ipairs({{0, 0, 0.18, 1}, {0.82, 0, 1, 1}, {0.18, 0, 0.82, 0.15}, {0.18, 0.85, 0.82, 1}}) do
      pcall(o.addFrameBlurRect, o, r[1], r[2], r[3], r[4], ColorF(1, 1, 1, alpha))
    end
  end
  local sounds = rawget(_G, 'core_sounds')
  if sounds and sounds.setAudioBlur then
    if a > 0 and T.fxMuffle ~= 0 then sounds.setAudioBlur(math.min(1, a * T.fxMuffleStrength)) fx.muffled = true
    elseif fx.muffled then sounds.setAudioBlur(0) fx.muffled = false end
  end
end
M.getFeel = function() return {amount = fxAmount(), muffled = fx.muffled, limping = limping() and true or false} end   -- (for tests and the console)
M.onVehicleDestroyed = function(id) state[id], last[id] = nil, nil end
M.onClientEndMission = function() state, last = {}, {} end
M._state = function(id) return state[id] end

return M
