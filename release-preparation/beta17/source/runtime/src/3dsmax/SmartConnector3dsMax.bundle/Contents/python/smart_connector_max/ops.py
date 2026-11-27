"""The bridge's operations. Every function here runs on 3ds Max's main thread (main.py dispatches to it), takes the
request's argument dict and returns JSON-friendly data. Lengths are returned in millimetres.

Privacy: answers carry what the AI client asked about the open scene and nothing else. Texture and file references are
returned as base names, not full paths. Nothing is sent anywhere except back down the local pipe.
"""
import json
import os
import traceback

import pymxs

from . import geometry

rt = pymxs.runtime

UNIT_MM = {"millimeters": 1.0, "centimeters": 10.0, "meters": 1000.0, "kilometers": 1000000.0,
           "inches": 25.4, "feet": 304.8, "miles": 1609344.0}
MAX_FACES_DEFAULT = 300000
MAX_FACES_LIMIT = 2000000


def exports_folder():
    base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    return os.path.join(base, "BIM-CAD-MCP", "exports", "3dsmax")


# ---------- scene helpers ----------

def mm_per_unit():
    system = str(rt.units.SystemType).lower().lstrip("#")
    return UNIT_MM.get(system, 1.0) * float(rt.units.SystemScale)


def max_year():
    # maxVersion() starts with the release number: 27000 is 3ds Max 2025.
    return int(rt.maxVersion()[0]) // 1000 + 1998


def scene_id():
    path, name = str(rt.maxFilePath or ""), str(rt.maxFileName or "")
    return os.path.join(path, name) if name else "untitled"


def _p3(value, scale):
    return [round(float(value.x) * scale, 3), round(float(value.y) * scale, 3), round(float(value.z) * scale, 3)]


def _is_geometry(node):
    try:
        return rt.superClassOf(node) == rt.GeometryClass and rt.canConvertTo(node, rt.TriMeshGeometry) and not rt.isKindOf(node, rt.TargetObject)
    except Exception:
        return False


def _handle(node):
    return str(int(node.inode.handle))


def _layer_name(node):
    try:
        return str(node.layer.name)
    except Exception:
        return ""


def _colour(value):
    try:
        return [int(round(float(value.r))), int(round(float(value.g))), int(round(float(value.b)))]
    except Exception:
        return None


def material_summary(material, depth=0):
    if material is None or depth > 2:
        return None
    summary = {"name": str(material.name), "class": str(rt.classOf(material))}
    for prop in ("base_color", "diffuse", "Diffuse", "diffuse_color", "color", "Color"):
        try:
            if rt.isProperty(material, prop):
                colour = _colour(rt.getProperty(material, prop))
                if colour:
                    summary["colour_rgb"] = colour
                    break
        except Exception:
            pass
    maps = []
    try:
        for texture in rt.getClassInstances(rt.BitmapTexture, target=material):
            file_name = str(texture.filename or "")
            if file_name:
                maps.append(os.path.basename(file_name))
    except Exception:
        pass
    if maps:
        summary["texture_files"] = sorted(set(maps))[:20]
    try:
        if rt.classOf(material) == rt.MultiMaterial:
            summary["sub_materials"] = [material_summary(sub, depth + 1) for sub in list(material.materialList)[:20] if sub is not None]
    except Exception:
        pass
    return summary


def find_nodes(arguments, geometry_only=True):
    handles = arguments.get("handles") or []
    names = arguments.get("names") or []
    nodes = []
    if handles or names:
        for handle in handles:
            node = rt.maxOps.getNodeByHandle(int(handle))
            if node is None:
                raise ValueError("[not_found] No object has handle " + str(handle) + ".")
            nodes.append(node)
        for name in names:
            matches = [n for n in rt.objects if str(n.name) == name]
            if not matches:
                raise ValueError("[not_found] No object is named " + name + ".")
            nodes.extend(matches)
    elif arguments.get("selected_only"):
        nodes = list(rt.selection)
    else:
        nodes = [n for n in rt.objects if not n.isHiddenInVpt]
    if geometry_only:
        nodes = [n for n in nodes if _is_geometry(n)]
    return nodes


def world_mesh(node, scale, face_budget):
    """World-space triangles of a node in mm. Returns (vertices, faces) or raises when over the face budget."""
    mesh = rt.snapshotAsMesh(node)
    try:
        face_count = int(mesh.numfaces)
        if face_count > face_budget:
            raise ValueError("[too_large] " + str(node.name) + " has " + str(face_count) + " faces, over the remaining limit of " +
                             str(face_budget) + ". Pass fewer objects or raise max_faces.")
        vertices = []
        for i in range(1, int(mesh.numverts) + 1):
            p = rt.getVert(mesh, i)
            vertices.append((float(p.x) * scale, float(p.y) * scale, float(p.z) * scale))
        faces = []
        for i in range(1, face_count + 1):
            f = rt.getFace(mesh, i)
            faces.append((int(f.x) - 1, int(f.y) - 1, int(f.z) - 1))
        return vertices, faces
    finally:
        rt.delete(mesh)


