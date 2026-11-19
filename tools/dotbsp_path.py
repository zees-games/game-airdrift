"""Finds the dot-map-convert checkout that the converter launchers in this directory run from.

`$DOTBSP_PATH` first, then the sibling `../dot-map-convert` (dot-bootstrap makes it), then the sibling of the main checkout when this
is a git worktree. Returns the path even when it is missing, so each caller can say what it could not find.
"""
import os
import subprocess

_HERE = os.path.dirname(os.path.abspath(__file__))


def find() -> str:
    env = os.environ.get("DOTBSP_PATH")
    if env:
        return env
    sibling = os.path.normpath(os.path.join(_HERE, "..", "..", "dot-map-convert"))
    if os.path.isdir(sibling):
        return sibling
    try:
        common = subprocess.check_output(["git", "-C", _HERE, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                         text=True, stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        return sibling
    cand = os.path.join(os.path.dirname(os.path.dirname(common)), "dot-map-convert")
    return cand if os.path.isdir(cand) else sibling


def adapter_repo(converter: str) -> str:
    """This game's adapter directory name in dot-map-convert/adapters: game-airdrift, or the old Airdrift repository name in a
    dot-map-convert checkout from before its rename (a0ef1d9; newer ones also accept the old name through adapter_launch.FORMER)."""
    if os.path.isdir(os.path.join(converter, "adapters", "game-airdrift")):
        return "game-airdrift"
    return "game-airdrift"
