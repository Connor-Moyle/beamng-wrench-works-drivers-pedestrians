-- Offline stand-ins for BeamNG's vec3, MatrixF and maths helpers, then the fake game (bng_shim_game.lua).
local V = {}
V.__index = V
function vec3(x, y, z)
  if type(x) == 'table' then x, y, z = x.x, x.y, x.z end
  return setmetatable({x = x or 0, y = y or 0, z = z or 0}, V)
end
V.__add = function(a, b) return vec3(a.x + b.x, a.y + b.y, a.z + b.z) end
V.__sub = function(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end
V.__unm = function(a) return vec3(-a.x, -a.y, -a.z) end
V.__mul = function(a, b)
  if type(a) == 'number' then a, b = b, a end
  return vec3(a.x * b, a.y * b, a.z * b)
end
V.__div = function(a, s) return vec3(a.x / s, a.y / s, a.z / s) end
V.__tostring = function(a) return string.format('vec3(%g,%g,%g)', a.x, a.y, a.z) end
function V:dot(b) return self.x * b.x + self.y * b.y + self.z * b.z end
function V:cross(b) return vec3(self.y * b.z - self.z * b.y, self.z * b.x - self.x * b.z, self.x * b.y - self.y * b.x) end
function V:length() return math.sqrt(self:dot(self)) end
function V:normalized() local l = self:length() return l > 0 and self / l or vec3(0, 0, 0) end
function V:distance(b) return (self - b):length() end

function clamp(v, lo, hi) return math.min(math.max(v, lo), hi) end
function lerp(a, b, t) return a + (b - a) * t end
function smootheststep(x) return x * x * x * (x * (x * 6 - 15) + 10) end
function sign(x) return x > 0 and 1 or (x < 0 and -1 or 0) end

local Mt = {}
Mt.__index = Mt
function MatrixF() return setmetatable({cols = {}, pos = vec3(0, 0, 0)}, Mt) end
function Mt:setColumn(i, v) self.cols[i] = vec3(v) end
function Mt:getColumn(i) return vec3(self.cols[i]) end
function Mt:setPosition(v) self.pos = vec3(v) end
function Mt:getPosition() return vec3(self.pos) end
function Mt:toQuatF()   -- the rotation of the columns, as the game's QuatF userdata (x, y, z, w)
  local c = self.cols
  local function r(i, j) local v = c[j] return i == 0 and v.x or (i == 1 and v.y or v.z) end   -- row i, column j
  local xx, yy, zz = r(0, 0), r(1, 1), r(2, 2)
  local t, q = xx + yy + zz
  if t > 0 then
    local s = math.sqrt(t + 1) * 2
    q = {w = 0.25 * s, x = (r(2, 1) - r(1, 2)) / s, y = (r(0, 2) - r(2, 0)) / s, z = (r(1, 0) - r(0, 1)) / s}
  elseif xx > yy and xx > zz then
    local s = math.sqrt(1 + xx - yy - zz) * 2
    q = {x = 0.25 * s, w = (r(2, 1) - r(1, 2)) / s, y = (r(0, 1) + r(1, 0)) / s, z = (r(0, 2) + r(2, 0)) / s}
  elseif yy > zz then
    local s = math.sqrt(1 + yy - xx - zz) * 2
    q = {y = 0.25 * s, w = (r(0, 2) - r(2, 0)) / s, x = (r(0, 1) + r(1, 0)) / s, z = (r(1, 2) + r(2, 1)) / s}
  else
    local s = math.sqrt(1 + zz - xx - yy) * 2
    q = {z = 0.25 * s, w = (r(1, 0) - r(0, 1)) / s, x = (r(0, 2) + r(2, 0)) / s, y = (r(1, 2) + r(2, 1)) / s}
  end
  q.isQuatF = true
  return q
end
function quat(q) return {x = q.x, y = q.y, z = q.z, w = q.w} end   -- the game's quat(): cdata, not a QuatF
-- a quaternion's rotation as three column vectors (0, 1, 2)
function quatColumns(q)
  local x, y, z, w = q.x, q.y, q.z, q.w
  return {[0] = vec3(1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y)),
          vec3(2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x)),
          vec3(2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y))}
end

-- self-check
assert(vec3(1, 0, 0):cross(vec3(0, 1, 0)).z == 1)
assert((2 * vec3(1, 2, 3)).z == 6 and (vec3(1, 2, 3) * 2).y == 4)
do   -- a matrix survives the trip through its quaternion
  local m = MatrixF()
  local a, b = 0.7, -1.9
  m:setColumn(0, vec3(math.cos(a), math.sin(a), 0)) m:setColumn(1, vec3(-math.sin(a) * math.cos(b), math.cos(a) * math.cos(b), math.sin(b)))
  m:setColumn(2, m:getColumn(0):cross(m:getColumn(1)))
  local c = quatColumns(m:toQuatF())
  for i = 0, 2 do assert(c[i]:distance(m:getColumn(i)) < 1e-9, 'toQuatF column ' .. i) end
end