# ---------- operations ----------

def scene_info(arguments):
    scale = mm_per_unit()
    layers = []
    manager = rt.LayerManager
    for i in range(int(manager.count)):
        layer = manager.getLayer(i)
        layers.append({"name": str(layer.name), "hidden": bool(layer.isHidden), "frozen": bool(layer.isFrozen)})
    objects = list(rt.objects)
    return {
        "scene": scene_id(),
        "saved": not bool(rt.getSaveRequired()),
        "max_version": max_year(),
        "system_units": str(rt.units.SystemType).lstrip("#"),
        "system_scale": float(rt.units.SystemScale),
        "mm_per_unit": scale,
        "object_count": len(objects),
        "geometry_count": sum(1 for n in objects if _is_geometry(n)),
        "selected_count": int(rt.selection.count),
        "layers": layers[:500],
    }


def list_objects(arguments):
    scale = mm_per_unit()
    layer = arguments.get("layer") or ""
    contains = (arguments.get("name_contains") or "").lower()
    offset = int(arguments.get("offset") or 0)
    limit = max(1, min(int(arguments.get("limit") or 100), 500))
    nodes = list(rt.selection) if arguments.get("selected_only") else list(rt.objects)
    if arguments.get("geometry_only", True):
        nodes = [n for n in nodes if _is_geometry(n)]
    if not arguments.get("include_hidden"):
        nodes = [n for n in nodes if not n.isHiddenInVpt]
    if layer:
        nodes = [n for n in nodes if _layer_name(n) == layer]
    if contains:
        nodes = [n for n in nodes if contains in str(n.name).lower()]
    page = nodes[offset:offset + limit]
    items = []
    for node in page:
        item = {"handle": _handle(node), "name": str(node.name), "class": str(rt.classOf(node)), "layer": _layer_name(node),
                "hidden": bool(node.isHiddenInVpt), "parent": str(node.parent.name) if node.parent is not None else ""}
        try:
            item["bbox_min_mm"], item["bbox_max_mm"] = _p3(node.min, scale), _p3(node.max, scale)
        except Exception:
            pass
        if node.material is not None:
            item["material"] = str(node.material.name)
        items.append(item)
    return {"total": len(nodes), "offset": offset, "objects": items,
            "next_offset": offset + limit if offset + limit < len(nodes) else None}


def get_object(arguments):
    scale = mm_per_unit()
    nodes = find_nodes(arguments, geometry_only=False)
    if len(nodes) != 1:
        raise ValueError("[invalid_argument] Name exactly one object (by handle, or by a unique name).")
    node = nodes[0]
    transform = node.transform
    euler = rt.quatToEuler(transform.rotation)
    result = {
        "handle": _handle(node), "name": str(node.name), "class": str(rt.classOf(node)), "superclass": str(rt.superClassOf(node)),
        "layer": _layer_name(node), "hidden": bool(node.isHiddenInVpt), "frozen": bool(node.isFrozen),
        "parent": str(node.parent.name) if node.parent is not None else "",
        "children": [str(c.name) for c in list(node.children)[:50]],
        "position_mm": _p3(node.pos, scale),
        "rotation_euler_deg": [round(float(euler.x), 4), round(float(euler.y), 4), round(float(euler.z), 4)],
        "scale": [round(float(s), 6) for s in (transform.scale.x, transform.scale.y, transform.scale.z)],
        "modifiers": [str(m.name) + " (" + str(rt.classOf(m)) + ")" for m in list(node.modifiers)[:30]],
        "material": material_summary(node.material),
        "wire_colour_rgb": _colour(node.wirecolor),
    }
    try:
        result["bbox_min_mm"], result["bbox_max_mm"] = _p3(node.min, scale), _p3(node.max, scale)
    except Exception:
        pass
    if _is_geometry(node):
        mesh = rt.snapshotAsMesh(node)
        try:
            result["vertex_count"], result["face_count"] = int(mesh.numverts), int(mesh.numfaces)
        finally:
            rt.delete(mesh)
    try:
        props = str(rt.getUserPropBuffer(node) or "")
        if props:
            result["user_properties"] = props[:2000]
    except Exception:
        pass
    return result


