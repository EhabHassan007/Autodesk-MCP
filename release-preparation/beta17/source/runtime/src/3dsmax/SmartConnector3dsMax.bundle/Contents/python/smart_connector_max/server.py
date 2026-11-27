"""Named-pipe server inside 3ds Max (Windows only, ctypes; no third-party packages).

Security model (the same as the Smart Connector Revit add-in, plus a token):
- No network socket. A named pipe with PIPE_REJECT_REMOTE_CLIENTS, so it cannot be reached from another computer.
- The pipe's DACL admits only the signed-in Windows user (protected DACL, no inherited entries).
- FILE_FLAG_FIRST_PIPE_INSTANCE on the first instance: if another program already created the pipe name, the bridge
  refuses to start instead of sharing a pipe it does not own.
- Every request carries the per-session token from this session's registry file (user-only %LOCALAPPDATA%).
- One request per connection, size-capped; at most 8 connections at once.
"""
import ctypes
import threading
from ctypes import wintypes

from . import protocol

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)

INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value
PIPE_ACCESS_DUPLEX = 0x00000003
FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000
PIPE_TYPE_BYTE, PIPE_READMODE_BYTE, PIPE_WAIT, PIPE_REJECT_REMOTE_CLIENTS = 0x0, 0x0, 0x0, 0x8
ERROR_PIPE_CONNECTED, ERROR_MORE_DATA, ERROR_ACCESS_DENIED = 535, 234, 5
TOKEN_QUERY, TOKEN_USER_CLASS = 0x0008, 1
MAX_INSTANCES = 8
BUFFER = 65536


class SECURITY_ATTRIBUTES(ctypes.Structure):
    _fields_ = [("nLength", wintypes.DWORD), ("lpSecurityDescriptor", ctypes.c_void_p), ("bInheritHandle", wintypes.BOOL)]


kernel32.CreateNamedPipeW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD,
                                      wintypes.DWORD, wintypes.DWORD, ctypes.POINTER(SECURITY_ATTRIBUTES)]
