"""Readers for SLRR skinned humans: .skl/.bon skeletons and skinned .SCX meshes.

Skinned SCX (v4) directory chunk tags: 0 material, 3 bone palette, 4 vertices, 5 indices.
Bone palette chunk: u32 3, u32 size, u32 0, u32 count, count * u32 skeleton bone index.
Vertex flags: 0x1 pos, 0x2 blend indices (u8x4 into the palette), 0x4/0x8/0x10 = 1/2/3
explicit weights (the last weight is 1 - sum), 0x40 normal, 0x200 uv.
Layout: pos f3, weights f*n, indices u8x4, normal f3, uv f2.

Skeleton text: per bone: name, parent index (index of itself / out of range = root),
3 rows of the local rotation, local translation (3ds Max row-vector convention:
p_parent = p_local * R + t), then 3 lines of joint limits.
"""
import struct

import numpy as np


def read_skl(path):
    lines = [l.strip() for l in open(path, encoding="latin-1") if l.strip()]
    bones = []
    i = 0
    while i + 8 <= len(lines):
        name = lines[i]
        parent = int(lines[i + 1])
        rows = [[float(x) for x in lines[i + 2 + k].split(",")] for k in range(4)]
        limits = [[float(x) for x in lines[i + 6 + k].split(",")] for k in range(3)]
        bones.append({"name": name, "parent": parent, "rot": np.array(rows[:3]), "pos": np.array(rows[3]),
                      "limits": limits})
        i += 9
    n = len(bones)
    for b in bones:
        if not (0 <= b["parent"] < n) or bones[b["parent"]] is b:
            b["parent"] = -1
    # world (model-space) matrices, 4x4 row-vector
    def world(k):
        b = bones[k]
        if "world" in b:
            return b["world"]
        m = np.eye(4)
        m[:3, :3] = b["rot"]
        m[3, :3] = b["pos"]
        if b["parent"] >= 0:
            m = m @ world(b["parent"])
        b["world"] = m
        return m
    for k in range(n):
        world(k)
    return bones


def read_skinned_scx(path):
    buf = open(path, "rb").read()
    assert buf[:4] == b"INVO", path
    count = struct.unpack_from("<I", buf, 8)[0]
    entries = [struct.unpack_from("<II", buf, 0xC + i * 8) for i in range(count)]
    subs, palette, verts = [], None, None
    for tag, off in entries:
        if tag == 3:
            n = struct.unpack_from("<I", buf, off + 12)[0]
            palette = list(struct.unpack_from("<%dI" % n, buf, off + 16))
        elif tag == 4:
            _, size, vc, flags = struct.unpack_from("<4I", buf, off)
            stride = (size - 16) // vc
            nw = {0x2: 0, 0x4: 1, 0x8: 2, 0x10: 3}[flags & 0x1C or 0x2]
            assert stride == 12 + 4 * nw + 4 + 12 + 8, (path, hex(flags), stride)
            pos, nrm, uv, bw = [], [], [], []
            for i in range(vc):
                o = off + 16 + i * stride
                pos.append(struct.unpack_from("<3f", buf, o))
                w = list(struct.unpack_from("<%df" % nw, buf, o + 12))
                w.append(1.0 - sum(w))
                idx = struct.unpack_from("<4B", buf, o + 12 + 4 * nw)
                bw.append([(palette[idx[k]], w[k]) for k in range(nw + 1) if w[k] > 1e-4])
                nrm.append(struct.unpack_from("<3f", buf, o + 16 + 4 * nw))
                uv.append(struct.unpack_from("<2f", buf, o + 28 + 4 * nw))
            verts = (np.array(pos), np.array(nrm), np.array(uv), bw)
        elif tag == 5:
            n = struct.unpack_from("<I", buf, off + 8)[0]
            idx = struct.unpack_from("<%dH" % n, buf, off + 12)
            subs.append({"pos": verts[0], "nrm": verts[1], "uv": verts[2], "weights": verts[3],
                         "tris": np.array(idx).reshape(-1, 3)})
    return subs
