# Imports the extensionless `minidsp-mqtt` script as module `minidsp_mqtt`
# so the pure logic (volume curve, calibration interpolation, command
# parsing) is testable without renaming the installed file.
#
# Requires the bridge's runtime deps (paho-mqtt, httpx, websockets) on the
# test host: python3 -m venv .venv && .venv/bin/pip install pytest paho-mqtt \
#     httpx websockets && .venv/bin/pytest
import importlib.machinery
import importlib.util
import pathlib
import sys

_SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "minidsp-mqtt"

_loader = importlib.machinery.SourceFileLoader("minidsp_mqtt", str(_SCRIPT))
_spec = importlib.util.spec_from_loader("minidsp_mqtt", _loader)
_mod = importlib.util.module_from_spec(_spec)
sys.modules["minidsp_mqtt"] = _mod
_loader.exec_module(_mod)
