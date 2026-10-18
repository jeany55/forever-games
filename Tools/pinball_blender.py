"""Builds the bench's pinball table in 3D in Blender and renders it seen tilted, the way the
pinball tables of the nineties were made: everything that doesn't move is one picture, and
everything that moves or lights up is a picture of its own, made in the same light from the same
camera, for the bench to put in place over it.

    blender -b --factory-startup --python pinball_blender.py -- <scene.json> <folder>

Run by Tools/make_pinball.py --render, which writes scene.json from Tools/pinball_table.py, with
Windows paths, as Blender here is the Windows one. Writes into <folder> the pictures, as 32 bit
TGA with sides a power of two, and tilt.json, what Art.lua says of them (see make_pinball.py).

The table is measured in millimetres with x across and y down the table, as the physics has it,
and z up from the playfield. Blender's world is in metres with y up the table, so a point of the
table is at (x, -y, z) thousandths. The camera is given back as the matrix that takes a point of
the table, in millimetres, to the picture's pixels.

What is rendered:
  background  the table with nothing lit and nothing that moves, in its cabinet, the backbox with
              the score display standing at the far end
  over        what stands higher than a ball, with see-through round it, to go over the balls that
              roll under or behind it; once for a ball on the playfield, and again for each height
              a ball rides at on the ramp and the wires (OVER), each only what is higher still.
              Along any line the camera looks down, what is higher is nearer the camera, so what is
              higher than a ball and drawn where it is, is in front of it
  lamps       each lamp's light, what it adds to the picture when it is lit: the lamps are lit a
              few at a time, those far enough apart that their light doesn't mix, and each is cut
              out of the difference with the picture unlit. The same for the bumpers' caps and
              the flashers
  movers      the flippers at 24 angles from rest to up, the spinner's blade at 8, the plunger
              at 6 pulls, the drop targets and the centre post up, each with its shadow and
              see-through round it
  ball        the ball, and its shadow
The score display is drawn by the bench: tilt.json says where its glass is in the background.
"""
import json
import math
import os
import sys
import time

import bmesh
import bpy
import numpy as np
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Matrix, Vector

ARGS = sys.argv[sys.argv.index("--") + 1:]
SCENE = json.load(open(ARGS[0]))
OUT = ARGS[1]
T = SCENE["table"]
COLOURS = SCENE["colours"]
QUICK = "--quick" in ARGS

MM = 0.001
BALL = T["ball"]
# What stands higher than each of these, in mm, is drawn over a ball whose top is lower: the first
# over a ball rolling on the playfield, the rest over balls on the ramp and the wires
OVER = [28.0, 52.0, 76.0, 100.0, 124.0, 148.0]
# The longest side of the background, px
SIDE = 2048
FRAMES = 24
SPINNER_FRAMES = 8
PLUNGER_FRAMES = 6
PLUNGER_TRAVEL = 30
SAMPLES = 64 if QUICK else 160

started = time.time()


def say(*words):
    print("PINBALL", round(time.time() - started, 1), *words, flush=True)


def at(x, y, z=0.0):
    return Vector((x * MM, -y * MM, z * MM))


#############################
# The scene
#############################

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene["overMode"] = 0.0
scene["overHeight"] = OVER[0] * MM
collection = scene.collection

# Everything made, by what it is to the passes
STATIC, MOVERS = [], {}
LAMPS, BUMPERS, FLASHERS = {}, {}, {}


def link(obj, kind="static", key=None):
    collection.objects.link(obj)
    obj["kind"] = kind
    if kind == "static":
        STATIC.append(obj)
    elif kind == "mover":
        MOVERS.setdefault(key, []).append(obj)
    return obj


#############################
# Materials
#############################

def wrap(tree, shader_socket):
    """Every material goes through this: in an "over" pass, whatever of it is lower than that pass's
    height is held out, see-through, so the picture has only what stands above a ball"""
    nodes, links = tree.nodes, tree.links
    out = nodes.new("ShaderNodeOutputMaterial")
    geometry = nodes.new("ShaderNodeNewGeometry")
    xyz = nodes.new("ShaderNodeSeparateXYZ")
    links.new(geometry.outputs["Position"], xyz.inputs[0])
    low = nodes.new("ShaderNodeMath")
    low.operation = "LESS_THAN"
    height = nodes.new("ShaderNodeAttribute")
    height.attribute_type = "VIEW_LAYER"
    height.attribute_name = "overHeight"
    links.new(xyz.outputs["Z"], low.inputs[0])
    links.new(height.outputs["Fac"], low.inputs[1])
    mode = nodes.new("ShaderNodeAttribute")
    mode.attribute_type = "VIEW_LAYER"
    mode.attribute_name = "overMode"
    both = nodes.new("ShaderNodeMath")
    both.operation = "MULTIPLY"
    links.new(low.outputs[0], both.inputs[0])
    links.new(mode.outputs["Fac"], both.inputs[1])
    holdout = nodes.new("ShaderNodeHoldout")
    mix = nodes.new("ShaderNodeMixShader")
    links.new(both.outputs[0], mix.inputs[0])
    links.new(shader_socket, mix.inputs[1])
    links.new(holdout.outputs[0], mix.inputs[2])
    links.new(mix.outputs[0], out.inputs["Surface"])


def material(name, colour=(0.8, 0.8, 0.8), metallic=0.0, rough=0.5, transmission=0.0, coat=0.0,
             emission=None, strength=0.0, ior=1.45, texture=None, alpha=1.0):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    tree = mat.node_tree
    tree.nodes.clear()
    bsdf = tree.nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.inputs["Base Color"].default_value = (*colour, 1)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Transmission Weight"].default_value = transmission
    bsdf.inputs["IOR"].default_value = ior
    bsdf.inputs["Coat Weight"].default_value = coat
    bsdf.inputs["Coat Roughness"].default_value = 0.04 if name != "playfield" else 0.12
    bsdf.inputs["Alpha"].default_value = alpha
    if emission is not None:
        bsdf.inputs["Emission Color"].default_value = (*emission, 1)
        bsdf.inputs["Emission Strength"].default_value = strength
    if texture is not None:
        image = tree.nodes.new("ShaderNodeTexImage")
        image.image = texture
        image.interpolation = "Cubic"
        tree.links.new(image.outputs["Color"], bsdf.inputs["Base Color"])
    wrap(tree, bsdf.outputs["BSDF"])
    mat["bsdf"] = bsdf.name
    return mat


def bsdf_of(mat):
    return mat.node_tree.nodes[mat["bsdf"]]


def wood():
    """Mahogany: dark red-brown with long grain, under a gloss"""
    mat = bpy.data.materials.new("wood")
    mat.use_nodes = True
    tree = mat.node_tree
    tree.nodes.clear()
    bsdf = tree.nodes.new("ShaderNodeBsdfPrincipled")
    coords = tree.nodes.new("ShaderNodeTexCoord")
    mapping = tree.nodes.new("ShaderNodeMapping")
    mapping.inputs["Scale"].default_value = (40, 4, 40)
    tree.links.new(coords.outputs["Object"], mapping.inputs[0])
    wave = tree.nodes.new("ShaderNodeTexWave")
    wave.inputs["Scale"].default_value = 3.0
    wave.inputs["Distortion"].default_value = 6.0
    wave.inputs["Detail"].default_value = 4.0
    tree.links.new(mapping.outputs[0], wave.inputs["Vector"])
    ramp = tree.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (0.10, 0.025, 0.012, 1)
    ramp.color_ramp.elements[1].color = (0.30, 0.08, 0.035, 1)
    tree.links.new(wave.outputs["Fac"], ramp.inputs[0])
    tree.links.new(ramp.outputs[0], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 0.35
    bsdf.inputs["Coat Weight"].default_value = 0.6
    bsdf.inputs["Coat Roughness"].default_value = 0.08
    wrap(tree, bsdf.outputs["BSDF"])
    mat["bsdf"] = bsdf.name
    return mat


def rgb(name):
    return tuple(COLOURS[name])


bare = bpy.data.images.load(SCENE["playfield"])
MAT = {
    "playfield": material("playfield", rough=0.32, coat=0.6, texture=bare),
    "wood": wood(),
    "chrome": material("chrome", (0.9, 0.9, 0.92), metallic=1.0, rough=0.06),
    "steel": material("steel", (0.8, 0.8, 0.82), metallic=1.0, rough=0.38),
    "gold": material("gold", (0.95, 0.68, 0.28), metallic=1.0, rough=0.18),
    "rubber": material("rubber", (0.92, 0.91, 0.87), rough=0.55),
    "redRubber": material("redRubber", (0.75, 0.05, 0.04), rough=0.5),
    "blackRubber": material("blackRubber", (0.02, 0.02, 0.02), rough=0.6),
    "ivory": material("ivory", (0.93, 0.9, 0.82), rough=0.25, coat=0.5),
    "darkPlastic": material("darkPlastic", (0.02, 0.02, 0.03), rough=0.3, coat=0.4),
    "redPlastic": material("redPlastic", (0.8, 0.06, 0.04), rough=0.12, transmission=0.3, coat=0.8),
    "clear": material("clear", (0.85, 0.92, 1.0), rough=0.02, transmission=1.0, ior=1.49),
    "smoke": material("smoke", (0.8, 0.88, 1.0), rough=0.03, transmission=1.0, ior=1.49),
    "targetRed": material("targetRed", (0.7, 0.04, 0.03), rough=0.25, coat=0.6),
    "targetFace": material("targetFace", (0.95, 0.75, 0.2), rough=0.25, coat=0.6),
    "black": material("black", (0.01, 0.01, 0.012), rough=0.4),
    "apron": material("apron", (0.05, 0.045, 0.06), metallic=0.6, rough=0.35),
}


#############################
# Shapes
#############################

def mesh_object(name, bm, mat, kind="static", key=None, smooth=False):
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    if smooth:
        for poly in mesh.polygons:
            poly.use_smooth = True
    mesh.materials.append(mat)
    return link(bpy.data.objects.new(name, mesh), kind, key)


def prism(name, points, z0, z1, mat, kind="static", key=None, origin=None):
    """A flat shape, x y pairs of the table, stood up from z0 to z1 mm. With an origin, the
    object is placed there and its points are around it"""
    bm = bmesh.new()
    ox, oy = origin if origin else (0, 0)
    verts = [bm.verts.new(((x - ox) * MM, -(y - oy) * MM, z0 * MM)) for x, y in zip(points[0::2], points[1::2])]
    face = bm.faces.new(verts)
    if face.normal.z < 0:
        face.normal_flip()
    result = bmesh.ops.extrude_face_region(bm, geom=[face])
    top = [v for v in result["geom"] if isinstance(v, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, verts=top, vec=(0, 0, (z1 - z0) * MM))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    obj = mesh_object(name, bm, mat, kind, key)
    if origin:
        obj.location = at(ox, oy)
    return obj


def slab(name, ax, ay, bx, by, thick, z0, z1, mat, **kw):
    """A wall along a line, `thick` mm through"""
    dx, dy = bx - ax, by - ay
    length = math.hypot(dx, dy) or 1
    nx, ny = -dy / length * thick / 2, dx / length * thick / 2
    return prism(name, [ax + nx, ay + ny, bx + nx, by + ny, bx - nx, by - ny, ax - nx, ay - ny], z0, z1, mat, **kw)


def cylinder(name, x, y, r, z0, z1, mat, segments=32, kind="static", key=None):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=segments, radius1=r * MM, radius2=r * MM, depth=(z1 - z0) * MM)
    obj = mesh_object(name, bm, mat, kind, key, smooth=True)
    obj.location = at(x, y, (z0 + z1) / 2)
    edge_split(obj)
    return obj


def cone(name, x, y, r1, r2, z0, z1, mat, segments=32, kind="static", key=None):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=segments, radius1=r1 * MM, radius2=r2 * MM, depth=(z1 - z0) * MM)
    obj = mesh_object(name, bm, mat, kind, key, smooth=True)
    obj.location = at(x, y, (z0 + z1) / 2)
    edge_split(obj)
    return obj


