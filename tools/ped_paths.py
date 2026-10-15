"""Offline check that pedestrians' sidewalks are on the pavement (Valo City).

    python ped_paths.py [--plot out.png] [--fix] [--walk file] [--offset]

--fix rebuilds the mod's walk file from tools/walk_slrr_valo_city.raw.json (convert_peds.py) against the map.

Samples every sidewalk polyline in walk_slrr_valo_city.json every 0.5 m and finds what a pedestrian stands on
there, the way slrrPedestrians.groundZ does (the highest static surface from 2 m above the path down to 4 m
below): the city's collision meshes (their material's groundType) or the terrain (its painted layer). Each
sample is then
  road      inside an AI lane's width (the lane DecalRoads in AIRoads)
  soft      grass, dirt, gravel, sand (mesh groundType or terrain layer)
  void      no surface at all
  pavement  any other hard surface.
Prints the share per class, the offending runs (with coordinates), and the best uniform x/y shift of the whole
data set (a non-zero one means the city.walk conversion is offset). Importable: classify(lines) for test_peds.
"""
import json
import math
import os
import re
import struct
import sys
import xml.etree.ElementTree as ET

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.join(HERE, "..", "mod")
MAP = r"C:\Dev\SLRR map for beam ng"
LEVEL = os.path.join(MAP, "mod", "levels", "slrr_valo_city")
WALK = os.path.join(MOD, "art", "slrr_pedestrians", "walk_slrr_valo_city.json")
RAW = os.path.join(HERE, "walk_slrr_valo_city.raw.json")     # convert_peds.py's output: SLRR's paths as converted
STEP = 0.5
UP, DOWN = 2.0, 4.0          # groundZ's ray: from 2 m above the path, 6 m long
CELL = 1.0
SOFT = {"GRASS", "DIRT", "GRAVEL", "SAND", "MUD"}
SOFT_TERRAIN = ("fu", "grass", "sand", "sivatag", "dirt", "area")   # SLRR names: fu = grass, sivatag = desert


def samples(lines, step=STEP):
    """(points N x 3, line index N, distance along N)."""
    pts, li, ds = [], [], []
    for i, l in enumerate(lines):
        p = np.array(l, float)
        seg = np.linalg.norm(np.diff(p[:, :2], axis=0), axis=1)
        cum = np.concatenate([[0], np.cumsum(seg)])
        for d in np.arange(0, cum[-1] + 1e-6, step):
            k = min(np.searchsorted(cum, d, side="right") - 1, len(seg) - 1)
            t = (d - cum[k]) / max(seg[k], 1e-6)
            pts.append(p[k] + (p[k + 1] - p[k]) * t)
            li.append(i)
            ds.append(d)
    return np.array(pts), np.array(li), np.array(ds)


def _mat_ground_types():
    gt = {}
    for root, _, fs in os.walk(os.path.join(LEVEL, "art")):
        for f in fs:
            if f.endswith("materials.json"):
                for name, m in json.load(open(os.path.join(root, f), encoding="utf-8")).items():
                    gt[m.get("mapTo", name)] = gt[name] = (m.get("groundType") or m.get("groundmodelName") or "").upper()
    return gt


