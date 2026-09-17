"""
Turns the Sketchfab Porsche .blend into a Roblox-ready FBX.

  * drops the lights, hidden helpers, ground shadow plane, clear-coat shell
  * applies modifiers (subsurf capped at level 1)
  * regroups faces by what they are in the game (paint, trim, glass, lamps, per-wheel
    tyre/rim/caliper), since a MeshPart carries a single colour and material
  * straightens the steered front wheels and snaps all four onto a common axle layout
  * decimates every group to a triangle budget (Roblox caps a mesh at 20k triangles)
  * moves everything into car space (origin at axle height, midway between the axles)
    at real-world scale in studs, and bakes Roblox axes (+Y up, -Z forward)

Usage, from this folder:
  blender -b source/9e528d02fb594880b6f241f668d63bc0.blend --python export_porsche.py -- export/Porsche.fbx summary.json preview
"""

import bpy
import bmesh
import json
import math
import sys
from collections import defaultdict
from mathutils import Matrix, Vector

import numpy as np

argv = sys.argv[sys.argv.index("--") + 1 :]
OUT_FBX, OUT_JSON, PREVIEW = argv[0], argv[1], argv[2]

STUDS_PER_METRE = 5 / 1.75
REAL_WHEELBASE_M = 2.45  # Porsche 911 (991) Carrera

DROP = {"Plane", "boot.011", "boot.007", "Plane.002", "Plane.003", "Plane.004"}
WHEEL_OBJECTS = {"Cylinder.001": "F", "Cylinder.000": "R"}

BUDGET = {
    "BodyLeft": 13000,
    "BodyRight": 13000,
    "Trim": 14000,
    "Chrome": 8000,
    "Windows": 4000,
    "LampGlass": 3000,
    "HeadlightLeft": 1500,
    "HeadlightRight": 1500,
    "TaillightLeft": 2000,
    "TaillightRight": 2000,
    "Plates": 1000,
    "Tyre": 2200,
    "Rim": 2600,
    "Caliper": 400,
}

scene = bpy.context.scene
depsgraph = bpy.context.evaluated_depsgraph_get()

# --- 1. clean up -----------------------------------------------------------------
for ob in list(scene.objects):
    if ob.type != "MESH" or ob.name in DROP or not ob.visible_get():
        bpy.data.objects.remove(ob, do_unlink=True)

for ob in scene.objects:
    for mod in ob.modifiers:
        if mod.type == "SUBSURF":
            mod.levels = min(mod.levels, 1)
depsgraph = bpy.context.evaluated_depsgraph_get()


def side_of(x):
    # Blender +X is the car's LEFT (the steering wheel side on this left-hand-drive car).
    return "Left" if x > 0 else "Right"


def group_for(ob_name, mat, centre):
    wheel_end = WHEEL_OBJECTS.get(ob_name)
    if wheel_end:
        corner = wheel_end + ("L" if centre.x > 0 else "R")
        if mat in ("rubber", "plastic"):
            return f"Wheel{corner}_Tyre"
        if mat == "silver":
            return f"Wheel{corner}_Rim"
        if mat == "Material.001":
            return f"Wheel{corner}_Caliper"
        return None
    if mat == "paint":
        return "Body" + side_of(centre.x)
    if mat in ("plastic", "full_black"):
        return "Trim"
    if mat == "silver":
        return "Chrome"
    if mat == "window":
        return "Windows"
    if mat == "glass":
        return "LampGlass"
    if mat == "lights":
        return "Headlight" + side_of(centre.x)
    if mat == "license":
        return "Plates"
    if mat == "tex_shiny":
        if ob_name == "Plane.001":
            return "Taillight" + side_of(centre.x)
        if ob_name == "boot.003":
            return "Trim"  # the strip between the tail lights
        return "LampGlass"  # the side markers on the front wings
    return None


# --- 2. apply modifiers and split faces into groups -------------------------------
groups = defaultdict(bmesh.new)
for ob in list(scene.objects):
    ev = ob.evaluated_get(depsgraph)
    me = bpy.data.meshes.new_from_object(ev, depsgraph=depsgraph)
    me.transform(ob.matrix_world)
    names = [s.material.name if s.material else None for s in ob.material_slots]

    src = bmesh.new()
    src.from_mesh(me)
    buckets = defaultdict(list)
    for f in src.faces:
        g = group_for(ob.name, names[f.material_index] if names else None, f.calc_center_median())
        if g:
            buckets[g].append(f.index)
    src.free()

    for g, face_ids in buckets.items():
        part = bmesh.new()
        part.from_mesh(me)
        part.faces.ensure_lookup_table()
        keep = set(face_ids)
        bmesh.ops.delete(part, geom=[f for f in part.faces if f.index not in keep], context="FACES")
        tmp = bpy.data.meshes.new("tmp")
        part.to_mesh(tmp)
        part.free()
        groups[g].from_mesh(tmp)
        bpy.data.meshes.remove(tmp)
    bpy.data.meshes.remove(me)

