import pytest

from shanwan_remap.gate import OutputGate, PASS, BLOCKED, is_white_code, decide

CABINET = {"white": 315, "bottom_right": 304, "bottom_middle": 305}


def test_default_mode_is_pass():
    assert OutputGate().get_mode() == PASS


def test_set_mode_round_trips():
    gate = OutputGate()
    gate.set_mode(BLOCKED)
    assert gate.get_mode() == BLOCKED
    gate.set_mode(PASS)
    assert gate.get_mode() == PASS


def test_set_mode_rejects_unknown_value():
    gate = OutputGate()
    with pytest.raises(ValueError):
        gate.set_mode("nope")
    assert gate.get_mode() == PASS  # rejected, unchanged


def test_is_white_code_matches_configured_white_position():
    assert is_white_code(315, CABINET)
    assert not is_white_code(304, CABINET)


def test_is_white_code_false_when_cabinet_has_no_white():
    assert not is_white_code(315, {})


def test_decide_drops_white_regardless_of_mode():
    assert decide(315, PASS, CABINET) is False
    assert decide(315, BLOCKED, CABINET) is False


def test_decide_forwards_non_white_only_in_pass_mode():
    assert decide(304, PASS, CABINET) is True
    assert decide(304, BLOCKED, CABINET) is False


def test_decide_treats_unconfigured_cabinet_as_never_white():
    # No cabinet.json yet -> total passthrough, same as before this feature
    # existed, rather than accidentally dropping some button.
    assert decide(304, PASS, {}) is True