def collision_triangles():
    """Upward-facing collision triangles of the level's static shapes, placed: (tris N x 3 x 3, material names N)."""
    sys.path.insert(0, os.path.join(MAP, "tools"))
    from measure_dae import _node_matrix, _mul
    tris, mats = [], []
    items = os.path.join(LEVEL, "main", "MissionGroup")
    placed = {}      # shape -> [4x4 placement]; rotationMatrix is stored transposed (row i = column i)
    for group in os.listdir(items):
        fn = os.path.join(items, group, "items.level.json")
        if os.path.isfile(fn):
            for line in open(fn, encoding="utf-8"):
                o = json.loads(line)
                if o.get("class") == "TSStatic" and str(o.get("collisionType", "")).startswith("Collision"):
                    P = np.eye(4)
                    if "rotationMatrix" in o:
                        P[:3, :3] = np.array(o["rotationMatrix"], float).reshape(3, 3).T
                    sc = o.get("scale", [1, 1, 1])
                    P[:3, :3] = P[:3, :3] * np.array(sc if isinstance(sc, list) else [sc] * 3, float)
                    P[:3, 3] = o.get("position", [0, 0, 0])
                    placed.setdefault(o["shapeName"], []).append(P)
    for s in sorted(placed):
        path = os.path.join(MAP, "mod", s.lstrip("/"))
        if not os.path.isfile(path):
            continue
        data = re.sub(rb'\sxmlns="[^"]+"', b"", open(path, "rb").read(), count=1)
        root = ET.fromstring(data)
        matname = {m.get("id"): m.get("name") for m in root.iter("material")}
        geoms = {}
        for g in root.iter("geometry"):
            mesh = g.find("mesh")
            vin = mesh.find("vertices/input[@semantic='POSITION']") if mesh is not None else None
            if vin is None:
                continue
            src = mesh.find("source[@id='%s']" % vin.get("source").lstrip("#"))
            pos = np.array(src.find("float_array").text.split(), float).reshape(-1, 3)
            parts = []
            for t in mesh.findall("triangles"):
                inputs = t.findall("input")
                stride = max(int(i.get("offset", 0)) for i in inputs) + 1
                voff = int([i for i in inputs if i.get("semantic") == "VERTEX"][0].get("offset", 0))
                idx = np.array(t.find("p").text.split(), int).reshape(-1, 3, stride)[:, :, voff]
                parts.append((t.get("material"), idx))
            geoms[g.get("id")] = (pos, parts)

        def walk(node, m):
            m = _mul(m, _node_matrix(node, None))
            col = "colmesh" in (node.get("name") or "").lower()
            for ig in node.findall("instance_geometry"):
                if not col or ig.get("url").lstrip("#") not in geoms:
                    continue
                pos, parts = geoms[ig.get("url").lstrip("#")]
                M = np.array(m)
                wp = pos @ M[:3, :3].T + M[:3, 3]
                bind = {b.get("symbol"): matname.get(b.get("target").lstrip("#"), "") for b in ig.iter("instance_material")}
                for sym, idx in parts:
                    for P in placed[s]:
                        tris.append(wp[idx] @ P[:3, :3].T + P[:3, 3])
                        mats.extend([bind.get(sym, "")] * len(idx))
            for c in node.findall("node"):
                walk(c, m)
        ident = [[float(i == j) for j in range(4)] for i in range(4)]
        for vs in root.iter("visual_scene"):
            for n in vs.findall("node"):
                walk(n, ident)
    t = np.concatenate(tris) if tris else np.zeros((0, 3, 3))
    mats = np.array(mats)
    n = np.cross(t[:, 1] - t[:, 0], t[:, 2] - t[:, 0])
    ln = np.linalg.norm(n, axis=1)
    up = (ln > 1e-9) & (np.abs(n[:, 2]) > 0.5 * ln)     # walkable: floor-like either winding
    return t[up], mats[up]


