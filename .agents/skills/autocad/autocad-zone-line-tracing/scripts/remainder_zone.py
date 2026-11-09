"""Remainder zone = space outline minus the user's finished zones, rebuilt as a polyline with true arcs.

Usage: remainder_zone.py <export.json> <config.json> <out.json>
config: {"route_layer": "...|AO-WALL-UNFOLD-REF", "close_with": [[x, y], ...],
         "zones": ["handle", ...],            # finished zones (user-drawn), subtracted from the space
         "keep_near": [x, y]}                 # optional: choose the remainder piece containing this point
The space is the room-facing wall route closed through `close_with` points (e.g. an entrance line).
Arcs are rebuilt only from the source linework (user polylines, route, closing lines), never from other plan
lines, so nearby circles cannot masquerade as edges. Writes {"rings": [[x, y, bulge], ...], "area_m2": ..}.
"""
import json, math, sys
from pathlib import Path
from shapely.geometry import Polygon, Point, LineString
from shapely.strtree import STRtree
sys.path.insert(0, str(Path(__file__).parent))
from geom import load, curve_geom
import prims as zs                # primitive helpers: add_entity, add_line, prims

g = load(sys.argv[1]); cfg = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8-sig")); out = Path(sys.argv[3])
host = {z["h"]: z for z in g["host"]}
route_e = next(e for e in g["xref"] if e["layer"] == cfg["route_layer"])
route = curve_geom(route_e)
closing = [tuple(p) for p in cfg["close_with"]]
space = Polygon(list(route.coords) + closing).buffer(0)
rest = space
for h in cfg["zones"]:
    rest = rest.difference(Polygon(curve_geom(host[h]).coords).buffer(0))
pieces = sorted(getattr(rest, "geoms", [rest]), key=lambda p: -p.area)
if cfg.get("keep_near"):
    pt = Point(cfg["keep_near"]); pieces.sort(key=lambda p: p.distance(pt))
zone = pieces[0]
print(f"space {space.area / 1e6:.1f} m2; remainder {zone.area / 1e6:.1f} m2; dropped {len(pieces) - 1} sliver pieces totalling {sum(p.area for p in pieces[1:]) / 1e6:.2f} m2")

zs.prims.clear()
for h in cfg["zones"]: zs.add_entity(host[h])
zs.add_entity(route_e)
pts = [route.coords[-1]] + closing + [route.coords[0]]
for a, b in zip(pts, pts[1:]): zs.add_line(tuple(a), tuple(b))
P = zs.prims; tree = STRtree([p["geom"] for p in P])

def source(a, b):
    m = Point((a[0] + b[0]) / 2, (a[1] + b[1]) / 2); best = None
    for j in tree.query(m.buffer(8)):
        d = P[j]["geom"].distance(m)
        if d < 8 and (best is None or d < best[0]): best = (d, j)
    return None if best is None else best[1]

def rebuild(ring):
    pts = list(ring.coords)[:-1]; n = len(pts); src = [source(pts[i], pts[(i + 1) % n]) for i in range(n)]
    k = next((i for i in range(n) if src[i] != src[i - 1]), 0); pts, src = pts[k:] + pts[:k], src[k:] + src[:k]
    res, i = [], 0
    while i < n:
        j = i
        while j + 1 < n and src[j + 1] == src[i]: j += 1
        a, b = pts[i], pts[(j + 1) % n]; s = src[i]
        if s is not None and P[s]["kind"] == "arc":
            c = P[s]["c"]; ang = [math.atan2(q[1] - c[1], q[0] - c[0]) for q in pts[i:j + 1] + [b]]
            sweep = sum((ang[t + 1] - ang[t] + math.pi) % (2 * math.pi) - math.pi for t in range(len(ang) - 1))
            res.append((a[0], a[1], math.tan(sweep / 4)))
        elif s is None:
            run = LineString(pts[i:j + 2] if j + 1 < n else pts[i:] + [pts[0]]).simplify(20)
            res.extend((x, y, 0.0) for x, y in list(run.coords)[:-1])
        else:
            res.append((a[0], a[1], 0.0))
        i = j + 1
    return [v for t, v in enumerate(res) if math.hypot(v[0] - res[t - 1][0], v[1] - res[t - 1][1]) > 2]

rings = [rebuild(zone.exterior)] + [rebuild(h) for h in zone.interiors if Polygon(h).area > 1e6]
arcs = [sum(1 for v in r if abs(v[2]) > 1e-9) for r in rings]
out.write_text(json.dumps({"rings": rings, "area_m2": round(zone.area / 1e6, 1)}))
print(f"rings {len(rings)}  vertices {[len(r) for r in rings]}  arcs {arcs}  -> {out.name}")

