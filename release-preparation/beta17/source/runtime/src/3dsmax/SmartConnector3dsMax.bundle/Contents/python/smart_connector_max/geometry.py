"""Mesh sections and file helpers for the 3ds Max bridge. Pure Python (no 3ds Max imports): tested offline.

All lengths here are millimetres in world coordinates; ops.py converts from 3ds Max system units before calling.
"""
import math
import os
import re

AXES = {
    # plane normal, in-plane U axis, in-plane V axis. Plan cuts look down Z; X/Y cuts are drawn as a viewer standing on
    # the negative side of the plane would see them (V is always world Z).
    "z": ((0.0, 0.0, 1.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)),
    "x": ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)),
    "y": ((0.0, 1.0, 0.0), (1.0, 0.0, 0.0), (0.0, 0.0, 1.0)),
}


def _sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def _dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def _cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _unit(v):
    length = math.sqrt(_dot(v, v))
    if length < 1e-12:
        raise ValueError("The section normal must not be zero.")
    return (v[0] / length, v[1] / length, v[2] / length)


def plane_basis(axis=None, offset=0.0, point=None, normal=None):
    """Returns (origin, normal, u, v). Either an axis (x, y, z) with an offset along it, or a point and a normal."""
    if axis:
        n, u, v = AXES[axis]
        origin = tuple(c * float(offset) for c in n)
        return origin, n, u, v
    n = _unit(normal)
    # V is the world Z projected on the plane (vertical sections read upright); for a horizontal plane, world Y.
    up = (0.0, 0.0, 1.0) if abs(n[2]) < 0.9 else (0.0, 1.0, 0.0)
    v = _unit(_sub(up, tuple(c * _dot(up, n) for c in n)))
    u = _cross(v, n)
    return tuple(float(c) for c in point), n, u, v


def slice_mesh(vertices, faces, origin, normal, epsilon=1e-7):
    """Intersects triangles with a plane. vertices: [(x, y, z)], faces: [(i, j, k)] 0-based. Returns 3D segments."""
    distances = [_dot(_sub(p, origin), normal) for p in vertices]
    segments = []
    for face in faces:
        a, b, c = face
        da, db, dc = distances[a], distances[b], distances[c]
        # Nudge vertices lying exactly on the plane, so shared edges are cut once and coplanar faces are skipped.
        da = epsilon if abs(da) < epsilon else da
        db = epsilon if abs(db) < epsilon else db
        dc = epsilon if abs(dc) < epsilon else dc
        points = []
        for (i, di), (j, dj) in (((a, da), (b, db)), ((b, db), (c, dc)), ((c, dc), (a, da))):
            if (di > 0) != (dj > 0):
                t = di / (di - dj)
                pi, pj = vertices[i], vertices[j]
                points.append((pi[0] + t * (pj[0] - pi[0]), pi[1] + t * (pj[1] - pi[1]), pi[2] + t * (pj[2] - pi[2])))
        if len(points) == 2:
            segments.append((points[0], points[1]))
    return segments


def to_plane(point, origin, u, v):
    d = _sub(point, origin)
    return (_dot(d, u), _dot(d, v))


def chain_segments(segments, tolerance=0.01):
    """Joins 2D segments that share end points (within tolerance) into polylines. Returns [(points, closed)]."""
    scale = 1.0 / max(tolerance, 1e-9)

    def key(p):
        return (int(round(p[0] * scale)), int(round(p[1] * scale)))

    ends = {}
    for index, (p, q) in enumerate(segments):
        if key(p) == key(q):
            continue
        ends.setdefault(key(p), []).append((index, 0))
        ends.setdefault(key(q), []).append((index, 1))
    used = [False] * len(segments)
    polylines = []

    def walk(points, last):
        while True:
            next_step = None
            for index, side in ends.get(key(last), ()):
                if not used[index]:
                    next_step = (index, side)
                    break
            if next_step is None:
                return points
            index, side = next_step
            used[index] = True
            last = segments[index][1 - side]
            points.append(last)

    for index, (p, q) in enumerate(segments):
        if used[index] or key(p) == key(q):
            continue
        used[index] = True
        forward = walk([p, q], q)
        backward = walk([p], p)
        points = list(reversed(backward[1:])) + forward
        closed = len(points) > 3 and key(points[0]) == key(points[-1])
        if closed:
            points = points[:-1]
        polylines.append((points, closed))
    return polylines


def _point_line_distance(p, a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    length = dx * dx + dy * dy
    if length < 1e-18:
        return math.hypot(p[0] - a[0], p[1] - a[1])
    t = max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / length))
    return math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy))


