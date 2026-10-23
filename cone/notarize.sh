#!/usr/bin/env bash
# Notarize one file with Apple's notary service and staple the ticket
# (Slice 29 merge 2). Used by .github/workflows/cone-desktop.yml for the app
# and the DMG instead of `notarytool submit --wait`, which gives up on the
# first dropped request: the first release run lost the Apple-silicon build
# when the runner's network dropped 16 minutes into the wait.
#
#   cone/notarize.sh <file-to-submit> [<path-to-staple>]
#
# <file-to-submit> is a .zip of an app, or a .dmg; <path-to-staple> defaults to
# it (an app is submitted as a zip but stapled as the .app). Credentials come
# from the environment: APPLE_API_KEY_PATH (the .p8), APPLE_API_KEY (its id),
# APPLE_API_ISSUER. Prints the submission's id and status, never a credential.
set -euo pipefail

submit_file="${1:?usage: cone/notarize.sh <file> [<path-to-staple>]}"
staple_path="${2:-$submit_file}"
: "${APPLE_API_KEY_PATH:?}" "${APPLE_API_KEY:?}" "${APPLE_API_ISSUER:?}"
poll_seconds="${CONE_NOTARY_POLL_SECONDS:-30}"
deadline=$(( $(date +%s) + ${CONE_NOTARY_TIMEOUT_SECONDS:-5400} ))
notary=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY" --issuer "$APPLE_API_ISSUER" --output-format json)

retry() { # retry <attempts> <cmd…>: run until it succeeds, 20 s apart
  local attempts="$1" n=1
  shift
  until "$@"; do
    (( n >= attempts )) && return 1
    echo "notarize: attempt $n of $attempts failed; retrying in 20 s" >&2
    n=$(( n + 1 ))
    sleep 20
  done
}

submit() { out="$(xcrun notarytool submit "$submit_file" "${notary[@]}" --no-wait)"; }
retry 3 submit || { echo "notarize: could not submit $submit_file" >&2; exit 1; }
id="$(jq -r '.id // empty' <<<"$out")"
[[ -n "$id" ]] || { echo "notarize: no submission id in: $out" >&2; exit 1; }
echo "notarize: $(basename "$submit_file") submitted as $id"

status="" failures=0
while :; do
  if out="$(xcrun notarytool info "$id" "${notary[@]}" 2>/dev/null)"; then
    failures=0
    status="$(jq -r '.status // empty' <<<"$out")"
    [[ "$status" == "In Progress" ]] || break
  else
    failures=$(( failures + 1 ))
    echo "notarize: status request failed ($failures in a row)" >&2
    (( failures < 20 )) || { echo "notarize: gave up asking about $id" >&2; exit 1; }
  fi
  (( $(date +%s) < deadline )) || { echo "notarize: $id still in progress at the deadline" >&2; exit 1; }
  sleep "$poll_seconds"
done
echo "notarize: $id $status"

if [[ "$status" != Accepted ]]; then
  retry 3 xcrun notarytool log "$id" --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY" --issuer "$APPLE_API_ISSUER" || true
  exit 1
fi
retry 5 xcrun stapler staple "$staple_path"
xcrun stapler validate "$staple_path"