for ob in list(scene.objects):
    bpy.data.objects.remove(ob, do_unlink=True)

# --- 3. wheels: straighten, then snap onto a symmetric layout ---------------------
def verts_np(bm):
    return np.array([v.co[:] for v in bm.verts])


corners = {}
for corner in ("FL", "FR", "RL", "RR"):
    tyre = groups[f"Wheel{corner}_Tyre"]
    # the rubber-and-plastic group is a solid of revolution: its thinnest principal
    # axis is the axle
    pts = verts_np(tyre)
    mean = pts.mean(axis=0)
    evals, evecs = np.linalg.eigh(np.cov((pts - mean).T))
    axle = Vector(evecs[:, 0])
    if axle.x < 0:
        axle = -axle
    rot = axle.rotation_difference(Vector((1, 0, 0))).to_matrix().to_4x4()
    pivot = Vector(mean)
    m = Matrix.Translation(pivot) @ rot @ Matrix.Translation(-pivot)
    for part in ("Tyre", "Rim", "Caliper"):
        bmesh.ops.transform(groups[f"Wheel{corner}_{part}"], matrix=m, verts=groups[f"Wheel{corner}_{part}"].verts)
    pts = verts_np(tyre)
    lo, hi = pts.min(axis=0), pts.max(axis=0)
    corners[corner] = {
        "axle_before": [round(a, 4) for a in axle],
        "steer_deg": round(math.degrees(math.atan2(axle.y, axle.x)), 2),
        "camber_deg": round(math.degrees(math.asin(max(-1, min(1, axle.z)))), 2),
        "centre": Vector(((lo + hi) / 2).tolist()),
        "diameter": float(hi[2] - lo[2]),
        "width": float(hi[0] - lo[0]),
    }

half_track = sum(abs(c["centre"].x) for c in corners.values()) / 4
axle_z = sum(c["centre"].z for c in corners.values()) / 4
front_y = (corners["FL"]["centre"].y + corners["FR"]["centre"].y) / 2
rear_y = (corners["RL"]["centre"].y + corners["RR"]["centre"].y) / 2
wheel_diameter = sum(c["diameter"] for c in corners.values()) / 4

for corner, c in corners.items():
    target = Vector(((half_track if corner[1] == "L" else -half_track), front_y if corner[0] == "F" else rear_y, axle_z))
    shift = target - c["centre"]
    for part in ("Tyre", "Rim", "Caliper"):
        bm = groups[f"Wheel{corner}_{part}"]
        bmesh.ops.translate(bm, vec=shift, verts=bm.verts)

# --- 4. car space, studs, Roblox axes ---------------------------------------------
wheelbase_bu = rear_y - front_y
metres_per_bu = REAL_WHEELBASE_M / wheelbase_bu
studs_per_bu = metres_per_bu * STUDS_PER_METRE
mid_y = (front_y + rear_y) / 2

# Roblox (x, y, z) = (-x, z, y) in Blender terms. The FBX exporter maps Blender
# (X, Y, Z) -> (X, Z, -Y), so bake (X, Y, Z) = (-x, -y, z): a half turn about Z.
to_car = (
    Matrix.Rotation(math.pi, 4, "Z")
    @ Matrix.Scale(studs_per_bu, 4)
    @ Matrix.Translation(Vector((0, -mid_y, -axle_z)))
)

# --- 5. decimate and build objects -------------------------------------------------
collection = scene.collection
summary = {"parts": {}}


def tri_count(mesh):
    mesh.calc_loop_triangles()
    return len(mesh.loop_triangles)


