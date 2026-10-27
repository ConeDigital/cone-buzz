#!/usr/bin/env bash
# The updater archive of one architecture (Slice 29 merge 3). Tauri makes
# Cone.app.tar.gz while it builds — before Apple has notarized the app and
# before its ticket is stapled — so that archive is not what an update may
# install. This makes it again from the release's stapled app and signs it
# with the updater key, as upstream's release.yml does after its own signing.
#
#   cone/updater-archive.sh <state-dir> <out-dir> <version> <arch>
#
# Writes <out-dir>/Cone_<version>_<arch>.app.tar.gz and its .sig from the
# state cone/release-advance.sh keeps, and refuses a state whose app carries
# no ticket yet (before stage app-stapled). Then checks what an app will get:
# the signature is by the key in cone/updater.pub (its key id; the promote job
# checks the signature itself), and the archive unpacks to Cone.app, stapled
# and valid. Signing needs TAURI_SIGNING_PRIVATE_KEY and
# TAURI_SIGNING_PRIVATE_KEY_PASSWORD (the cone-release secrets) and the
# desktop's node_modules (`pnpm install`).
set -euo pipefail

usage="usage: cone/updater-archive.sh <state-dir> <out-dir> <version> <arch>"
state="${1:?$usage}" out="${2:?$usage}" version="${3:?$usage}" arch="${4:?$usage}"
here="$(cd "$(dirname "$0")" && pwd)"
pub="${CONE_UPDATER_PUB:-$here/updater.pub}"

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cone-updater-archive.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/app" "$work/check" "$out"
ditto -x -k "$state/Cone.zip" "$work/app"
xcrun stapler validate "$work/app/Cone.app" || { echo "updater-archive: the app in $state is not stapled yet (stage $(cat "$state/stage"))" >&2; exit 1; }

archive="$(cd "$out" && pwd)/Cone_${version}_${arch}.app.tar.gz"
rm -f "$archive" "$archive.sig"
tar -C "$work/app" -czf "$archive" Cone.app
if [[ -n "${CONE_TAURI_SIGN:-}" ]]; then
  "$CONE_TAURI_SIGN" "$archive"                     # the test's stand-in
else
  (cd "$here/../desktop" && pnpm tauri signer sign "$archive")
fi
[[ -s "$archive.sig" ]] || { echo "updater-archive: no signature for $(basename "$archive")" >&2; exit 1; }
"$here/updater-verify.sh" --key-id-only "$archive" "$archive.sig" "$pub"

tar -C "$work/check" -xzf "$archive"
xcrun stapler validate "$work/check/Cone.app"
codesign --verify --deep --strict "$work/check/Cone.app"
echo "updater-archive: $(basename "$archive") ($(wc -c <"$archive" | tr -d ' ') bytes) from the stapled app, signed by the key in $(basename "$pub")"
