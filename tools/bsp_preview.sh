#!/usr/bin/env bash
# Render an imported map to screenshots/<id>_*.png so a person can look at it.
#
#   tools/bsp_preview.sh                       # every imported map, from its spawn
#   tools/bsp_preview.sh surf_kitsune          # one, from its spawn
#   tools/bsp_preview.sh surf_kitsune orbit    # one, orbiting the whole map
#   tools/bsp_preview.sh surf_kitsune spawn 6  # six angles instead of four
#   GAME=1 tools/bsp_preview.sh                # as the GAME draws it: the map's own sky,
#                                              # fog and tone map, not the neutral stage
#   PREVIEW_PITCH=0.5 tools/bsp_preview.sh m spawn  # look up from the spawn (radians)
#
# `tools/bsp_preview.gd` has named this script since it was written and it did not
# exist, so the one thing in this repository whose bugs are invisible to every
# assertion available had no one-line way to look at it. Four of the bugs in this
# family's own list were found by looking at a picture.
#
# xvfb-run because this needs a rendering context and the machines this runs on have
# no display. `--headless` is NOT a substitute: it gives a null renderer and saves a
# frame of nothing, which is worse than no screenshot because it looks like one.
set -euo pipefail
cd "$(dirname "$0")/.."

# A map takes 30+ minutes per frame on llvmpipe (a machine with no GPU). `heavy` already offers this
# script to a GPU box, but when both boxes are busy for its 90 s window it runs the script right here,
# and a QA run was killed after 30 minutes that way. So a host with no render node hands itself to
# `gpu.sh shot` (which waits GPU_SHOT_WAIT, default 1 h here, for a box and carries frames back), and a
# second arrival without a GPU stops loudly instead of crawling. PREVIEW_ALLOW_CPU=1 renders here anyway.
if ! ls /dev/dri/renderD* /dev/nvidiactl >/dev/null 2>&1 && [ -z "${PREVIEW_ALLOW_CPU:-}" ]; then
    gpu_sh="${GPU_SH:-$(command -v gpu.sh || echo "$HOME/godot/gs-bootstrap/tools/gpu.sh")}"
    if [ -z "${PREVIEW_VIA_GPU:-}" ] && [ -n "$gpu_sh" ] && [ -x "$gpu_sh" ]; then
        export PREVIEW_VIA_GPU=1 SHOT_DIR="$PWD" GPU_SHOT_WAIT="${GPU_SHOT_WAIT:-3600}" GPU_SHOT_TIMEOUT="${GPU_SHOT_TIMEOUT:-3600}"
        exec "$gpu_sh" shot "$(basename "$PWD")" tools/bsp_preview.sh "$@"
    fi
    echo "bsp_preview: no GPU here (llvmpipe takes 30+ minutes a map) and no GPU box took the job." >&2
    echo "  Set GPU_SH to gpu.sh or run it through heavy; PREVIEW_ALLOW_CPU=1 renders here anyway." >&2
    exit 75
fi
mkdir -p screenshots

ids=()
if [ $# -gt 0 ] && [ -n "${1:-}" ]; then
    ids=("$1"); shift
else
    # No list anywhere: whatever is on the disk, which is how the game finds them too.
    for d in maps/imported/*/; do
        id="$(basename "$d")"
        [ -f "$d/$id.json" ] && ids+=("$id")
    done
fi
view="${1:-spawn}" ; shots="${2:-4}"

for id in "${ids[@]}"; do
    echo "  rendering $id ($view)"
    xvfb-run -a godot --path . --resolution 1600x900 \
        tools/bsp_preview.tscn -- "$id" "screenshots/${id}_${view}${GAME:+_game}.png" "$shots" "$view" \
        ${GAME:+- - - keepenv} \
        2>&1 | grep -E "^\[preview\]" || true
done
echo "screenshots/ now holds:"
ls -1 screenshots/ | sed 's/^/  /'
