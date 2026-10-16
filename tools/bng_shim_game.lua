-- Just enough of BeamNG's GE Lua for slrrDrivers.lua to run offline (tools/stress_driver.py).
-- Needs vec3 / MatrixF / clamp / lerp / smootheststep / sign from bng_shim_vec.lua first.

function log() end
function jsonWriteFile() end
function loadJsonMaterialsFile() end
function readFile(path)
  if path:find('%.bin$') then   -- real data from the mod folder (tint sources)
    local f = io.open(SHIM_MOD .. path, 'rb') if not f then return nil end
    local d = f:read('*a') f:close() return d
  end
  return 'dae'
end
SHIM_SAVED = {}
function GBitmap()
  local b = {}
  function b:init(w, h) self.w, self.h = w, h end
  function b:fromBuffer(buf) self.data = buf:tostring() return true end
  function b:saveFile(path) SHIM_SAVED[path] = self.data return true end
  return b
end
function writeFile() end
function simObjectExists(o) return o ~= nil and not o.deleted end

FS = {
  findFiles = function(_, root, pattern)
    if pattern == 'driver.json' then
      local list = {'/art/slrr_drivers/slrr_mitch/driver.json'}
      if SHIM_PASSENGER then list[2] = '/art/slrr_drivers/slrr_opponent1/driver.json' end
      return list
    end
    if pattern:find('_shade') or pattern:find('_shirt') or pattern:find('_trousers') or pattern:find('_tint') then return {root .. pattern:gsub('%*', 'mitch_whole')} end
    return {}
  end,
  fileExists = function() return true end,
}

