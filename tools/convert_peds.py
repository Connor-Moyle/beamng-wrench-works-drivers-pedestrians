"""Convert SLRR pedestrians (humans/pedestrians) into animated BeamNG shapes, plus the city's sidewalks.

    python convert_peds.py [SLRR_DIR] [MOD_DIR]

Each pedestrian becomes one skinned Collada shape whose walk cycle (from <name>_walk.matrixdata) is
the shape's own animation, so a TSStatic plays it as its ambient sequence with no Lua per bone.
SLRR units (cm, y up, facing +z) are converted by a parent node: metres, z up, facing +y.

.matrixdata: u32 bone count, then per bone (in .skl order): u32 key count, keys of
    f32 time, f32 quat x y z w (local rotation, column-vector form), f32[3] unit direction of the
    bone's offset from its parent (length from the .skl), then a text list of the bone names.

Sidewalks: maps/city/ai/city.walk is one line per walk-mesh cell, "minx,miny,minz,maxx,maxy,maxz id;"
then the cell's binary data written as hex with the letters A-P. Inside it the walkable polylines
are runs of 24-byte records (point, step to the next point); they are found as points inside the cell's
box whose offsets step by 24. Points are written in Valo City coordinates (x, -z, y).

Output: MOD_DIR/art/slrr_pedestrians/<name>/<name>.dae, skin, main.materials.json, and
MOD_DIR/art/slrr_pedestrians/walk_slrr_valo_city.json (sidewalk polylines).
"""
import json
import math
import os
import shutil
import struct
import sys
from xml.sax.saxutils import quoteattr

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from slrr_skin import read_skl, read_skinned_scx  # noqa: E402

SLRR = sys.argv[1] if len(sys.argv) > 1 else r"L:\SteamLibrary\steamapps\common\Street Legal Racing Redline"
MOD = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mod")
OUT = os.path.join(MOD, "art", "slrr_pedestrians")

PEDS = [("gambler", "Gambler.dds"), ("golgoth", "golgoth.dds"), ("hooley", "Hooley.dds"),
        ("kilos", "kilos.dds"), ("kim", "kim.dds"), ("meka", "Meka.dds")]

# SLRR cm, y up, pedestrians facing +z  ->  m, z up, facing +y (row-major, column vectors)
CONV = np.array([[-0.01, 0, 0, 0], [0, 0, 0.01, 0], [0, 0.01, 0, 0], [0, 0, 0, 1]])


def read_anim(path, bones):
    b = open(path, "rb").read()
    n = struct.unpack_from("<I", b, 0)[0]
    assert n == len(bones), (path, n, len(bones))
    o, tracks = 4, []
    for i in range(n):
        k = struct.unpack_from("<I", b, o)[0]
        o += 4
        keys = []
        for j in range(k):
            t, qx, qy, qz, qw, dx, dy, dz = struct.unpack_from("<8f", b, o + 32 * j)
            keys.append((t, (qx, qy, qz, qw), (dx, dy, dz)))
        o += 32 * k
        tracks.append(keys)
    names = b[o:].decode("latin-1").split()
    return tracks


def q2m(x, y, z, w):
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def local_matrix(rot_cv, t):
    m = np.eye(4)
    m[:3, :3] = rot_cv
    m[:3, 3] = t
    return m


def fl(a):
    return " ".join("%.6g" % v for v in np.asarray(a).ravel())