def edge_split(obj, angle=40):
    """Smooth round the sides, sharp at the rims"""
    modifier = obj.modifiers.new("split", "EDGE_SPLIT")
    modifier.split_angle = math.radians(angle)


def torus(name, x, y, z, major, minor, mat, kind="static", key=None):
    bpy.ops.mesh.primitive_torus_add(major_radius=major * MM, minor_radius=minor * MM, major_segments=40,
                                     minor_segments=12, location=at(x, y, z))
    obj = bpy.context.active_object
    bpy.context.scene.collection.objects.unlink(obj)
    obj.data.materials.append(mat)
    for poly in obj.data.polygons:
        poly.use_smooth = True
    return link(obj, kind, key)


def sphere(name, x, y, z, r, mat, kind="static", key=None, half=False):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=32, v_segments=16, radius=r * MM)
    if half:
        bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.z < -1e-6], context="VERTS")
    obj = mesh_object(name, bm, mat, kind, key, smooth=True)
    obj.location = at(x, y, z)
    return obj


def tube(name, points, radius, mat, kind="static", key=None, closed=False):
    """A round bar through points (x, y, z of the table), a wire or a rubber band"""
    curve = bpy.data.curves.new(name, "CURVE")
    curve.dimensions = "3D"
    curve.bevel_depth = radius * MM
    curve.bevel_resolution = 4
    curve.use_fill_caps = True
    spline = curve.splines.new("POLY")
    spline.points.add(len(points) - 1)
    for point, (x, y, z) in zip(spline.points, points):
        point.co = (*at(x, y, z), 1)
    spline.use_cyclic_u = closed
    curve.materials.append(mat)
    return link(bpy.data.objects.new(name, curve), kind, key)


def text(name, words, x, y, z, size, mat, font=None, angle=0.0, extrude=0.0):
    curve = bpy.data.curves.new(name, "FONT")
    curve.body = words
    curve.size = size * MM
    curve.align_x, curve.align_y = "CENTER", "CENTER"
    curve.extrude = extrude * MM
    if font:
        curve.font = font
    curve.materials.append(mat)
    obj = bpy.data.objects.new(name, curve)
    obj.location = at(x, y, z)
    obj.rotation_euler.z = -angle
    return link(obj)


def segments(points):
    return [(points[i], points[i + 1], points[i + 2], points[i + 3]) for i in range(0, len(points) - 2, 2)]


def offset_polygon(points, by, steps=6):
    """A convex polygon grown outwards by `by` mm all round, its corners rounded, as a rubber band
    round posts lies"""
    pts = list(zip(points[0::2], points[1::2]))
    n = len(pts)
    area = sum(pts[i][0] * pts[(i + 1) % n][1] - pts[(i + 1) % n][0] * pts[i][1] for i in range(n))
    sign = 1 if area > 0 else -1
    normals = []
    for i in range(n):
        (ax, ay), (bx, by_) = pts[i], pts[(i + 1) % n]
        dx, dy = bx - ax, by_ - ay
        length = math.hypot(dx, dy)
        normals.append((dy / length * sign, -dx / length * sign))
    out = []
    for i in range(n):
        (x, y), (n0x, n0y), (n1x, n1y) = pts[i], normals[i - 1], normals[i]
        a0, a1 = math.atan2(n0y, n0x), math.atan2(n1y, n1x)
        turn = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi
        for k in range(steps + 1):
            a = a0 + turn * k / steps
            out += [x + by * math.cos(a), y + by * math.sin(a)]
    return out


#############################
# The table
#############################

shapes = T["shapes"]
W, H = T["width"], T["height"]

# The playfield, with its print, a little bigger than the table under the cabinet's walls
bm = bmesh.new()
corners = [(-24, -24), (W + 24, -24), (W + 24, H + 30), (-24, H + 30)]
uv_layer = bm.loops.layers.uv.new()
face = bm.faces.new([bm.verts.new(at(x, y)) for x, y in corners])
for loop in face.loops:
    x, y = loop.vert.co.x / MM, -loop.vert.co.y / MM
    loop[uv_layer].uv = (x / W, 1 - y / H)
playfield = mesh_object("playfield", bm, MAT["playfield"])

# The cabinet: the wood from the playfield's edge out, as high as CABINET, with a chrome rail
# along its inside edge
CABINET = 45
cabinet = next(s for s in shapes if s.get("name") == "cabinet")["points"]
SIDE_RAIL = 24
outline = cabinet + [W + SIDE_RAIL, H, W + SIDE_RAIL, -SIDE_RAIL, -SIDE_RAIL, -SIDE_RAIL, -SIDE_RAIL, H]
CABINET_PARTS = [prism("cabinet", outline, 0, CABINET, MAT["wood"])]
CABINET_PARTS.append(tube("cabinetRail", [(x, y, CABINET - 1) for x, y in zip(cabinet[0::2], cabinet[1::2])], 3.2, MAT["chrome"]))
# The chrome side rails along the cabinet's top, and the lockdown bar across its front
for x in (-SIDE_RAIL + 6, W + SIDE_RAIL - 6):
    CABINET_PARTS.append(prism(f"sideRail{x}", [x - 6, -SIDE_RAIL, x + 6, -SIDE_RAIL, x + 6, H + 40, x - 6, H + 40], CABINET, CABINET + 5, MAT["steel"]))
CABINET_PARTS.append(prism("front", [-SIDE_RAIL, H, W + SIDE_RAIL, H, W + SIDE_RAIL, H + 40, -SIDE_RAIL, H + 40], 0, CABINET, MAT["wood"]))
CABINET_PARTS.append(prism("lockdown", [-SIDE_RAIL, H + 8, W + SIDE_RAIL, H + 8, W + SIDE_RAIL, H + 36, -SIDE_RAIL, H + 36], CABINET, CABINET + 8,
      MAT["steel"]))
# The apron the ball drains under, with a card at each side
prism("apron", [12, 990, 464, 990, 464, H, 12, H], 0, 10, MAT["apron"])
tube("apronEdge", [(12, 990, 10), (464, 990, 10)], 1.4, MAT["gold"])

rail_index = 0
for s in shapes:
    role, kind, name = s.get("role"), s["kind"], s.get("name")
    layers = s.get("layers", 1)
    if s.get("sensor") or layers == 2:
        continue
    if kind == "line" and role == "rail" and name != "cabinet":
        tall = 32 if name in ("orbit", "rightOrbitWall", "lane") else 18
        for ax, ay, bx, by in segments(s["points"]):
            rail_index += 1
            if name == "lane":
                slab(f"lane{rail_index}", ax, ay, bx, by, 6, 0, tall, MAT["wood"])
                tube(f"laneTop{rail_index}", [(ax, ay, tall), (bx, by, tall)], 3.0, MAT["chrome"])
            else:
                slab(f"rail{rail_index}", ax, ay, bx, by, 2.2, 0, tall, MAT["steel"])
                tube(f"railTop{rail_index}", [(ax, ay, tall), (bx, by, tall)], 1.4, MAT["chrome"])
    elif kind == "line" and role == "ramp":
        # The ramp's entrance under its mouth: clear plastic
        for ax, ay, bx, by in segments(s["points"]):
            rail_index += 1
            slab(f"mouthWall{rail_index}", ax, ay, bx, by, 3, 0, 22, MAT["clear"])
    elif kind == "line" and role == "standup":
        p = s["points"]
        mx, my = (p[0] + p[2]) / 2, (p[1] + p[3]) / 2
        slab(f"{name}Face", p[0] + 1, p[1], p[2] - 1, p[3], 4, 2, 28, MAT["targetFace"])
        slab(f"{name}Stripe", p[0] + 1, p[1] + 2.2, p[2] - 1, p[3] + 2.2, 0.5, 12, 18, MAT["ivory"])
        cylinder(f"{name}Spring", mx, my - 6, 1.8, 0, 18, MAT["steel"], 12)
    elif kind == "circle" and role == "post" and s.get("active", True) and name != "corkscrewPost":
        x, y, r = s["x"], s["y"], s["r"]
        metal = s.get("material") == "metal"
        high = 30 if metal else 26
        if metal:
            cylinder(f"post{x}_{y}", x, y, r, 0, high, MAT["chrome"], 24)
        else:
            cylinder(f"post{x}_{y}", x, y, max(1.6, r * 0.42), 0, high, MAT["chrome"], 16)
            torus(f"postRubber{x}_{y}", x, y, 11, max(1.2, r - 1.7), min(1.8, r * 0.36), MAT["rubber"])
            cylinder(f"postNut{x}_{y}", x, y, max(2.2, r * 0.6), high - 3, high, MAT["chrome"], 6)
    elif kind == "circle" and role == "bumper":
        x, y, r = s["x"], s["y"], s["r"]
        colour = rgb("blue") if name == "bumper3" else rgb("red")
        cylinder(f"{name}Base", x, y, r + 3, 0, 2.5, MAT["darkPlastic"])
        cylinder(f"{name}Skirt", x, y, r, 2.5, 9, MAT["chrome"])
        cylinder(f"{name}Body", x, y, r * 0.72, 9, 31, MAT["ivory"])
        cap = material(f"{name}Cap", tuple(c * 0.55 for c in colour), rough=0.08, transmission=0.55, coat=1.0,
                       emission=colour, strength=0.0)
        cone(f"{name}Cap", x, y, r * 0.95, r * 0.86, 31, 41, cap).visible_shadow = False
        top = sphere(f"{name}Dome", x, y, 41, r * 0.86, cap, half=True)
        top.visible_shadow = False
        top.scale.z = 0.22
        star = [c for k in range(10) for c in (x + (7 if k % 2 == 0 else 3) * math.cos(math.pi * k / 5 - math.pi / 2),
                                               y + (7 if k % 2 == 0 else 3) * math.sin(math.pi * k / 5 - math.pi / 2))]
        prism(f"{name}Star", star, 45.2, 45.7, MAT["gold"])
        light = bpy.data.lights.new(f"{name}Light", "POINT")
        light.color = colour
        light.shadow_soft_size = 8 * MM
        light.energy = 0
        bulb = bpy.data.objects.new(f"{name}Light", light)
        bulb.location = at(x, y, 36)
        collection.objects.link(bulb)
        BUMPERS[name] = {"material": cap, "light": bulb, "x": x, "y": y, "r": r + 30, "colour": colour}

# Slingshots: a rubber band round three posts, a kicking face, and a red plastic over them
for s in shapes:
    if s.get("role") == "sling" and s["kind"] == "line" and s.get("name") is None:
        p = s["points"]
        band = offset_polygon(p, 4.4)
        tube(f"slingBand{p[0]}", [(x, y, 12) for x, y in zip(band[0::2], band[1::2])], 2.0, MAT["rubber"], closed=True)
        cover = offset_polygon(p, 7.5)
        prism(f"slingPlastic{p[0]}", cover, 30, 32.5, MAT["redPlastic"])
        cx, cy = (p[0] + p[2] + p[4]) / 3, (p[1] + p[3] + p[5]) / 3
        moon = [c for k in range(24) for c in (cx + 7 * math.cos(2 * math.pi * k / 24), cy + 7 * math.sin(2 * math.pi * k / 24))]
        prism(f"slingMoon{p[0]}", moon, 32.5, 32.9, MAT["gold"])
        prism(f"slingMoonCut{p[0]}", [c for k in range(24) for c in (cx + 2.5 + 6 * math.cos(2 * math.pi * k / 24),
                                                                     cy - 1.5 + 6 * math.sin(2 * math.pi * k / 24))],
              32.9, 33.0, MAT["redPlastic"])
        for x, y in zip(p[0::2], p[1::2]):
            cylinder(f"slingStandoff{x}_{y}", x, y, 2.2, 26, 30, MAT["chrome"], 12)
            cylinder(f"slingScrew{x}_{y}", x, y, 2.6, 32.5, 33.6, MAT["chrome"], 6)

