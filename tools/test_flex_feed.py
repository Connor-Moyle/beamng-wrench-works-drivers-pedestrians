"""The flex driver's vehicle side (slrrDriverFeed): a bad pose never reaches obj:setBeamLength, and only the driver's own beams are resized.

    python tools/test_flex_feed.py

The real slrrDriverFeed.lua in lupa with a fake vehicle: a camera node, torso nodes, one joint (r_wr) held by two of our beams
(spring 150000, our part), and a car beam and a beam with a break group. NaN, inf, absent, huge and a far-off pose
are dropped; a good pose resizes our beams only.
"""
import os

from lupa.luajit21 import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.join(HERE, "..", "mod")

SETUP = """
calls = {}
log = function() end
objectId = 1
electrics = {values = {}}
tableSize = function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
obj = {setBeamLength = function(_, b, l) calls[#calls + 1] = {b, l} end, getNodeMass = function() return 1 end, setNodeMass = function() end,
       queueGameEngineLua = function() end}
local N = function(name, x, y, z) return {name = name, pos = {x = x, y = y, z = z}, cid = 0} end
v = {data = {
  nodes = {[0] = N('cam', 0.3, 0.2, 1.0), [1] = N('slrr_rd_chest', 0.3, 0.3, 0.6), [2] = N('slrr_rd_pelvis', 0.3, 0.4, 0.2),
           [3] = N('slrr_rd_r_wr', 0.2, -0.3, 0.8), [4] = N('car_node', 0, 0, 0)},
  beams = {
    [0] = {id1 = 3, id2 = 1, beamSpring = 150000, partOrigin = 'slrr_ragdoll', beamType = 0},
    [1] = {id1 = 3, id2 = 2, beamSpring = 150000, partOrigin = 'slrr_ragdoll', beamType = 0},
    [2] = {id1 = 4, id2 = 1, beamSpring = 4000000, partOrigin = 'covet_body', beamType = 0},   -- a car beam
    [3] = {id1 = 3, id2 = 1, beamSpring = 150000, partOrigin = 'slrr_ragdoll', beamType = 0, breakGroup = 'x'},   -- has a break group: not ours
    [4] = {id1 = 3, id2 = 4, beamSpring = 150000, partOrigin = 'slrr_ragdoll', beamType = 0}}}}   -- ours: a hold to a car node
"""


def pose(vals):
    return "{" + ",".join(vals) + "}"


def main():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    lua.execute(SETUP)
    M = lua.execute(open(os.path.join(MOD, "lua", "vehicle", "extensions", "slrrDriverFeed.lua")).read())
    lua.globals().M = M
    lua.execute("M.setDriverMass(0, 0)")   # records the camera node
    good = ["0.2"] * 27
    bad = {
        "NaN": ["0.2"] * 5 + ["(0/0)"] + ["0.2"] * 21,
        "inf": ["math.huge"] + ["0.2"] * 26,
        "absent": ["0.2"] * 20,
        "huge": ["99"] + ["0.2"] * 26,
    }
    for name, vals in bad.items():
        lua.execute("calls = {} now = {}")
        lua.execute("M.pose(" + pose(vals) + ") M.updateGFX(1/60)")
        assert lua.eval("#calls") == 0, name + ": a bad pose reached setBeamLength"
    far = ["0.2"] * 27
    far[6] = "4"   # r_wr 4 m to the side: inside the 5 m pose check, but its beams would be far past their rest length
    lua.execute("calls = {} now = {} M.pose(" + pose(far) + ") M.updateGFX(1)")
    assert lua.eval("#calls") == 0, "a far-off joint resized a beam"
    lua.execute("calls = {} now = {} M.pose(" + pose(good) + ") M.updateGFX(1)")
    beams = sorted({lua.eval("calls[%d][1]" % (i + 1)) for i in range(lua.eval("#calls"))})
    assert beams == [0, 1, 4], "only our own beams may be resized (a car node hold is ours), got %s" % beams
    # the health log line (every 5 s) runs and does not break posing
    lua.execute("""logged = {} log = function(l, t, m) logged[#logged + 1] = l .. ' ' .. m end
                   obj.beamIsBroken = function(_, b) return b == 1 end
                   obj.getNodePosition = function(_, c) return vec3(c, 0, 0) end
                   calls = {} now = {} M.pose(""" + pose(good) + """) M.updateGFX(6)""")
    assert lua.eval("#calls") > 0, "posing stopped after the health log"
    line = lua.eval("table.concat(logged, '|')")
    assert "1 of" in line and "broken" in line and "health log failed" not in line, line
    # a torso that sank 0.2 m (car faces +y, up +z, no turn): the beam is measured to the rest place until the car has stood
    # still 3 s, then, once, to the settled place
    lua.execute("""
      local function W(c) local n = v.data.nodes[c] return vec3(-n.pos.x, -n.pos.y, n.pos.z - (c == 1 and 0.2 or 0)) end
      obj.getNodePosition = function(_, c) return W(c) end
      obj.getDirectionVector = function() return vec3(0, 1, 0) end
      obj.getDirectionVectorUp = function() return vec3(0, 0, 1) end
      obj.getVelocity = function() return vec3(0, 0, 0) end
      logged = {}
      calls = {} now = {} M.onReset() M.pose(""" + pose(good) + """) M.updateGFX(1)
      pre = nil for _, c in ipairs(calls) do if c[1] == 0 then pre = c[2] end end
      for i = 1, 4 do M.pose(""" + pose(good) + """) M.updateGFX(1) end
      calls = {} M.updateGFX(1)
      post = nil for _, c in ipairs(calls) do if c[1] == 0 then post = c[2] end end
      local n, cam = v.data.nodes[1], v.data.nodes[0].pos
      local tg = vec3(cam.x - 0.2, cam.y - 0.2, cam.z + 0.2)   -- the r_wr target as told (seat 0.2, 0.2, 0.2 from the eye)
      want_pre = tg:distance(vec3(n.pos.x, n.pos.y, n.pos.z))
      want_post = tg:distance(vec3(n.pos.x, n.pos.y, n.pos.z - 0.2))""")
    assert abs(lua.eval("pre") - lua.eval("want_pre")) < 1e-6, "before settling the rest place is used"
    assert abs(lua.eval("post") - lua.eval("want_post")) < 1e-6, (lua.eval("post"), lua.eval("want_post"))
    print("ok: bad poses dropped, health log line written, torso settled once after 3 s")


if __name__ == "__main__":
    main()
