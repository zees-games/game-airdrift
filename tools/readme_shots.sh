#!/usr/bin/env bash
# Renders the README's gameplay frames (docs/screenshots/) from the real offline client.
#
#   tools/readme_shots.sh <scenario> [map] [seconds]
#
# Scenarios are listed in tools/readme_shots.gd. Needs a rendering context and a real GPU:
# a host with none hands itself to gpu.sh (llvmpipe takes far too long and looks different).
set -euo pipefail
cd "$(dirname "$0")/.."
if ! ls /dev/dri/renderD* /dev/nvidiactl >/dev/null 2>&1 && [ -z "${SHOT_ALLOW_CPU:-}" ]; then
    gpu_sh="${GPU_SH:-$(command -v gpu.sh || echo "$HOME/godot/dot-bootstrap/tools/gpu.sh")}"
    if [ -z "${SHOT_VIA_GPU:-}" ] && [ -x "$gpu_sh" ]; then
        export SHOT_VIA_GPU=1
        exec "$gpu_sh" shot "$(basename "$PWD")" tools/readme_shots.sh "$@"
    fi
    echo "readme_shots: no GPU here and no GPU box took the job." >&2
    exit 75
fi
mkdir -p screenshots
# Several scenarios in one job (a GPU box upload is slow): each argument is scenario:map:arg:arg...
if [[ "${1:-}" == *:* ]]; then
    for spec in "$@"; do
        IFS=: read -r -a parts <<<"$spec"
        xvfb-run -a godot --path . --resolution 1280x720 --script tools/readme_shots.gd -- "${parts[@]}"
    done
    exit 0
fi
exec xvfb-run -a godot --path . --resolution 1280x720 --script tools/readme_shots.gd -- "$@"
