import math

import pytest

import minidsp_mqtt as m


# ── _parse_calibration ───────────────────────────────────────────────────
def test_parse_calibration_basic():
    assert m._parse_calibration("0:0,50:60,100:100") == [(0, 0), (50, 60), (100, 100)]


def test_parse_calibration_sorts_and_skips_malformed():
    pairs = m._parse_calibration("100:100, 0:0, junk, 5:x, 50:60,")
    assert pairs == [(0, 0), (50, 60), (100, 100)]


def test_parse_calibration_empty_falls_back_to_identity():
    assert m._parse_calibration("") == [(0, 0), (100, 100)]
    assert m._parse_calibration("garbage") == [(0, 0), (100, 100)]


# ── _interp ──────────────────────────────────────────────────────────────
IDENT = [(0, 0), (100, 100)]


def test_interp_below_and_above_range_clamps():
    pairs = [(10, 20), (90, 80)]
    assert m._interp(0, pairs, 0, 1) == 20
    assert m._interp(10, pairs, 0, 1) == 20
    assert m._interp(90, pairs, 0, 1) == 80
    assert m._interp(200, pairs, 0, 1) == 80


def test_interp_midpoint():
    pairs = [(0, 0), (100, 50)]
    assert m._interp(50, pairs, 0, 1) == pytest.approx(25.0)


def test_interp_duplicate_keys_never_raise():
    # A user-supplied CALIBRATION can contain duplicate values in either
    # column (LMS's curve is locally flat); inverted, that gives identical
    # keys. The x1 == x0 guard is defensive — with sorted pairs the
    # preceding segment captures x first — but no input may ever divide by
    # zero, and results must stay within the table's value range.
    pairs = [(0, 0), (49, 25), (49, 26), (66, 50)]
    for x in range(-5, 75):
        y = m._interp(x, pairs, 0, 1)
        assert 0 <= y <= 50


# ── calibration round-trip on the shipped default table ──────────────────
def test_lms_to_sq_matches_default_table_anchors():
    for lms, sq in m._parse_calibration(m.CALIBRATION_DEFAULT):
        assert m.lms_to_sq(lms) == sq


def test_sq_to_lms_round_trip_stability():
    # sq_to_lms(lms_to_sq(v)) can differ where LMS's curve is locally flat
    # (documented ±1 ambiguity); it must never drift beyond that.
    for v in range(0, 101):
        assert abs(m.sq_to_lms(m.lms_to_sq(v)) - v) <= 1


def test_calibration_monotonic_non_decreasing():
    table = [m.lms_to_sq(v) for v in range(0, 101)]
    assert table == sorted(table)


# ── volume curve forward/inverse ─────────────────────────────────────────
@pytest.mark.parametrize("floor,k", [(-50.0, 1.0), (-50.0, 2.0),
                                     (-30.0, 1.0), (-72.0, 2.0)])
def test_db_vol_round_trip(monkeypatch, floor, k):
    monkeypatch.setattr(m, "FLOOR_DB", floor)
    monkeypatch.setattr(m, "CURVE_K", k)
    for v in range(0, 101):
        assert m.db_to_vol(m.vol_to_db(v)) == v


def test_vol_to_db_edges(monkeypatch):
    monkeypatch.setattr(m, "FLOOR_DB", -50.0)
    monkeypatch.setattr(m, "CURVE_K", 2.0)
    assert m.vol_to_db(0) == -50.0          # HA slider 0 -> floor, NOT -127
    assert m.vol_to_db(-5) == -50.0
    assert m.vol_to_db(100) == pytest.approx(0.0)
    assert m.vol_to_db(150) == pytest.approx(0.0)   # clamped to 100


def test_db_to_vol_edges(monkeypatch):
    monkeypatch.setattr(m, "FLOOR_DB", -50.0)
    monkeypatch.setattr(m, "CURVE_K", 2.0)
    assert m.db_to_vol(-127.0) == 0          # squeezelite pause sentinel
    assert m.db_to_vol(-126.5) == 0
    assert m.db_to_vol(0.0) == 100
    assert m.db_to_vol(5.0) == 100           # above range clamps
    assert m.db_to_vol(-60.0) == 0           # below floor clamps


def test_db_to_vol_degenerate_params(monkeypatch):
    monkeypatch.setattr(m, "FLOOR_DB", 0.0)
    assert m.db_to_vol(-10.0) == 100
    monkeypatch.setattr(m, "FLOOR_DB", -50.0)
    monkeypatch.setattr(m, "CURVE_K", 0.0)
    assert m.db_to_vol(-10.0) == 100


# ── _build_patch ─────────────────────────────────────────────────────────
@pytest.fixture
def bridge_patch():
    # _build_patch is effectively a pure method: grab it unbound.
    return lambda field, payload: m.Bridge._build_patch(None, field, payload)


def test_patch_volume_clamps_and_translates(monkeypatch, bridge_patch):
    monkeypatch.setattr(m, "FLOOR_DB", -50.0)
    monkeypatch.setattr(m, "CURVE_K", 2.0)
    p = bridge_patch("volume", "100")
    assert p == {"master_status": {"volume": pytest.approx(0.0)}}
    p = bridge_patch("volume", "250")        # clamps to 100
    assert p == {"master_status": {"volume": pytest.approx(0.0)}}
    p = bridge_patch("volume", "0")
    assert p["master_status"]["volume"] == pytest.approx(-50.0)
    p = bridge_patch("volume", "-3")         # clamps to 0
    assert p["master_status"]["volume"] == pytest.approx(-50.0)


def test_patch_volume_rejects_junk(bridge_patch):
    assert bridge_patch("volume", "loud") is None
    assert bridge_patch("volume", "") is None


def test_patch_mute(bridge_patch):
    for on in ("ON", "on", "1", "TRUE", "yes"):
        assert bridge_patch("mute", on) == {"master_status": {"mute": True}}
    for off in ("OFF", "0", "FALSE", "no", "junk"):
        assert bridge_patch("mute", off) == {"master_status": {"mute": False}}


def test_patch_source_passthrough(bridge_patch):
    assert bridge_patch("source", "Toslink") == {"master_status": {"source": "Toslink"}}


def test_patch_preset_numeric_and_named(bridge_patch):
    assert bridge_patch("preset", "1") == {"master_status": {"preset": 0}}
    assert bridge_patch("preset", "4") == {"master_status": {"preset": 3}}
    assert bridge_patch("preset", "0") == {"master_status": {"preset": 0}}
    assert bridge_patch("preset", "Config 2") == {"master_status": {"preset": 1}}
    assert bridge_patch("preset", "9") is None
    assert bridge_patch("preset", "Config 9") is None


def test_patch_unknown_field(bridge_patch):
    assert bridge_patch("bass", "11") is None


# ── read_lms_vol ─────────────────────────────────────────────────────────
def test_read_lms_vol(monkeypatch, tmp_path):
    f = tmp_path / "vol"
    monkeypatch.setattr(m, "LMS_VOL_FILE", str(f))
    assert m.read_lms_vol() is None          # missing
    f.write_text("66\n")
    assert m.read_lms_vol() == 66
    f.write_text("250")
    assert m.read_lms_vol() == 100           # clamped
    f.write_text("not-a-number")
    assert m.read_lms_vol() is None
