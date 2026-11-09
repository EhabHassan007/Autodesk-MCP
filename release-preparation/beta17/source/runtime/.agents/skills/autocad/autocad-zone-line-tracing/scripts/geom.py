"""Shared helpers: turn exported AutoCAD curves (lines, arcs, circles, bulged polylines) into shapely geometry."""
import json, math
from shapely.geometry import LineString, Polygon, Point

def arc_pts(cx, cy, r, a0, a1, step=math.radians(3)):
    if a1 < a0:
        a1 += 2 * math.pi
    n = max(2, int((a1 - a0) / step) + 1)
    return [(cx + r * math.cos(a0 + (a1 - a0) * i / (n - 1)), cy + r * math.sin(a0 + (a1 - a0) * i / (n - 1))) for i in range(n)]

def bulge_pts(p, q, b):
    """points of a polyline segment p->q with bulge b (tan of 1/4 included angle)"""
    if abs(b) < 1e-9 or math.hypot(q[0] - p[0], q[1] - p[1]) < 1e-6:   # straight or zero-length segment
        return [p, q]
    theta = 4 * math.atan(b); dx, dy = q[0] - p[0], q[1] - p[1]; chord = math.hypot(dx, dy)
    r = chord / (2 * math.sin(theta / 2)); mx, my = (p[0] + q[0]) / 2, (p[1] + q[1]) / 2
    d = r * math.cos(theta / 2); nx, ny = -dy / chord, dx / chord
    cx, cy = mx + nx * d, my + ny * d
    a0, a1 = math.atan2(p[1] - cy, p[0] - cx), math.atan2(q[1] - cy, q[0] - cx)
    r = abs(r)
    pts = arc_pts(cx, cy, r, a0, a1) if b > 0 else arc_pts(cx, cy, r, a1, a0)[::-1]
    pts[0], pts[-1] = p, q
    return pts

def curve_geom(e):
    t = e["t"]
    if t == "line":
        return LineString([e["a"], e["b"]])
    if t == "arc":
        return LineString(arc_pts(e["c"][0], e["c"][1], e["r"], e["sa"], e["ea"]))
    if t == "circle":
        return LineString(arc_pts(e["c"][0], e["c"][1], e["r"], 0, 2 * math.pi - 1e-6))
    if t == "pline":
        pts = e["pts"]; n = len(pts); out = []
        segs = n if e["closed"] else n - 1
        for i in range(segs):
            p, q = pts[i], pts[(i + 1) % n]
            seg = bulge_pts((p[0], p[1]), (q[0], q[1]), p[2])
            out.extend(seg if not out else seg[1:])
        return LineString(out) if len(out) > 1 else None

def load(path):
    return json.loads(open(path, encoding="utf-8-sig").read())
