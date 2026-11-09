"""Check user-drawn zone polylines against the plan linework and against each other.

Input: an export from export-geometry.ps1 (xref curves + host polylines with handles/layers).
Per polyline: closure, vertices, true arcs, area, validity, tiny segments, and how much of the outline lies
on plan linework (<= ON_TOL) with the longest off-linework runs. Per pair: overlap and shared edge length,
plus narrow gaps (< GAP) between neighbours.
"""
import json, math, sys
from collections import defaultdict
from pathlib import Path
from shapely.geometry import Polygon
from shapely.strtree import STRtree
from shapely.validation import explain_validity
sys.path.insert(0, str(Path(__file__).parent))
from geom import load, curve_geom

ON_TOL, GAP = 20.0, 1000.0
g = load(sys.argv[1]); names = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8-sig"))   # file: {"handle": "label"}
X = [(e, curve_geom(e)) for e in g["xref"]]; X = [(e, c) for e, c in X if c is not None and c.length > 1]
tree = STRtree([c for _, c in X])
polys = {}
for z in g["host"]:
    label = names.get(z["h"], z["h"]); ring = curve_geom(z); poly = Polygon(ring.coords); polys[label] = poly
    pts = z["pts"]; arcs = sum(1 for p in pts if abs(p[2]) > 1e-9)
    short = [(i, round(math.hypot(pts[(i + 1) % len(pts)][0] - pts[i][0], pts[(i + 1) % len(pts)][1] - pts[i][1]))) for i in range(len(pts))]
    print(f"\n== {label} ({z['h']}, {z['layer']})")
    print(f"   closed={z['closed']}  vertices={len(pts)}  arcs={arcs}  perimeter={ring.length / 1000:.1f} m  area={poly.area / 1e6:.1f} m2  valid={poly.is_valid}"
          + ("" if poly.is_valid else f" ({explain_validity(poly)})"))
    tiny = [s for s in short if s[1] < 50]
    if tiny: print(f"   segments under 50 mm (vertex, length): {tiny}")
    L = ring.length; n = int(L / 100); layers = defaultdict(float); runs = []; cur = None
    for i in range(n):
        p = ring.interpolate(i * L / n)
        best = min(((X[j][1].distance(p), X[j][0]["layer"]) for j in tree.query(p.buffer(ON_TOL + 5))), default=(1e9, None))
        if best[0] <= ON_TOL:
            layers[best[1]] += L / n
            if cur: runs.append(cur); cur = None
        else:
            far = min((X[j][1].distance(p) for j in tree.query(p.buffer(1500))), default=None)
            if cur is None: cur = {"a": p.coords[0], "b": p.coords[0], "len": 0.0, "max": 0.0}
            cur["b"] = p.coords[0]; cur["len"] += L / n; cur["max"] = max(cur["max"], far if far is not None else 1500)
    if cur: runs.append(cur)
    off = sum(r["len"] for r in runs)
    print(f"   on plan linework (<= {ON_TOL:.0f} mm): {(L - off) / L:.1%}   off: {off / 1000:.2f} m in {len(runs)} runs")
    for l, v in sorted(layers.items(), key=lambda t: -t[1])[:5]: print(f"      {v / 1000:6.1f} m on {l}")
    for r in sorted(runs, key=lambda r: -r["len"])[:6]:
        print(f"      off {r['len'] / 1000:5.2f} m (up to {r['max']:.0f} mm from a plan line)  {r['a'][0]:.0f},{r['a'][1]:.0f} -> {r['b'][0]:.0f},{r['b'][1]:.0f}")
labels = list(polys)
for i, a in enumerate(labels):
    for b in labels[i + 1:]:
        A, B = polys[a], polys[b]
        if not A.buffer(GAP).intersects(B): continue
        inner = (A.contains(B) or B.contains(A))
        ov = A.intersection(B).area / 1e6
        shared = A.exterior.intersection(B.exterior.buffer(ON_TOL)).length / 1000
        gap = A.buffer(GAP / 2).intersection(B.buffer(GAP / 2)).difference(A).difference(B)
        gap_area = gap.area / 1e6
        note = " (one inside the other: island)" if inner else ""
        print(f"\n-- {a} / {b}{note}: overlap {ov:.2f} m2, shared edge {shared:.1f} m, gap strip between them {gap_area:.2f} m2")