# Rollovers: gold stars in the top lanes, wires across the lanes at the bottom
for s in shapes:
    if s.get("role") != "rollover":
        continue
    if s["kind"] == "circle":
        x, y = s["x"], s["y"]
        cylinder(f"rolloverRing{x}", x, y, 8.5, 0, 0.6, MAT["black"])
        star = [c for k in range(10) for c in (x + (7.5 if k % 2 == 0 else 3.2) * math.cos(math.pi * k / 5 - math.pi / 2),
                                               y + (7.5 if k % 2 == 0 else 3.2) * math.sin(math.pi * k / 5 - math.pi / 2))]
        prism(f"rolloverStar{x}", star, 0.6, 2.4, MAT["gold"])
    else:
        p = s["points"]
        mx, my = (p[0] + p[2]) / 2, (p[1] + p[3]) / 2
        # Along the lane, across the line
        arc = [(mx, my + 9 * math.cos(math.pi * k / 10), 5 * math.sin(math.pi * k / 10)) for k in range(11)]
        tube(f"rolloverWire{mx}", arc, 0.8, MAT["chrome"])
        prism(f"rolloverSlot{mx}", [mx - 2, my - 11, mx + 2, my - 11, mx + 2, my + 11, mx - 2, my + 11], 0, 0.15, MAT["black"])

# The saucer's gold rim, the spinner's bracket, the shooter gate, the kickback
saucer = next(s for s in shapes if s.get("role") == "saucer")
torus("saucerRim", saucer["x"], saucer["y"], 0.8, 16.5, 1.6, MAT["gold"])
spinner = next(s for s in shapes if s.get("role") == "spinner")["points"]
SPINNER_Z = 30
for x in (spinner[0] + 3, spinner[2] - 3):
    slab(f"spinnerBracket{x}", x, spinner[1] - 2, x, spinner[1] + 2, 3, 0, SPINNER_Z + 4, MAT["steel"])
tube("spinnerAxle", [(spinner[0] + 3, spinner[1], SPINNER_Z), (spinner[2] - 3, spinner[1], SPINNER_Z)], 1.0, MAT["chrome"])
gate = next(s for s in shapes if s.get("role") == "gate")["points"]
tube("gateWire", [(gate[0] + 3, gate[1], 22), (gate[0] + 3, gate[1], 4), (gate[2] - 3, gate[3], 4), (gate[2] - 3, gate[3], 22)],
     0.9, MAT["chrome"])
kick = next(s for s in shapes if s.get("role") == "kickback")
cylinder("kickbackHead", kick["x"], kick["y"] + 14, 4.5, 0, 7, MAT["chrome"], 20)

#############################
# The ramp and the wires
#############################

ramp_def = T["ramps"][0]
path = ramp_def["path"]
PATH = [(path[i], path[i + 1], path[i + 2]) for i in range(0, len(path), 3)]


def ramp_height(x, y):
    """How high the ramp's floor is over a point, from the nearest stretch of its path"""
    best, height = 1e9, 0
    for (ax, ay, az), (bx, by, bz) in zip(PATH, PATH[1:]):
        dx, dy = bx - ax, by - ay
        t = max(0, min(1, ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy)))
        d = math.hypot(ax + dx * t - x, ay + dy * t - y)
        if d < best:
            best, height = d, az + (bz - az) * t
    return height


RAMP_WALL = 26
# The ramp's lane, from its walls: straight up from its mouth to a little past where the wire takes
# the ball
lane_wall = next(s for s in shapes if s.get("name") == "ramp")["points"]
LEFT_X, RIGHT_X = lane_wall[0], lane_wall[6]
MOUTH_Y = lane_wall[1]
TOP_Y = PATH[-1][1] - 8
ROWS = 24
rows_y = [MOUTH_Y + (TOP_Y - MOUTH_Y) * k / ROWS for k in range(ROWS + 1)]

# Smoked plastic up the lane: a floor, and clear walls each side
bm = bmesh.new()
rows = []
for y in rows_y:
    z = ramp_height((LEFT_X + RIGHT_X) / 2, y)
    rows.append([bm.verts.new(at(LEFT_X, y, z)), bm.verts.new(at(RIGHT_X, y, z)),
                 bm.verts.new(at(LEFT_X, y, z - 2.5)), bm.verts.new(at(RIGHT_X, y, z - 2.5))])
for r0, r1 in zip(rows, rows[1:]):
    bm.faces.new([r0[0], r1[0], r1[1], r0[1]])
    bm.faces.new([r0[2], r0[3], r1[3], r1[2]])
    bm.faces.new([r0[0], r0[2], r1[2], r1[0]])
    bm.faces.new([r0[1], r1[1], r1[3], r0[3]])
bm.faces.new([rows[0][0], rows[0][1], rows[0][3], rows[0][2]])
bm.faces.new([rows[-1][0], rows[-1][2], rows[-1][3], rows[-1][1]])
bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
mesh_object("rampFloor", bm, MAT["smoke"])
walls = bmesh.new()
wall_rows = []
for y in rows_y:
    z = ramp_height((LEFT_X + RIGHT_X) / 2, y)
    wall_rows.append([walls.verts.new(at(LEFT_X, y, z)), walls.verts.new(at(RIGHT_X, y, z)),
                      walls.verts.new(at(LEFT_X, y, z + RAMP_WALL)), walls.verts.new(at(RIGHT_X, y, z + RAMP_WALL))])
for r0, r1 in zip(wall_rows, wall_rows[1:]):
    walls.faces.new([r0[0], r0[2], r1[2], r1[0]])
    walls.faces.new([r0[1], r1[1], r1[3], r0[3]])
wall_object = mesh_object("rampWalls", walls, MAT["clear"])
wall_object.modifiers.new("thick", "SOLIDIFY").thickness = 1.6 * MM
for x in (LEFT_X, RIGHT_X):
    tube(f"rampEdge{x}", [(x, y, ramp_height(x, y) + RAMP_WALL) for y in rows_y], 1.2, MAT["chrome"])
mouth = next(s for s in shapes if s.get("name") == "rampIn")["points"]
prism("rampFlap", [mouth[0], mouth[1] + 1, mouth[2], mouth[3] + 1, mouth[2], mouth[3] - 8, mouth[0], mouth[1] - 8], 0, 1.2, MAT["steel"])
# Chevrons printed up its floor
for k in range(3, ROWS - 2, 5):
    x, y = (LEFT_X + RIGHT_X) / 2, rows_y[k]
    z = ramp_height(x, y) + 0.4
    chevron = [x - 9, y + 3, x, y - 5, x + 9, y + 3, x + 9, y + 7, x, y - 1, x - 9, y + 7]
    prism(f"rampChevron{k}", chevron, z, z + 0.3, MAT["gold"])
# A gold plate across its top, where the wire takes over, and a sign on it
prism("rampTopPlate", [LEFT_X - 3, TOP_Y - 2, RIGHT_X + 3, TOP_Y - 2, RIGHT_X + 3, TOP_Y + 6, LEFT_X - 3, TOP_Y + 6],
      PATH[-1][2] + RAMP_WALL - 2, PATH[-1][2] + RAMP_WALL + 4, MAT["gold"])

# The wires: two the ball rolls on, two at its sides, on hoops; each follows its rail's way through
# the air (Tools/pinball_table.py), which the physics has the ball ride
WIRES = {"floorL": (-9, 2.0), "floorR": (9, 2.0), "sideL": (-17, 13), "sideR": (17, 13)}
WIRE_POINTS = []


def rail_points(rail):
    p = rail["points"]
    return [(p[i], p[i + 1], p[i + 2]) for i in range(0, len(p), 3)]


def side_of(points, k):
    """Across the way at point k, level: the left of where it goes"""
    a, b = points[max(0, k - 1)], points[min(len(points) - 1, k + 1)]
    dx, dy = b[0] - a[0], b[1] - a[1]
    length = math.hypot(dx, dy) or 1
    return -dy / length, dx / length


for rail in T["rails"]:
    points = rail_points(rail)
    if rail.get("tube"):
        # Up a glass tube first: the wires begin at its top
        first = next(k for k, (x, y, z) in enumerate(points) if z >= rail["tube"] - 0.01)
        points = points[first:]
    sides = [side_of(points, k) for k in range(len(points))]
    for wire, (off, lift) in WIRES.items():
        tube(f"{rail['name']}_{wire}", [(x + nx * off, y + ny * off, z + lift) for (x, y, z), (nx, ny) in zip(points, sides)],
             1.3, MAT["chrome"])
    along = 0.0
    last = None
    for k, ((x, y, z), (nx, ny)) in enumerate(zip(points, sides)):
        if last:
            along += math.dist(last, (x, y, z))
        last = (x, y, z)
        if k == 0 or along >= 30:
            along = 0.0
            hoop = [(x + nx * 17 * math.cos(t), y + ny * 17 * math.cos(t), z + 13 - 13 * math.sin(t))
                    for t in [math.pi * j / 12 for j in range(13)]]
            tube(f"{rail['name']}Hoop{k}", hoop, 0.9, MAT["chrome"])
    WIRE_POINTS.append((rail, points, sides))

# What holds the wires up: a post from what it stands on, and an arm out to the wire's side
for index, stand in enumerate(T.get("supports", [])):
    sx, sy = stand["x"], stand["y"]
    base = stand["base"]
    if stand.get("onRamp"):
        base = ramp_height(sx, sy) + RAMP_WALL
    best = None
    for rail, points, sides in WIRE_POINTS:
        for (x, y, z), (nx, ny) in zip(points, sides):
            for off in (-17, 17):
                wx, wy = x + nx * off, y + ny * off
                d = math.hypot(wx - sx, wy - sy)
                if best is None or d < best[0]:
                    best = (d, wx, wy, z + 13)
    _, wx, wy, top = best
    cylinder(f"support{index}", sx, sy, 2.2, base, top + 3, MAT["chrome"], 12)
    cylinder(f"supportFoot{index}", sx, sy, 3.4, base, base + 3, MAT["steel"], 12)
    tube(f"supportArm{index}", [(sx, sy, top), (wx, wy, top)], 1.5, MAT["chrome"])

# The corkscrew's post, as tall as the corkscrew, with an arm out to its inside wire every quarter turn
screw = T["corkscrew"]
cx, cy = screw["x"], screw["y"]
cylinder("corkscrewPole", cx, cy, 5.5, 0, screw["top"] + 30, MAT["chrome"], 24)
cylinder("corkscrewCap", cx, cy, 7.5, screw["top"] + 30, screw["top"] + 34, MAT["gold"], 24)
torus("corkscrewRubber", cx, cy, 11, 6.2, 1.8, MAT["rubber"])
for rail, points, sides in WIRE_POINTS:
    if rail["name"] != "rampWire":
        continue
    for k, ((x, y, z), (nx, ny)) in enumerate(zip(points, sides)):
        r = math.hypot(x - cx, y - cy)
        if abs(r - screw["r"]) < 1.5 and k % 12 == 0 and z < screw["top"] - 4:
            # The side of the wire nearer the post
            off = -17 if math.hypot(x - 17 * nx - cx, y - 17 * ny - cy) < math.hypot(x + 17 * nx - cx, y + 17 * ny - cy) else 17
            tube(f"corkscrewArm{k}", [(cx, cy, z + 13), (x + nx * off, y + ny * off, z + 13)], 1.4, MAT["chrome"])

#############################
# Lamps and flashers
#############################

fonts = {}


def font(path):
    if path not in fonts:
        fonts[path] = bpy.data.fonts.load(path)
    return fonts[path]


ARROW = [(1.0, 0.0), (0.0, 0.85), (0.0, 0.38), (-0.95, 0.38), (-0.95, -0.38), (0.0, -0.38), (0.0, -0.85)]


