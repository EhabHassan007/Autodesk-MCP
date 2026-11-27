"""Starts and stops the Smart Connector bridge inside 3ds Max.

start() is called once by smart_connector_max_start.ms after 3ds Max has started. It
- does nothing when %LOCALAPPDATA%\\BIM-CAD-MCP\\runtime\\max-bridge-disabled exists (the user's off switch),
- opens the owner-only pipe (server.py) with a fresh random token,
- registers this session in %LOCALAPPDATA%\\BIM-CAD-MCP\\runtime\\max-sessions\\<session>.json for SmartConnector.exe,
- runs every scene operation on 3ds Max's main thread through a Qt timer (pymxs is not safe on other threads).
stop() closes the pipe and removes the registration; 3ds Max calls it before it shuts down.
"""
import datetime
import json
import os
import queue
import threading
import time
import traceback

from . import protocol

_state = {"server": None, "timer": None, "session_file": None, "snapshot": {}, "dispatcher": None}
BRIDGE_VERSION = "1.0.0"


def _runtime_folder():
    base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    return os.path.join(base, "BIM-CAD-MCP", "runtime")


def _log(message):
    try:
        folder = os.path.join(_runtime_folder(), "logs")
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, "3dsmax-bridge.log"), "a", encoding="utf-8") as handle:
            handle.write("%s %s\n" % (datetime.datetime.now().isoformat(timespec="seconds"), message))
    except Exception:
        pass


class _Job(object):
    def __init__(self, operation, arguments):
        self.operation, self.arguments = operation, arguments
        self.done = threading.Event()
        self.started = False
        self.cancelled = False
        self.result, self.error = None, None


class Dispatcher(object):
    """Pipe threads submit jobs; tick() runs them one at a time on 3ds Max's main thread."""

    def __init__(self, operations):
        self.operations = operations
        self.jobs = queue.Queue()
        self.busy_since = None

    def submit(self, operation, arguments):
        if operation in protocol.PIPE_THREAD_OPERATIONS:
            snapshot = dict(_state["snapshot"])
            snapshot["busy"] = self.busy_since is not None
            snapshot["queued"] = self.jobs.qsize()
            return snapshot
        timeout = max(1, min(int(arguments.get("timeout_seconds") or 120), 300))
        job = _Job(operation, arguments)
        self.jobs.put(job)
        if job.done.wait(timeout):
            if job.error:
                raise ValueError(job.error)
            return job.result
        if not job.started:
            job.cancelled = True
            raise ValueError("[max_busy] 3ds Max did not start the request within %d s (a dialog may be open, or it is busy). "
                             "Nothing was run. Ask the user to check 3ds Max, then retry." % timeout)
        raise ValueError("[max_busy] The request is still running in 3ds Max after %d s; its answer will be discarded. "
                         "Call max_scene_info before running anything else." % timeout)

    def tick(self):
        try:
            job = self.jobs.get_nowait()
        except queue.Empty:
            return
        if job.cancelled:
            return
        job.started = True
        self.busy_since = time.time()
        try:
            job.result = self.operations[job.operation](job.arguments)
        except Exception as error:
            text = str(error)
            job.error = text if text.startswith("[") else "[max_error] " + text
            if not text.startswith("["):
                _log("operation %s failed: %s" % (job.operation, traceback.format_exc(limit=2)[-600:]))
        finally:
            self.busy_since = None
            job.done.set()


def _refresh_snapshot(ops):
    try:
        _state["snapshot"].update({"scene": ops.scene_id(), "saved": not bool(ops.rt.getSaveRequired()),
                                   "refreshed_utc": datetime.datetime.utcnow().isoformat() + "Z"})
    except Exception:
        pass


def _write_registration(record):
    folder = os.path.join(_runtime_folder(), "max-sessions")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, record["session_id"] + ".json")
    temporary = path + ".%d.tmp" % os.getpid()
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(record, handle)
    os.replace(temporary, path)
    return path


def start():
    if _state["server"] is not None:
        return "already running"
    if os.path.exists(os.path.join(_runtime_folder(), "max-bridge-disabled")):
        _log("bridge not started: switched off (max-bridge-disabled)")
        return "switched off"
    from . import ops, server  # 3ds Max only
    try:
        from PySide6.QtCore import QTimer
    except ImportError:
        from PySide2.QtCore import QTimer

    year, pid = ops.max_year(), os.getpid()
    session_id = "%d-%d" % (year, pid)
    pipe_name = "SmartConnector.Max.%d.%d" % (year, pid)
    token = protocol.new_token()
    dispatcher = Dispatcher(ops.OPERATIONS)
    pipe = server.PipeServer(pipe_name, token, dispatcher.submit, _log)
    pipe.start()

    timer = QTimer()
    ticks = {"n": 0}

    def tick():
        dispatcher.tick()
        ticks["n"] += 1
        if ticks["n"] % 20 == 1:
            _refresh_snapshot(ops)

    timer.timeout.connect(tick)
    timer.start(50)

    _state["snapshot"] = {"session_id": session_id, "process_id": pid, "max_version": year, "bridge_version": BRIDGE_VERSION}
    _refresh_snapshot(ops)
    started = datetime.datetime.utcnow().isoformat() + "Z"
    _state.update(server=pipe, timer=timer, dispatcher=dispatcher, session_file=_write_registration({
        "session_id": session_id, "pid": pid, "max_version": year, "pipe_name": pipe_name, "token": token,
        "bridge_version": BRIDGE_VERSION, "started_utc": started}))
    _log("bridge started: session %s" % session_id)
    return "started"


def stop():
    pipe, timer, path = _state["server"], _state["timer"], _state["session_file"]
    _state.update(server=None, timer=None, session_file=None, dispatcher=None)
    try:
        if timer is not None:
            timer.stop()
    except Exception:
        pass
    try:
        if pipe is not None:
            pipe.stop()
    except Exception:
        pass
    try:
        if path and os.path.exists(path):
            os.remove(path)
    except Exception:
        pass
    _log("bridge stopped")
    return "stopped"


def status():
    return "running" if _state["server"] is not None else "stopped"
