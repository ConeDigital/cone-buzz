#!/usr/bin/env bash
# Moves one architecture's release through Apple's notary service, resumably
# (Slice 29 merge 2, defect 225: Apple held submissions for hours, and every
# run that gave up threw away a signed build).
#
#   cone/release-advance.sh <state-dir>
#
# The state directory is the release in progress, uploaded by the workflow
# after every run, failed or not, and downloaded again by a resume run:
#   Cone.zip   the signed app (stapled from stage app-stapled on)
#   dmg        the DMG's file name; that file is Tauri's DMG until
#              dmg-submitted, then the signed DMG Apple has
#   app_id, dmg_id   the submissions
#   stage      built → app-submitted → app-stapled → dmg-submitted → done
# A step writes its files first and `stage` last, so a run stopped anywhere
# redoes at most the step it was in. A submission Apple already has is never
# made again.
#
# Exits 0 when done, 3 when Apple is still working at CONE_NOTARY_DEADLINE
# (the state is consistent: resume), 1 on any failure. Signing the DMG needs
# APPLE_SIGNING_IDENTITY and KEYCHAIN; notarize.sh needs the APPLE_API_* key.
set -euo pipefail

state="${1:?usage: cone/release-advance.sh <state-dir>}"
notarize="$(cd "$(dirname "$0")" && pwd)/notarize.sh"
text_size="${CONE_DMG_TEXT_SIZE:-desktop/scripts/set-dmg-finder-text-size.sh}"
dmg="$state/$(cat "$state/dmg")"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cone-advance.XXXXXX")"
mnt="$work/mnt" mounted=0 app=""
cleanup() {
  if (( mounted )); then hdiutil detach "$mnt" >/dev/null 2>&1 || hdiutil detach -force "$mnt" >/dev/null 2>&1 || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

set_stage() {
  printf '%s\n' "$1" >"$state/stage.tmp"
  mv "$state/stage.tmp" "$state/stage"
  echo "release-advance: stage $1"
}
unpack_app() {
  rm -rf "$work/app"
  mkdir -p "$work/app"
  ditto -x -k "$state/Cone.zip" "$work/app"
  app="$work/app/Cone.app"
}
apple() { # apple <notarize.sh args…>: 0, or exit with notarize.sh's status (3 = still in progress)
  local rc=0
  "$notarize" "$@" || rc=$?
  (( rc == 0 )) || exit "$rc"
}

while :; do
  stage="$(cat "$state/stage")"
  echo "release-advance: at $stage"
  case "$stage" in
    built)
      id="$("$notarize" submit "$state/Cone.zip")"
      printf '%s\n' "$id" >"$state/app_id"
      set_stage app-submitted ;;
    app-submitted)
      unpack_app
      apple wait "$(cat "$state/app_id")" "$app"
      ditto -c -k --keepParent "$app" "$state/Cone.zip.tmp"
      mv "$state/Cone.zip.tmp" "$state/Cone.zip"
      set_stage app-stapled ;;
    app-stapled)
      unpack_app
      xcrun stapler validate "$app"
      new="$work/$(basename "$dmg")" rw="$work/rw.dmg"
      ditto "$dmg" "$new"
      # Upstream's label size (Tauri does not expose it); it edits Finder's
      # .DS_Store, so it also fails if the Finder layout did not run.
      "$text_size" "$new" 14
      # Tauri's DMG holds the app before its ticket: put the stapled app in its
      # place, under the name the Finder layout uses. The image has tens of MB
      # free; the ticket adds a few KB.
      hdiutil convert "$new" -format UDRW -o "$rw" -ov >/dev/null
      mkdir -p "$mnt"
      hdiutil attach "$rw" -nobrowse -readwrite -noverify -noautoopen -mountpoint "$mnt" >/dev/null
      mounted=1
      rm -rf "$mnt/Cone.app"
      ditto "$app" "$mnt/Cone.app"
      xcrun stapler validate "$mnt/Cone.app"
      sync
      hdiutil detach "$mnt" >/dev/null || hdiutil detach -force "$mnt" >/dev/null
      mounted=0
      hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -o "$new" -ov >/dev/null
      codesign --force --timestamp --sign "${APPLE_SIGNING_IDENTITY:?}" --keychain "${KEYCHAIN:?}" "$new"
      id="$("$notarize" submit "$new")"
      rm -rf "$dmg"
      mv "$new" "$dmg"
      printf '%s\n' "$id" >"$state/dmg_id"
      set_stage dmg-submitted ;;
    dmg-submitted)
      apple wait "$(cat "$state/dmg_id")" "$dmg"
      set_stage "done" ;;
    done)
      echo "release-advance: done"
      exit 0 ;;
    *)
      echo "release-advance: unknown stage '$stage'" >&2
      exit 1 ;;
  esac
done