def write_skinned_dae(path, name, bones, subs, tracks, material):
    n = len(bones)
    # rest local transforms (column vectors): rotation is the transposed .skl rows
    rest_local = [local_matrix(b["rot"].T, b["pos"]) for b in bones]
    world = [None] * n

    def w(i):
        if world[i] is None:
            p = bones[i]["parent"]
            world[i] = rest_local[i] if p < 0 else w(p) @ rest_local[i]
        return world[i]
    for i in range(n):
        w(i)
    jid = ["j%d" % i for i in range(n)]

    pos, nrm, uv, tris, vw = [], [], [], [], []
    for s in subs:
        base = len(pos)
        P, N = s["pos"], s["nrm"]
        agree = sum(np.dot(np.cross(P[b] - P[a], P[c] - P[a]), N[a] + N[b] + N[c]) for a, b, c in s["tris"])
        pos += [tuple(p) for p in P]
        nrm += [tuple(q) for q in N]
        uv += [(u, 1.0 - v) for u, v in s["uv"]]
        vw += s["weights"]
        for a, b, c in s["tris"]:
            tris.append((base + a, base + c, base + b) if agree < 0 else (base + a, base + b, base + c))
    weights, vcount, vlist = [], [], []
    for wl in vw:
        vcount.append(len(wl))
        for bi, wt in wl:
            vlist += [bi, len(weights)]
            weights.append(wt)

    out = ['<?xml version="1.0" encoding="utf-8"?>\n<COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">'
           '<asset><unit name="meter" meter="1"/><up_axis>Z_UP</up_axis></asset>']
    out.append('<library_effects><effect id="fx"><profile_COMMON><technique sid="common"><phong><diffuse><color>1 1 1 1</color>'
               '</diffuse></phong></technique></profile_COMMON></effect></library_effects>')
    out.append('<library_materials><material id="mat" name=%s><instance_effect url="#fx"/></material></library_materials>'
               % quoteattr(material))
    out.append('<library_geometries><geometry id="geo" name="%s"><mesh>' % name)
    for sid, rows, params in (("geo-p", pos, "XYZ"), ("geo-n", nrm, "XYZ"), ("geo-t", uv, "ST")):
        ps = "".join('<param name="%s" type="float"/>' % c for c in params)
        out.append('<source id="%s"><float_array id="%s-a" count="%d">%s</float_array><technique_common>'
                   '<accessor source="#%s-a" count="%d" stride="%d">%s</accessor></technique_common></source>'
                   % (sid, sid, len(rows) * len(params), fl(rows), sid, len(rows), len(params), ps))
    out.append('<vertices id="geo-v"><input semantic="POSITION" source="#geo-p"/></vertices>'
               '<triangles material="m0" count="%d"><input semantic="VERTEX" source="#geo-v" offset="0"/>'
               '<input semantic="NORMAL" source="#geo-n" offset="0"/><input semantic="TEXCOORD" source="#geo-t" offset="0" set="0"/>'
               '<p>%s</p></triangles></mesh></geometry></library_geometries>' % (len(tris), fl(tris)))
    inv_bind = [np.linalg.inv(world[i]) for i in range(n)]
    out.append('<library_controllers><controller id="skin"><skin source="#geo"><bind_shape_matrix>%s</bind_shape_matrix>'
               % fl(np.eye(4)))
    out.append('<source id="skin-j"><Name_array id="skin-j-a" count="%d">%s</Name_array><technique_common>'
               '<accessor source="#skin-j-a" count="%d" stride="1"><param name="JOINT" type="name"/></accessor>'
               '</technique_common></source>' % (n, " ".join(jid), n))
    out.append('<source id="skin-b"><float_array id="skin-b-a" count="%d">%s</float_array><technique_common>'
               '<accessor source="#skin-b-a" count="%d" stride="16"><param name="TRANSFORM" type="float4x4"/></accessor>'
               '</technique_common></source>' % (16 * n, fl([m for m in inv_bind]), n))
    out.append('<source id="skin-w"><float_array id="skin-w-a" count="%d">%s</float_array><technique_common>'
               '<accessor source="#skin-w-a" count="%d" stride="1"><param name="WEIGHT" type="float"/></accessor>'
               '</technique_common></source>' % (len(weights), fl(weights), len(weights)))
    out.append('<joints><input semantic="JOINT" source="#skin-j"/><input semantic="INV_BIND_MATRIX" source="#skin-b"/></joints>'
               '<vertex_weights count="%d"><input semantic="JOINT" source="#skin-j" offset="0"/>'
               '<input semantic="WEIGHT" source="#skin-w" offset="1"/><vcount>%s</vcount><v>%s</v></vertex_weights>'
               '</skin></controller></library_controllers>' % (len(vw), fl(vcount), fl(vlist)))

    # walk cycle: one matrix track per bone, looped by Torque as the "ambient" sequence
    out.append("<library_animations>")
    for i, keys in enumerate(tracks):
        L = np.linalg.norm(bones[i]["pos"])
        times = [k[0] for k in keys]
        mats = [local_matrix(q2m(*k[1]), np.array(k[2]) * L) for k in keys]
        if times and times[-1] < 0.99:      # close the loop on the first key
            times.append(times[-1] + (times[1] - times[0] if len(times) > 1 else 0.1))
            mats.append(mats[0])
        a = "a%d" % i
        out.append('<animation id="%s"><source id="%s-i"><float_array id="%s-i-a" count="%d">%s</float_array><technique_common>'
                   '<accessor source="#%s-i-a" count="%d" stride="1"><param name="TIME" type="float"/></accessor></technique_common></source>'
                   % (a, a, a, len(times), fl(times), a, len(times)))
        out.append('<source id="%s-o"><float_array id="%s-o-a" count="%d">%s</float_array><technique_common>'
                   '<accessor source="#%s-o-a" count="%d" stride="16"><param name="TRANSFORM" type="float4x4"/></accessor></technique_common></source>'
                   % (a, a, 16 * len(mats), fl(mats), a, len(mats)))
        out.append('<source id="%s-l"><Name_array id="%s-l-a" count="%d">%s</Name_array><technique_common>'
                   '<accessor source="#%s-l-a" count="%d" stride="1"><param name="INTERPOLATION" type="name"/></accessor></technique_common></source>'
                   % (a, a, len(times), " ".join(["LINEAR"] * len(times)), a, len(times)))
        out.append('<sampler id="%s-s"><input semantic="INPUT" source="#%s-i"/><input semantic="OUTPUT" source="#%s-o"/>'
                   '<input semantic="INTERPOLATION" source="#%s-l"/></sampler><channel source="#%s-s" target="%s/transform"/></animation>'
                   % (a, a, a, a, a, jid[i]))
    out.append("</library_animations>")

    def node(i):
        kids = "".join(node(c) for c in range(n) if bones[c]["parent"] == i)
        return ('<node id="%s" sid="%s" name="%s" type="JOINT"><matrix sid="transform">%s</matrix>%s</node>'
                % (jid[i], jid[i], jid[i], fl(rest_local[i]), kids))
    roots = "".join(node(i) for i in range(n) if bones[i]["parent"] < 0)
    root_ids = [jid[i] for i in range(n) if bones[i]["parent"] < 0]
    out.append('<library_visual_scenes><visual_scene id="scene" name="scene">'
               '<node id="base00" name="base00" type="NODE"><node id="start01" name="start01" type="NODE">'
               '<node id="slrr_conv" name="slrr_conv" type="NODE"><matrix sid="transform">%s</matrix>%s'
               '<node id="%s_mesh_a" name="%s_mesh_a" type="NODE"><instance_controller url="#skin"><skeleton>#%s</skeleton>'
               '<bind_material><technique_common><instance_material symbol="m0" target="#mat"/></technique_common></bind_material>'
               '</instance_controller></node></node></node></node></visual_scene></library_visual_scenes>'
               '<scene><instance_visual_scene url="#scene"/></scene></COLLADA>'
               % (fl(CONV), roots, name, name, root_ids[0]))
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("".join(out))
    return len(tris)


