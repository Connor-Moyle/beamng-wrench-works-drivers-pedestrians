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

-- self-check
assert(vec3(1, 0, 0):cross(vec3(0, 1, 0)).z == 1)
assert((2 * vec3(1, 2, 3)).z == 6 and (vec3(1, 2, 3) * 2).y == 4)