def simplify(points, tolerance, closed=False):
    """Ramer-Douglas-Peucker, iterative. A closed ring keeps its two farthest-apart corners as anchors."""
    if tolerance <= 0 or len(points) < 3:
        return list(points)
    if closed:
        start = 0
        far = max(range(len(points)), key=lambda i: math.hypot(points[i][0] - points[0][0], points[i][1] - points[0][1]))
        if far == start:
            return list(points)
        first = simplify(points[start:far + 1], tolerance)
        second = simplify(points[far:] + [points[start]], tolerance)
        return first[:-1] + second[:-1]
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        first, last = stack.pop()
        best, index = 0.0, -1
        for i in range(first + 1, last):
            distance = _point_line_distance(points[i], points[first], points[last])
            if distance > best:
                best, index = distance, i
        if index >= 0 and best > tolerance:
            keep[index] = True
            stack.append((first, index))
            stack.append((index, last))
    return [p for p, k in zip(points, keep) if k]


def polyline_length(points, closed):
    total = sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(points, points[1:]))
    if closed and len(points) > 1:
        total += math.hypot(points[0][0] - points[-1][0], points[0][1] - points[-1][1])
    return total


def section(meshes, origin, normal, u, v, tolerance=0.5, chain_tolerance=0.01, max_points=20000):
    """meshes: [(label, vertices, faces)] in mm, world space. Returns per-object polylines in plane coordinates."""
    results, total_points, truncated = [], 0, False
    for label, vertices, faces in meshes:
        segments3d = slice_mesh(vertices, faces, origin, normal)
        segments = [(to_plane(p, origin, u, v), to_plane(q, origin, u, v)) for p, q in segments3d]
        rings = []
        for points, closed in chain_segments(segments, chain_tolerance):
            points = simplify(points, tolerance, closed)
            if len(points) < 2:
                continue
            if total_points + len(points) > max_points:
                truncated = True
                break
            total_points += len(points)
            rings.append({
                "closed": closed,
                "length_mm": round(polyline_length(points, closed), 2),
                "points": [[round(x, 3), round(y, 3)] for x, y in points],
            })
        if rings:
            results.append({"object": label, "polylines": rings})
        if truncated:
            break
    return {"objects": results, "point_count": total_points, "truncated": truncated}


# ---------- files ----------

_UNSAFE_NAME = re.compile(r'[<>:"/\\|?*\x00-\x1f]+')


def safe_file_name(name, extension):
    stem = _UNSAFE_NAME.sub("_", name or "").strip(" .")[:80] or "export"
    return stem + "." + extension.lstrip(".").lower()


def unique_path(folder, file_name):
    """A path in folder that does not exist yet: name.ext, name_1.ext, ... Never overwrites."""
    stem, extension = os.path.splitext(file_name)
    candidate = os.path.join(folder, file_name)
    number = 1
    while os.path.exists(candidate):
        candidate = os.path.join(folder, "%s_%d%s" % (stem, number, extension))
        number += 1
    return candidate


def resolve_output_folder(requested, default):
    """The default local folder, or an existing absolute folder the caller named. Never a file, never relative."""
    if not requested:
        os.makedirs(default, exist_ok=True)
        return default
    folder = os.path.normpath(requested)
    if not os.path.isabs(folder) or folder.startswith("\\\\"):
        raise ValueError("[invalid_argument] output_folder must be an absolute local folder.")
    if not os.path.isdir(folder):
        raise ValueError("[invalid_argument] output_folder does not exist.")
    return folder


def dxf_r12(section_result, layer_prefix="MAX_SECTION"):
    """A minimal AutoCAD R12 DXF of the section polylines (one layer per object), in mm."""
    lines = ["0", "SECTION", "2", "HEADER", "9", "$INSUNITS", "70", "4", "0", "ENDSEC",
             "0", "SECTION", "2", "ENTITIES"]
    for entry in section_result["objects"]:
        layer = (layer_prefix + "_" + re.sub(r"[^A-Za-z0-9_-]+", "_", entry["object"]))[:60]
        for ring in entry["polylines"]:
            lines += ["0", "POLYLINE", "8", layer, "66", "1", "70", "1" if ring["closed"] else "0"]
            for x, y in ring["points"]:
                lines += ["0", "VERTEX", "8", layer, "10", repr(float(x)), "20", repr(float(y)), "30", "0.0"]
            lines += ["0", "SEQEND", "8", layer]
    lines += ["0", "ENDSEC", "0", "EOF"]
    return "\n".join(lines) + "\n"