for name in sorted(groups):
    bm = groups[name]
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.transform(bm, matrix=to_car, verts=bm.verts)
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()

    ob = bpy.data.objects.new(name, mesh)
    collection.objects.link(ob)

    before = tri_count(mesh)
    budget = BUDGET[name.split("_")[-1]] if name.startswith("Wheel") else BUDGET[name]
    if before > budget:
        mod = ob.modifiers.new("Decimate", "DECIMATE")
        mod.decimate_type = "COLLAPSE"
        mod.ratio = budget / before
        if not name.startswith(("Wheel", "Body", "Headlight", "Taillight")):
            mod.use_symmetry = True
            mod.symmetry_axis = "X"
        dg = bpy.context.evaluated_depsgraph_get()
        new_mesh = bpy.data.meshes.new_from_object(ob.evaluated_get(dg), depsgraph=dg)
        ob.modifiers.clear()
        ob.data = new_mesh
        bpy.data.meshes.remove(mesh)
        mesh = new_mesh
        mesh.name = name
    after = tri_count(mesh)

    # origin at the bounding-box centre, like an imported mesh part
    lo = Vector((min(v.co.x for v in mesh.vertices), min(v.co.y for v in mesh.vertices), min(v.co.z for v in mesh.vertices)))
    hi = Vector((max(v.co.x for v in mesh.vertices), max(v.co.y for v in mesh.vertices), max(v.co.z for v in mesh.vertices)))
    centre = (lo + hi) / 2
    mesh.transform(Matrix.Translation(-centre))
    ob.location = centre

    mat = bpy.data.materials.new(name)
    mesh.materials.clear()
    mesh.materials.append(mat)

    # report in Roblox car space: (X, Y, Z) blender -> (X, Z, -Y) roblox
    summary["parts"][name] = {
        "tris_before": before,
        "tris": after,
        "centre": [round(centre.x, 4), round(centre.z, 4), round(-centre.y, 4)],
        "size": [round(hi.x - lo.x, 4), round(hi.z - lo.z, 4), round(hi.y - lo.y, 4)],
    }

summary["total_tris"] = sum(p["tris"] for p in summary["parts"].values())
summary["metres_per_blender_unit"] = metres_per_bu
summary["studs_per_blender_unit"] = studs_per_bu
summary["wheels_blender_units"] = {
    k: {kk: (list(vv) if isinstance(vv, Vector) else vv) for kk, vv in v.items()} for k, v in corners.items()
}
summary["layout_metres"] = {
    "wheelbase": wheelbase_bu * metres_per_bu,
    "track": 2 * half_track * metres_per_bu,
    "wheel_radius": wheel_diameter / 2 * metres_per_bu,
    "tyre_width_front": (corners["FL"]["width"] + corners["FR"]["width"]) / 2 * metres_per_bu,
    "tyre_width_rear": (corners["RL"]["width"] + corners["RR"]["width"]) / 2 * metres_per_bu,
}

# --- 6. export ---------------------------------------------------------------------
for ob in scene.objects:
    ob.select_set(True)
bpy.ops.export_scene.fbx(
    filepath=OUT_FBX,
    use_selection=True,
    object_types={"MESH"},
    apply_unit_scale=True,
    bake_space_transform=True,
    mesh_smooth_type="FACE",
    use_mesh_modifiers=True,
    add_leaf_bones=False,
    bake_anim=False,
    path_mode="STRIP",
)

with open(OUT_JSON, "w") as fh:
    json.dump(summary, fh, indent=2)

# --- 7. preview renders, one colour per group ---------------------------------------
PALETTE = {
    "Body": (0.55, 0.05, 0.04, 1),
    "Trim": (0.03, 0.03, 0.03, 1),
    "Chrome": (0.6, 0.6, 0.62, 1),
    "Windows": (0.1, 0.2, 0.3, 1),
    "LampGlass": (0.8, 0.9, 1.0, 1),
    "Headlight": (1.0, 0.95, 0.5, 1),
    "Taillight": (1.0, 0.0, 0.0, 1),
    "Plates": (1, 1, 1, 1),
    "Tyre": (0.02, 0.02, 0.02, 1),
    "Rim": (0.7, 0.7, 0.7, 1),
    "Caliper": (0.9, 0.1, 0.1, 1),
}
for ob in scene.objects:
    key = next(k for k in PALETTE if k in ob.name)
    ob.data.materials[0].diffuse_color = PALETTE[key]

scene.render.engine = "BLENDER_WORKBENCH"
scene.display.shading.light = "STUDIO"
scene.display.shading.color_type = "MATERIAL"
scene.render.resolution_x = 900
scene.render.resolution_y = 600
cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
collection.objects.link(cam)
scene.camera = cam
# car space in Blender terms now: front is +Y, left is -X, up is +Z
for key, pos in {"front34": Vector((-14, 18, 8)), "rear34": Vector((14, -18, 7)), "side": Vector((-26, 0, 1)), "top": Vector((0, 0.01, 30))}.items():
    cam.location = pos
    cam.rotation_euler = (-pos).to_track_quat("-Z", "Y").to_euler()
    scene.render.filepath = f"{PREVIEW}_{key}.png"
    bpy.ops.render.render(write_still=True)