def section(arguments):
    scale = mm_per_unit()
    budget = max(1, min(int(arguments.get("max_faces") or MAX_FACES_DEFAULT), MAX_FACES_LIMIT))
    axis = arguments.get("axis")
    if axis:
        origin, normal, u, v = geometry.plane_basis(axis=axis, offset=float(arguments.get("offset_mm") or 0.0))
    else:
        if not arguments.get("point") or not arguments.get("normal"):
            raise ValueError("[invalid_argument] Give axis (x, y or z) with offset_mm, or point and normal.")
        origin, normal, u, v = geometry.plane_basis(point=arguments["point"], normal=arguments["normal"])
    nodes = find_nodes(arguments)
    if not nodes:
        raise ValueError("[not_found] No geometry objects matched.")
    meshes = []
    for node in nodes:
        vertices, faces = world_mesh(node, scale, budget)
        budget -= len(faces)
        meshes.append((str(node.name), vertices, faces))
    result = geometry.section(meshes, origin, normal, u, v,
                              tolerance=float(arguments.get("tolerance_mm") if arguments.get("tolerance_mm") is not None else 0.5),
                              max_points=int(arguments.get("max_points") or 20000))
    result["plane"] = {"origin_mm": [round(c, 3) for c in origin], "normal": list(normal), "u_axis": list(u), "v_axis": list(v),
                       "note": "points are [u, v] in mm on the plane; for axis z they are world X, Y"}
    result["scene"] = scene_id()
    if arguments.get("output_dxf"):
        folder = geometry.resolve_output_folder(arguments.get("output_folder"), exports_folder())
        label = "section-" + (axis or "plane") + "-" + str(int(round(float(arguments.get("offset_mm") or 0))))
        path = geometry.unique_path(folder, geometry.safe_file_name(label, "dxf"))
        with open(path, "w", encoding="ascii", newline="\n") as handle:
            handle.write(geometry.dxf_r12(result))
        result["dxf_path"] = path
    return result


def capture_viewport(arguments):
    folder = geometry.resolve_output_folder(arguments.get("output_folder"), exports_folder())
    path = geometry.unique_path(folder, geometry.safe_file_name("viewport", "png"))
    image = rt.gw.getViewportDib()
    try:
        width, height = int(image.width), int(image.height)
        image.filename = path
        rt.save(image)
    finally:
        rt.close(image)
    return {"image_path": path, "width": width, "height": height}


def export(arguments):
    fmt = (arguments.get("format") or "obj").lower()
    if fmt not in ("obj", "fbx", "dwg"):
        raise ValueError("[invalid_argument] format must be obj, fbx or dwg.")
    nodes = find_nodes(arguments, geometry_only=False)
    if not nodes:
        raise ValueError("[not_found] No objects matched.")
    folder = geometry.resolve_output_folder(arguments.get("output_folder"), exports_folder())
    stem = os.path.splitext(str(rt.maxFileName or ""))[0] or "untitled"
    path = geometry.unique_path(folder, geometry.safe_file_name(stem + "-export", fmt))
    previous = list(rt.selection)
    try:
        rt.select(nodes)
        ok = rt.exportFile(path, rt.name("noPrompt"), selectedOnly=True)
    finally:
        rt.clearSelection()
        if previous:
            rt.select(previous)
    if not ok or not os.path.exists(path):
        raise ValueError("[export_failed] 3ds Max did not write the " + fmt.upper() + " file.")
    return {"path": path, "format": fmt, "object_count": len(nodes), "bytes": os.path.getsize(path)}


def execute_python(arguments):
    expected = arguments.get("expected_scene") or ""
    if expected and os.path.normcase(expected) != os.path.normcase(scene_id()):
        raise ValueError("[scene_changed] The open scene is not expected_scene. Read max_scene_info again.")
    mode = arguments.get("execution_mode") or "read"
    allow = bool(arguments.get("allow_model_changes"))
    if mode == "write" and not allow:
        raise ValueError("[invalid_argument] execution_mode write needs allow_model_changes=true.")
    try:
        parameters = json.loads(arguments.get("parameters_json") or "{}")
    except Exception:
        raise ValueError("[invalid_argument] parameters_json is not valid JSON.")
    code = arguments.get("code") or ""
    namespace = {"rt": rt, "pymxs": pymxs, "params": parameters, "mm_per_unit": mm_per_unit(), "result": None}
    was_dirty = bool(rt.getSaveRequired())
    try:
        compiled = compile(code, "<smart-connector>", "exec")
    except SyntaxError as error:
        raise ValueError("[compile_error] line %s: %s" % (error.lineno, error.msg))
    try:
        if mode == "write":
            with pymxs.undo(True, "Smart Connector"):
                exec(compiled, namespace)
        else:
            exec(compiled, namespace)
    except Exception:
        raise ValueError("[runtime_error] " + traceback.format_exc(limit=3)[-1500:])
    changed = bool(rt.getSaveRequired()) and not was_dirty
    answer = {"execution_mode": mode, "result": namespace.get("result"), "scene_changed": changed}
    if mode == "read" and changed:
        answer["warning"] = "The scene changed during a read run. Use Edit > Undo in 3ds Max to revert it, and use execution_mode write for edits."
    try:
        json.dumps(answer["result"])
    except Exception:
        answer["result"] = str(answer["result"])
    return answer


OPERATIONS = {
    "scene_info": scene_info,
    "list_objects": list_objects,
    "get_object": get_object,
    "section": section,
    "capture_viewport": capture_viewport,
    "export": export,
    "execute_python": execute_python,
}
