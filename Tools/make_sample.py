#!/usr/bin/env python3
"""Generates Samples/sample-plates.3mf: a Bambu-style multi-plate, multi-color 3MF
made of procedural shapes (no third-party models)."""
import json, math, os, zipfile

BED = 256.0
GAP = BED * 1.2

def lathe(profile, seg=64):
    """profile: list of (r, z) from bottom to top. Returns verts, tris (closed)."""
    v, t = [], []
    for r, z in profile:
        for i in range(seg):
            a = 2 * math.pi * i / seg
            v.append((r * math.cos(a), r * math.sin(a), z))
    n = len(profile)
    for j in range(n - 1):
        for i in range(seg):
            a, b = j * seg + i, j * seg + (i + 1) % seg
            c, d = a + seg, b + seg
            t += [(a, b, d), (a, d, c)]
    bot = len(v); v.append((0, 0, profile[0][1]))
    top = len(v); v.append((0, 0, profile[-1][1]))
    for i in range(seg):
        t.append((bot, (i + 1) % seg, i))
        o = (n - 1) * seg
        t.append((top, o + i, o + (i + 1) % seg))
    return v, t

def box(sx, sy, sz, r=0):
    x, y = sx / 2, sy / 2
    v = [(-x, -y, 0), (x, -y, 0), (x, y, 0), (-x, y, 0), (-x, -y, sz), (x, -y, sz), (x, y, sz), (-x, y, sz)]
    t = [(0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4),
         (1, 2, 6), (1, 6, 5), (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7)]
    return v, t

def torus(R, r, seg=72, side=32, z0=0):
    v, t = [], []
    for i in range(seg):
        a = 2 * math.pi * i / seg
        for j in range(side):
            b = 2 * math.pi * j / side
            v.append(((R + r * math.cos(b)) * math.cos(a), (R + r * math.cos(b)) * math.sin(a), z0 + r + r * math.sin(b)))
    for i in range(seg):
        for j in range(side):
            a = i * side + j; b = ((i + 1) % seg) * side + j
            c = ((i + 1) % seg) * side + (j + 1) % side; d = i * side + (j + 1) % side
            t += [(a, b, c), (a, c, d)]
    return v, t

def gear(teeth=14, r=28, depth=4, h=8, hole=6, seg_per=6):
    outer = []
    n = teeth * seg_per
    for i in range(n):
        a = 2 * math.pi * i / n
        phase = (i % seg_per) / seg_per
        rr = r + (depth if 0.15 < phase < 0.6 else 0)
        outer.append((rr * math.cos(a), rr * math.sin(a)))
    inner = [(hole * math.cos(2 * math.pi * i / n), hole * math.sin(2 * math.pi * i / n)) for i in range(n)]
    v = [(x, y, 0) for x, y in outer] + [(x, y, h) for x, y in outer] + \
        [(x, y, 0) for x, y in inner] + [(x, y, h) for x, y in inner]
    O0, O1, I0, I1 = 0, n, 2 * n, 3 * n
    t = []
    for i in range(n):
        k = (i + 1) % n
        t += [(O0 + i, O0 + k, O1 + k), (O0 + i, O1 + k, O1 + i)]       # outer wall
        t += [(I0 + i, I1 + k, I0 + k), (I0 + i, I1 + i, I1 + k)]       # hole wall
        t += [(O1 + i, O1 + k, I1 + k), (O1 + i, I1 + k, I1 + i)]       # top ring
        t += [(O0 + i, I0 + k, O0 + k), (O0 + i, I0 + i, I0 + k)]       # bottom ring
    return v, t

def translate(mesh, dx, dy, dz=0):
    v, t = mesh
    return [(x + dx, y + dy, z + dz) for x, y, z in v], t

