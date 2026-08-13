from evdev import ecodes

from shanwan_remap.remap import (
    compose_button_map,
    build_feed_message,
    neutralize_outputs,
)

CABINET = {"white": 315, "bottom_right": 304, "bottom_middle": 305}
KEYMAP = {"bottom_right": "A", "bottom_middle": "B", "white": "Start"}


class FakeEvent:
    def __init__(self, etype, code, value):
        self.type = etype
        self.code = code
        self.value = value


class FakeUInput:
    """Records writes instead of touching a real uinput device."""

    def __init__(self):
        self.writes = []

    def write(self, etype, code, value):
        self.writes.append((etype, code, value))

    def syn(self):
        pass


def test_compose_button_map_skips_the_joystick_key():
    button_map = compose_button_map(CABINET, {"joystick": "dpad", "bottom_right": "A"})
    assert button_map == {304: ecodes.BTN_SOUTH}


def test_compose_button_map_is_empty_without_both_files():
    assert compose_button_map({}, KEYMAP) == {}
    assert compose_button_map(CABINET, {}) == {}


def test_compose_button_map_skips_unknown_position_and_xbox_name():
    button_map = compose_button_map(
        CABINET, {"bottom_right": "A", "made_up": "A", "bottom_middle": "NotAButton"}
    )
    assert button_map == {304: ecodes.BTN_SOUTH}


def test_build_feed_message_reports_white_as_system_with_null_xbox():
    # Even though this keymap maps white -> Start, the feed must still say
    # xbox=None: white is a system position now, whatever a keymap claims.
    button_map = compose_button_map(CABINET, KEYMAP)
    code_to_position = {code: pos for pos, code in CABINET.items()}
    event = FakeEvent(ecodes.EV_KEY, 315, 1)
    assert build_feed_message(1, event, code_to_position, button_map) == {
        "t": "btn", "pad": 1, "pos": "white", "xbox": None, "v": 1,
    }


def test_build_feed_message_reports_the_mapped_xbox_name():
    button_map = compose_button_map(CABINET, KEYMAP)
    code_to_position = {code: pos for pos, code in CABINET.items()}
    event = FakeEvent(ecodes.EV_KEY, 304, 1)
    assert build_feed_message(1, event, code_to_position, button_map) == {
        "t": "btn", "pad": 1, "pos": "bottom_right", "xbox": "A", "v": 1,
    }


def test_build_feed_message_reports_hat_axes():
    event = FakeEvent(ecodes.EV_ABS, ecodes.ABS_HAT0X, -1)
    assert build_feed_message(1, event, {}, {}) == {"t": "hat", "pad": 1, "axis": "x", "v": -1}


def test_build_feed_message_ignores_unrelated_events():
    event = FakeEvent(ecodes.EV_ABS, ecodes.ABS_X, 127)
    assert build_feed_message(1, event, {}, {}) is None


def test_neutralize_outputs_releases_every_mapped_button():
    ui = FakeUInput()
    button_map = compose_button_map(CABINET, KEYMAP)
    neutralize_outputs(ui, button_map)
    released_keys = {code for etype, code, value in ui.writes if etype == ecodes.EV_KEY and value == 0}
    assert ecodes.BTN_SOUTH in released_keys  # "A", from bottom_right
    assert ecodes.BTN_EAST in released_keys  # "B", from bottom_middle


def test_neutralize_outputs_centers_both_sticks_and_the_hat():
    ui = FakeUInput()
    neutralize_outputs(ui, {})
    writes = {(etype, code): value for etype, code, value in ui.writes}
    for axis in (ecodes.ABS_X, ecodes.ABS_Y, ecodes.ABS_RX, ecodes.ABS_RY):
        assert writes[(ecodes.EV_ABS, axis)] == 127
    for axis in (ecodes.ABS_HAT0X, ecodes.ABS_HAT0Y):
        assert writes[(ecodes.EV_ABS, axis)] == 0
