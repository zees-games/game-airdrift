#!/usr/bin/env bash
# One third-person look at an avatar: another runner 2.5 m ahead, facing the camera, playing
# an emote. Writes screenshots/hud_action_<id>_a.png (and _b). Real GPU via gpu.sh.
#   tools/avatar_shot.sh [emote-id]
set -euo pipefail
cd "$(dirname "$0")/.."
exec tools/screenshot_hud.sh --action emote "${1:-dance}"