function jsonReadFile(path)
  if path:find('rig%.json$') then return shim_decode(SHIM_RIG) end
  if path:find('driver%.json$') then local id = path:match('/([^/]+)/driver%.json$') return {name = id, model = 'vin', skin = id} end
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
addNode(50, CAM.x - 0.32, -0.30, CAM.z - 0.50)     -- H-pattern lever knob (car's right of the driver)
-- footwell collision triangles: the floor 1.2 m below the eye and a firewall 1.05 m ahead of it
addNode(60, CAM.x + 0.8, -0.1, CAM.z - 1.2) addNode(61, CAM.x - 0.8, -0.1, CAM.z - 1.2)
addNode(62, CAM.x + 0.8, -1.05, CAM.z - 1.2) addNode(63, CAM.x - 0.8, -1.05, CAM.z - 1.2)
addNode(64, CAM.x + 0.8, -1.05, CAM.z - 0.5) addNode(65, CAM.x - 0.8, -1.05, CAM.z - 0.5)
local triangles = {{id1 = 60, id2 = 61, id3 = 62}, {id1 = 61, id2 = 63, id3 = 62},
                   {id1 = 62, id2 = 63, id3 = 64}, {id1 = 63, id2 = 65, id3 = 64}}
if SHIM_NO_TRIANGLES then triangles = nil end
-- a realistic footwell has a few hundred triangles (224 in the etk800): pad it out for timing
for k = 1, (SHIM_EXTRA_TRIS or 0) do
  local x, y, z = CAM.x + (k % 15) * 0.1 - 0.7, -0.2 - (k % 9) * 0.12, CAM.z - 1.3 + (k % 7) * 0.02
  addNode(1000 + 3 * k, x, y, z) addNode(1001 + 3 * k, x + 0.1, y, z) addNode(1002 + 3 * k, x, y - 0.1, z)
  table.insert(triangles, {id1 = 1000 + 3 * k, id2 = 1001 + 3 * k, id3 = 1002 + 3 * k})
end
local torsionHydros = {}
if SHIM_HPATTERN then torsionHydros = {{id1 = 41, id2 = 42, id3 = 43, id4 = 50, inputSource = 'hPatternAxisY'}} end
local props = {
  {func = 'steering', idRef = 2},
  {func = 'throttle', idRef = 40, rotation = vec3(-0.436, 0, 0)},
  {func = 'brake', idRef = 41, rotation = vec3(-0.436, 0, 0)},
}
if SHIM_HPATTERN then table.insert(props, {func = 'clutch', idRef = 42, rotation = vec3(-0.436, 0, 0)}) end

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
SHIM_CMDS = {}
function veh:queueLuaCommand(cmd) SHIM_CMDS[#SHIM_CMDS + 1] = cmd end
function veh:getVelocity() return vec3(car.vel) end
function veh:getDirectionVector() local f = axes() return f end
function veh:getDirectionVectorUp() local _, u = axes() return u end
function veh:getNodePositionXYZ(cid)
  local n = nodes[cid] or nodes[1]
  local fwd, up, left = axes()
  local p = left * n.pos.x - fwd * n.pos.y + up * n.pos.z
  return p.x, p.y, p.z
end
-- the driver's parts as vehicle props (what slrrDriverMount adds at spawn), when SHIM_PROPS is set
local shimProps = {}
local SHIM_PARTS = {'body', 'head', 'r_upperarm', 'r_forearm', 'r_hand', 'l_upperarm', 'l_forearm', 'l_hand',
                    'r_thigh', 'r_calf', 'r_foot', 'l_thigh', 'l_calf', 'l_foot'}
local function shimPropSet(skin)
  for _, part in ipairs(SHIM_PARTS) do
    local p = {mesh = skin .. '_' .. part, visible = true}
    function p:getMeshName() return self.mesh end
    function p:setVisible(v) self.visible = v end
    function p:setMaterialOverride() error('a material override on a prop crashes the game (slot 2026-10-16)') end
    function p:setBaseTranslationGlobal(v) self.t = vec3(v) end
    function p:setBaseRotationGlobalQuat(q) assert(q.isQuatF, 'expect userdata, got cdata') self.q = q end
    shimProps[#shimProps + 1] = p
  end
end
if SHIM_PROPS then shimPropSet('slrr_mitch') end
if SHIM_PASSENGER then shimPropSet('slrr_opponent1') end
function shimPropsList() return shimProps end
-- what slrrDriverMount gave the car: the driver's skin, and the passenger's seat 0.7 m to the car's right
SHIM_PASSENGER_AT = {x = CAM.x - 0.7, y = CAM.y, z = CAM.z}
if SHIM_PROPS then
  slrrDriverMount = {getMount = function() return {driver = 'slrr_mitch', passenger = SHIM_PASSENGER and 'slrr_opponent1' or nil,
                                                    passengerAt = SHIM_PASSENGER and SHIM_PASSENGER_AT or nil} end}
end
function veh:getPropCount() return #shimProps end
function veh:getProp(pid) return shimProps[pid + 1] end
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
local powertrain = {{type = SHIM_HPATTERN and 'manualGearbox' or 'automaticGearbox', name = 'gearbox'}}
core_vehicle_manager = {getVehicleData = function() return {vdata = {nodes = nodes, props = props, torsionHydros = torsionHydros, powertrain = powertrain, triangles = triangles}} end}
function shim_node_seat(cid)   -- a car node in the seat frame (x right, y forward, z up)
  local fwd, up, left = axes()
  local d = vec3(veh:getNodePositionXYZ(cid)) - vec3(veh:getNodePositionXYZ(1))
  return {x = d:dot(fwd:cross(up)), y = d:dot(fwd), z = d:dot(up)}
end

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
-- drawn this frame (no render lead: LEAD_FRAMES is 0)
function shim_parts_local()
  local c = SHIM_M.getState(car.id)
  local fwd, up, left = axes()
  local right = fwd:cross(up)
  local eye = car.pos + vec3(veh:getNodePositionXYZ(1))
  local out = {}
  for name, o in pairs(c.parts) do
    local d = o:getTransform():getPosition() - eye
    out[name] = {x = d:dot(right), y = d:dot(fwd), z = d:dot(up)}
  end
  return out
end

-- props: the worst distance between where a prop's base transform (jbeam space) puts a part and where the
-- TSStatic path put it (world space), for positions and for the parts' axes
function shim_prop_error()
  local c = SHIM_M.getState(car.id)
  local fwd, up, left = axes()
  local function world(j) return left * j.x - fwd * j.y + up * j.z end   -- jbeam -> world, as getNodePositionXYZ
  local ep, ea = 0, 0
  for _, o in pairs(c.parts) do
    if o.isProp then
      local p, m = o.prop, o:getTransform()
      ep = math.max(ep, (car.pos + world(p.t)):distance(m:getPosition()))
      local cols = quatColumns(p.q)
      for i = 0, 2 do ea = math.max(ea, world(cols[i]):distance(m:getColumn(i))) end
    end
  end
  return ep, ea
end