kernel32.CreateNamedPipeW.restype = ctypes.c_void_p
kernel32.ConnectNamedPipe.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
kernel32.ConnectNamedPipe.restype = wintypes.BOOL
kernel32.DisconnectNamedPipe.argtypes = [ctypes.c_void_p]
kernel32.FlushFileBuffers.argtypes = [ctypes.c_void_p]
kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
kernel32.ReadFile.argtypes = [ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
kernel32.ReadFile.restype = wintypes.BOOL
kernel32.WriteFile.argtypes = [ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
kernel32.WriteFile.restype = wintypes.BOOL
kernel32.GetCurrentProcess.restype = ctypes.c_void_p
kernel32.LocalFree.argtypes = [ctypes.c_void_p]
advapi32.OpenProcessToken.argtypes = [ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(ctypes.c_void_p)]
advapi32.GetTokenInformation.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
advapi32.ConvertSidToStringSidW.argtypes = [ctypes.c_void_p, ctypes.POINTER(wintypes.LPWSTR)]
advapi32.ConvertStringSecurityDescriptorToSecurityDescriptorW.argtypes = [
    wintypes.LPCWSTR, wintypes.DWORD, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(wintypes.ULONG)]


def _fail(what):
    raise OSError("%s failed (Windows error %d)" % (what, ctypes.get_last_error()))


def current_user_sid():
    token = ctypes.c_void_p()
    if not advapi32.OpenProcessToken(kernel32.GetCurrentProcess(), TOKEN_QUERY, ctypes.byref(token)):
        _fail("OpenProcessToken")
    try:
        size = wintypes.DWORD(0)
        advapi32.GetTokenInformation(token, TOKEN_USER_CLASS, None, 0, ctypes.byref(size))
        buffer = ctypes.create_string_buffer(size.value)
        if not advapi32.GetTokenInformation(token, TOKEN_USER_CLASS, buffer, size, ctypes.byref(size)):
            _fail("GetTokenInformation")
        sid_pointer = ctypes.c_void_p.from_buffer(buffer).value  # TOKEN_USER.User.Sid
        text = wintypes.LPWSTR()
        if not advapi32.ConvertSidToStringSidW(sid_pointer, ctypes.byref(text)):
            _fail("ConvertSidToStringSid")
        try:
            return text.value
        finally:
            kernel32.LocalFree(ctypes.cast(text, ctypes.c_void_p))
    finally:
        kernel32.CloseHandle(token)


def owner_only_attributes(sid):
    """SECURITY_ATTRIBUTES whose protected DACL grants full access to this user only. Keep the descriptor alive."""
    descriptor = ctypes.c_void_p()
    if not advapi32.ConvertStringSecurityDescriptorToSecurityDescriptorW("D:P(A;;GA;;;%s)" % sid, 1, ctypes.byref(descriptor), None):
        _fail("ConvertStringSecurityDescriptorToSecurityDescriptor")
    attributes = SECURITY_ATTRIBUTES(ctypes.sizeof(SECURITY_ATTRIBUTES), descriptor, False)
    return attributes, descriptor


class PipeServer(object):
    """Accepts connections on a background thread; handle(operation, arguments) -> result runs per request."""

    def __init__(self, pipe_name, token, handle, log):
        self.pipe_name = pipe_name
        self.path = "\\\\.\\pipe\\" + pipe_name
        self.token = token
        self.handle = handle
        self.log = log
        self._stopping = threading.Event()
        self._slots = threading.BoundedSemaphore(MAX_INSTANCES)
        self._attributes, self._descriptor = owner_only_attributes(current_user_sid())
        self._first = True
        self._thread = None

    def _create_instance(self):
        mode = PIPE_ACCESS_DUPLEX | (FILE_FLAG_FIRST_PIPE_INSTANCE if self._first else 0)
        handle = kernel32.CreateNamedPipeW(self.path, mode, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                                           MAX_INSTANCES, BUFFER, BUFFER, 0, ctypes.byref(self._attributes))
        if handle in (None, INVALID_HANDLE_VALUE):
            error = ctypes.get_last_error()
            if self._first and error == ERROR_ACCESS_DENIED:
                raise OSError("The pipe name is already in use by another program; the 3ds Max bridge did not start.")
            raise OSError("CreateNamedPipe failed (Windows error %d)" % error)
        self._first = False
        return handle

    def start(self):
        first = self._create_instance()  # fail here, on 3ds Max's thread, if the name is taken
        self._thread = threading.Thread(target=self._listen, args=(first,), name="Smart Connector 3ds Max pipe", daemon=True)
        self._thread.start()

    def stop(self):
        self._stopping.set()
        # Wake the blocked ConnectNamedPipe with a throwaway connection.
        try:
            with open(self.path, "r+b", buffering=0):
                pass
        except OSError:
            pass

    def _listen(self, handle):
        while not self._stopping.is_set():
            try:
                if handle is None:
                    handle = self._create_instance()
                connected = kernel32.ConnectNamedPipe(handle, None) or ctypes.get_last_error() == ERROR_PIPE_CONNECTED
                if self._stopping.is_set():
                    kernel32.CloseHandle(handle)
                    return
                if not connected:
                    kernel32.CloseHandle(handle)
                    handle = None
                    continue
                self._slots.acquire()
                threading.Thread(target=self._serve, args=(handle,), daemon=True).start()
                handle = None
            except Exception as error:  # keep listening; report once
                self.log("pipe error: %s" % error)
                if handle is not None:
                    kernel32.CloseHandle(handle)
                    handle = None
                self._stopping.wait(0.25)

    def _read_line(self, handle):
        chunks, total = [], 0
        buffer = ctypes.create_string_buffer(BUFFER)
        read = wintypes.DWORD(0)
        while True:
            ok = kernel32.ReadFile(handle, buffer, BUFFER, ctypes.byref(read), None)
            if not ok and ctypes.get_last_error() != ERROR_MORE_DATA:
                break
            if read.value == 0:
                break
            data = buffer.raw[:read.value]
            chunks.append(data)
            total += len(data)
            if b"\n" in data or total > protocol.MAX_REQUEST_BYTES:
                break
        return b"".join(chunks).split(b"\n", 1)[0].decode("utf-8", "replace")

    def _write(self, handle, text):
        data = text.encode("utf-8")
        written = wintypes.DWORD(0)
        offset = 0
        while offset < len(data):
            chunk = data[offset:offset + BUFFER]
            if not kernel32.WriteFile(handle, chunk, len(chunk), ctypes.byref(written), None):
                break
            offset += written.value
        kernel32.FlushFileBuffers(handle)

    def _serve(self, handle):
        try:
            line = self._read_line(handle)
            try:
                operation, arguments = protocol.parse_request(line, self.token)
                answer = protocol.encode_ok(self.handle(operation, arguments))
            except protocol.ProtocolError as error:
                answer = protocol.encode_error(str(error))
            except Exception as error:
                answer = protocol.encode_error(str(error))
            self._write(handle, answer)
        except Exception as error:
            self.log("pipe client error: %s" % error)
        finally:
            try:
                kernel32.DisconnectNamedPipe(handle)
            finally:
                kernel32.CloseHandle(handle)
                self._slots.release()