def mesh_ground(pts, tris, mats):
    """Per sample: (surface z or nan, material) of the highest collision triangle within the ray."""
    z = np.full(len(pts), np.nan)
    mat = np.array([""] * len(pts), dtype=object)
    cells = {}
    for i, (x, y) in enumerate(np.floor(pts[:, :2] / CELL).astype(int)):
        cells.setdefault((x, y), []).append(i)
    lo = np.floor(tris[:, :, :2].min(1) / CELL).astype(int)
    hi = np.floor(tris[:, :, :2].max(1) / CELL).astype(int)
    # only triangles near a sample: small ones by their corner cell, large ones always
    near = {(x + a, y + b) for x, y in cells for a in (-2, -1, 0, 1) for b in (-2, -1, 0, 1)}
    keep = [k for k in range(len(tris)) if (hi[k] - lo[k]).max() > 2 or (lo[k, 0], lo[k, 1]) in near]
    for k in keep:
        cand = [i for cx in range(lo[k, 0], hi[k, 0] + 1) for cy in range(lo[k, 1], hi[k, 1] + 1)
                for i in cells.get((cx, cy), ())]
        if not cand:
            continue
        a, b, c = tris[k]
        p = pts[cand]
        v0, v1, v2 = c[:2] - a[:2], b[:2] - a[:2], p[:, :2] - a[:2]
        den = v0[0] * v1[1] - v1[0] * v0[1]
        if abs(den) < 1e-12:
            continue
        u = (v2[:, 0] * v1[1] - v1[0] * v2[:, 1]) / den
        v = (v0[0] * v2[:, 1] - v2[:, 0] * v0[1]) / den
        inside = (u >= -1e-6) & (v >= -1e-6) & (u + v <= 1 + 1e-6)
        zz = a[2] + u * (c[2] - a[2]) + v * (b[2] - a[2])
        ok = inside & (zz <= p[:, 2] + UP) & (zz >= p[:, 2] - DOWN)
        for i, zi in zip(np.array(cand)[ok], zz[ok]):
            if np.isnan(z[i]) or zi > z[i]:
                z[i], mat[i] = zi, mats[k]
    return z, mat


def terrain_ground(pts):
    """Per sample: (terrain z or nan, painted layer name) from the level's .ter files."""
    sys.path.insert(0, os.path.join(MAP, "tools"))
    import terrain
    blocks = [("slrr_valo_city.ter", terrain.X0, terrain.Y0, terrain.SQ)]
    try:
        import multibot
        blocks.append((multibot.VALLEY + ".ter", multibot.VX0, multibot.VY0, multibot.VSQ))
    except Exception:
        pass
    z = np.full(len(pts), np.nan)
    layer = np.array([""] * len(pts), dtype=object)
    for fn, x0, y0, sq in blocks:
        path = os.path.join(LEVEL, fn)
        if not os.path.isfile(path):
            continue
        b = open(path, "rb").read()
        n = struct.unpack_from("<I", b, 1)[0]
        h = np.frombuffer(b, "<u2", n * n, 5).reshape(n, n).astype(np.float32) / 65535.0 * terrain.ZRANGE + terrain.ZMIN
        lay = np.frombuffer(b, "u1", n * n, 5 + n * n * 2).reshape(n, n)
        names = [s.decode() for s in re.findall(rb"[\x20-\x7e]{3,}", b[5 + n * n * 3:])]
        i = np.round((pts[:, 0] - x0) / sq).astype(int)
        j = np.round((pts[:, 1] - y0) / sq).astype(int)
        ok = (i >= 0) & (j >= 0) & (i < n) & (j < n)
        hz = np.full(len(pts), np.nan)
        hz[ok] = h[j[ok], i[ok]]
        better = ok & (hz <= pts[:, 2] + UP) & (hz >= pts[:, 2] - DOWN) & ~(hz <= z)
        z[better] = hz[better]
        li = lay[j[better], i[better]]
        layer[better] = [names[k] if k < len(names) else "?" for k in li]
    return z, layer


def lanes():
    """AI lane segments: (a N x 3, b N x 3, half width N)."""
    A, B, W = [], [], []
    fn = os.path.join(LEVEL, "main", "MissionGroup", "AIRoads", "items.level.json")
    for line in open(fn, encoding="utf-8"):
        o = json.loads(line)
        if o.get("class") == "DecalRoad" and o["name"].startswith("ai_lane_"):
            nodes = o["nodes"]
            for p, q in zip(nodes, nodes[1:]):
                A.append(p[:3])
                B.append(q[:3])
                W.append(min(p[3] if len(p) > 3 else 4, q[3] if len(q) > 3 else 4) / 2)
    return np.array(A, float), np.array(B, float), np.array(W)


