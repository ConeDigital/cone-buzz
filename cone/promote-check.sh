#!/usr/bin/env bash
# May the feed move to this version? (Slice 29 merge 3, review of #6.) A
# promotion replaces the one latest.json every app reads, and an app looks only
# for a version newer than its own — so a feed moved back to an older release
# hides the newer one from every app still below it. The promote job runs this
# against what the feed serves right before it uploads (one promotion at a
# time: the job's feed-wide concurrency group).
#
#   cone/promote-check.sh <current-feed-file> <version>
#
# <current-feed-file> is the latest.json the feed serves now; a missing or
# empty file, or one without a `version` (the placeholder), allows any
# version. Allowed: the same version again (a re-promotion) or a newer one.
# Refused: an older version, or a current version that is not X.Y.Z (the feed
# holds something no promotion wrote: look at it first). Exits 0 allowed, 1
# refused, 2 on a usage error. Restoring a saved feed byte for byte is not a
# promotion (docs/operations.md in cone-buzz-infra).
set -euo pipefail

(( $# == 2 )) || { echo "usage: cone/promote-check.sh <current-feed-file> <version>" >&2; exit 2; }
current_file="$1" version="$2"
semver='^([0-9]+)\.([0-9]+)\.([0-9]+)$'
[[ "$version" =~ $semver ]] || { echo "promote-check: '$version' is not X.Y.Z" >&2; exit 2; }
new=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")

current=""
if [[ -s "$current_file" ]]; then
  current="$(jq -r '.version // empty' "$current_file" 2>/dev/null)" \
    || { echo "promote-check: REFUSED — the feed serves something that is not JSON; look at it first" >&2; exit 1; }
fi
if [[ -z "$current" ]]; then
  echo "promote-check: the feed names no version; $version allowed"
  exit 0
fi
[[ "$current" =~ $semver ]] \
  || { echo "promote-check: REFUSED — the feed serves version '$current', which no promotion writes; look at it first" >&2; exit 1; }
cur=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")

for i in 0 1 2; do
  if (( 10#${new[i]} > 10#${cur[i]} )); then echo "promote-check: $current → $version allowed (newer)"; exit 0; fi
  if (( 10#${new[i]} < 10#${cur[i]} )); then
    echo "promote-check: REFUSED — the feed serves $current; $version is older and would hide $current from every app below it" >&2
    exit 1
  fi
done
echo "promote-check: $version again allowed (the feed already serves it)"
