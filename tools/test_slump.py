"""#39: the player's driver slumps over the wheel when the injury add-on says so, and sits up again.

    python tools/test_slump.py

The real slrrDrivers.lua in lupa inside the fake BeamNG: at rest, then setSlump(true): the head goes forward and down, the torso leans, every part
stays a finite number; setSlump(false): back where he was.
"""
import json
import math
import os

from lupa.luajit21 import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.join(HERE, "..", "mod")
DT = 1 / 60


def settle(g, frames):
    for _ in range(frames):
        g.shim_step(DT, 0, 0, 0, 0, 900, 1, 0, 0, 0)


def main():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(HERE, "bng_shim.lua")).read())
    g = lua.globals()
    g.SHIM_PROPS = False
    lua.execute(open(os.path.join(HERE, "bng_shim_game.lua")).read())
    g.SHIM_MOD = MOD.replace("\\", "/")
    g.SHIM_RIG = json.dumps(json.load(open(os.path.join(MOD, "art/slrr_drivers/models/vin/rig.json"))))
    lua.execute("shim_setup()")
    M = lua.execute(open(os.path.join(MOD, "lua", "ge", "extensions", "slrrDrivers.lua")).read())
    g.M = M
    lua.execute("shim_start(M)")
    M.setAnimated(True)
    settle(g, 120)

    def pos(name):
        p = g.shim_parts_local()[name]
        assert all(math.isfinite(c) for c in (p.x, p.y, p.z)), (name, p.x, p.y, p.z)
        return (p.x, p.y, p.z)
    head0, body0 = pos("head"), pos("body")
    M.setSlump(7, True)
    settle(g, 120)
    head1, body1 = pos("head"), pos("body")
    for name in g.shim_parts_local():
        pos(name)
    print("slumped: head moved (%.2f, %.2f, %.2f), torso (%.2f, %.2f, %.2f)" % tuple([b - a for a, b in zip(head0, head1)] + [b - a for a, b in zip(body0, body1)]))
    assert head1[1] - head0[1] > 0.05, "the head did not go forward"
    assert head0[2] - head1[2] > 0.03, "the head did not drop"
    assert body1[1] - body0[1] > 0.02, "the torso did not lean"
    M.setSlump(7, False)
    settle(g, 120)
    head2 = pos("head")
    assert max(abs(a - b) for a, b in zip(head2, head0)) < 0.02, ("he did not sit up", head0, head2)
    print("sits up again: ok")
    # #38: a wave out of the window with the hand that is not on the lever; he turns his head to it; both come back
    settle(g, 60)
    hands0 = {n: pos(n) for n in ("r_hand", "l_hand")}
    head_before = pos("head")
    M.wave(7, 2.0)
    best = {n: 0.0 for n in hands0}
    for _ in range(int(1.2 / DT)):
        g.shim_step(DT, 0, 0, 0, 0, 900, 1, 0, 0, 0)
        for n in hands0:
            best[n] = max(best[n], pos(n)[2] - hands0[n][2])
    for n in g.shim_parts_local():
        pos(n)
    print("wave: hand rise", {k: round(v, 2) for k, v in best.items()})
    assert sorted(best.values())[1] > 0.12, "no hand was raised"
    assert sorted(best.values())[0] < 0.05, "both hands left the wheel"
    settle(g, int(2.5 / DT))
    for n, h0 in hands0.items():
        h = pos(n)
        assert max(abs(a_ - b_) for a_, b_ in zip(h, h0)) < 0.03, ("the hand did not come back", n, h0, h)
    assert max(abs(a_ - b_) for a_, b_ in zip(pos("head"), head_before)) < 0.03, "the head did not come back"
    print("wave ok")


if __name__ == "__main__":
    main()
