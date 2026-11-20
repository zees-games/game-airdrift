#!/bin/bash
# Publishes this game's pack (id game-airdrift). worlds/, maps/imported and the model/pbr libraries link to airdrift-maps (../airdrift-maps).
#   tools/publish.sh [--version V | --bump patch] [--site URL --token-file F --dry-run ...]   (lock: ./content.lock.json, override with --lock)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
X=(); for d in screenshots worlds model-library pbr-library imported tools examples docs images .github; do X+=(--exclude-dir "$d"); done
PUB="$HERE/../dot-cloud/tools/publish_pack.sh"; HOSTLOCK="$HERE/../dot-server-deploy/addons.lock"; GV=0.0.0
BASE=(publish --source "$HERE" --id game-airdrift --host-addons "$HOSTLOCK" "${X[@]}")
# Gates before an upload: every load of the game's own files goes through the game's path rebase
# (tools/check_pack_paths.sh), and publish_pack.sh boots the pack it builds mounted, under res://dot_cloud/<id>/<version>/,
# on a host built at --host-addons addons.lock's tags (dot-cloud tools/pack_boot_test.sh; exit 1 does not boot, 2 could
# not judge). Airdrift and Playlot 0.1.33, Zombie Zone 0.1.40 and Hungario 0.1.19 booted nothing on servers without it.
"$HERE/tools/check_pack_paths.sh" "$HERE"
exec "$PUB" "${BASE[@]}" --lock "$HERE/content.lock.json" "$@"