def lamp_outline(lamp):
    x, y, r = lamp["x"], lamp["y"], lamp["r"]
    if lamp["shape"] == "arrow":
        a = math.radians(lamp.get("angle", 0))
        return [c for u, v in ARROW for c in (x + r * (u * math.cos(a) - v * math.sin(a)), y + r * (u * math.sin(a) + v * math.cos(a)))]
    if lamp["shape"] == "label":
        w, h, c = lamp["w"] / 2, lamp["h"] / 2, 3.0
        pts = []
        for cx, cy, start in ((w - c, -h + c, -90), (w - c, h - c, 0), (-w + c, h - c, 90), (-w + c, -h + c, 180)):
            for k in range(5):
                a = math.radians(start + 90 * k / 4)
                pts += [x + cx + c * math.cos(a), y + cy + c * math.sin(a)]
        return pts
    return [c for k in range(32) for c in (x + r * math.cos(2 * math.pi * k / 32), y + r * math.sin(2 * math.pi * k / 32))]


label_ink = material("labelInk", (0.02, 0.015, 0.01), rough=0.4)
for lamp in T["lamps"]:
    colour = rgb(lamp["color"])
    mat = material(f"insert_{lamp['name']}", tuple(c * 0.22 for c in colour), rough=0.12, transmission=0.2, coat=0.9,
                   emission=colour, strength=0.0)
    pts = lamp_outline(lamp)
    prism(f"insert_{lamp['name']}", pts, 0.05, 0.35, mat)
    # A dark ring round it where the plastic is set into the wood
    if lamp["shape"] != "label":
        ring = offset_polygon(pts, 1.0) if lamp["shape"] == "arrow" else lamp_outline(dict(lamp, r=lamp["r"] + 1.0))
        prism(f"insertRim_{lamp['name']}", ring, 0.0, 0.2, MAT["black"])
    else:
        text(f"label_{lamp['name']}", lamp["text"], lamp["x"], lamp["y"], 0.4, lamp["h"] * 0.5, label_ink, font(SCENE["fonts"]["label"]))
    light = bpy.data.lights.new(f"bulb_{lamp['name']}", "POINT")
    light.color = colour
    light.shadow_soft_size = 3 * MM
    light.energy = 0
    bulb = bpy.data.objects.new(f"bulb_{lamp['name']}", light)
    bulb.location = at(lamp["x"], lamp["y"], 5)
    collection.objects.link(bulb)
    reach = max(lamp["r"], lamp.get("w", 0) / 2) + 26
    LAMPS[lamp["name"]] = {"material": mat, "light": bulb, "x": lamp["x"], "y": lamp["y"], "r": reach, "size": lamp["r"]}

# Cards on the apron, the way a machine says how it is played
card_ink = material("cardInk", (0.95, 0.75, 0.3), metallic=0.6, rough=0.3)
for cx, words in ((70, ("MOONGLADE", "3 BALLS PER GAME")), (T["middle"] * 2 - 70 + 0, ("REPLAY", "AT 1,000,000"))):
    prism(f"card{cx}", [cx - 50, 996, cx + 50, 996, cx + 50, 1018, cx - 50, 1018], 10, 10.4, MAT["black"])
    text(f"cardTitle{cx}", words[0], cx, 1003, 10.6, 7, card_ink, font(SCENE["fonts"]["title"]))
    text(f"cardLine{cx}", words[1], cx, 1012, 10.6, 4.5, card_ink, font(SCENE["fonts"]["label"]))

for flash in T["flashers"]:
    x, y, z = flash["x"], flash["y"], flash["z"]
    colour = rgb(flash["color"])
    if flash.get("kind") == "tube":
        # The Moonwell's glass tube, from above a ball rolling into the saucer up to the wire, lit
        # from inside all along, gold rings at its ends
        top = flash["top"]
        glass = material(f"{flash['name']}Glass", tuple(0.75 + 0.25 * c for c in colour), rough=0.04, transmission=0.9,
                         coat=1.0, emission=colour, strength=0.0)
        bm = bmesh.new()
        bmesh.ops.create_cone(bm, cap_ends=False, segments=40, radius1=17 * MM, radius2=17 * MM, depth=(top - z) * MM)
        pipe = mesh_object(f"{flash['name']}Pipe", bm, glass, smooth=True)
        pipe.location = at(x, y, (z + top) / 2)
        pipe.modifiers.new("thick", "SOLIDIFY").thickness = 1.5 * MM
        pipe.visible_shadow = False
        for ring_z in (z, top, (z + top) / 2):
            torus(f"{flash['name']}Ring{ring_z}", x, y, ring_z, 18.2, 1.6, MAT["gold"])
        light = bpy.data.lights.new(f"{flash['name']}Light", "POINT")
        light.color = colour
        light.shadow_soft_size = 12 * MM
        light.energy = 0
        bulb = bpy.data.objects.new(f"{flash['name']}Light", light)
        bulb.location = at(x, y, (z + top) / 2)
        collection.objects.link(bulb)
        FLASHERS[flash["name"]] = {"material": glass, "light": bulb, "x": x, "y": y, "lift": top + 20}
        continue
    # In the cabinet's corners beyond the playfield's arch they stand on its wood
    in_corner = y < 256 and math.hypot(x - 256, y - 256) > 244
    base = max(z, CABINET) if in_corner else z
    cylinder(f"{flash['name']}Base", x, y, 10, base - 5, base, MAT["chrome"])
    glass = material(f"{flash['name']}Glass", tuple(0.6 + 0.4 * c for c in colour), rough=0.05, transmission=0.85, coat=1.0,
                     emission=colour, strength=0.0)
    dome = sphere(f"{flash['name']}Dome", x, y, base, 10, glass, half=True)
    # Glass a flash shines through: it casts no shadow of its own bulb
    dome.visible_shadow = False
    light = bpy.data.lights.new(f"{flash['name']}Light", "POINT")
    light.color = colour
    light.shadow_soft_size = 4 * MM
    light.energy = 0
    bulb = bpy.data.objects.new(f"{flash['name']}Light", light)
    bulb.location = at(x, y, base + 5)
    collection.objects.link(bulb)
    FLASHERS[flash["name"]] = {"material": glass, "light": bulb, "x": x, "y": y}
    if z > 60:
        # The one on the ramp hangs off its wall on a bracket
        tube(f"{flash['name']}Bracket", [(x, y, base - 5), (x, y + 12, base - 5), (x, y + 12, base - 25)], 1.6, MAT["steel"])

#############################
# The backbox and the cabinet
#############################
# The backbox stands at the far end of the cabinet, the way a real machine's head does: the score
# display in the speaker panel at its bottom, between the speakers, and the backglass over them. Its
# face is leant back to look straight at the camera, so that the display on it is a plain oblong in
# the picture, which the bench draws its dots into (tilt.json's dmd), as a player standing at the
# machine sees it. Its face is HEAD_W across and HEAD_H up, in mm
PITCH = SCENE.get("pitch", 50)
HEAD_W, HEAD_H = 580, 330
HEAD_Y, HEAD_Z = -34, CABINET + 8
LEAN = math.radians(PITCH)
DMD = (-150, 40, 150, 115)


def face(u, v, d=0.0):
    """A point of the backbox's face: u across from its middle, v up it from its bottom edge, d out
    of it towards the camera, as a point of the table"""
    return (W / 2 + u, HEAD_Y - v * math.sin(LEAN) + d * math.cos(LEAN), HEAD_Z + v * math.cos(LEAN) + d * math.sin(LEAN))


def panel(name, u0, v0, u1, v1, d0, d1, mat, uv=False):
    """A slab on the face, from u0, v0 to u1, v1, d0 to d1 out of it"""
    bm = bmesh.new()
    layer = bm.loops.layers.uv.new() if uv else None
    corners = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]
    back = [bm.verts.new(at(*face(u, v, d0))) for u, v in corners]
    front = [bm.verts.new(at(*face(u, v, d1))) for u, v in corners]
    top = bm.faces.new(front)
    bm.faces.new(back[::-1])
    for k in range(4):
        bm.faces.new([back[k], back[(k + 1) % 4], front[(k + 1) % 4], front[k]])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    if uv:
        for loop in top.loops:
            co = loop.vert.co
            for (u, v), vert in zip(corners, front):
                if vert == loop.vert:
                    loop[layer].uv = ((u - u0) / (u1 - u0), (v - v0) / (v1 - v0))
    return mesh_object(name, bm, mat)


def face_tube(name, uvs, d, radius, mat, closed=True):
    return tube(name, [face(u, v, d) for u, v in uvs], radius, mat, closed=closed)


def backglass_material():
    """The backglass, lit from behind: deep blue fading to violet, a drift of nebula, and stars"""
    mat = bpy.data.materials.new("backglass")
    mat.use_nodes = True
    tree = mat.node_tree
    tree.nodes.clear()
    nodes, links = tree.nodes, tree.links
    emit = nodes.new("ShaderNodeEmission")
    emit.inputs["Strength"].default_value = 1.0
    coords = nodes.new("ShaderNodeTexCoord")
    xyz = nodes.new("ShaderNodeSeparateXYZ")
    links.new(coords.outputs["UV"], xyz.inputs[0])
    gradient = nodes.new("ShaderNodeValToRGB")
    gradient.color_ramp.elements[0].color = (0.09, 0.03, 0.15, 1)
    gradient.color_ramp.elements[1].color = (0.008, 0.016, 0.06, 1)
    links.new(xyz.outputs["Y"], gradient.inputs[0])
    scaled = nodes.new("ShaderNodeVectorMath")
    scaled.operation = "MULTIPLY"
    scaled.inputs[1].default_value = (3.3, 1.0, 1.0)
    links.new(coords.outputs["UV"], scaled.inputs[0])
    noise = nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 2.2
    noise.inputs["Detail"].default_value = 10
    noise.inputs["Distortion"].default_value = 0.6
    links.new(scaled.outputs[0], noise.inputs["Vector"])
    nebula = nodes.new("ShaderNodeValToRGB")
    nebula.color_ramp.elements[0].position = 0.5
    nebula.color_ramp.elements[0].color = (0, 0, 0, 1)
    nebula.color_ramp.elements[1].position = 0.75
    nebula.color_ramp.elements[1].color = (0.16, 0.05, 0.24, 1)
    links.new(noise.outputs["Fac"], nebula.inputs[0])
    sum1 = nodes.new("ShaderNodeMix")
    sum1.data_type = "RGBA"
    sum1.blend_type = "ADD"
    sum1.inputs["Factor"].default_value = 1.0
    links.new(gradient.outputs[0], sum1.inputs[6])
    links.new(nebula.outputs[0], sum1.inputs[7])
    stars = nodes.new("ShaderNodeTexVoronoi")
    stars.inputs["Scale"].default_value = 70
    links.new(scaled.outputs[0], stars.inputs["Vector"])
    points = nodes.new("ShaderNodeValToRGB")
    points.color_ramp.elements[0].position = 0.0
    points.color_ramp.elements[0].color = (3.0, 2.8, 2.4, 1)
    points.color_ramp.elements[1].position = 0.09
    points.color_ramp.elements[1].color = (0, 0, 0, 1)
    links.new(stars.outputs["Distance"], points.inputs[0])
    sum2 = nodes.new("ShaderNodeMix")
    sum2.data_type = "RGBA"
    sum2.blend_type = "ADD"
    sum2.inputs["Factor"].default_value = 1.0
    links.new(sum1.outputs[2], sum2.inputs[6])
    links.new(points.outputs[0], sum2.inputs[7])
    links.new(sum2.outputs[2], emit.inputs["Color"])
    wrap(tree, emit.outputs[0])
    mat["bsdf"] = emit.name
    return mat


