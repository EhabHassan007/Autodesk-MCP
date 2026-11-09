"""One-call zone tool core (used by zone.ps1).

  zone_tool.py check     <export.json> <cfg.json>
  zone_tool.py remainder <export.json> <cfg.json> <out.json>
  zone_tool.py snap      <export.json> <cfg.json> <out.json>

export.json: xref curves + host polylines (with layer) from export-geometry.ps1.
cfg.json: {"route_layer": "...", "close_with": [[x, y], ...], "target": "ZONE-X", "sketch_layer": "SKETCH",
           "near": [x, y] (optional), "snap_tol": 150}
Output is short on purpose: one line per zone plus a summary.
"""
import json, math, sys
from pathlib import Path
from shapely.geometry import Polygon, Point, LineString
from shapely.ops import unary_union
from shapely.strtree import STRtree
sys.path.insert(0, str(Path(__file__).parent))
from geom import load, curve_geom
import prims as pr

mode, g, cfg = sys.argv[1], load(sys.argv[2]), json.loads(Path(sys.argv[3]).read_text(encoding="utf-8-sig"))
OUT = Path(sys.argv[4]) if len(sys.argv) > 4 else None
zones = [z for z in g["host"] if z["layer"].upper().startswith("ZONE-") and z["closed"]]
X = [(e, curve_geom(e)) for e in g["xref"]]; X = [(e, c) for e, c in X if c is not None and c.length > 1]
xtree = STRtree([c for _, c in X])

def poly(z): return Polygon(curve_geom(z).coords).buffer(0)

def space():
    r = next((e for e in g["xref"] if e["layer"] == cfg.get("route_layer")), None)
    if r is None: return None, None
    return Polygon(list(curve_geom(r).coords) + [tuple(p) for p in cfg.get("close_with", [])]).buffer(0), r

def on_linework(z):
    ring = curve_geom(z); n = max(1, int(ring.length / 200)); on = 0
    for i in range(n):
        p = ring.interpolate(i * ring.length / n)
        if any(X[j][1].distance(p) <= 20 for j in xtree.query(p.buffer(25))): on += 1
    return on / n

def write(rings, area):
    OUT.write_text(json.dumps({"rings": rings, "area_m2": round(area / 1e6, 1)}))

if mode == "check":
    P = {z["h"]: poly(z) for z in zones}
    for z in zones:
        arcs = sum(1 for p in z["pts"] if abs(p[2]) > 1e-9)
        print(f"{z['layer']:22s} {z['h']}  {P[z['h']].area / 1e6:7.1f} m2  v={len(z['pts']):3d} arcs={arcs:2d}  on-plan {on_linework(z):5.1%}  valid={P[z['h']].is_valid}")
    hs = list(P); ov = []
    for i, a in enumerate(hs):
        for b in hs[i + 1:]:
            if P[a].contains(P[b]) or P[b].contains(P[a]): continue           # islands (e.g. track infield)
            o = P[a].intersection(P[b]).area / 1e6
            if o > 0.05: ov.append(f"{a}/{b} {o:.2f} m2")
    print("overlaps > 0.05 m2:", ", ".join(ov) if ov else "none")
    sp, _ = space()
    if sp is not None:
        outer = [P[h] for h in hs if not any(P[k].contains(P[h]) for k in hs if k != h)]
        left = sp.difference(unary_union(outer)); parts = list(getattr(left, "geoms", [left]))
        big = [p for p in parts if 2 * p.area / p.length > 300]
        print(f"unzoned in space: {left.area / 1e6:.2f} m2 ({len(parts)} pieces); real gaps (> 300 mm wide): "
              + (", ".join(f"{p.area / 1e6:.2f} m2 near {p.centroid.x:.0f},{p.centroid.y:.0f}" for p in big) or "none"))