vase = lathe([(22, 0), (26, 10), (30, 35), (24, 70), (14, 95), (16, 110), (18, 112)], 96)
plates = [
    ("Spiral vase", [("Vase", [(vase, 2)])]),
    ("Gear set", [("Large gear", [(gear(18, 34, 5, 10, 8), 1)]),
                  ("Small gear", [(translate(gear(10, 18, 4, 10, 5), 62, 0), 3)])]),
    ("Two-tone coaster", [("Coaster", [(box(90, 90, 3), 4), (translate(torus(30, 4), 0, 0, 3), 2)])]),
    ("Calibration", [("Cube", [(box(20, 20, 20), 1)]), ("Ring", [(translate(torus(14, 5), 40, 0), 3)]),
                     ("Tower", [(translate(box(12, 12, 60), -40, 0), 4)])]),
]
colors = ["#E8E3D9", "#E5533D", "#2F6FDE", "#2BA36B"]

def mesh_xml(v, t):
    out = ["<mesh><vertices>"]
    out += [f'<vertex x="{x:.4f}" y="{y:.4f}" z="{z:.4f}"/>' for x, y, z in v]
    out.append("</vertices><triangles>")
    out += [f'<triangle v1="{a}" v2="{b}" v3="{c}"/>' for a, b, c in t]
    out.append("</triangles></mesh>")
    return "".join(out)

objs, items, settings = [], [], ["<?xml version='1.0' encoding='utf-8'?><config>"]
oid = 1
cols = 2
for pi, (pname, objects) in enumerate(plates):
    ox = (pi % cols) * GAP + BED / 2
    oy = -(pi // cols) * GAP + BED / 2
    settings.append(f'<plate><metadata key="plater_id" value="{pi + 1}"/><metadata key="plater_name" value="{pname}"/>')
    obj_xml = []
    for k, (oname, parts) in enumerate(objects):
        comp_ids, part_xml = [], []
        for mesh, ext in parts:
            objs.append(f'<object id="{oid}" type="model" name="{oname}">{mesh_xml(*mesh)}</object>')
            comp_ids.append(oid)
            part_xml.append(f'<part id="{oid}" subtype="normal_part"><metadata key="extruder" value="{ext}"/></part>')
            oid += 1
        parent = oid; oid += 1
        objs.append(f'<object id="{parent}" type="model" name="{oname}"><components>' +
                    "".join(f'<component objectid="{c}"/>' for c in comp_ids) + "</components></object>")
        dx = (k - (len(objects) - 1) / 2) * 20 if len(objects) > 1 else 0
        items.append(f'<item objectid="{parent}" transform="1 0 0 0 1 0 0 0 1 {ox + dx:.3f} {oy:.3f} 0" printable="1"/>')
        settings.append(f'<model_instance><metadata key="object_id" value="{parent}"/></model_instance>')
        obj_xml.append(f'<object id="{parent}"><metadata key="name" value="{oname}"/>'
                       f'<metadata key="extruder" value="{parts[0][1]}"/>{"".join(part_xml)}</object>')
    settings.append("</plate>")
    settings += obj_xml
settings.append("</config>")

model = ('<?xml version="1.0" encoding="UTF-8"?><model unit="millimeter" xml:lang="en-US" '
         'xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">'
         '<metadata name="Title">Sample Shapes</metadata><metadata name="Designer">3MF Preview</metadata>'
         f'<resources>{"".join(objs)}</resources><build>{"".join(items)}</build></model>')
project = {"printer_model": "Bambu Lab X1 Carbon", "nozzle_diameter": ["0.4"], "layer_height": "0.2",
           "sparse_infill_density": "15%", "filament_type": ["PLA", "PLA", "PETG", "PLA"],
           "filament_colour": colors, "printable_area": ["0x0", "256x0", "256x256", "0x256"]}

out = os.path.join(os.path.dirname(__file__), "..", "Samples", "sample-plates.3mf")
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("[Content_Types].xml", '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>')
    z.writestr("_rels/.rels", '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>')
    z.writestr("3D/3dmodel.model", model)
    z.writestr("Metadata/model_settings.config", "".join(settings))
    z.writestr("Metadata/project_settings.config", json.dumps(project))
print("wrote", os.path.normpath(out))