HEAD_PARTS = []
# The box: wood, as deep as a real head, behind its face
HEAD_PARTS.append(panel("head", -HEAD_W / 2, -10, HEAD_W / 2, HEAD_H + 10, -230, 0, MAT["wood"]))
HEAD_PARTS.append(face_tube("headTrim", [(-HEAD_W / 2, -10), (HEAD_W / 2, -10), (HEAD_W / 2, HEAD_H + 10),
                                         (-HEAD_W / 2, HEAD_H + 10)], 1, 3.5, MAT["chrome"]))
# The speaker panel: black, the display's window in its middle, a speaker each side with a lit ring
grille = material("grille", (0.012, 0.012, 0.015), metallic=0.5, rough=0.7)
speaker_panel = material("speakerPanel", (0.004, 0.0035, 0.005), rough=0.6)
HEAD_PARTS.append(panel("speakerPanel", -HEAD_W / 2 + 14, 8, HEAD_W / 2 - 14, 150, 0, 4, speaker_panel))
dmd_glass = material("dmdGlass", (0.003, 0.002, 0.002), rough=0.9)
HEAD_PARTS.append(panel("dmdWindow", DMD[0], DMD[1], DMD[2], DMD[3], 4, 4.6, dmd_glass))
HEAD_PARTS.append(face_tube("dmdBezel", [(DMD[0] - 6, DMD[1] - 6), (DMD[2] + 6, DMD[1] - 6), (DMD[2] + 6, DMD[3] + 6),
                                         (DMD[0] - 6, DMD[3] + 6)], 5, 2.6, MAT["gold"]))
for side, u in (("Left", -212), ("Right", 212)):
    ring = [(u + 46 * math.cos(2 * math.pi * k / 40), 79 + 46 * math.sin(2 * math.pi * k / 40)) for k in range(40)]
    disc = bmesh.new()
    verts = [disc.verts.new(at(*face(a, b, 4.3))) for a, b in ring]
    disc.faces.new(verts)
    HEAD_PARTS.append(mesh_object(f"speaker{side}", disc, grille))
    for r in (14, 26, 38):
        face_tube(f"speaker{side}Grille{r}", [(u + r * math.cos(2 * math.pi * k / 32), 79 + r * math.sin(2 * math.pi * k / 32))
                                              for k in range(32)], 4.6, 0.8, MAT["steel"])
    colour = rgb("purple")
    glow = material(f"speaker{side}Glass", tuple(0.6 + 0.4 * c for c in colour), rough=0.1, transmission=0.6, coat=1.0,
                    emission=colour, strength=0.0)
    HEAD_PARTS.append(face_tube(f"speaker{side}Ring", ring, 6, 3.2, glow))
    light = bpy.data.lights.new(f"speaker{side}Light", "POINT")
    light.color = colour
    light.shadow_soft_size = 20 * MM
    light.energy = 0
    bulb = bpy.data.objects.new(f"speaker{side}Light", light)
    bulb.location = at(*face(u, 79, 30))
    collection.objects.link(bulb)
    fx, fy, fz = face(u, 79)
    FLASHERS[f"speaker{side}"] = {"material": glow, "light": bulb, "x": fx, "y": fy, "z": fz - 70, "lift": 140, "reach": 80}
# The backglass over the speakers, lit from behind: the table's name in gold, and the moon
HEAD_PARTS.append(panel("backglass", -HEAD_W / 2 + 14, 164, HEAD_W / 2 - 14, HEAD_H - 6, 0, 3, backglass_material(), uv=True))
HEAD_PARTS.append(face_tube("backglassTrim", [(-HEAD_W / 2 + 14, 164), (HEAD_W / 2 - 14, 164), (HEAD_W / 2 - 14, HEAD_H - 6),
                                              (-HEAD_W / 2 + 14, HEAD_H - 6)], 3.5, 2.2, MAT["gold"]))
moon_mat = material("glassMoon", (0.9, 0.92, 1.0), emission=(0.85, 0.9, 1.0), strength=2.5)
# The moon: a crescent, the bright disc less a disc beside it
MOON, SHADE = (-205, 247, 44), (-188, 257, 40)
crescent = []
for k in range(96):
    t = 2 * math.pi * k / 96
    u, v = MOON[0] + MOON[2] * math.cos(t), MOON[1] + MOON[2] * math.sin(t)
    if math.hypot(u - SHADE[0], v - SHADE[1]) >= SHADE[2]:
        crescent.append((u, v, t))
# From where the bright edge comes out of the shade round to where it goes back in, then back along
# the shade's edge inside the moon
start = max(range(len(crescent)), key=lambda i: (crescent[(i + 1) % len(crescent)][2] - crescent[i][2]) % (2 * math.pi))
crescent = crescent[start + 1:] + crescent[:start + 1]
inner = []
for k in range(96):
    t = 2 * math.pi * k / 96
    u, v = SHADE[0] + SHADE[2] * math.cos(t), SHADE[1] + SHADE[2] * math.sin(t)
    if math.hypot(u - MOON[0], v - MOON[1]) < MOON[2]:
        inner.append((u, v, t))
last = crescent[-1]
# The shade's edge inside the moon in order round it, begun at the end nearer the crescent's last point
inner.sort(key=lambda q: math.atan2(q[1] - SHADE[1], q[0] - SHADE[0]))
gap = max(range(len(inner)), key=lambda i: (inner[(i + 1) % len(inner)][2] - inner[i][2]) % (2 * math.pi))
inner = inner[gap + 1:] + inner[:gap + 1]
if math.dist(inner[-1][:2], last[:2]) < math.dist(inner[0][:2], last[:2]):
    inner.reverse()
outline = [(u, v) for u, v, _ in crescent] + [(u, v) for u, v, _ in inner]
moon_bm = bmesh.new()
moon_bm.faces.new([moon_bm.verts.new(at(*face(u, v, 3.4))) for u, v in outline])
HEAD_PARTS.append(mesh_object("backglassMoon", moon_bm, moon_mat))
title_mat = material("title", (1.0, 0.66, 0.22), metallic=0.3, rough=0.35, emission=(1.0, 0.62, 0.2), strength=0.7)
for words, v, size, extrude, u in (("MOONGLADE", 252, 64, 6, 30), ("~ a pinball table ~", 196, 18, 1, 30)):
    curve = bpy.data.curves.new(words, "FONT")
    curve.body = words
    curve.size = size * MM
    curve.align_x, curve.align_y = "CENTER", "CENTER"
    curve.extrude = extrude * MM
    curve.bevel_depth = extrude / 3 * MM
    if SCENE["fonts"]["title"]:
        curve.font = font(SCENE["fonts"]["title"])
    curve.materials.append(title_mat)
    obj = bpy.data.objects.new(words, curve)
    obj.location = at(*face(u, v, 4 + extrude))
    # Lying on the face: turned up from flat by the face's lean from flat
    obj.rotation_euler = (math.pi / 2 - LEAN, 0, 0)
    HEAD_PARTS.append(link(obj))
under = bpy.data.curves.new("speakerName", "FONT")
under.body = "FOREVER GAMES"
under.size = 11 * MM
under.align_x, under.align_y = "CENTER", "CENTER"
if SCENE["fonts"]["label"]:
    under.font = font(SCENE["fonts"]["label"])
under.materials.append(material("speakerInk", (0.95, 0.75, 0.3), metallic=0.6, rough=0.3))
obj = bpy.data.objects.new("speakerName", under)
obj.location = at(*face(0, 22, 4.3))
obj.rotation_euler = (math.pi / 2 - LEAN, 0, 0)
HEAD_PARTS.append(link(obj))

# The flipper buttons out of the cabinet's sides near the front, and the start button on its front,
# which lights up to say a game can be started
for side, x in (("Left", -SIDE_RAIL), ("Right", W + SIDE_RAIL)):
    out = -1 if side == "Left" else 1
    knob = cylinder(f"flipperButton{side}", x + out * 6, H - 70, 9, -6, 6, MAT["redPlastic"], 24)
    knob.rotation_euler.y = math.pi / 2
    knob.location = at(x + out * 6, H - 70, 26)
    bezel = cylinder(f"flipperBezel{side}", x + out * 1.5, H - 70, 12, -1.5, 1.5, MAT["chrome"], 24)
    bezel.rotation_euler.y = math.pi / 2
    bezel.location = at(x + out * 1.5, H - 70, 26)
    HEAD_PARTS += [knob, bezel]
start_colour = rgb("gold")
start_glass = material("startGlass", tuple(0.5 + 0.5 * c for c in start_colour), rough=0.15, transmission=0.5, coat=1.0,
                       emission=start_colour, strength=0.0)
start_button = cylinder("startButton", 60, H + 46, 10, -5, 5, start_glass, 24)
start_button.rotation_euler.x = math.pi / 2
start_button.location = at(60, H + 45, 26)
start_bezel = cylinder("startBezel", 60, H + 41, 13, -1, 1, MAT["chrome"], 24)
start_bezel.rotation_euler.x = math.pi / 2
start_bezel.location = at(60, H + 41, 26)
HEAD_PARTS += [start_button, start_bezel]
light = bpy.data.lights.new("startLight", "POINT")
light.color = start_colour
light.shadow_soft_size = 8 * MM
light.energy = 0
bulb = bpy.data.objects.new("startLight", light)
bulb.location = at(60, H + 62, 30)
collection.objects.link(bulb)
FLASHERS["start"] = {"material": start_glass, "light": bulb, "x": 60, "y": H + 46, "z": 0, "lift": 50, "reach": 40}
CABINET_PARTS += HEAD_PARTS

#############################
# What moves
#############################

def paddle_outline(length, base, tip, steps=14):
    """A flipper lying along +x from where it turns, round at both ends"""
    s = (base - tip) / length
    a = math.asin(max(-1, min(1, s)))
    pts = []
    for k in range(steps + 1):
        t = math.pi / 2 + a + (math.pi - 2 * a) * k / steps
        pts.append((base * math.cos(t), -base * math.sin(t)))
    for k in range(steps + 1):
        t = -math.pi / 2 - a + (math.pi + 2 * a) * k / steps
        pts.append((length + tip * math.cos(t), -tip * math.sin(t)))
    return pts


flippers = {}
for s in shapes:
    if s["kind"] != "paddle":
        continue
    name = s["name"]
    outline_pts = paddle_outline(s["length"], s["base"] - 2.2, s["tip"] - 2.2)
    flat = [c for x, y in outline_pts for c in (s["x"] + x, s["y"] + y)]
    body = prism(f"{name}Body", flat, 1, 21, MAT["ivory"], kind="mover", key="flippers", origin=(s["x"], s["y"]))
    band = paddle_outline(s["length"], s["base"] - 1.6, s["tip"] - 1.6, 20)
    rubber = tube(f"{name}Rubber", [(s["x"] + x, s["y"] + y, 10) for x, y in band], 1.8, MAT["redRubber"], kind="mover",
                  key="flippers", closed=True)
    rubber.location = at(s["x"], s["y"])
    for point in rubber.data.splines[0].points:
        point.co = (point.co[0] - s["x"] * MM, point.co[1] + s["y"] * MM, point.co[2], 1)
    cap = cylinder(f"{name}Cap", s["x"], s["y"], 4.2, 21, 23, MAT["gold"], 20, kind="mover", key="flippers")
    flippers[name] = {"shape": s, "parts": [body, rubber]}


def place_paddle(name, angle):
    for part in flippers[name]["parts"]:
        part.rotation_euler.z = -angle


# Drop targets, the centre post, the spinner's blade, the plunger
targets = {}
for s in shapes:
    if s.get("role") == "target":
        p = s["points"]
        targets[s["name"]] = [slab(f"{s['name']}Body", p[0], p[1] + 1, p[2], p[3] - 1, 6, 0, 30, MAT["targetRed"], kind="mover",
                                   key="targets"),
                              slab(f"{s['name']}Face", p[0] + 3.2, p[1] + 2, p[2] + 3.2, p[3] - 2, 0.6, 4, 27, MAT["ivory"],
                                   kind="mover", key="targets")]
