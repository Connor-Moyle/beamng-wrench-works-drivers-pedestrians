-- Just enough of BeamNG's GE Lua for slrrDrivers.lua to run offline (tools/stress_driver.py).
-- Needs vec3 / MatrixF / clamp / lerp / smootheststep / sign from bng_shim_vec.lua first.

function log() end
function jsonWriteFile() end
function loadJsonMaterialsFile() end
function readFile() return 'dae' end
function writeFile() end
function simObjectExists(o) return o ~= nil and not o.deleted end

FS = {
  findFiles = function(_, root, pattern)
    if pattern == 'driver.json' then return {'/art/slrr_drivers/slrr_mitch/driver.json'} end
    return {}
  end,
  fileExists = function() return true end,
}

function jsonReadFile(path)
  if path:find('rig%.json$') then return shim_decode(SHIM_RIG) end
  if path:find('driver%.json$') then return {name = 'Mitch', model = 'vin', skin = 'slrr_mitch'} end
  return nil
end

-- a tiny JSON decoder (numbers, strings, arrays, objects) for rig.json
function shim_decode(s)
  local i = 1
  local function ws() i = s:find('[^%s]', i) or #s + 1 end
  local val
  local function str() local j = s:find('"', i + 1, true) local r = s:sub(i + 1, j - 1) i = j + 1 return r end
  function val()
    ws()
    local ch = s:sub(i, i)
    if ch == '{' then
      local t = {} i = i + 1 ws()
      if s:sub(i, i) == '}' then i = i + 1 return t end
      while true do
        ws() local k = str() ws() i = i + 1 t[k] = val() ws()
        local d = s:sub(i, i) i = i + 1
        if d == '}' then return t end
      end
    elseif ch == '[' then
      local t = {} i = i + 1 ws()
      if s:sub(i, i) == ']' then i = i + 1 return t end
      while true do
        t[#t + 1] = val() ws()
        local d = s:sub(i, i) i = i + 1
        if d == ']' then return t end
      end
    elseif ch == '"' then return str()
    else
      local j = s:find('[,%]}%s]', i) or #s + 1
      local n = tonumber(s:sub(i, j - 1)) i = j return n
    end
  end
  return val()
end

local function newObj()
  local o = {pos = vec3(0, 0, 0), hidden = false, fields = {}}
  function o:setField(k, _, v) self.fields[k] = v end
  function o:getField(k) return self.fields[k] end
  function o:registerObject() end
  function o:addObject() end
  function o:setHidden(h) self.hidden = h end
  function o:isHidden() return self.hidden end
  function o:delete() self.deleted = true end
  function o:setTransform(m) self.pos = m:getPosition() self.m = m end
  function o:getTransform() return self.m or MatrixF() end
  function o:getPosition() return self.pos end
  return o
end
function createObject() return newObj() end
scenetree = {findObject = function() return nil end, MissionGroup = newObj()}

-- the car: a point that drives along, with a driver-camera node and a cabin around the seat.
-- jbeam axes: x is the car's left, y its back, z up.
local car = {pos = vec3(0, 0, 0.5), yaw = math.pi / 2, speed = 0, vel = vec3(0, 0, 0), id = 7}
local CAM = vec3(0.35, 0.1, 1.15)
local nodes = {[1] = {cid = 1, pos = CAM}}
local function addNode(cid, x, y, z) nodes[cid] = {cid = cid, pos = vec3(x, y, z)} end
addNode(2, 0.35, -0.55, 0.85)                       -- steering hub (in front of the eye)
for k = 0, 5 do                                     -- seat bolsters both sides of the chest and shoulders
  addNode(10 + k, CAM.x + 0.24, 0.12 + k * 0.05, CAM.z - 0.25 - k * 0.06)
  addNode(20 + k, CAM.x - 0.24, 0.12 + k * 0.05, CAM.z - 0.25 - k * 0.06)
end
addNode(30, CAM.x, 0.25, CAM.z - 0.2)               -- seat back
addNode(31, CAM.x + 0.55, 0.0, CAM.z - 0.1)         -- door and pillar
addNode(32, CAM.x - 0.5, -0.1, CAM.z - 0.1)
addNode(33, CAM.x, -0.4, CAM.z + 0.25)              -- roof / windscreen top
for k = 0, 3 do addNode(40 + k, CAM.x - 0.2 + k * 0.12, -0.75, CAM.z - 1.25) end   -- footwell floor
local props = {
  {func = 'steering', idRef = 2},
  {func = 'throttle', idRef = 40, rotation = vec3(-0.436, 0, 0)},
  {func = 'brake', idRef = 41, rotation = vec3(-0.436, 0, 0)},
}

local function axes()
  local fwd = vec3(math.cos(car.yaw), math.sin(car.yaw), 0)
  local up = vec3(0, 0, 1)
  local left = up:cross(fwd)
  return fwd, up, left
end

local veh = {}
function veh:getPosition() return vec3(car.pos) end
function veh:getId() return car.id end
function veh:getJBeamFilename() return 'testcar' end
function veh:queueLuaCommand() end
function veh:getVelocity() return vec3(car.vel) end
function veh:getDirectionVector() local f = axes() return f end
function veh:getDirectionVectorUp() local _, u = axes() return u end
function veh:getNodePositionXYZ(cid)
  local n = nodes[cid] or nodes[1]
  local fwd, up, left = axes()
  local p = left * n.pos.x - fwd * n.pos.y + up * n.pos.z
  return p.x, p.y, p.z
end
function veh:getSpawnLocalAABB() return {minExtents = vec3(-1, -2, 0), maxExtents = vec3(1, 2, 1.5)} end

be = {
  getObjectByID = function(_, id) return id == car.id and veh or nil end,
  getObjectCount = function() return 1 end,
  getObject = function() return veh end,
  getPlayerVehicleID = function() return car.id end,
}
core_camera = {
  getDriverDataById = function() return 1, false end,
  getPosition = function() local f = axes() return car.pos - f * 5 + vec3(0, 0, 2) end,
  getActiveCamName = function() return 'orbit' end,
  getQuat = function() return nil end,
}
core_vehicle_manager = {getVehicleData = function() return {vdata = {nodes = nodes, props = props}} end}

function shim_setup() end
function shim_start(M)
  M.onExtensionLoaded()
  for _ = 1, 3 do M.onPreRender(1 / 60, 1 / 60) end   -- attach
  SHIM_M = M
end

-- one frame: speed and acceleration along the car, steering (deg of wheel), a sideways jolt (kerb)
function shim_step(dt, speed, acc, steer, kerb, rpm, gear, throttle, brake, clutch)
  local fwd = axes()
  car.yaw = car.yaw + speed * math.tan(math.rad(steer) / 15) / 2.6 * dt
  fwd = axes()
  local _, up, left = axes()
  car.vel = fwd * speed + left * (kerb * dt * 3) + up * (kerb * dt)
  car.pos = car.pos + car.vel * dt
  SHIM_M.feed(car.id, steer, rpm, 7000, gear, throttle, brake, clutch)
  SHIM_M.onPreRender(dt, dt)
end

-- every part's position in the seat frame (x right, y forward, z up), relative to where the eye is
-- drawn this frame (the eye plus the one-frame lead the mod adds on purpose)
function shim_parts_local()
  local c = SHIM_M.getState(car.id)
  local fwd, up, left = axes()
  local right = fwd:cross(up)
  local eye = car.pos + vec3(veh:getNodePositionXYZ(1)) + car.vel * (c.dtAvg or 0)
  local out = {}
  for name, o in pairs(c.parts) do
    local d = o.pos - eye
    out[name] = {x = d:dot(right), y = d:dot(fwd), z = d:dot(up)}
  end
  return out
end
