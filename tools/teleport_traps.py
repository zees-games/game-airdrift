"""Launcher: this script lives in dot-map-convert/adapters/game-g2gfast/teleport_traps.py, the family's one converter repository."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dotbsp_path  # noqa: E402
_C = dotbsp_path.find()
sys.path.insert(0, os.path.join(_C, "adapters"))
import adapter_launch  # noqa: E402
adapter_launch.run(globals(), "game-g2gfast", "teleport_traps.py")
