"""Pure decision logic for whether a physical event reaches the virtual pad.

Kept free of evdev/uinput imports (see remap.py for the code that actually
grabs devices and writes to them) so the rules below can be unit-tested
without real hardware.

There are exactly two things that keep a physical button or axis from
reaching a game once it has been decoded off the wire:

  * It is the white/system button. White is never forwarded to a game, in
    any mode — the launcher owns it exclusively, and the only way its press
    ever reaches a game is the explicit "inject" control command (used for
    "Send pause"). This is what keeps a system-overlay press out of the game
    entirely, rather than relying on the launcher to swallow it after the
    fact — by the time the launcher could see it, a game reading the same
    virtual pad would already have seen it too.
  * The gate is BLOCKED. This is set while a game is frozen behind the
    system overlay, the attract screen, or the held-game menu, so that
    joystick and button presses used to navigate the launcher's own UI do
    not queue up on the game's device fd and replay the instant it resumes.
"""
import threading

PASS = "pass"
BLOCKED = "blocked"
MODES = (PASS, BLOCKED)


class OutputGate:
    """Tracks whether physical input should currently reach the virtual pad.

    A single instance is shared by every per-controller remapping thread (see
    remap_all() in remap.py), so the launcher's mode command affects both
    cabinet controllers at once.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._mode = PASS

    def get_mode(self):
        with self._lock:
            return self._mode

    def set_mode(self, mode):
        if mode not in MODES:
            raise ValueError("unknown mode: %r" % (mode,))
        with self._lock:
            self._mode = mode


def is_white_code(code, cabinet):
    """True if `code` is the physical evdev code of the white/system button.

    `cabinet` is the position -> evdev code mapping loaded from
    cabinet.json. A cabinet with no `white` position configured never
    matches, so passthrough behaves exactly as it did before this button
    existed.
    """
    return cabinet.get("white") == code


def decide(code, mode, cabinet):
    """Whether a physical EV_KEY `code` should be written to the virtual pad.

    Returns True to forward it (through the caller's button map) or False to
    drop it silently. This only governs EV_KEY codes — axis/other events are
    gated by the caller checking `mode` directly, since white is a button and
    cannot collide with an axis code.
    """
    if is_white_code(code, cabinet):
        return False
    return mode == PASS