def sidewalks():
    path = os.path.join(SLRR, "maps", "city", "ai", "city.walk")
    lines = []
    for row in open(path, "rb").read().decode("latin-1").split("\r\n"):
        if ";" not in row:
            continue
        head, blob = row.split(";", 1)
        bb = [float(v) for v in head.split(" ")[0].split(",")]
        b = bytes(((ord(blob[i]) - 65) << 4) | (ord(blob[i + 1]) - 65) for i in range(0, len(blob) - 1, 2))
        cur, last = [], None
        for i in range(0, len(b) - 11, 4):
            x, y, z = struct.unpack_from("<3f", b, i)
            if not (bb[0] - 0.5 <= x <= bb[3] + 0.5 and bb[1] - 0.5 <= y <= bb[4] + 0.5 and bb[2] - 0.5 <= z <= bb[5] + 0.5) or abs(x) < 1e-3:
                continue
            if last is not None and i - last == 24:
                cur.append((x, y, z))
            else:
                if len(cur) > 1:
                    lines.append(cur)
                cur = [(x, y, z)]
            last = i
        if len(cur) > 1:
            lines.append(cur)
    # Valo City coordinates; drop near-duplicate polylines (neighbouring cells share edges)
    out, seen = [], set()
    for l in lines:
        pts = [[round(x, 2), round(-z, 2), round(y, 2)] for x, y, z in l]
        length = sum(math.dist(a, b) for a, b in zip(pts, pts[1:]))
        key = tuple(round(c / 2) for c in pts[0] + pts[-1])
        if length < 3 or key in seen or tuple(round(c / 2) for c in pts[-1] + pts[0]) in seen:
            continue
        seen.add(key)
        out.append(pts)
    return out


if __name__ == "__main__":
    pdir = os.path.join(SLRR, "humans", "pedestrians")
    for name, skin in PEDS:
        d = os.path.join(OUT, name)
        os.makedirs(d, exist_ok=True)
        bones = read_skl(os.path.join(pdir, name + "_walk.skl"))
        subs = read_skinned_scx(os.path.join(pdir, name + "_walk.SCX"))
        tracks = read_anim(os.path.join(pdir, name + "_walk.matrixdata"), bones)
        mat = "slrr_ped_" + name
        tri = write_skinned_dae(os.path.join(d, name + ".dae"), name, bones, subs, tracks, mat)
        shutil.copyfile(os.path.join(pdir, skin), os.path.join(d, skin))
        json.dump({mat: {"name": mat, "mapTo": mat, "class": "Material", "version": 1.5, "materialTag0": "beamng",
                         "Stages": [{"baseColorMap": "/art/slrr_pedestrians/%s/%s" % (name, skin), "roughnessFactor": 0.8,
                                     "metallicFactor": 0}, {}, {}, {}]}},
                  open(os.path.join(d, "main.materials.json"), "w"), indent=1)
        print(name, tri, "triangles,", len(tracks[0]), "keys")
    walks = sidewalks()
    json.dump(walks, open(os.path.join(OUT, "walk_slrr_valo_city.json"), "w"), separators=(",", ":"))
    print(len(walks), "sidewalk polylines, %.1f km" % (sum(math.dist(a, b) for l in walks for a, b in zip(l, l[1:])) / 1000))
