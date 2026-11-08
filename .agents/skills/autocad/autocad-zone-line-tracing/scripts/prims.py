"""Geometric primitives (line segments and arcs) from exported AutoCAD curves, polyline bulges included."""
import math
from shapely.geometry import LineString
from geom import arc_pts

prims = []   # {"kind": "line", "a", "b", "geom"} | {"kind": "arc", "c", "r", "geom"}

def add_line(p, q):
    if math.hypot(q[0] - p[0], q[1] - p[1]) > 1:
        prims.append({"kind": "line", "a": tuple(p), "b": tuple(q), "geom": LineString([p, q])})

def add_arc(c, r, a0, a1):
    prims.append({"kind": "arc", "c": tuple(c), "r": r, "geom": LineString(arc_pts(c[0], c[1], r, a0, a1, step=math.radians(2)))})

def add_bulge(p, q, b):
    if abs(b) < 1e-9 or math.hypot(q[0] - p[0], q[1] - p[1]) < 1e-6:
        return add_line(p, q)
    theta = 4 * math.atan(b); dx, dy = q[0] - p[0], q[1] - p[1]; chord = math.hypot(dx, dy)
    r = chord / (2 * math.sin(theta / 2)); d = r * math.cos(theta / 2)
    cx, cy = (p[0] + q[0]) / 2 - dy / chord * d, (p[1] + q[1]) / 2 + dx / chord * d
    a0, a1 = math.atan2(p[1] - cy, p[0] - cx), math.atan2(q[1] - cy, q[0] - cx)
    add_arc((cx, cy), abs(r), a0, a1) if b > 0 else add_arc((cx, cy), abs(r), a1, a0)

def add_entity(e):
    t = e["t"]
    if t == "line": add_line(tuple(e["a"]), tuple(e["b"]))
    elif t == "arc": add_arc(tuple(e["c"]), e["r"], e["sa"], e["ea"])
    elif t == "circle": add_arc(tuple(e["c"]), e["r"], 0, 2 * math.pi - 1e-6)
    elif t == "pline":
        pts = e["pts"]; n = len(pts)
        for i in range(n if e["closed"] else n - 1):
            p, q = pts[i], pts[(i + 1) % n]; add_bulge((p[0], p[1]), (q[0], q[1]), p[2])
