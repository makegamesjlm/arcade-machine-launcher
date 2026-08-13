"""TCP control channel between the remapper and the arcade launcher.

Newline-delimited JSON, remapper as server. Loopback-only (127.0.0.1) — the
launcher and the remapper always run on the same box, and nothing else on a
kiosk needs to reach this port, so there is no authentication.

Two directions:

  * Feed (remapper -> launcher): every physical button/hat event, broadcast
    to every connected client, so the launcher can drive its own UI (the
    system overlay, or menu navigation while a game is held) off the same
    controllers a game reads, without ever installing its own evdev grab.
  * Commands (launcher -> remapper): "hello" to handshake, "mode" to flip
    the OutputGate between pass/blocked, "inject" to write one synthetic
    press+release through the current keymap (used for "Send pause").

The remapper is the thing with root and the uinput handles, so it is also
the thing that has to notice if nobody is listening anymore: if the last
control client disconnects while the gate is BLOCKED, a game would be frozen
and permanently deaf to its own controller. `revert_fn` exists so remap.py
can put the gate back to `pass` the moment that happens, rather than after
the launcher happens to reconnect.
"""
import json
import logging
import socket
import threading

LOG = logging.getLogger("shanwan-remap.control")

HOST = "127.0.0.1"
PORT = 47811

# Bumped whenever the wire format changes. The launcher's handshake refuses
# to enable overlay features against a remapper that reports an older
# version, so a half-upgraded cabinet is diagnosable rather than mysterious.
PROTOCOL_VERSION = 1


def encode(message):
    """Serialize one message to a newline-terminated JSON line."""
    return (json.dumps(message, separators=(",", ":")) + "\n").encode("utf-8")


def decode_line(line):
    """Parse one newline-delimited JSON command line.

    Raises ValueError (bad JSON) or TypeError (valid JSON, wrong shape) —
    callers should treat both as "reject this line", not crash the client.
    """
    message = json.loads(line)
    if not isinstance(message, dict):
        raise TypeError("command must be a JSON object")
    return message


class ControlServer:
    """Owns the listening socket and every connected client.

    remap.py supplies three callbacks rather than handing over the gate and
    uinput registry directly, so this module never needs to import evdev:
      set_mode_fn(mode) -> None, raises ValueError on an unknown mode
      inject_fn(pos) -> "" on success, or a human-readable error string
      revert_fn() -> None, called when the last client disconnects
    """

    def __init__(self, has_white, set_mode_fn, inject_fn, revert_fn):
        self._has_white = has_white
        self._set_mode_fn = set_mode_fn
        self._inject_fn = inject_fn
        self._revert_fn = revert_fn
        self._clients_lock = threading.Lock()
        self._clients = set()
        self._server = None

    def start(self, host=HOST, port=PORT):
        """Bind and start accepting clients.

        `host`/`port` default to the real cabinet address; tests pass
        port=0 to get an OS-assigned free port instead (see `address`).
        """
        self._server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server.bind((host, port))
        self._server.listen(4)
        t = threading.Thread(target=self._accept_loop, daemon=True)
        t.start()
        LOG.info("Control channel listening on %s:%d", *self.address)
        return t

    @property
    def address(self):
        """The (host, port) actually bound, after start()."""
        return self._server.getsockname()

    @property
    def client_count(self):
        """Number of currently connected clients. Mainly for tests."""
        with self._clients_lock:
            return len(self._clients)

    def stop(self):
        if self._server is not None:
            try:
                self._server.close()
            except OSError:
                pass

    def broadcast(self, message):
        """Send a feed message to every connected client. Never raises."""
        with self._clients_lock:
            clients = list(self._clients)
        if not clients:
            return
        data = encode(message)
        for conn in clients:
            try:
                conn.sendall(data)
            except OSError:
                self._drop_client(conn)

    def _accept_loop(self):
        while True:
            try:
                conn, _addr = self._server.accept()
            except OSError:
                return  # socket closed under us (stop(), or shutdown)
            with self._clients_lock:
                self._clients.add(conn)
            LOG.info("Control client connected")
            t = threading.Thread(target=self._client_loop, args=(conn,), daemon=True)
            t.start()

    def _client_loop(self, conn):
        buf = b""
        try:
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if line.strip():
                        self._handle_line(conn, line)
        except OSError:
            pass
        finally:
            self._drop_client(conn)

    def _handle_line(self, conn, line):
        try:
            message = decode_line(line)
        except (ValueError, TypeError) as e:
            self._send(conn, {"ok": False, "error": "bad message: %s" % e})
            return

        command = message.get("c")
        if command == "hello":
            self._send(conn, {
                "ok": True, "reply": "hello",
                "proto": PROTOCOL_VERSION, "has_white": self._has_white,
            })
        elif command == "mode":
            mode = message.get("m")
            try:
                self._set_mode_fn(mode)
            except ValueError as e:
                self._send(conn, {"ok": False, "reply": "mode", "error": str(e)})
                return
            self._send(conn, {"ok": True, "reply": "mode", "m": mode})
        elif command == "inject":
            pos = message.get("pos")
            error = self._inject_fn(pos)
            if error:
                self._send(conn, {"ok": False, "reply": "inject", "error": error})
            else:
                self._send(conn, {"ok": True, "reply": "inject", "pos": pos})
        else:
            self._send(conn, {"ok": False, "error": "unknown command: %r" % (command,)})

    def _send(self, conn, message):
        try:
            conn.sendall(encode(message))
        except OSError:
            self._drop_client(conn)

    def _drop_client(self, conn):
        with self._clients_lock:
            self._clients.discard(conn)
            remaining = len(self._clients)
        try:
            conn.close()
        except OSError:
            pass
        LOG.info("Control client disconnected (%d remaining)", remaining)
        if remaining == 0:
            LOG.warning("No control clients left; reverting gate")
            self._revert_fn()
