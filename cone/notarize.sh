#!/usr/bin/env bash
# Apple's notary service for the release run (Slice 29 merge 2), in two halves
# so a release survives Apple taking hours (cone/release-advance.sh):
#
#   cone/notarize.sh submit <file>                 prints the submission id
#   cone/notarize.sh wait <id> <path-to-staple>    polls, then staples
#
# `submit` uploads a .zip of an app or a .dmg (3 tries). `wait` asks for the
# status every CONE_NOTARY_POLL_SECONDS through up to 20 failed requests in a
# row (the first release run lost a build to one, defect 224), prints the
# notary log on any status but Accepted, and staples with retries. It exits 0
# when stapled, 3 when the submission is still in progress at
# CONE_NOTARY_DEADLINE (epoch seconds; default 150 minutes from now), 1 on a
# refusal or any other failure. Never resubmits: on 2026-10-23 a second and
# third copy of a held file were held as well (defect 225).
#
# Credentials come from the environment — APPLE_API_KEY_PATH (the .p8),
# APPLE_API_KEY (its id), APPLE_API_ISSUER — and are never printed.
set -euo pipefail

: "${APPLE_API_KEY_PATH:?}" "${APPLE_API_KEY:?}" "${APPLE_API_ISSUER:?}"
poll_seconds="${CONE_NOTARY_POLL_SECONDS:-30}"
retry_seconds="${CONE_NOTARY_RETRY_SECONDS:-20}"
deadline="${CONE_NOTARY_DEADLINE:-$(( $(date +%s) + 9000 ))}"
auth=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY" --issuer "$APPLE_API_ISSUER")

retry() { # retry <attempts> <cmd…>: run until it succeeds, retry_seconds apart
  local attempts="$1" n=1
  shift
  until "$@"; do
    (( n >= attempts )) && return 1
    echo "notarize: attempt $n of $attempts failed; retrying in ${retry_seconds} s" >&2
    n=$(( n + 1 ))
    sleep "$retry_seconds"
  done
}

upload() { out="$(xcrun notarytool submit "$1" "${auth[@]}" --output-format json --no-wait)"; }

submit() {
  local file="${1:?usage: cone/notarize.sh submit <file>}" id
  retry 3 upload "$file" || { echo "notarize: could not submit $file" >&2; return 1; }
  id="$(jq -r '.id // empty' <<<"$out")"
  [[ -n "$id" ]] || { echo "notarize: no submission id in: $out" >&2; return 1; }
  echo "notarize: $(basename "$file") submitted as $id" >&2
  printf '%s\n' "$id"
}

wait_and_staple() {
  local id="${1:?usage: cone/notarize.sh wait <id> <path>}" path="${2:?usage: cone/notarize.sh wait <id> <path>}"
  local status="" failures=0
  while :; do
    if out="$(xcrun notarytool info "$id" "${auth[@]}" --output-format json 2>/dev/null)"; then
      failures=0
      status="$(jq -r '.status // empty' <<<"$out")"
      [[ "$status" == "In Progress" ]] || break
    else
      failures=$(( failures + 1 ))
      echo "notarize: status request failed ($failures in a row)" >&2
      (( failures < 20 )) || { echo "notarize: gave up asking Apple about $id" >&2; return 1; }
    fi
    if (( $(date +%s) >= deadline )); then
      echo "notarize: $id is still in progress at the deadline" >&2
      return 3
    fi
    sleep "$poll_seconds"
  done
  echo "notarize: $id $status" >&2
  if [[ "$status" != Accepted ]]; then
    retry 3 xcrun notarytool log "$id" "${auth[@]}" >&2 || true
    return 1
  fi
  retry 5 xcrun stapler staple "$path" >&2
  xcrun stapler validate "$path" >&2
}

out=""
case "${1:-}" in
  submit) shift; submit "$@" ;;
  wait) shift; wait_and_staple "$@" ;;
  *) echo "usage: cone/notarize.sh submit <file> | wait <id> <path-to-staple>" >&2; exit 2 ;;
esac
