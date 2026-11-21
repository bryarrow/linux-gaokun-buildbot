#!/usr/bin/env bash
# Pin one kernel output under a stable name, keeping the three most recent
# revisions. Cachix GC is LRU-based; the EL2 modules output is cold and would
# otherwise be the first thing evicted when the 5 GB quota fills.
#
# The pin is skipped when the latest revision already names this store path:
# CI runs on commits that do not change the kernel would otherwise pin the same
# path again, and three duplicate revisions would evict the older generations
# this is meant to keep.
set -euo pipefail

cache=${1:?usage: pin-kernel.sh CACHE PIN-NAME STORE-PATH}
pin_name=${2:?usage: pin-kernel.sh CACHE PIN-NAME STORE-PATH}
store_path=${3:?usage: pin-kernel.sh CACHE PIN-NAME STORE-PATH}

: "${CACHIX_AUTH_TOKEN:?CACHIX_AUTH_TOKEN is not set}"

# The CLI bundled with cachix-action 1.x has no `pins get`; the same listing is
# available from the dashboard API as `[Pin]`, where lastRevision.storePath is
# the revision's store path.
latest=$(
  curl -fsS --max-time 30 \
    -H "Authorization: Bearer $CACHIX_AUTH_TOKEN" \
    "https://app.cachix.org/api/v1/cache/$cache/pin" |
    jq -r --arg name "$pin_name" \
      '.[] | select(.name == $name) | .lastRevision.storePath' |
    head -n 1
)

if [ "$latest" = "$store_path" ]; then
  echo "$pin_name is already pinned to $store_path"
  exit 0
fi

# Pin only after the path is in the cache; a pin does not upload anything and
# fails if the path is missing.
cachix push "$cache" "$store_path"
cachix pin "$cache" "$pin_name" "$store_path" --keep-revisions 3