def road_distance(pts, A, B, W, cell=20.0):
    """Per sample: distance from the nearest lane's edge (negative = inside the lane), within 3 m in height."""
    out = np.full(len(pts), np.inf)
    grid = {}
    for k in range(len(A)):
        lo = np.floor(np.minimum(A[k, :2], B[k, :2]) / cell).astype(int)
        hi = np.floor(np.maximum(A[k, :2], B[k, :2]) / cell).astype(int)
        for cx in range(lo[0] - 1, hi[0] + 2):
            for cy in range(lo[1] - 1, hi[1] + 2):
                grid.setdefault((cx, cy), []).append(k)
    for i, p in enumerate(pts):
        ks = grid.get(tuple(np.floor(p[:2] / cell).astype(int)))
        if not ks:
            continue
        a, b, w = A[ks], B[ks], W[ks]
        ab = b[:, :2] - a[:, :2]
        t = np.clip(((p[:2] - a[:, :2]) * ab).sum(1) / np.maximum((ab * ab).sum(1), 1e-9), 0, 1)
        q = a + (b - a) * t[:, None]
        d = np.linalg.norm(q[:, :2] - p[:2], axis=1) - w
        d[np.abs(q[:, 2] - p[2]) > 3] = np.inf
        out[i] = d.min()
    return out


def classify(lines, tris=None, mats=None, lane=None, gt=None):
    """Per sample class, plus the samples and their kerb distance:
    pavement  SLRR's sidewalk, kerb or concrete material (even where an AI lane's width overlaps it)
    crossing  SLRR's zebra material
    road      any other surface inside an AI lane's width
    soft      grass, dirt, gravel, sand (mesh groundType or the terrain's painted layer)
    void      no surface within the ray
    hard      any other hard surface off the road (squares, forecourts)"""
    pts, li, ds = samples(lines)
    if tris is None:
        tris, mats = collision_triangles()
    if lane is None:
        lane = lanes()
    gt = gt or _mat_ground_types()
    mz, mm = mesh_ground(pts, tris, mats)
    tz, tl = terrain_ground(pts)
    kerb = road_distance(pts, *lane)
    cls = np.array(["hard"] * len(pts), dtype=object)
    use_terrain = ~np.isnan(tz) & (np.isnan(mz) | (tz > mz + 0.05))
    soft_mesh = np.array([gt.get(m, "") in SOFT for m in mm])
    soft_ter = np.array([any(s in (l or "").lower() for s in SOFT_TERRAIN) for l in tl])
    cls[(kerb < 0) & ~use_terrain] = "road"
    cls[np.where(use_terrain, soft_ter, soft_mesh)] = "soft"
    on_mesh = ~use_terrain & ~np.isnan(mz)
    cls[on_mesh & np.array([bool(PAVE.search(m or "")) for m in mm])] = "pavement"
    cls[on_mesh & np.array(["cross" in (m or "") for m in mm])] = "crossing"
    cls[np.isnan(mz) & np.isnan(tz)] = "void"
    return cls, pts, li, ds, kerb


PAVE = re.compile(r"sidwalk|kerb|beton", re.I)     # SLRR's pavement, kerb and concrete materials
INSET, REACH, GAP = 0.5, 4.0, 4.0


def _runs_offset(row, offs):
    """Offset to the nearest pavement run across the line (INSET in from its edges), or nan."""
    best, j = None, 0
    while j < len(offs):
        if row[j]:
            k = j
            while k + 1 < len(offs) and row[k + 1]:
                k += 1
            lo, hi = offs[j], offs[k]
            o = (lo + hi) / 2 if hi - lo < 2 * INSET else float(np.clip(0, lo + INSET, hi - INSET))
            if best is None or abs(o) < abs(best):
                best = o
            j = k + 1
        else:
            j += 1
    return np.nan if best is None else best


