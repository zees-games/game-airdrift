#!/usr/bin/env bash
# The windowed benchmark on a GPU box: gs-game's tools/perf_bench.sh with this checkout (see tools/perf_bench.gd).
# The bots ride and fire nothing, so the world is legitimately static: skip the inert-per-tick check.
export PERF_BENCH_INERT_PER_TICK="${PERF_BENCH_INERT_PER_TICK:-0}"
exec bash "$(dirname "$0")/../addons/gs_game/tools/gs_game_perf_bench.sh" "$@"