centre_post = next(s for s in shapes if s.get("name") == "centerPost")
post_parts = [cylinder("centrePost", centre_post["x"], centre_post["y"], 2.6, 0, 30, MAT["chrome"], 20, kind="mover", key="post"),
              torus("centrePostRubber", centre_post["x"], centre_post["y"], 11, centre_post["r"] - 1.7, 1.8, MAT["rubber"],
                    kind="mover", key="post")]
sx, sy = (spinner[0] + spinner[2]) / 2, spinner[1]
blade = prism("spinnerBlade", [spinner[0] + 6, sy - 0.8, spinner[2] - 6, sy - 0.8, spinner[2] - 6, sy + 0.8, spinner[0] + 6, sy + 0.8],
              SPINNER_Z - 20, SPINNER_Z, MAT["steel"], kind="mover", key="spinner")
emblem = prism("spinnerEmblem", [sx - 6, sy - 1.0, sx + 6, sy - 1.0, sx + 6, sy + 1.0, sx - 6, sy + 1.0], SPINNER_Z - 16,
               SPINNER_Z - 4, MAT["gold"], kind="mover", key="spinner")
for part in (blade, emblem):
    # Turning about the axle, which runs across the lane
    part.location = at(0, 0, 0)
    mesh = part.data
    for v in mesh.vertices:
        v.co.z -= SPINNER_Z * MM
        v.co.y += sy * MM
        v.co.x -= sx * MM
    part.location = at(sx, sy, SPINNER_Z)
start = T["start"]
plunger_parts = [
    cylinder("plungerTip", start[0], 0, 8.5, 0, 9, MAT["blackRubber"], 24, kind="mover", key="plunger"),
    cylinder("plungerRod", start[0], 0, 2.8, 0, 60, MAT["chrome"], 16, kind="mover", key="plunger"),
]
for part, (y0, y1) in zip(plunger_parts, ((1000, 1009), (1009, 1069))):
    part.rotation_euler.x = math.pi / 2
    part.location = at(start[0], (y0 + y1) / 2, BALL)


def place_plunger(pull):
    for part, (y0, y1) in zip(plunger_parts, ((1000, 1009), (1009, 1069))):
        part.location = at(start[0], (y0 + y1) / 2 + pull * PLUNGER_TRAVEL, BALL)


def place_spinner(angle):
    blade.rotation_euler.x = angle
    emblem.rotation_euler.x = angle


ball = sphere("ball", 238, 700, BALL, BALL, MAT["chrome"], kind="mover", key="ball")
ball.hide_render = True
for group in MOVERS.values():
    for part in group:
        part.hide_render = True

#############################
# Light
#############################

world = bpy.data.worlds.new("world")
scene.world = world
world.use_nodes = True
background = world.node_tree.nodes["Background"]
sky = world.node_tree.nodes.new("ShaderNodeTexSky") if False else None
# A dark room with a bright band above, for the chrome to have something to show
coords = world.node_tree.nodes.new("ShaderNodeTexCoord")
separate = world.node_tree.nodes.new("ShaderNodeSeparateXYZ")
world.node_tree.links.new(coords.outputs["Generated"], separate.inputs[0])
ramp_node = world.node_tree.nodes.new("ShaderNodeValToRGB")
ramp_node.color_ramp.elements[0].position = 0.42
ramp_node.color_ramp.elements[0].color = (0.05, 0.045, 0.05, 1)
ramp_node.color_ramp.elements[1].position = 0.95
ramp_node.color_ramp.elements[1].color = (0.12, 0.115, 0.11, 1)
world.node_tree.links.new(separate.outputs["Z"], ramp_node.inputs[0])
world.node_tree.links.new(ramp_node.outputs[0], background.inputs["Color"])
# Dim as light on the table, brighter as what the chrome and the ball show of the room round them
path_node = world.node_tree.nodes.new("ShaderNodeLightPath")
strength = world.node_tree.nodes.new("ShaderNodeMapRange")
strength.inputs["To Min"].default_value = 0.6
strength.inputs["To Max"].default_value = 4.0
world.node_tree.links.new(path_node.outputs["Is Glossy Ray"], strength.inputs["Value"])
world.node_tree.links.new(strength.outputs["Result"], background.inputs["Strength"])


def area(name, x, y, z, size_x, size_y, energy, colour=(1, 0.93, 0.82)):
    light = bpy.data.lights.new(name, "AREA")
    light.shape = "RECTANGLE"
    light.size, light.size_y = size_x * MM, size_y * MM
    light.energy = energy
    light.color = colour
    obj = bpy.data.objects.new(name, light)
    obj.location = at(x, y, z)
    collection.objects.link(obj)
    return obj


# How bright the table's own light is: what a playfield lit by it comes out as in the picture
LIGHT = SCENE.get("light", 1.6)
# The light over the table, soft and warm, and the cabinet's own bulbs along its sides
area("over", T["middle"], 560, 1100, 1300, 1900, LIGHT * 8.5).data.shape = "ELLIPSE"
area("back", T["middle"], -200, 500, 600, 150, LIGHT * 0.8, (0.85, 0.9, 1.0)).rotation_euler.x = math.radians(-35)
# The cabinet's bulbs: long warm strips along its walls, shining in across the playfield
for x, turn in ((20, -1), (456, 1)):
    strip = area(f"gi{x}", x, 560, 70, 14, 820, LIGHT * 0.25, (1.0, 0.8, 0.55))
    strip.rotation_euler.y = math.radians(35) * turn

#############################
# The camera
#############################

camera_data = bpy.data.cameras.new("camera")
camera_data.sensor_fit = "HORIZONTAL"
camera_data.sensor_width = 36
camera_data.lens = SCENE.get("lens", 60)
camera = bpy.data.objects.new("camera", camera_data)
collection.objects.link(camera)
scene.camera = camera
# The corners of everything that must be in the picture: the cabinet, its buttons, and the backbox
bounds = [at(x, y, z) for x in (-40, W + 40) for y in (-24, H + 50) for z in (0, CABINET + 8)]
bounds += [at(*face(u, v, 6)) for u in (-HEAD_W / 2 - 6, HEAD_W / 2 + 6) for v in (-14, HEAD_H + 14)]


def frame_camera():
    """Looks down the table at PITCH degrees from flat, from as far back as makes the table fill
    the picture, then sizes the picture to the table and zooms and shifts the lens to fill it"""
    pitch = math.radians(PITCH)
    camera.rotation_euler = (math.pi / 2 - pitch, 0, 0)
    target = at(W / 2, H * 0.52, 0)
    forward = Vector((0, math.cos(pitch), -math.sin(pitch)))
    render = scene.render
    render.resolution_x = render.resolution_y = 1000
    camera_data.shift_x = camera_data.shift_y = 0

    def measure():
        bpy.context.view_layer.update()
        seen = [world_to_camera_view(scene, camera, p) for p in bounds]
        return min(p.x for p in seen), max(p.x for p in seen), min(p.y for p in seen), max(p.y for p in seen)

    distance = 2.0
    for _ in range(25):
        camera.location = target - forward * distance
        x0, x1, y0, y1 = measure()
        distance *= max(x1 - x0, y1 - y0) / 0.9
    x0, x1, y0, y1 = measure()
    aspect = (x1 - x0) / (y1 - y0)
    if aspect <= 1:
        camera_data.sensor_fit = "VERTICAL"
        camera_data.sensor_height = camera_data.sensor_width
        render.resolution_y, render.resolution_x = SIDE, int(SIDE * aspect) // 2 * 2
        camera_data.lens *= 0.985 / (y1 - y0)
    else:
        render.resolution_x, render.resolution_y = SIDE, int(SIDE / aspect) // 2 * 2
        camera_data.lens *= 0.985 / (x1 - x0)
    rx, ry = render.resolution_x, render.resolution_y
    # How far the middle of the table moves for a shift of the lens, found by trying it, which
    # spares knowing what the shift is measured against
    for axis in ("shift_x", "shift_y"):
        for _ in range(6):
            x0, x1, y0, y1 = measure()
            centre = (x0 + x1) / 2 if axis == "shift_x" else (y0 + y1) / 2
            setattr(camera_data, axis, getattr(camera_data, axis) + 0.01)
            x0, x1, y0, y1 = measure()
            moved = ((x0 + x1) / 2 if axis == "shift_x" else (y0 + y1) / 2) - centre
            setattr(camera_data, axis, getattr(camera_data, axis) - 0.01 - (centre - 0.5) * 0.01 / moved)
    x0, x1, y0, y1 = measure()
    say("framed", rx, "x", ry, "spans", round(x0, 3), round(x1, 3), round(y0, 3), round(y1, 3))


frame_camera()
RX, RY = scene.render.resolution_x, scene.render.resolution_y


def project(x, y, z=0.0):
    p = world_to_camera_view(scene, camera, at(x, y, z))
    return p.x * RX, (1 - p.y) * RY, p.z


def solve_camera():
    """The matrix that takes a point of the table to the picture's pixels, found from points
    projected the way Blender does it, whatever its own conventions"""
    rows, rhs = [], []
    samples = [(x, y, z) for x in (0, 150, 300, 512) for y in (0, 300, 650, 1024) for z in (0, 40, 90)]
    for x, y, z in samples:
        u, v, depth = project(x, y, z)
        rows.append([x, y, z, 1, 0, 0, 0, 0, -u * x, -u * y, -u * z])
        rhs.append(u)
        rows.append([0, 0, 0, 0, x, y, z, 1, -v * x, -v * y, -v * z])
        rhs.append(v)
    solution, *_ = np.linalg.lstsq(np.array(rows), np.array(rhs), rcond=None)
    p = list(solution) + [1.0]
    m = np.array(p).reshape(3, 4)
    # Scaled so that w is the distance from the camera, in mm, along its view
    x, y, z = 238, 600, 0
    _, _, depth = project(x, y, z)
    w = m[2] @ np.array([x, y, z, 1])
    m *= (depth / MM) / w
    error = 0
    for x, y, z in samples:
        u, v, _ = project(x, y, z)
        q = m @ np.array([x, y, z, 1])
        error = max(error, abs(q[0] / q[2] - u), abs(q[1] / q[2] - v))
    say("camera matrix error", round(error, 4), "px")
    return m


P = solve_camera()


def to_pixel(x, y, z=0.0):
    q = P @ np.array([x, y, z, 1.0])
    return q[0] / q[2], q[1] / q[2], q[2]


#############################
# Rendering
#############################

render = scene.render
render.engine = "CYCLES"
prefs = bpy.context.preferences.addons["cycles"].preferences
for kind in ("OPTIX", "CUDA", "HIP", "ONEAPI"):
    try:
        prefs.compute_device_type = kind
        prefs.get_devices()
        if any(d.type == kind for d in prefs.devices):
            for d in prefs.devices:
                d.use = d.type == kind
            scene.cycles.device = "GPU"
            say("rendering on", kind)
            break
    except TypeError:
        continue
scene.cycles.samples = SAMPLES
scene.cycles.use_adaptive_sampling = False
scene.cycles.seed = 0
scene.cycles.use_denoising = True
scene.cycles.denoiser = "OPENIMAGEDENOISE"
scene.cycles.max_bounces = 8
scene.cycles.transmission_bounces = 8
scene.cycles.film_transparent_glass = True
render.use_persistent_data = True
render.image_settings.file_format = "PNG"
render.image_settings.color_mode = "RGBA"
render.image_settings.color_depth = "8"
scene.view_settings.view_transform = "Standard"
scene.view_settings.look = "None"
scene.view_settings.exposure = SCENE.get("exposure", 0.0)

WORK = os.path.join(OUT, "work")
os.makedirs(WORK, exist_ok=True)