elif mode in ("remainder", "snap"):
    pr.prims.clear()
    def rebuild(ring):
        P = pr.prims; t = STRtree([p["geom"] for p in P])
        def src(a, b):
            m = Point((a[0] + b[0]) / 2, (a[1] + b[1]) / 2); best = None
            for j in t.query(m.buffer(8)):
                d = P[j]["geom"].distance(m)
                if d < 8 and (best is None or d < best[0]): best = (d, j)
            return None if best is None else best[1]
        pts = list(ring.coords)[:-1]; n = len(pts); s = [src(pts[i], pts[(i + 1) % n]) for i in range(n)]
        k = next((i for i in range(n) if s[i] != s[i - 1]), 0); pts, s = pts[k:] + pts[:k], s[k:] + s[:k]
        res, i = [], 0
        while i < n:
            j = i
            while j + 1 < n and s[j + 1] == s[i]: j += 1
            a, b = pts[i], pts[(j + 1) % n]
            if s[i] is not None and P[s[i]]["kind"] == "arc":
                c = P[s[i]]["c"]; ang = [math.atan2(q[1] - c[1], q[0] - c[0]) for q in pts[i:j + 1] + [b]]
                sw = sum((ang[u + 1] - ang[u] + math.pi) % (2 * math.pi) - math.pi for u in range(len(ang) - 1))
                res.append((a[0], a[1], math.tan(sw / 4)))
            elif s[i] is None:
                run = LineString(pts[i:j + 2] if j + 1 < n else pts[i:] + [pts[0]]).simplify(20)
                res.extend((x, y, 0.0) for x, y in list(run.coords)[:-1])
            else:
                res.append((a[0], a[1], 0.0))
            i = j + 1
        return [v for u, v in enumerate(res) if math.hypot(v[0] - res[u - 1][0], v[1] - res[u - 1][1]) > 2]

    if mode == "remainder":
        sp, route_e = space()
        if sp is None: sys.exit("no route layer found for the space outline")
        others = [z for z in zones if z["layer"].upper() != cfg["target"].upper()]
        rest = sp
        for z in others: rest = rest.difference(poly(z))
        parts = sorted(getattr(rest, "geoms", [rest]), key=lambda p: -p.area)
        if cfg.get("near"): parts.sort(key=lambda p: p.distance(Point(cfg["near"])))
        zone = parts[0]
        for z in others: pr.add_entity(z)
        pr.add_entity(route_e)
        cw = [tuple(curve_geom(route_e).coords[-1])] + [tuple(p) for p in cfg.get("close_with", [])] + [tuple(curve_geom(route_e).coords[0])]
        for a, b in zip(cw, cw[1:]): pr.add_line(a, b)
        rings = [rebuild(zone.exterior)] + [rebuild(h) for h in zone.interiors if Polygon(h).area > 1e6]
        write(rings, zone.area)
        print(f"remainder {cfg['target']}: {zone.area / 1e6:.1f} m2, vertices {len(rings[0])}, arcs {sum(1 for v in rings[0] if abs(v[2]) > 1e-9)}; slivers dropped {sum(p.area for p in parts[1:]) / 1e6:.2f} m2")

    else:   # snap: rough sketch corners -> nearest real plan corner (line intersection / zone vertex) within tol
        sk = [z for z in g["host"] if z["layer"].upper() == cfg.get("sketch_layer", "SKETCH").upper()]
        if not sk: sys.exit("no polyline on the sketch layer")
        sk = max(sk, key=lambda z: poly(z).area); tol = float(cfg.get("snap_tol", 150))
        for e, c in X: pr.add_entity(e)
        for z in zones: pr.add_entity(z)
        P = pr.prims; t = STRtree([p["geom"] for p in P])
        cands, how = [], []
        for x, y, _ in sk["pts"]:
            p = Point(x, y); near = [P[j]["geom"] for j in t.query(p.buffer(tol)) if P[j]["geom"].distance(p) <= tol]
            corners = []
            for i, a in enumerate(near):
                for b in near[i + 1:]:
                    it = a.intersection(b)
                    for q in getattr(it, "geoms", [it]):
                        if q.geom_type == "Point" and q.distance(p) <= tol: corners.append((q.x, q.y))
                for q in (a.coords[0], a.coords[-1]):
                    if Point(q).distance(p) <= tol: corners.append(tuple(q))
            # corners that only exist on extended lines (e.g. a column face meeting a wall face)
            lin = [l for l in near if len(l.coords) == 2]
            for i, a in enumerate(lin):
                (x1, y1), (x2, y2) = a.coords
                for b in lin[i + 1:]:
                    (x3, y3), (x4, y4) = b.coords
                    den = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
                    if abs(den) < 1e-6 * a.length * b.length: continue
                    tt = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / den
                    q = (x1 + tt * (x2 - x1), y1 + tt * (y2 - y1))
                    if Point(q).distance(p) <= tol: corners.append(q)
            corners = sorted(set((round(c[0], 1), round(c[1], 1)) for c in corners), key=lambda c: Point(c).distance(p))[:8]
            if corners: cands.append(corners); how.append("corner")
            elif near:
                a = min(near, key=lambda a: a.distance(p)); q = a.interpolate(a.project(p)); cands.append([(q.x, q.y)]); how.append("line")
            else: cands.append([(x, y)]); how.append("free")
        # double walls make the nearest corner ambiguous: per vertex keep the candidate whose two adjacent
        # edges lie most on plan lines (a wrong-face corner makes edges cut across the wall); ties -> nearest
        def on_plan(a, b):
            seg = LineString([a, b]); n = max(2, int(seg.length / 250))
            pts = [seg.interpolate(k / n, normalized=True) for k in range(1, n)]
            return sum(1 for q in pts if any(P[j]["geom"].distance(q) <= 20 for j in t.query(q.buffer(25)))) / len(pts)
        # ties (both faces of a double wall are plan lines) go to the candidate towards the sketch's inside,
        # because zones stop at room-facing faces
        skp = [Point(x, y) for x, y, _ in sk["pts"]]
        snapped = [c[0] for c in cands]; m = len(snapped)
        # neighbouring corners on a double wall only switch face together, so optimise corner pairs jointly
        for _ in range(3):
            for i in range(m):
                j = (i + 1) % m; a0, b1 = snapped[i - 1], snapped[(j + 1) % m]
                best = max(((ci, cj) for ci in cands[i] for cj in cands[j]),
                           key=lambda pr2: (round(on_plan(a0, pr2[0]) + on_plan(pr2[0], pr2[1]) + on_plan(pr2[1], b1), 1),
                                            -(Point(pr2[0]).distance(skp[i]) + Point(pr2[1]).distance(skp[j]))))   # tie -> nearest to the clicks
                snapped[i], snapped[j] = best
        zone = Polygon(snapped).buffer(0)
        ring = [(x, y, 0.0) for x, y in snapped]
        write([ring], zone.area)
        moved = [(k, round(Point(s).distance(skp[k]))) for k, s in enumerate(snapped) if Point(s).distance(skp[k]) > 80]
        print(f"snap {cfg['target']}: {zone.area / 1e6:.1f} m2 from {len(ring)} corners "
              f"({how.count('corner')} on plan corners, {how.count('line')} on a line, {how.count('free')} not snapped)"
              + (f"; check corners moved > 80 mm (index, mm): {moved}" if moved else "; all corners within 80 mm of your clicks"))


