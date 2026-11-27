"""Offline tests for the 3ds Max bridge's pure parts (protocol.py, geometry.py). No 3ds Max needed.

    python -m unittest release-preparation/beta17/tests/test_3dsmax_bridge.py
"""
import math
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "source", "runtime", "src", "3dsmax", "SmartConnector3dsMax.bundle", "Contents", "python"))

import threading  # noqa: E402

from smart_connector_max import geometry, main, protocol  # noqa: E402


def box(x0, y0, z0, x1, y1, z1):
    v = [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0), (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)]
    quads = [(0, 1, 2, 3), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    f = []
    for a, b, c, d in quads:
        f += [(a, b, c), (a, c, d)]
    return v, f


def cylinder(radius, height, segments=64):
    v, f = [], []
    for i in range(segments):
        a = 2 * math.pi * i / segments
        v += [(radius * math.cos(a), radius * math.sin(a), 0.0), (radius * math.cos(a), radius * math.sin(a), height)]
    for i in range(segments):
        j = (i + 1) % segments
        f += [(2 * i, 2 * j, 2 * j + 1), (2 * i, 2 * j + 1, 2 * i + 1)]
    return v, f


class ProtocolTests(unittest.TestCase):
    def test_round_trip(self):
        token = protocol.new_token()
        self.assertEqual(len(token), 64)
        line = protocol.encode_request("section", token, {"axis": "z", "offset_mm": 900})
        operation, arguments = protocol.parse_request(line, token)
        self.assertEqual(operation, "section")
        self.assertEqual(arguments, {"axis": "z", "offset_mm": 900})
        self.assertEqual(protocol.decode_answer(protocol.encode_ok({"a": [1, 2]})), {"a": [1, 2]})

    def test_wrong_token_is_refused_without_detail(self):
        line = protocol.encode_request("scene_info", "a" * 64, {})
        with self.assertRaises(protocol.ProtocolError) as caught:
            protocol.parse_request(line, "b" * 64)
        self.assertEqual(str(caught.exception), "[unauthorized] The request was refused.")
        with self.assertRaises(protocol.ProtocolError):
            protocol.parse_request(line, "")

    def test_unknown_operation_and_bad_payloads(self):
        token = protocol.new_token()
        for line in ("", "x\ty", "rm_rf\t%s\te30=" % token, "scene_info\t%s\t!!notbase64" % token,
                     "scene_info\t%s\tWzFd" % token):  # WzFd = "[1]", not an object
            with self.assertRaises(protocol.ProtocolError):
                protocol.parse_request(line, token)

    def test_oversized_request(self):
        with self.assertRaises(protocol.ProtocolError):
            protocol.parse_request("x" * (protocol.MAX_REQUEST_BYTES + 1), "t")

    def test_errors_are_typed(self):
        with self.assertRaises(protocol.ProtocolError) as caught:
            protocol.decode_answer(protocol.encode_error("boom"))
        self.assertEqual(str(caught.exception), "[max_error] boom")


class GeometryTests(unittest.TestCase):
    def test_plan_section_of_a_box_is_one_closed_rectangle(self):
        v, f = box(0, 0, 0, 2400, 600, 1100)
        origin, n, u, w = geometry.plane_basis(axis="z", offset=900)
        result = geometry.section([("counter", v, f)], origin, n, u, w)
        rings = result["objects"][0]["polylines"]
        self.assertEqual(len(rings), 1)
        self.assertTrue(rings[0]["closed"])
        self.assertEqual(len(rings[0]["points"]), 4)
        self.assertAlmostEqual(rings[0]["length_mm"], 6000.0, places=3)
        xs = sorted({p[0] for p in rings[0]["points"]})
        self.assertEqual(xs, [0.0, 2400.0])

    def test_vertical_section_reads_upright(self):
        v, f = box(0, 0, 0, 2400, 600, 1100)
        origin, n, u, w = geometry.plane_basis(axis="x", offset=1200)
        ring = geometry.section([("counter", v, f)], origin, n, u, w)["objects"][0]["polylines"][0]
        heights = sorted({p[1] for p in ring["points"]})
        self.assertEqual(heights, [0.0, 1100.0])  # V is world Z

    def test_cylinder_section_keeps_its_radius(self):
        v, f = cylinder(1000.0, 600.0)
        origin, n, u, w = geometry.plane_basis(axis="z", offset=300)
        # The quads' diagonals add collinear chord points; a small tolerance removes them and keeps every true corner.
        ring = geometry.section([("drum", v, f)], origin, n, u, w, tolerance=0.01)["objects"][0]["polylines"][0]
        self.assertTrue(ring["closed"])
        self.assertEqual(len(ring["points"]), 64)
        for x, y in ring["points"]:
            self.assertAlmostEqual(math.hypot(x, y), 1000.0, places=2)

    def test_plane_through_vertices_and_missing_plane(self):
        v, f = box(0, 0, 0, 100, 100, 100)
        origin, n, u, w = geometry.plane_basis(axis="z", offset=0)  # exactly on the bottom face
        result = geometry.section([("b", v, f)], origin, n, u, w)
        self.assertLessEqual(len(result["objects"]), 1)
        origin, n, u, w = geometry.plane_basis(axis="z", offset=500)  # above the box
        self.assertEqual(geometry.section([("b", v, f)], origin, n, u, w)["objects"], [])

    def test_arbitrary_plane_matches_axis_plane(self):
        v, f = box(0, 0, 0, 2400, 600, 1100)
        origin, n, u, w = geometry.plane_basis(point=(0, 0, 900), normal=(0, 0, 2))
        ring = geometry.section([("c", v, f)], origin, n, u, w)["objects"][0]["polylines"][0]
        self.assertAlmostEqual(ring["length_mm"], 6000.0, places=3)
        with self.assertRaises(ValueError):
            geometry.plane_basis(point=(0, 0, 0), normal=(0, 0, 0))

    def test_simplify_removes_collinear_points_only(self):
        line = [(float(i), 0.0) for i in range(11)] + [(10.0, 5.0)]
        self.assertEqual(geometry.simplify(line, 0.1), [(0.0, 0.0), (10.0, 0.0), (10.0, 5.0)])

    def test_point_cap_truncates(self):
        v, f = cylinder(1000.0, 600.0, 256)
        origin, n, u, w = geometry.plane_basis(axis="z", offset=300)
        result = geometry.section([("a", v, f), ("b", v, f)], origin, n, u, w, tolerance=0.0, max_points=300)
        self.assertTrue(result["truncated"])
        self.assertLessEqual(result["point_count"], 300)

    def test_dxf_is_r12_with_one_layer_per_object(self):
        v, f = box(0, 0, 0, 10, 10, 10)
        origin, n, u, w = geometry.plane_basis(axis="z", offset=5)
        text = geometry.dxf_r12(geometry.section([("Top/Panel 1", v, f)], origin, n, u, w))
        self.assertIn("POLYLINE", text)
        self.assertIn("MAX_SECTION_Top_Panel_1", text)
        self.assertTrue(text.endswith("EOF\n"))

    def test_output_paths_never_overwrite_and_reject_bad_folders(self):
        folder = tempfile.mkdtemp()
        first = geometry.unique_path(folder, "a.obj")
        open(first, "w").close()
        self.assertTrue(geometry.unique_path(folder, "a.obj").endswith("a_1.obj"))
        self.assertEqual(geometry.safe_file_name('..\\x:y*"z', "dxf"), "_x_y_z.dxf")
        for bad in ("relative\\folder", os.path.join(folder, "missing")):
            with self.assertRaises(ValueError):
                geometry.resolve_output_folder(bad, folder)
        self.assertEqual(geometry.resolve_output_folder("", os.path.join(folder, "new")), os.path.join(folder, "new"))


class DispatcherTests(unittest.TestCase):
    """main.Dispatcher: pipe threads submit, 3ds Max's main thread (here: the test) runs tick()."""

    def test_job_runs_on_tick_and_errors_are_typed(self):
        dispatcher = main.Dispatcher({"scene_info": lambda a: {"ok": a["x"]}, "section": lambda a: 1 / 0})
        answers = {}

        def client(name, op, args):
            try:
                answers[name] = dispatcher.submit(op, args)
            except ValueError as error:
                answers[name] = str(error)

        threads = [threading.Thread(target=client, args=("good", "scene_info", {"x": 5})),
                   threading.Thread(target=client, args=("bad", "section", {}))]
        for t in threads:
            t.start()
        for _ in range(200):
            dispatcher.tick()
            if len(answers) == 2:
                break
            threading.Event().wait(0.01)
        for t in threads:
            t.join(2)
        self.assertEqual(answers["good"], {"ok": 5})
        self.assertTrue(answers["bad"].startswith("[max_error] "))

    def test_busy_max_returns_without_running_the_job(self):
        ran = []
        dispatcher = main.Dispatcher({"scene_info": lambda a: ran.append(1)})
        with self.assertRaises(ValueError) as caught:
            dispatcher.submit("scene_info", {"timeout_seconds": 1})
        self.assertIn("[max_busy]", str(caught.exception))
        dispatcher.tick()  # 3ds Max frees up later: the abandoned job is dropped, not run
        self.assertEqual(ran, [])

    def test_status_is_answered_without_the_main_thread(self):
        dispatcher = main.Dispatcher({})
        main._state["snapshot"] = {"session_id": "2025-1"}
        status = dispatcher.submit("status", {})
        self.assertEqual(status["session_id"], "2025-1")
        self.assertFalse(status["busy"])


if __name__ == "__main__":
    unittest.main()
