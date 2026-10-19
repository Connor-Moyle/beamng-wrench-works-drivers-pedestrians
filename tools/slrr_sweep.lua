-- Coverage sweep for the rigged driver (a dev tool, not part of the mod). In the game's GE Lua console:
--   sweep = dofile('C:/Dev/wt_driver_rework/tools/slrr_sweep.lua'); sweep.start()                 -- every drivable stock car and truck
--   sweep.start({models = {'covet', 'pickup'}})                                                    -- or a list of model keys
--   sweep.start({models = {{model = 'pickup', config = 'd15_4wd_A'}}, shot = function(path) ... end})
-- For every model: the car is spawned to be entered (the player's car: it gets the flex driver), waited for, driven by the
-- steering input through 0, -0.5, 0, +0.5, 0 while slrrDrivers records the pose, and a summary line is written. Everything goes to
-- <userdir>/slrr_sweep/: <model>.json (the pose recording, for tools/check_sweep.py), summary.json (one record per model) and
-- <model>.jpg when a screenshot function is given (opts.shot(path): the caller's own way of taking one).
-- The display mode is set for each car only (never the saved global one). Progress goes to the log as 'slrrSweep'. Stop it with
-- sweep.stop(). Do not run it with a game that matters open: it deletes the car it spawned last, not any other.
local M = {}
local log = log or function() end
local OUT = 'slrr_sweep/'
local running, summary, wasMode = false, {}, nil

local function finite(v) return type(v) == 'number' and v == v and math.abs(v) < 1e6 end

-- every model key that looks like a drivable car, truck or van
local function defaultModels()
  local list = {}
  local ml = core_vehicles and core_vehicles.getModelList and core_vehicles.getModelList()
  for key, m in pairs(ml and ml.models or {}) do
    local t = tostring(m.Type or ''):lower()
    local aggs = m.aggregates or {}
    if (t == 'car' or t == 'truck' or t == 'van' or t == 'suv') and not (aggs.Type and (aggs.Type.Prop or aggs.Type.Trailer)) and key ~= 'unicycle' then
      list[#list + 1] = {model = key}
    end
  end
  table.sort(list, function(a, b) return a.model < b.model end)
  return list
end

local function nodesOf(vid)
  local vd = core_vehicle_manager and core_vehicle_manager.getVehicleData(vid)
  return vd and vd.vdata and vd.vdata.nodes
end

-- from the car's own nodes (jbeam space: x left, y back, z up), in metres above and ahead of the driver's eye node (c.cam0)
local function carFit(c, nodes)
  local fit = {}
  if not (c.cam0 and nodes) then return fit end
  local roof, seatTop = -math.huge, -math.huge
  for _, n in pairs(nodes) do
    if type(n) == 'table' and n.pos then
      local dx, dy, dz = n.pos.x - c.cam0.x, n.pos.y - c.cam0.y, n.pos.z - c.cam0.z
      if dz > 0.05 and math.abs(dx) < 0.35 and math.abs(dy) < 0.5 then roof = math.max(roof, dz) end   -- anything over his head (roof, headliner)
    end
  end
  fit.roomAboveEye = roof > -math.huge and roof or nil
  return fit
end

local function wait(job, s) job.sleep(s) end

local function oneCar(job, entry, opts)
  local rec = {model = entry.model, config = entry.config}
  local t0 = os.clock()
  local vid
  local ok, err = pcall(function()
    local o = core_vehicles.spawnNewVehicle(entry.model, {config = entry.config, pos = opts.pos, rot = opts.rot, autoEnterVehicle = true})
    vid = o and o:getID()
  end)
  if not (ok and vid) then rec.error = 'spawn failed: ' .. tostring(err) return rec end
  rec.vid = vid
  -- the mount: how long until the rig exists and the meshes are visible
  local waited = 0
  while waited < 12 and not (slrrDriverMount and slrrDriverMount.hasFlexDriver(vid) and slrrDriverMount.flexShown(vid)) do wait(job, 0.25) waited = waited + 0.25 end
  rec.mountS = os.clock() - t0
  rec.flex = slrrDriverMount and slrrDriverMount.hasFlexDriver(vid) or false
  wait(job, 4)   -- the pose settles (the torso is fixed after 3 s)
  local c = slrrDrivers.getState(vid)
  if not c then rec.error = 'no driver state' return rec end
  slrrDrivers.setDisplayMode('full', vid)
  rec.wheelR, rec.wheelTilt = c.wheelR, c.wN0 and math.deg(math.atan2(c.wN0.z, math.sqrt(c.wN0.x ^ 2 + c.wN0.y ^ 2))) or nil
  rec.seatLeft, rec.hasSeatBack = c.seatLeft, c.seatBack ~= nil
  local fit = carFit(c, nodesOf(vid))
  rec.roomAboveEye = fit.roomAboveEye
  -- steering 0, -0.5, 0, +0.5, 0 held 2 s each while the pose is recorded
  slrrDrivers.startRecording(vid)
  local veh = be:getObjectByID(vid)
  for _, s in ipairs({0, -0.5, 0, 0.5, 0}) do
    if veh then veh:queueLuaCommand('input.event("steering", ' .. s .. ', 1)') end
    wait(job, 2)
    if s == 0.5 and opts.shot then pcall(opts.shot, OUT .. entry.model .. '.jpg') end
  end
  local n, r = slrrDrivers.stopRecording(vid)
  rec.frames = n
  if r then
    jsonWriteFile(OUT .. entry.model .. '.json', r, false)
    -- non-finite or runaway numbers anywhere in the pose
    for _, fr in ipairs(r.frames) do
      for name, p in pairs(fr.parts) do
        for i = 1, 3 do if not finite(p[i]) or math.abs(p[i]) > 3 then rec.bad = (rec.bad or 0) + 1 break end end
      end
    end
  end
  rec.state = {flexShown = slrrDriverMount and slrrDriverMount.flexShown(vid) or false}
  return rec
end

function M.start(opts)
  opts = opts or {}
  if running then log('W', 'slrrSweep', 'already running') return end
  running, summary = true, {}
  wasMode = nil
  local list = {}
  for _, m in ipairs(opts.models or defaultModels()) do list[#list + 1] = type(m) == 'string' and {model = m} or m end
  opts.pos = opts.pos or vec3(0, 0, 0.3)
  opts.rot = opts.rot or quat(0, 0, 0, 1)
  if not opts.pos_given and be and be.getPlayerVehicle and be:getPlayerVehicle(0) then
    local pv = be:getPlayerVehicle(0)
    opts.pos = vec3(pv:getPosition()) + vec3(0, 6, 0)   -- near wherever the player is (a flat place is the caller's choice: opts.pos)
  end
  core_jobsystem.create(function(job)
    log('I', 'slrrSweep', 'sweep of ' .. #list .. ' models')
    local last
    for i, entry in ipairs(list) do
      if not running then break end
      if last and be:getObjectByID(last) then be:getObjectByID(last):delete() wait(job, 1) end
      local rec = oneCar(job, entry, opts)
      last = rec.vid
      summary[#summary + 1] = rec
      log('I', 'slrrSweep', string.format('%d/%d %s: %s, mount %.1f s, wheel R %s tilt %s, room above eye %s, bad %s%s', i, #list, entry.model,
        rec.flex and 'flex' or 'props', rec.mountS or -1, tostring(rec.wheelR and string.format('%.3f', rec.wheelR)), tostring(rec.wheelTilt and string.format('%.0f', rec.wheelTilt)),
        tostring(rec.roomAboveEye and string.format('%.2f', rec.roomAboveEye)), tostring(rec.bad or 0), rec.error and (', ' .. rec.error) or ''))
      jsonWriteFile(OUT .. 'summary.json', summary, true)
    end
    if last and be:getObjectByID(last) then be:getObjectByID(last):delete() end
    running = false
    log('I', 'slrrSweep', 'sweep done: ' .. #summary .. ' models')
  end)
end

function M.stop() running = false end
function M.summary() return summary end
return M
