import json
import socket
import threading
import time

import pytest

from shanwan_remap.control import ControlServer, encode, decode_line, PROTOCOL_VERSION


def test_encode_produces_one_newline_terminated_json_line():
    data = encode({"a": 1})
    assert data.endswith(b"\n")
    assert data.count(b"\n") == 1
    assert json.loads(data.decode("utf-8")) == {"a": 1}


def test_decode_line_parses_object():
    assert decode_line(b'{"c":"hello"}') == {"c": "hello"}


def test_decode_line_rejects_non_object():
    with pytest.raises(TypeError):
        decode_line(b"[1,2,3]")


def test_decode_line_rejects_malformed_json():
    with pytest.raises(ValueError):
        decode_line(b"not json")


def _connect(server):
    host, port = server.address
    return socket.create_connection((host, port), timeout=2)


def _read_line(sock):
    buf = b""
    while b"\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
    line, _, _ = buf.partition(b"\n")
    return json.loads(line.decode("utf-8"))


@pytest.fixture
def server():
    """A ControlServer bound to an OS-assigned free port, torn down after."""
    instances = []

    def make(has_white=True, set_mode_fn=None, inject_fn=None, revert_fn=None):
        s = ControlServer(
            has_white,
            set_mode_fn or (lambda m: None),
            inject_fn or (lambda p: ""),
            revert_fn or (lambda: None),
        )
        s.start(port=0)
        instances.append(s)
        return s

    yield make
    for s in instances:
        s.stop()


def test_hello_handshake_reports_protocol_version_and_has_white(server):
    sock = _connect(server(has_white=True))
    sock.sendall(encode({"c": "hello"}))
    reply = _read_line(sock)
    assert reply == {"ok": True, "reply": "hello", "proto": PROTOCOL_VERSION, "has_white": True}


def test_mode_command_invokes_callback_and_acks(server):
    seen = []
    sock = _connect(server(set_mode_fn=seen.append))
    sock.sendall(encode({"c": "mode", "m": "blocked"}))
    reply = _read_line(sock)
    assert reply == {"ok": True, "reply": "mode", "m": "blocked"}
    assert seen == ["blocked"]


def test_mode_command_reports_rejection_from_set_mode_fn(server):
    def rejecting(mode):
        raise ValueError("unknown mode: %r" % (mode,))

    sock = _connect(server(set_mode_fn=rejecting))
    sock.sendall(encode({"c": "mode", "m": "nonsense"}))
    reply = _read_line(sock)
    assert reply["ok"] is False
    assert reply["reply"] == "mode"


def test_inject_command_acks_on_success(server):
    sock = _connect(server(inject_fn=lambda pos: ""))
    sock.sendall(encode({"c": "inject", "pos": "white"}))
    reply = _read_line(sock)
    assert reply == {"ok": True, "reply": "inject", "pos": "white"}


def test_inject_command_reports_error_from_inject_fn(server):
    sock = _connect(server(inject_fn=lambda pos: "position not found"))
    sock.sendall(encode({"c": "inject", "pos": "white"}))
    reply = _read_line(sock)
    assert reply == {"ok": False, "reply": "inject", "error": "position not found"}


def test_unknown_command_is_rejected(server):
    sock = _connect(server())
    sock.sendall(encode({"c": "made-up"}))
    reply = _read_line(sock)
    assert reply["ok"] is False


def test_broadcast_reaches_every_connected_client(server):
    s = server()
    a, b = _connect(s), _connect(s)
    deadline = time.monotonic() + 2
    while s.client_count < 2 and time.monotonic() < deadline:
        time.sleep(0.01)  # let the accept thread register both sockets
    s.broadcast({"t": "btn", "pad": 1, "pos": "white", "xbox": None, "v": 1})
    assert _read_line(a)["pos"] == "white"
    assert _read_line(b)["pos"] == "white"


def test_last_client_disconnect_triggers_dead_man_revert(server):
    reverted = threading.Event()
    sock = _connect(server(revert_fn=reverted.set))
    sock.sendall(encode({"c": "hello"}))
    _read_line(sock)
    sock.close()
    assert reverted.wait(timeout=2)
