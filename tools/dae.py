"""Minimal Collada writer for BeamNG static shapes.

write_dae(path, nodes) where nodes = [(node_name, [part, ...]), ...] and a part is a dict:
    material: str, pos: [(x,y,z)], nrm: [(x,y,z)], uv: [(u,v)], uv2: [(u,v)] or None, tris: [(a,b,c)]
Each node becomes one geometry (parts = one <triangles> per material). A node called
"Colmesh-1" is what BeamNG collides with when the TSStatic uses collisionType "Collision Mesh".
Node names must not end in a digit unless meant as a LOD size.
"""
from xml.sax.saxutils import quoteattr


def _floats(rows):
    return " ".join("%.5g" % c for r in rows for c in r)


def _source(sid, rows, params):
    n = len(params)
    ps = "".join('<param name="%s" type="float"/>' % p for p in params)
    return ('<source id="%s"><float_array id="%s-a" count="%d">%s</float_array><technique_common>'
            '<accessor source="#%s-a" count="%d" stride="%d">%s</accessor></technique_common></source>'
            % (sid, sid, len(rows) * n, _floats(rows), sid, len(rows), n, ps))


def write_dae(path, nodes, null_detail=None):
    """null_detail=N adds a `nulldetailN` marker: the shape is not drawn below N pixels (mesh node must end in a bigger number)."""
    mats = []
    for _, parts in nodes:
        for p in parts:
            if p["material"] not in mats:
                mats.append(p["material"])
    out = ['<?xml version="1.0" encoding="utf-8"?>\n<COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">'
           '<asset><unit name="meter" meter="1"/><up_axis>Z_UP</up_axis></asset>']
    out.append("<library_effects>")
    for i, m in enumerate(mats):
        out.append('<effect id="fx%d"><profile_COMMON><technique sid="common"><phong><diffuse><color>1 1 1 1</color>'
                   '</diffuse></phong></technique></profile_COMMON></effect>' % i)
    out.append("</library_effects><library_materials>")
    for i, m in enumerate(mats):
        out.append('<material id="mat%d" name=%s><instance_effect url="#fx%d"/></material>' % (i, quoteattr(m), i))
    out.append("</library_materials><library_geometries>")
    scene = []
    for gi, (name, parts) in enumerate(nodes):
        pos, nrm, uv, uv2, prims = [], [], [], [], []
        has_uv2 = any(p.get("uv2") for p in parts)
        for p in parts:
            base = len(pos)
            pos += p["pos"]; nrm += p["nrm"]; uv += p["uv"]
            if has_uv2:
                uv2 += p.get("uv2") or p["uv"]
            prims.append((mats.index(p["material"]), " ".join("%d %d %d" % (a + base, b + base, c + base) for a, b, c in p["tris"]), len(p["tris"])))
        g = "g%d" % gi
        out.append('<geometry id="%s" name=%s><mesh>' % (g, quoteattr(name)))
        out.append(_source(g + "-p", pos, "XYZ"))
        out.append(_source(g + "-n", nrm, "XYZ"))
        out.append(_source(g + "-t", uv, "ST"))
        if has_uv2:
            out.append(_source(g + "-t2", uv2, "ST"))
        out.append('<vertices id="%s-v"><input semantic="POSITION" source="#%s-p"/></vertices>' % (g, g))
        for mi, idx, count in prims:
            out.append('<triangles material="m%d" count="%d"><input semantic="VERTEX" source="#%s-v" offset="0"/>'
                       '<input semantic="NORMAL" source="#%s-n" offset="0"/>'
                       '<input semantic="TEXCOORD" source="#%s-t" offset="0" set="0"/>%s<p>%s</p></triangles>'
                       % (mi, count, g, g, g,
                          '<input semantic="TEXCOORD" source="#%s-t2" offset="0" set="1"/>' % g if has_uv2 else "", idx))
        out.append("</mesh></geometry>")
        binds = "".join('<instance_material symbol="m%d" target="#mat%d"/>' % (mi, mi) for mi in sorted({m for m, _, _ in prims}))
        scene.append('<node id="n%d" name=%s type="NODE"><instance_geometry url="#%s"><bind_material><technique_common>%s'
                     '</technique_common></bind_material></instance_geometry></node>' % (gi, quoteattr(name), g, binds))
    null = '<node id="nulldetail%d" name="nulldetail%d" type="NODE"/>' % (null_detail, null_detail) if null_detail else ""
    out.append('</library_geometries><library_visual_scenes><visual_scene id="scene" name="scene">'
               '<node id="base00" name="base00" type="NODE"><node id="start01" name="start01" type="NODE">'
               + "".join(scene) + '</node>' + null + '</node>'
               '</visual_scene></library_visual_scenes><scene><instance_visual_scene url="#scene"/></scene></COLLADA>')
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out))
