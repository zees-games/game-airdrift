"""Launcher: this script lives in gs-map-convert/adapters/game-airdrift/teleport_traps.py, the family's one converter repository."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gsbsp_path  # noqa: E402
_C = gsbsp_path.find()
sys.path.insert(0, os.path.join(_C, "adapters"))
import adapter_launch  # noqa: E402
adapter_launch.run(globals(), gsbsp_path.adapter_repo(_C), "teleport_traps.py")
