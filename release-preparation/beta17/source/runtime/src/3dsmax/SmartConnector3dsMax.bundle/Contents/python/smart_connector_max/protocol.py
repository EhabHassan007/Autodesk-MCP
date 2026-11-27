"""Wire protocol between SmartConnector.exe and the 3ds Max bridge. Pure Python, no 3ds Max imports, so it is tested
offline (tests/test_3dsmax_bridge.py).

One request per pipe connection, one line each way, UTF-8:

    request:  <operation> TAB <token> TAB <base64(JSON arguments)> LF
    answer:   OK  TAB <base64(JSON result)> LF
              ERR TAB <base64(message)> LF

The token is the random per-session secret written to this Max session's registry file in the user's own
%LOCALAPPDATA%. The pipe itself only admits the signed-in Windows user (see server.py); the token is a second check so
another program of the same user that merely guesses the pipe name is still refused.
"""
import base64
import hmac
import json
import secrets

# Read-only questions about the scene, file outputs that never change the scene, and the two calls that may change it.
OPERATIONS = (
    "status", "scene_info", "list_objects", "get_object", "section",
    "capture_viewport", "export", "execute_python",
)
# Answered on the pipe thread from a cached snapshot, so they work while 3ds Max's own thread is busy.
PIPE_THREAD_OPERATIONS = ("status",)
MAX_REQUEST_BYTES = 4 * 1024 * 1024


class ProtocolError(Exception):
    """A malformed or refused request. The message is safe to send back to the client."""


def new_token():
    return secrets.token_hex(32)


def _b64(text):
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


def encode_request(operation, token, arguments):
    return "\t".join((operation, token, _b64(json.dumps(arguments or {}, separators=(",", ":"))))) + "\n"


def parse_request(line, expected_token):
    """Returns (operation, arguments) or raises ProtocolError with a typed message."""
    if line is None or not line.strip():
        raise ProtocolError("[invalid_request] Empty request.")
    if len(line) > MAX_REQUEST_BYTES:
        raise ProtocolError("[invalid_request] The request is too large.")
    parts = line.rstrip("\r\n").split("\t")
    if len(parts) != 3:
        raise ProtocolError("[invalid_request] The request is not valid.")
    operation, token, payload = parts
    # Constant-time comparison; a wrong token gets the same answer whatever the operation.
    if not expected_token or not hmac.compare_digest(token.encode("utf-8"), expected_token.encode("utf-8")):
        raise ProtocolError("[unauthorized] The request was refused.")
    if operation not in OPERATIONS:
        raise ProtocolError("[invalid_request] Unknown operation.")
    try:
        arguments = json.loads(base64.b64decode(payload.encode("ascii"), validate=True).decode("utf-8")) if payload else {}
    except Exception:
        raise ProtocolError("[invalid_request] The request arguments are not valid.")
    if not isinstance(arguments, dict):
        raise ProtocolError("[invalid_request] The request arguments must be an object.")
    return operation, arguments


def encode_ok(result):
    return "OK\t" + _b64(json.dumps(result, separators=(",", ":"), default=str)) + "\n"


def encode_error(message):
    text = str(message or "error")
    if not text.startswith("["):
        text = "[max_error] " + text
    return "ERR\t" + _b64(text) + "\n"


def decode_answer(line):
    """Client side, used by the tests: returns the result or raises ProtocolError with the bridge's message."""
    kind, _, payload = line.rstrip("\r\n").partition("\t")
    text = base64.b64decode(payload).decode("utf-8")
    if kind == "OK":
        return json.loads(text)
    if kind == "ERR":
        raise ProtocolError(text)
    raise ProtocolError("[invalid_response] Unknown answer.")