def snap(lines, tris, mats, step=2.0):
    """Sidewalks moved sideways onto the nearest pavement strip (INSET in from its edges), cut where there is no
    pavement within REACH m; pieces under 5 m dropped."""
    offs = np.arange(-REACH, REACH + 1e-6, 0.5)
    pts, li, _ = samples(lines, step)
    t = np.zeros((len(pts), 2))
    for i in np.unique(li):            # tangents per line
        k = np.where(li == i)[0]
        if len(k) > 1:
            t[k] = np.gradient(pts[k, :2], axis=0)
    t /= np.maximum(np.linalg.norm(t, axis=1, keepdims=True), 1e-9)
    n = np.stack([t[:, 1], -t[:, 0]], 1)
    q = np.repeat(pts, len(offs), 0)
    q[:, :2] += np.tile(offs, len(pts))[:, None] * np.repeat(n, len(offs), 0)
    z, m = mesh_ground(q, tris, mats)
    pave = np.array([bool(PAVE.search(x or "")) for x in m]).reshape(len(pts), len(offs))
    z = z.reshape(len(pts), len(offs))
    target = np.array([_runs_offset(row, offs) for row in pave])
    out = []
    for i in np.unique(li):
        k = np.where(li == i)[0]
        tg = target[k]
        sm = np.array([np.nanmedian(tg[max(0, j - 2):j + 3]) if not np.all(np.isnan(tg[max(0, j - 2):j + 3])) else np.nan
                       for j in range(len(k))])            # median of 5, ignoring holes
        piece = []
        for j in range(len(k) + 1):
            if j < len(k) and not np.isnan(sm[j]):
                g = k[j]
                c = int(np.argmin(np.abs(offs - sm[j])))
                zz = z[g, c] if not np.isnan(z[g, c]) else pts[g, 2]
                piece.append([round(float(pts[g, 0] + n[g, 0] * sm[j]), 2), round(float(pts[g, 1] + n[g, 1] * sm[j]), 2),
                              round(float(zz), 2)])
            elif piece:
                if len(piece) * step >= 5:
                    out.append(piece)
                piece = []
    return out


BODY = 0.25     # half a pedestrian's width: kept clear of the pavement's edge


def room(lines, tris, mats, step=1.0):
    """Per line [left, right]: how far a pedestrian can step to each side (of the line's own direction) and stay on
    pavement all along it, less BODY; from a sideways scan of the collision meshes."""
    offs = np.arange(-REACH, REACH + 1e-6, 0.25)
    pts, li, _ = samples(lines, step)
    t = np.zeros((len(pts), 2))
    for i in np.unique(li):
        k = np.where(li == i)[0]
        if len(k) > 1:
            t[k] = np.gradient(pts[k, :2], axis=0)
    t /= np.maximum(np.linalg.norm(t, axis=1, keepdims=True), 1e-9)
    n = np.stack([t[:, 1], -t[:, 0]], 1)        # right of the line's direction
    q = np.repeat(pts, len(offs), 0)
    q[:, :2] += np.tile(offs, len(pts))[:, None] * np.repeat(n, len(offs), 0)
    _, m = mesh_ground(q, tris, mats)
    pave = np.array([bool(PAVE.search(x or "")) for x in m]).reshape(len(pts), len(offs))
    zero = int(np.argmin(np.abs(offs)))
    right, left = np.zeros(len(pts)), np.zeros(len(pts))
    for i, row in enumerate(pave):
        if not row[zero]:
            continue
        j = zero
        while j + 1 < len(offs) and row[j + 1]:
            j += 1
        right[i] = offs[j]
        j = zero
        while j > 0 and row[j - 1]:
            j -= 1
        left[i] = -offs[j]
    out = []
    for i in range(len(lines)):
        k = li == i
        out.append([round(max(0.0, float(left[k].min()) - BODY), 2), round(max(0.0, float(right[k].min()) - BODY), 2)])
    return out


