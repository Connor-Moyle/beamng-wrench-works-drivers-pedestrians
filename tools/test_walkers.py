"""#35: every driver has a walker (a body for the on-foot player), and slrrDrivers.onVehicleSwitched finds it.

    python tools/test_walkers.py

Per driver folder under mod/art/slrr_drivers: walker/ped.json lists walk shapes and an idle that exist, each shape is a skinned
collada with one animation per bone, wearing the driver's own material; and the real slrrDrivers.lua (in lupa, inside the fake
BeamNG of tools/bng_shim.lua) sends the on-foot player to that driver's walker folder when the player gets out of a car as that driver.
"""
import json
import os
import re
import sys

from lupa.luajit21 import LuaRuntime   # BeamNG runs LuaJIT 2.1

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.join(HERE, "..", "mod")
ART = os.path.join(MOD, "art", "slrr_drivers")


def drivers():
    return sorted(d for d in os.listdir(ART) if os.path.isfile(os.path.join(ART, d, "driver.json")))


def check_files(did):
    wdir = os.path.join(ART, did, "walker")
    ped = json.load(open(os.path.join(wdir, "ped.json")))
    assert ped["walks"] and ped["idle"], (did, "ped.json lists no walks or no idle")
    shapes = list(ped["walks"]) + [ped["idle"]]
    for shape in shapes:
        path = os.path.join(wdir, shape)
        assert os.path.isfile(path), (did, "missing", shape)
        xml = open(path, encoding="utf-8").read()
        joints = len(re.findall(r'type="JOINT"', xml))
        anims = len(re.findall(r"<animation ", xml))
        assert joints >= 20 and anims == joints, (did, shape, "joints", joints, "animations", anims)
        assert ("%s_driver" % did) in xml, (did, shape, "not wearing his own material")
    assert min(ped["walks"].values()) > 0.5, (did, "walking speed", ped["walks"])
    return len(shapes)


def check_switch(ids):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    g = lua.globals()
    g.SHIM_PROPS = False
    lua.execute(open(os.path.join(HERE, "bng_shim_game.lua")).read())
    g.SHIM_MOD = MOD.replace("\\", "/")
    g.SHIM_RIG = json.dumps(json.load(open(os.path.join(ART, "models", "vin", "rig.json"))))
    lua.execute("shim_setup()")
    g.REAL_DRIVERS = lua.table_from(ids)
    lua.execute("""
      local real = {}
      for _, id in ipairs(REAL_DRIVERS) do real[id] = true end
      local oldFind = FS.findFiles
      FS.findFiles = function(self, root, pattern, ...)
        if pattern == 'driver.json' then
          local list = {}
          for id in pairs(real) do list[#list + 1] = '/art/slrr_drivers/' .. id .. '/driver.json' end
          return list
        end
        return oldFind(self, root, pattern, ...)
      end
      FS.directoryExists = function(self, dir) return SHIM_WALKERS[dir] == true end
    """)
    walkers = {"/art/slrr_drivers/%s/walker/" % d: True for d in ids if os.path.isdir(os.path.join(ART, d, "walker"))}
    g.SHIM_WALKERS = lua.table_from(walkers)
    M = lua.execute(open(os.path.join(MOD, "lua", "ge", "extensions", "slrrDrivers.lua")).read())
    g.M = M
    lua.execute("""
      GOT = {}
      slrrPedestrians = {followPlayer = function(vid, dir) GOT[#GOT + 1] = dir or false end}
      local uni = {getJBeamFilename = function() return 'unicycle' end}
      local old = be.getObjectByID
      be.getObjectByID = function(self, id) if id == 99 then return uni end return old(self, id) end
    """)
    M.onExtensionLoaded()
    found = {}
    for did in ids:
        M.setDefaultDriver(did)
        g.GOT = lua.table()
        M.onVehicleSwitched(-1, 99)            # out of a car, onto the unicycle: the default driver gets out
        got = list(g.GOT.values())
        found[did] = got[0] if got else None
    return found


def main():
    ids = drivers()
    for did in ids:
        n = check_files(did) if os.path.isdir(os.path.join(ART, did, "walker")) else None
        assert n, (did, "has no walker folder: the on-foot player would be the snowman")
        print("%-14s %d walker shapes" % (did, n))
    found = check_switch(ids)
    for did in ids:
        assert found[did] == "/art/slrr_drivers/%s/walker/" % did, (did, "onVehicleSwitched sent the walker to", found[did])
    print("onVehicleSwitched finds the walker of all", len(ids), "drivers")
    print("all ok")


if __name__ == "__main__":
    main()
