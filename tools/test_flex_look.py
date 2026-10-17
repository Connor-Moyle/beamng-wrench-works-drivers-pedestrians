"""The flex driver's appearance (slrrDriverMount's hook, driverRig 'flex'): setAppearance scale resizes its nodes and meshes,
a helmet adds a head-bound flexbody, no helmet adds none.

    python tools/test_flex_look.py
"""
import json
import os

from lupa.luajit21 import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.join(HERE, "..", "mod")


def build(look):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    lua.execute(open(os.path.join(HERE, "bng_shim_game.lua")).read())
    errors = []
    lua.globals().SHIM_RIG = json.dumps(json.load(open(os.path.join(MOD, "art/slrr_drivers/models/vin/rig.json"))))
    lua.globals().py_err = lambda msg: errors.append(msg)
    lua.execute("""
      function log(level, tag, msg) if level == 'E' then py_err(msg) end end
      nodes = {}
      package.preload['jbeam/utils'] = function() return {
        increaseMax = function(v, k) v.maxIDs = v.maxIDs or {} v.maxIDs[k] = (v.maxIDs[k] or 0) + 1 return v.maxIDs[k] end,
        addNodeWithOptions = function(v, pos, ntype, o) nodes[o.name] = pos return #v.nodes + 100 + #nodes end,
        addBeamWithOptions = function() return 0 end}
      end
    """)
    lua.globals().LOOK = lua.table_from(look)
    lua.execute("""
      slrrDrivers = {getDriver = function() return nil end, getDefaultDriver = function() return 'slrr_mitch' end,
                     getDrivers = function() return {} end, getAppearance = function() return LOOK end}
    """)
    M = lua.execute(open(os.path.join(MOD, "lua/ge/extensions/slrrDriverMount.lua")).read())
    lua.globals().M = M
    M.onExtensionLoaded()
    M.setDriverRig("flex")
    lua.execute("""
      v = {nodes = {{cid = 4, name = 'cam', pos = {x = 0.35, y = 0.1, z = 1.15}}}, props = {}, flexbodies = {},
           cameras = {onboard = {{name = 'driver', camNodeID = 4}}}}
    """)
    M.onJbeamLoadingPhase1(0.5, 7, lua.globals().v)
    return lua, M, errors


def main():
    lua, M, errors = build({})
    n1 = lua.eval("#v.flexbodies")
    assert n1 == 14 and lua.eval("v.flexbodies[1].scale.x") == 1 and M.getFlexScale(7) == 1, ("plain", n1)
    sh1 = lua.eval("nodes.slrr_rd_r_sh.x")
    lua, M, errors2 = build({"scale": 1.1, "helmet": True})
    assert lua.eval("#v.flexbodies") == 15, "a helmet adds one flexbody"
    helmet = lua.eval("v.flexbodies[15]")
    assert helmet.mesh.endswith("_helmet"), helmet.mesh
    assert lua.eval("v.flexbodies[15]['[group]:nodes'][1]") == lua.eval("v.flexbodies[2]['[group]:nodes'][1]"), "helmet is bound like the head"
    assert abs(lua.eval("v.flexbodies[1].scale.x") - 1.1) < 1e-9 and M.getFlexScale(7) == 1.1
    # the shoulder sits 1.1x as far from the eye (jbeam x is left: cam.x - p.x)
    sh2 = lua.eval("nodes.slrr_rd_r_sh.x")
    assert abs((0.35 - sh2) - 1.1 * (0.35 - sh1)) < 1e-6, (sh1, sh2)
    assert not errors and not errors2, (errors, errors2)
    print("flex look ok: scale resizes nodes and meshes, a helmet adds a head-bound flexbody")


if __name__ == "__main__":
    main()