def graph(lines, link=14.0):
    """(km of path, [component km, largest first]): sidewalks joined where their ends are within `link` m, as
    slrrPedestrians links them."""
    ends = [(i, np.array(l[0][:2])) for i, l in enumerate(lines)] + [(i, np.array(l[-1][:2])) for i, l in enumerate(lines)]
    parent = list(range(len(lines)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    cells = {}
    for i, p in ends:
        cells.setdefault(tuple(np.floor(p / link).astype(int)), []).append((i, p))
    for i, p in ends:
        cx, cy = np.floor(p / link).astype(int)
        for a in (-1, 0, 1):
            for b in (-1, 0, 1):
                for j, q in cells.get((cx + a, cy + b), ()):
                    if j != i and np.linalg.norm(p - q) < link:
                        parent[find(i)] = find(j)
    km = [sum(np.linalg.norm(np.diff(np.array(l)[:, :2], axis=0), axis=1)) / 1000 for l in lines]
    comp = {}
    for i in range(len(lines)):
        comp[find(i)] = comp.get(find(i), 0) + km[i]
    return sum(km), sorted(comp.values(), reverse=True)


OK = ("pavement", "hard")
LINK_DIST = 14.0            # as slrrPedestrians.LINK_DIST
CROSS_ANGLE = 0.5           # a crossing's direction may be at most 60 deg off square to the road (|cos| to the lane)
JUNCTION = 30.0             # a crossing this close to a junction counts as at the junction


def trim(lines, cls, li, pts, step=2):
    """Lines cut at every sample that isn't pavement; points every `step` samples; pieces under 5 m dropped."""
    out = []
    for i in range(len(lines)):
        k = np.where(li == i)[0]
        piece = []
        for j in list(k) + [None]:
            if j is not None and cls[j] in OK:
                piece.append(j)
            elif piece:
                if (len(piece) - 1) * STEP >= 5:
                    keep = piece[::step] + ([piece[-1]] if (len(piece) - 1) % step else [])
                    out.append([[round(float(c), 2) for c in pts[q]] for q in keep])
                piece = []
    return out


def junction_centres(lane):
    """Signal groups' centres (signals.json) and places where three or more AI lanes end or start."""
    out = []
    sig = os.path.join(LEVEL, "signals.json")
    if os.path.isfile(sig):
        groups = {}
        for d in json.load(open(sig))["instances"]:
            groups.setdefault(d.get("group", d["name"]), []).append(d["pos"][:2])
        out += [np.mean(v, 0) for v in groups.values()]
    A, B, _ = lane
    ends = np.concatenate([A[:, :2], B[:, :2]])
    key = {}
    for p in ends:
        key.setdefault(tuple(np.round(p / 15).astype(int)), []).append(p)
    out += [np.mean(v, 0) for v in key.values() if len(v) >= 3]
    return np.array(out)


def build_links(lines, tris, mats, lane, gt):
    """[[line, at start, line, at start, crosses road]] for sidewalk ends within LINK_DIST m: corners over pavement,
    and road crossings only where they're square to the road, at a zebra or a junction, and lead to a sidewalk
    of 10 m or more."""
    ends = [(i, True, np.array(l[0])) for i, l in enumerate(lines)] + [(i, False, np.array(l[-1])) for i, l in enumerate(lines)]
    cells = {}
    for e in ends:
        cells.setdefault(tuple(np.floor(e[2][:2] / LINK_DIST).astype(int)), []).append(e)
    cand = []
    for e in ends:
        cx, cy = np.floor(e[2][:2] / LINK_DIST).astype(int)
        for a in (-1, 0, 1):
            for b in (-1, 0, 1):
                for o in cells.get((cx + a, cy + b), ()):
                    if o[0] != e[0] and (e[0], e[1]) < (o[0], o[1]) and np.linalg.norm(e[2][:2] - o[2][:2]) < LINK_DIST:
                        cand.append((e, o))
    segs = [[list(e[2]), list(o[2])] for e, o in cand]
    cls, pts, li, _, _ = classify(segs, tris, mats, lane, gt)
    length = [sum(np.linalg.norm(np.diff(np.array(l)[:, :2], axis=0), axis=1)) for l in lines]
    jc = junction_centres(lane)
    A, B, _ = lane
    out, kinds = [], {"corner": 0, "crossing": 0, "rejected": 0}
    for n, (e, o) in enumerate(cand):
        c = cls[li == n]
        if all(x in OK for x in c):
            out.append([int(e[0]), bool(e[1]), int(o[0]), bool(o[1]), False])
            kinds["corner"] += 1
            continue
        ok = not any(x in ("soft", "void") for x in c) and min(length[e[0]], length[o[0]]) >= 10
        if ok:
            mid, d = (e[2][:2] + o[2][:2]) / 2, o[2][:2] - e[2][:2]
            d = d / max(np.linalg.norm(d), 1e-9)
            ab = B[:, :2] - A[:, :2]
            t = np.clip(((mid - A[:, :2]) * ab).sum(1) / np.maximum((ab * ab).sum(1), 1e-9), 0, 1)
            k = int(np.argmin(np.linalg.norm(A[:, :2] + ab * t[:, None] - mid, axis=1)))
            road_dir = ab[k] / max(np.linalg.norm(ab[k]), 1e-9)
            square = abs(d @ road_dir) <= CROSS_ANGLE
            at_junction = len(jc) and np.min(np.linalg.norm(jc - mid, axis=1)) < JUNCTION
            ok = square and ("crossing" in c or at_junction)
        if ok:
            out.append([int(e[0]), bool(e[1]), int(o[0]), bool(o[1]), True])
            kinds["crossing"] += 1
        else:
            kinds["rejected"] += 1
    return out, kinds


def link_components(lines, links):
    """Connected parts (km each, largest first) and the part of each line, joined by the links."""
    parent = list(range(len(lines)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    for a, _, b, _, _ in links:
        parent[find(a)] = find(b)
    km = [sum(np.linalg.norm(np.diff(np.array(l)[:, :2], axis=0), axis=1)) / 1000 for l in lines]
    comp = {}
    for i in range(len(lines)):
        comp[find(i)] = comp.get(find(i), 0) + km[i]
    return comp, [find(i) for i in range(len(lines))]


def runs(cls, li, ds, pts, bad=("road", "soft", "void", "crossing")):
    """Offending stretches: [(line, class, from m, to m, (x, y) at the middle)]."""
    out, start = [], None
    for i in range(len(cls) + 1):
        b = i < len(cls) and cls[i] in bad
        if start is not None and (not b or li[i] != li[start] or cls[i] != cls[start]):
            mid = (start + i - 1) // 2
            out.append((int(li[start]), cls[start], float(ds[start]), float(ds[i - 1]), tuple(np.round(pts[mid, :2], 1))))
            start = None
        if b and start is None:
            start = i
    return out


def main():
    plot = sys.argv[sys.argv.index("--plot") + 1] if "--plot" in sys.argv else None
    lines = json.load(open(sys.argv[sys.argv.index("--walk") + 1] if "--walk" in sys.argv else WALK))
    if isinstance(lines, dict):
        lines = lines["lines"]
    tris, mats = collision_triangles()
    km, comp = graph(lines)
    print("%.1f km of sidewalk in %d connected parts (largest %.1f km)" % (km, len(comp), comp[0]))
    if "--fix" in sys.argv:
        lines = json.load(open(RAW))      # always from SLRR's own paths, so new pavement in the map is picked up
        before = sum(len(l) for l in lines)
        lines = snap(snap(lines, tris, mats), tris, mats)   # a second pass settles lines the first moved
        km, comp = graph(lines)
        print("after snapping: %.1f km in %d connected parts (largest %.1f km; %d under 100 m)" % (
            km, len(comp), comp[0], sum(c < 0.1 for c in comp)))
        lane, gt = lanes(), _mat_ground_types()
        for _ in range(4):      # resampling a cut line can land a new sample on grass: trim until none is off
            cls, pts, li, _, _ = classify(lines, tris, mats, lane, gt)
            if all(c in OK for c in cls):
                break
            lines = trim(lines, cls, li, pts)
        links, kinds = build_links(lines, tris, mats, lane, gt)
        comp, part = link_components(lines, links)
        keep = [i for i in range(len(lines)) if comp[part[i]] >= 0.1]      # islands under 100 m: dropped
        index = {old: new for new, old in enumerate(keep)}
        print("trimmed to pavement: %.1f km; links %s; %d parts, dropping %d under 100 m (%.2f km)" % (
            sum(comp.values()), kinds, len(comp), sum(v < 0.1 for v in comp.values()),
            sum(v for v in comp.values() if v < 0.1)))
        lines = [lines[i] for i in keep]
        links = [[index[a], sa, index[b], sb, x] for a, sa, b, sb, x in links if a in index and b in index]
        comp, _ = link_components(lines, links)
        top = sorted(comp.values(), reverse=True)
        print("result: %.1f km in %d connected parts (largest %.1f km, then %s)" % (
            sum(top), len(top), top[0], ", ".join("%.1f" % v for v in top[1:6])))
        rooms = room(lines, tris, mats)
        print("room to the sides (m, median left/right): %.2f / %.2f; %d lines with under 0.2 m either side" % (
            np.median([r[0] for r in rooms]), np.median([r[1] for r in rooms]), sum(min(r) < 0.2 for r in rooms)))
        json.dump({"lines": lines, "links": links, "room": rooms}, open(WALK, "w"), separators=(",", ":"))
        print("%d sidewalks, %d links -> %s (from %d points)" % (len(lines), len(links), WALK, before))
    print(len(tris), "walkable collision triangles,", len(lines), "sidewalks")
    lane = lanes()
    cls, pts, li, ds, kerb = classify(lines, tris, mats, lane)
    n = len(cls)
    for c in ("pavement", "hard", "crossing", "road", "soft", "void"):
        print("  %-9s %6d samples  %5.1f%%" % (c, (cls == c).sum(), 100 * (cls == c).mean()))
    r = runs(cls, li, ds, pts)
    print(len(r), "offending stretches; longest:")
    for x in sorted(r, key=lambda x: x[2] - x[3])[:15]:
        print("   line %d %s %.1f-%.1f m at %s" % x)
    # systematic offset (--offset): the uniform shift that puts the most samples on pavement (subsampled)
    if "--offset" in sys.argv:
        sub = np.arange(0, len(lines), 7)
        sl = [lines[i] for i in sub]
        best = []
        for dx in (-1.5, -0.75, 0, 0.75, 1.5):
            for dy in (-1.5, -0.75, 0, 0.75, 1.5):
                shifted = [[[p[0] + dx, p[1] + dy, p[2]] for p in l] for l in sl]
                c2 = classify(shifted, tris, mats, lane)[0]
                best.append(((c2 == "pavement").mean(), dx, dy))
        best.sort(reverse=True)
        print("pavement share by uniform shift (best 3):", ["%.3f at (%g, %g)" % b for b in best[:3]],
              "| unshifted %.3f" % [b for b in best if b[1] == 0 and b[2] == 0][0][0])
    if plot:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(figsize=(14, 14), dpi=110)
        colours = {"pavement": "#2a9d4b", "hard": "#7fb77e", "crossing": "#3a86ff", "road": "#d62828",
                   "soft": "#e9a23b", "void": "#6a4c93"}
        for c, col in colours.items():
            m = cls == c
            ax.scatter(pts[m, 0], pts[m, 1], s=0.3 if c == "pavement" else 1.2, c=col, label="%s %.1f%%" % (c, 100 * m.mean()))
        ax.set_aspect("equal")
        ax.legend(markerscale=10)
        ax.set_title("Valo City sidewalks: what pedestrians stand on")
        fig.savefig(plot, bbox_inches="tight")
        print("->", plot)


if __name__ == "__main__":
    main()