def shot(name, transparent=False, border=None, samples=None):
    """Renders the scene as it is now; returns it as rows of 0-1 RGBA, top row first"""
    render.film_transparent = transparent
    scene.cycles.samples = samples or SAMPLES
    if border:
        left, top, right, bottom = border
        render.use_border, render.use_crop_to_border = True, False
        render.border_min_x, render.border_max_x = max(0, left / RX), min(1, right / RX)
        render.border_min_y, render.border_max_y = max(0, 1 - bottom / RY), min(1, 1 - top / RY)
    else:
        render.use_border = False
    path = os.path.join(WORK, name + ".png")
    render.filepath = path
    bpy.ops.render.render(write_still=True)
    image = bpy.data.images.load(path)
    image.colorspace_settings.name = "Non-Color"
    pixels = np.empty(len(image.pixels), dtype=np.float32)
    image.pixels.foreach_get(pixels)
    bpy.data.images.remove(image)
    say("rendered", name)
    rows = pixels.reshape(RY, RX, 4)[::-1].copy()
    if transparent:
        # The faint speckle a render leaves where there is nothing is cleared, so that what is cut
        # out of it is only as big as what is there
        faint = rows[:, :, 3] < 0.03
        rows[faint] = 0
    return rows


def show(objects, shown):
    for obj in objects:
        obj.hide_render = not shown


def camera_only(objects, seen):
    """Whether the camera sees them, and whether their shadows fall: unseen, they are still in
    reflections, but cast no shadow for the playfield to catch, which is to have only the shadows
    of what moves"""
    for obj in objects:
        if not seen and "shadow" not in obj:
            obj["shadow"] = obj.visible_shadow
        obj.visible_camera = seen
        obj.visible_shadow = obj.get("shadow", True) if seen else False


def write_tga(path, rgba):
    """0-255 rows top first, as a 32 bit TGA with its rows bottom to top as the client reads them"""
    height, width = rgba.shape[:2]
    header = bytes([0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, width & 255, width >> 8, height & 255, height >> 8, 32, 8])
    bgra = rgba[::-1][:, :, [2, 1, 0, 3]]
    with open(path, "wb") as out:
        out.write(header + np.ascontiguousarray(bgra).tobytes())


def to_bytes(rows):
    return (np.clip(rows, 0, 1) * 255 + 0.5).astype(np.uint8)


def pow2(n):
    return 1 << max(4, (int(n) - 1).bit_length())


FILES = {}


def save(name, rows):
    """Writes a picture into a texture with sides a power of two, at its top left corner"""
    height, width = rows.shape[:2]
    canvas = np.zeros((pow2(height), pow2(width), 4), dtype=np.uint8)
    canvas[:height, :width] = to_bytes(rows) if rows.dtype != np.uint8 else rows
    write_tga(os.path.join(OUT, name + ".tga"), canvas)
    FILES[name] = {"w": canvas.shape[1], "h": canvas.shape[0]}
    return canvas


SPRITES = []


def sprite(rows, left, top, scale=1.0, key=None):
    """Keeps a piece of a picture to be packed into an atlas: where it goes on the background"""
    entry = {"rows": rows, "u": left, "v": top, "pw": rows.shape[1] / scale, "ph": rows.shape[0] / scale, "key": key}
    SPRITES.append(entry)
    return entry


def crop_alpha(rows, margin=2):
    alpha = rows[:, :, 3]
    ys, xs = np.nonzero(alpha > 0.004)
    if len(xs) == 0:
        return None
    left, right = max(0, xs.min() - margin), min(RX, xs.max() + 1 + margin)
    top, bottom = max(0, ys.min() - margin), min(RY, ys.max() + 1 + margin)
    return rows[top:bottom, left:right], left, top


def region(x, y, reach, z=0.0, lift=0.0):
    """A box round a circle of the table, in the picture's px"""
    us, vs = [], []
    for k in range(16):
        a = 2 * math.pi * k / 16
        for zz in (z, z + lift):
            u, v, _ = to_pixel(x + reach * math.cos(a), y + reach * math.sin(a), zz)
            us.append(u)
            vs.append(v)
    return (max(0, int(min(us)) - 2), max(0, int(min(vs)) - 2), min(RX, int(max(us)) + 3), min(RY, int(max(vs)) + 3))


def bloom(rows, radius):
    """The glow round a light, as a camera sees it: the light spread out a little and added back"""
    if radius < 1:
        return rows
    k = np.exp(-np.linspace(-2.5, 2.5, 2 * radius + 1) ** 2)
    k /= k.sum()
    out = rows.copy()
    for c in range(3):
        channel = rows[:, :, c]
        blurred = np.apply_along_axis(lambda m: np.convolve(m, k, mode="same"), 0, channel)
        blurred = np.apply_along_axis(lambda m: np.convolve(m, k, mode="same"), 1, blurred)
        out[:, :, c] = channel + blurred * 0.5
    return out


def feather(rows, part=0.22):
    """A light's picture faded out towards its sides, so that where it is cut off doesn't show"""
    h, w = rows.shape[:2]
    ys = np.minimum(np.arange(h), np.arange(h)[::-1]) / max(1, h * part)
    xs = np.minimum(np.arange(w), np.arange(w)[::-1]) / max(1, w * part)
    fade = np.clip(np.minimum(ys[:, None], xs[None, :]), 0, 1)
    fade = fade * fade * (3 - 2 * fade)
    rows = rows.copy()
    rows[:, :, :3] *= fade[:, :, None]
    return rows


tilt = {}

# The background
background_rows = shot("background")
save("tiltBackground", background_rows)
tilt["background"] = "tiltBackground"
tilt["crop"] = [0, 0, RX, RY]

if "--look" in ARGS:
    say("look only: background rendered", RX, "x", RY)
    sys.exit(0)

# What stands above a ball, at each height of OVER, but for the cabinet's walls round the outside
# and the backbox, which no ball is ever behind. Each cut into tiles, only those with something in
# them kept
OVER_TILE = 128
scene["overMode"] = 1.0
show(CABINET_PARTS, False)
over_layers = []
for number, height in enumerate(OVER):
    scene["overHeight"] = height * MM
    over = shot(f"over{number}", transparent=True)
    over_layers.append(over)
    for top in range(0, RY, OVER_TILE):
        for left in range(0, RX, OVER_TILE):
            tile = over[top:top + OVER_TILE, left:left + OVER_TILE]
            if tile[:, :, 3].max() > 0:
                sprite(tile, left, top, 1.0, f"over{number}")
show(CABINET_PARTS, True)
scene["overMode"] = 0.0
scene["overHeight"] = OVER[0] * MM
over_rows = over_layers[0]


def light_up(entry, on, strength):
    bsdf_of(entry["material"]).inputs["Emission Strength"].default_value = strength if on else 0.0
    entry["light"].data.energy = entry.get("energy", 0.06) if on else 0.0


def batches(entries, apart):
    """Lights in groups, each far enough from the others in its group that their light doesn't mix"""
    left = list(entries.items())
    groups = []
    while left:
        group, rest = [], []
        for name, entry in left:
            if all(math.hypot(entry["x"] - other["x"], entry["y"] - other["y"]) > entry["r"] + other["r"] + apart
                   for _, other in group):
                group.append((name, entry))
            else:
                rest.append((name, entry))
        groups.append(group)
        left = rest
    return groups


def lit(entries, label, strength, key, scale=1.0, glow=4):
    base = background_rows[:, :, :3]
    for number, group in enumerate(batches(entries, 10)):
        for _, entry in group:
            light_up(entry, True, strength)
        rows = shot(f"{label}{number}")
        for _, entry in group:
            light_up(entry, False, strength)
        difference = np.clip(rows[:, :, :3] - base, 0, None)
        difference[difference < 3 / 255] = 0
        for name, entry in group:
            left, top, right, bottom = region(entry["x"], entry["y"], entry["r"], 0, entry.get("lift", 0))
            piece = feather(bloom(difference[top:bottom, left:right], glow), 0.15)
            alpha = np.ones(piece.shape[:2] + (1,), dtype=np.float32)
            rgba = np.concatenate([np.clip(piece, 0, 1), alpha], axis=2)
            if scale != 1.0:
                step = int(round(1 / scale))
                rgba = rgba[::step, ::step]
            entry_sprite = sprite(rgba, left, top, scale, key)
            entry_sprite["name"] = name
    say(label, "done")


for entry in LAMPS.values():
    entry["energy"] = 0.0004
lit(LAMPS, "lamps", 0.85, "lamps")
for entry in BUMPERS.values():
    entry["energy"] = 0.06
    entry["lift"] = 45
lit(BUMPERS, "bumpers", 2.5, "bumpers", glow=6)
for name, entry in FLASHERS.items():
    small = "reach" in entry
    entry["energy"] = 0.15 if small else 3.0
    entry["r"] = entry.get("reach", 260)
    lift = entry.get("lift", 90)
    light_up(entry, True, 6.0 if small else 18.0)
    rows = shot(f"flash_{name}")
    light_up(entry, False, 6.0 if small else 18.0)
    difference = np.clip(rows[:, :, :3] - background_rows[:, :, :3], 0, None)
    difference[difference < 4 / 255] = 0
    # Only round the dome: its light is soft, so a third as many pixels carry it
    left, top, right, bottom = region(entry["x"], entry["y"], entry["r"] + 60, entry.get("z", 0), lift + 10)
    piece = feather(bloom(difference[top:bottom, left:right], 8), 0.3)
    rgba = np.concatenate([np.clip(piece, 0, 1), np.ones(piece.shape[:2] + (1,), dtype=np.float32)], axis=2)[::3, ::3]
    sprite(rgba, left, top, 1 / 3, "flashers")["name"] = name

# What moves, rendered alone over the playfield, which catches its shadow and nothing else: the
# rest of the table is taken out of the picture altogether, from the camera, from shadows, from
# reflections and from the light it would throw about, so that all that is left is what moves,
# lit by the table's lights, and its shadow, see-through round it


def alone(objects, on):
    """Takes things out of the picture altogether, or puts them back as they were"""
    for obj in objects:
        if not on and "shadow" not in obj:
            obj["shadow"] = obj.visible_shadow
        obj.visible_camera = obj.visible_diffuse = on
        obj.visible_shadow = obj.get("shadow", True) if on else False
        obj.visible_glossy = obj.visible_transmission = obj.visible_volume_scatter = on


def widen(box, by=24):
    return (max(0, box[0] - by), max(0, box[1] - by), min(RX, box[2] + by), min(RY, box[3] + by))


alone(STATIC, False)
alone([playfield], True)
playfield.is_shadow_catcher = True
for group in ("flippers", "spinner", "plunger"):
    show(MOVERS[group], True)
for frame in range(FRAMES):
    boxes = []
    for name, flipper in flippers.items():
        s = flipper["shape"]
        angle = s["rest"] + (s["up"] - s["rest"]) * frame / (FRAMES - 1)
        place_paddle(name, angle)
        boxes.append(region(s["x"], s["y"], s["length"] + s["base"] + 6, 0, 24))
    show(MOVERS["spinner"], frame < SPINNER_FRAMES)
    if frame < SPINNER_FRAMES:
        place_spinner(math.pi * frame / SPINNER_FRAMES)
        boxes.append(region(sx, sy, 30, 0, SPINNER_Z + 6))
    show(MOVERS["plunger"], frame < PLUNGER_FRAMES)
    if frame < PLUNGER_FRAMES:
        place_plunger(frame / (PLUNGER_FRAMES - 1))
        boxes.append(region(start[0], 1040, 50, 0, 30))
    border = widen((min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes)))
    rows = shot(f"movers{frame}", transparent=True, border=border)

    def cut(box):
        left, top, right, bottom = box
        found = crop_alpha(rows[top:bottom, left:right])
        if not found:
            return None
        piece, l, t = found
        return piece, left + l, top + t

    for name, flipper in flippers.items():
        s = flipper["shape"]
        piece = cut(region(s["x"], s["y"], s["length"] + s["base"] + 6, 0, 24))
        angle = s["rest"] + (s["up"] - s["rest"]) * frame / (FRAMES - 1)
        if not piece:
            continue
        entry = sprite(piece[0], piece[1], piece[2], 1.0, "flippers")
        entry["name"], entry["angle"] = name, angle
    if frame < SPINNER_FRAMES:
        piece = cut(region(sx, sy, 30, 0, SPINNER_Z + 6)) or (np.zeros((2, 2, 4), np.float32), 0, 0)
        entry = sprite(piece[0], piece[1], piece[2], 1.0, "spinner")
        entry["angle"] = math.pi * frame / SPINNER_FRAMES
    if frame < PLUNGER_FRAMES:
        piece = cut(region(start[0], 1040, 50, 0, 30))
        entry = sprite(piece[0], piece[1], piece[2], 1.0, "plunger")
        entry["pull"] = frame / (PLUNGER_FRAMES - 1)
