"""Blender (headless) side of convert_hd.py: an FBX character's skeleton and skinned mesh to JSON.

    blender -b --factory-startup -P tools/fbx_dump.py -- <in.fbx> <out.json>

Bones: name, parent, head and tail in world space (Blender units, z up). Mesh: per loop-split vertex
position, normal, uv, the triangles, and each vertex's bone weights (bone index, weight). The mesh is
taken as Blender shows it on the skeleton (rest pose, or an animated export's first frame), so the mesh
and the bones always line up.
"""
import json
import sys

import bpy

src, dst = sys.argv[sys.argv.index("--") + 1:][:2]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=src, automatic_bone_orientation=False)
arm = next(o for o in bpy.context.scene.objects if o.type == "ARMATURE")
# the skeleton and the mesh exactly as Blender shows them together: the rest pose, or for an animated
# export (whose rest skeleton and raw mesh need not line up) the first frame of its action
act = arm.animation_data and arm.animation_data.action
arm.data.pose_position = "POSE" if act else "REST"
bpy.context.scene.frame_set(int(act.frame_range[0]) if act else 1)
bpy.context.view_layer.update()
depsgraph = bpy.context.evaluated_depsgraph_get()
names = [b.name for b in arm.data.bones]
idx = {n: i for i, n in enumerate(names)}
pose = arm.pose.bones
bones = [{"name": b.name, "parent": idx[b.parent.name] if b.parent else -1,
          "head": list(arm.matrix_world @ pose[b.name].head), "tail": list(arm.matrix_world @ pose[b.name].tail)}
         for b in arm.data.bones]
meshes = []
for o in bpy.context.scene.objects:
    if o.type != "MESH":
        continue
    oe = o.evaluated_get(depsgraph)
    me = oe.to_mesh()
    me.calc_loop_triangles()
    me.calc_normals_split()
    groups = {g.index: g.name for g in o.vertex_groups}
    uv = me.uv_layers.active.data if me.uv_layers.active else None
    # some exports keep the mesh in the armature's space under an unrelated object transform: take the
    # transform that puts the hip bone inside the mesh
    hip = arm.matrix_world @ next(pb.head for pb in arm.pose.bones if pb.name.endswith("hip"))

    def holds_hip(M):
        ws = [M @ v.co for v in me.vertices]
        return all(min(w[i] for w in ws) - 0.05 < hip[i] < max(w[i] for w in ws) + 0.05 for i in range(3))
    M = oe.matrix_world if holds_hip(oe.matrix_world) else arm.matrix_world
    assert holds_hip(M), "mesh and skeleton don't line up in " + o.name
    N = M.to_3x3().inverted().transposed()
    key, pos, nrm, uvs, wts, tris = {}, [], [], [], [], []
    for t in me.loop_triangles:
        tri = []
        for li in t.loops:
            l = me.loops[li]
            u = tuple(uv[li].uv) if uv else (0.0, 0.0)
            k = (l.vertex_index, round(u[0], 5), round(u[1], 5), tuple(round(c, 3) for c in l.normal))
            if k not in key:
                key[k] = len(pos)
                v = me.vertices[l.vertex_index]
                pos.append(list(M @ v.co))
                nrm.append(list((N @ l.normal).normalized()))
                uvs.append(list(u))
                wts.append([[idx[groups[g.group]], g.weight] for g in v.groups
                            if groups.get(g.group) in idx and g.weight > 1e-4])
            tri.append(key[k])
        tris.append(tri)
    meshes.append({"name": o.name, "material": me.materials[0].name if me.materials else "", "pos": pos,
                   "nrm": nrm, "uv": uvs, "tris": tris, "weights": wts})
json.dump({"bones": bones, "meshes": meshes}, open(dst, "w"))
print("dumped", len(bones), "bones,", sum(len(m["tris"]) for m in meshes), "triangles")