# The drop targets and the centre post up, on their own: the upper flipper is beside the targets
show(MOVERS["flippers"] + MOVERS["spinner"] + MOVERS["plunger"], False)
show(MOVERS["targets"] + MOVERS["post"], True)
boxes = [region(66, 505, 60, 0, 34), region(centre_post["x"], centre_post["y"], 20, 0, 32)]
border = widen((min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes)))
rows = shot("targets", transparent=True, border=border)
for name, parts in targets.items():
    s = next(t for t in shapes if t.get("name") == name)
    p = s["points"]
    piece = cut(region((p[0] + p[2]) / 2, (p[1] + p[3]) / 2, 20, 0, 34))
    sprite(piece[0], piece[1], piece[2], 1.0, "targets")["name"] = name
piece = cut(region(centre_post["x"], centre_post["y"], 14, 0, 32))
sprite(piece[0], piece[1], piece[2], 1.0, "post")
show(MOVERS["flippers"] + MOVERS["spinner"] + MOVERS["plunger"] + MOVERS["targets"] + MOVERS["post"], False)

# The ball, alone; and its shadow, the ball unseen but still in the light
playfield.is_shadow_catcher = False
alone(STATIC, True)
BALL_AT = (238, 700)
ball.location = at(BALL_AT[0], BALL_AT[1], BALL)
ball.hide_render = False
camera_only(STATIC, False)
box = region(BALL_AT[0], BALL_AT[1], BALL + 4, 0, BALL * 2 + 2)
rows = shot("ball", transparent=True, border=box)
piece, left, top = crop_alpha(rows[box[1]:box[3], box[0]:box[2]])
left, top = left + box[0], top + box[1]
u, v, _ = to_pixel(BALL_AT[0], BALL_AT[1], BALL)
across = abs(to_pixel(BALL_AT[0] + BALL, BALL_AT[1], BALL)[0] - to_pixel(BALL_AT[0] - BALL, BALL_AT[1], BALL)[0])
ball_entry = sprite(piece, left, top, 1.0, "ball")
ball_entry["mm"] = 2 * BALL * piece.shape[1] / across
ball_entry["ax"], ball_entry["ay"] = u - left, v - top
alone(STATIC, False)
alone([playfield], True)
playfield.is_shadow_catcher = True
ball.visible_camera = False
box = widen(region(BALL_AT[0] + 10, BALL_AT[1] + 10, 40, 0, 0))
rows = shot("shadow", transparent=True, border=box)
piece, left, top = crop_alpha(rows[box[1]:box[3], box[0]:box[2]])
left, top = left + box[0], top + box[1]
floor_u, floor_v, _ = to_pixel(BALL_AT[0], BALL_AT[1], 0)
shadow_entry = sprite(piece, left, top, 1.0, "shadow")
shadow_entry["mm"] = 2 * BALL * piece.shape[1] / across
shadow_entry["ax"], shadow_entry["ay"] = floor_u - left, floor_v - top
ball.hide_render = True
ball.visible_camera = True
playfield.is_shadow_catcher = False
alone(STATIC, True)


#############################
# Packing
#############################

def pack(entries, prefix):
    """Shelves of sprites, tallest first, into atlases SIDE across"""
    order = sorted(range(len(entries)), key=lambda i: -entries[i]["rows"].shape[0])
    pages, page, x, y, shelf = [], None, 0, 0, 0
    for i in order:
        rows = entries[i]["rows"]
        h, w = rows.shape[:2]
        if page is None or x + w + 2 > SIDE:
            x, y, shelf = 0, y + shelf + 2, 0
        if page is None or y + h > SIDE:
            page = np.zeros((SIDE, SIDE, 4), dtype=np.uint8)
            pages.append(page)
            x, y, shelf = 0, 0, 0
        page[y:y + h, x:x + w] = to_bytes(rows)
        entries[i]["file"] = f"{prefix}{len(pages)}"
        entries[i]["x"], entries[i]["y"], entries[i]["w"], entries[i]["h"] = x, y, w, h
        x += w + 2
        shelf = max(shelf, h)
    for number, page in enumerate(pages, 1):
        used = np.nonzero(page[:, :, 3].any(axis=1) | page[:, :, :3].any(axis=(1, 2)))[0]
        height = pow2(used.max() + 1) if len(used) else 16
        save(f"{prefix}{number}", page[:height])


pack(SPRITES, "tiltAtlas")


def placed(entry, extra=()):
    out = {"file": entry["file"], "x": entry["x"], "y": entry["y"], "w": entry["w"], "h": entry["h"],
           "u": round(float(entry["u"]), 2), "v": round(float(entry["v"]), 2),
           "pw": round(float(entry["pw"]), 2), "ph": round(float(entry["ph"]), 2)}
    for key in extra:
        out[key] = round(float(entry[key]), 4)
    return out


tilt["over"] = [{"height": height, "tiles": [placed(e) for e in SPRITES if e["key"] == f"over{number}"]}
                for number, height in enumerate(OVER)]
tilt["lamps"] = {e["name"]: placed(e) for e in SPRITES if e["key"] == "lamps"}
tilt["bumpers"] = {e["name"]: placed(e) for e in SPRITES if e["key"] == "bumpers"}
tilt["flashers"] = {e["name"]: placed(e) for e in SPRITES if e["key"] == "flashers"}
tilt["flippers"] = {}
for e in SPRITES:
    if e["key"] == "flippers":
        tilt["flippers"].setdefault(e["name"], {"frames": []})["frames"].append(placed(e, ("angle",)))
tilt["targets"] = {e["name"]: placed(e) for e in SPRITES if e["key"] == "targets"}
tilt["post"] = next(placed(e) for e in SPRITES if e["key"] == "post")
tilt["spinner"] = {"frames": [placed(e, ("angle",)) for e in SPRITES if e["key"] == "spinner"]}
tilt["plunger"] = {"frames": [placed(e, ("pull",)) for e in SPRITES if e["key"] == "plunger"]}
for key in ("ball", "shadow"):
    e = next(e for e in SPRITES if e["key"] == key)
    tilt[key] = {"file": e["file"], "x": e["x"], "y": e["y"], "w": e["w"], "h": e["h"], "mm": round(e["mm"], 3),
                 "ax": round(float(e["ax"]), 2), "ay": round(float(e["ay"]), 2)}
tilt["camera"] = [round(float(c), 9) for c in P.flatten()]
q = P @ np.array([238, 600, BALL, 1.0])
left_u = (P @ np.array([238 - BALL, 600, BALL, 1.0]))
right_u = (P @ np.array([238 + BALL, 600, BALL, 1.0]))
tilt["ballPx"] = round(float(abs(right_u[0] / right_u[2] - left_u[0] / left_u[2]) * q[2]), 4)
tilt["pitch"] = PITCH
tilt["lens"] = camera_data.lens

#############################
# A look at it all together
#############################

def preview():
    """The background with lamps lit, a flasher, the flippers, a target and the post up, and balls
    on the playfield, under the ramp and on it, put together the way the bench draws them"""
    canvas = background_rows[:, :, :3].copy()

    def find(key, name=None, frame=None):
        found = [e for e in SPRITES if e["key"] == key and (name is None or e.get("name") == name)]
        return found[frame] if frame is not None else found[0]

    def add(entry):
        rows = entry["rows"][:, :, :3]
        step = int(round(entry["pw"] / rows.shape[1]))
        if step > 1:
            rows = rows.repeat(step, axis=0).repeat(step, axis=1)
        u, v = int(entry["u"]), int(entry["v"])
        h, w = min(rows.shape[0], RY - v), min(rows.shape[1], RX - u)
        canvas[v:v + h, u:u + w] += rows[:h, :w]

    def over_at(rows, u, v):
        u, v = int(round(u)), int(round(v))
        h, w = min(rows.shape[0], RY - v), min(rows.shape[1], RX - u)
        a = rows[:h, :w, 3:4]
        canvas[v:v + h, u:u + w] = canvas[v:v + h, u:u + w] * (1 - a) + rows[:h, :w, :3] * a

    def resized(rows, scale):
        h, w = max(1, int(rows.shape[0] * scale)), max(1, int(rows.shape[1] * scale))
        ys = np.minimum((np.arange(h) / scale).astype(int), rows.shape[0] - 1)
        xs = np.minimum((np.arange(w) / scale).astype(int), rows.shape[1] - 1)
        return rows[ys][:, xs]

    ball_sprite, shadow_sprite = find("ball"), find("shadow")
    w0 = to_pixel(BALL_AT[0], BALL_AT[1], BALL)[2]

    def ball_at(x, y, z):
        u, v, w = to_pixel(x, y, z)
        scale = w0 / w
        fu, fv, _ = to_pixel(x, y, z - BALL)
        shadow = resized(shadow_sprite["rows"], scale)
        over_at(shadow, fu - shadow_sprite["ax"] * scale, fv - shadow_sprite["ay"] * scale)
        rows = resized(ball_sprite["rows"], scale)
        over_at(rows, u - ball_sprite["ax"] * scale, v - ball_sprite["ay"] * scale)

    for name in list(LAMPS)[::2]:
        add(find("lamps", name))
    add(find("bumpers", "bumper2"))
    add(find("flashers", "flashRamp"))
    for name in flippers:
        frames = [e for e in SPRITES if e["key"] == "flippers" and e["name"] == name]
        entry = frames[-1] if name != "rightFlipper" else frames[0]
        over_at(entry["rows"], entry["u"], entry["v"])
    for key in ("targets", "post"):
        entry = find(key)
        over_at(entry["rows"], entry["u"], entry["v"])
    entry = find("spinner")
    over_at(entry["rows"], entry["u"], entry["v"])
    entry = find("plunger")
    over_at(entry["rows"], entry["u"], entry["v"])
    ball_at(200, 820, BALL)
    ball_at(390, 420, BALL)
    ball_at(300, 260, BALL)
    over_at(over_rows, 0, 0)
    ball_at(359, 380, ramp_height(359, 380) + BALL)
    for rail, points, _ in WIRE_POINTS:
        x, y, z = points[len(points) // 3]
        ball_at(x, y, z + BALL)
    rgba = np.concatenate([np.clip(canvas, 0, 1), np.ones((RY, RX, 1), np.float32)], axis=2)
    write_tga(os.path.join(WORK, "preview.tga"), to_bytes(rgba))
    say("preview written")


if "--preview" in ARGS:
    preview()

# Where the score display's glass is in the background: its face looks straight at the camera,
# so it is an oblong there
corners = [to_pixel(*face(u, v, 4.6)) for u in (DMD[0], DMD[2]) for v in (DMD[1], DMD[3])]
tilt["dmd"] = [round(float(min(c[0] for c in corners)), 1), round(float(min(c[1] for c in corners)), 1),
               round(float(max(c[0] for c in corners)), 1), round(float(max(c[1] for c in corners)), 1)]
say("display at", tilt["dmd"])
tilt["files"] = FILES
json.dump(tilt, open(os.path.join(OUT, "tilt.json"), "w"), indent=1)
say("done", RX, "x", RY)
