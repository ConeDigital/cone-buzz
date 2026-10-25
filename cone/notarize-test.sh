#!/usr/bin/env bash
# Tests for cone/notarize.sh and cone/release-advance.sh against mocks of
# xcrun, hdiutil and codesign (no Apple, no network, no credential; a "DMG" is
# a directory). Run by `just cone-notarize-test` and by the release workflow
# before it touches a secret. Each case names the change it must catch.
#
#   cone/notarize-test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/cone-notarize-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# Apple: a submission's id is <MOCK_CASE>-<n>; every submission is "In
# Progress" until $MOCK_DIR/status-<id> says otherwise; MOCK_DROP_FIRST=1
# fails the first status request.
cat >"$work/bin/xcrun" <<'MOCK'
#!/usr/bin/env bash
d="$MOCK_DIR"
count() { local n; n=$(( $(cat "$d/$1" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$d/$1"; echo "$n"; }
case "$1 $2" in
  "notarytool submit") echo "{\"id\":\"$MOCK_CASE-$(count submit-calls)\"}" ;;
  "notarytool info")
    n="$(count info-calls)"
    if [[ "${MOCK_DROP_FIRST:-}" == 1 && "$n" -eq 1 ]]; then exit 1; fi
    echo "{\"status\":\"$(cat "$d/status-$3" 2>/dev/null || echo 'In Progress')\"}" ;;
  "notarytool log") count log-calls >/dev/null; echo "mock log" ;;
  "stapler staple") count staple-calls >/dev/null; touch "$3/stapled" 2>/dev/null || true ;;
  "stapler validate") [[ ! -d "$3" || -e "$3/stapled" ]] ;;
  *) echo "mock xcrun: unexpected $*" >&2; exit 9 ;;
esac
MOCK
cat >"$work/bin/hdiutil" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  convert) in="$2" out=""; while (( $# )); do [[ "$1" == -o ]] && out="$2"; shift; done
           rm -rf "$out"; ditto "$in" "$out" ;;                             # convert <in> … -o <out> -ov
  attach) mnt="${*: -1}"; rm -rf "$mnt"; ln -s "$(cd "$2" && pwd)" "$mnt" ;;  # attach <img> … -mountpoint <mnt>
  detach) rm -f "$2" ;;
  *) echo "mock hdiutil: unexpected $*" >&2; exit 9 ;;
esac
MOCK
cat >"$work/bin/codesign" <<'MOCK'
#!/usr/bin/env bash
n=$(( $(cat "$MOCK_DIR/codesign-calls" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$MOCK_DIR/codesign-calls"
MOCK
chmod +x "$work/bin/"*
"$work/bin/xcrun" stapler validate /nonexistent || true # a new file's first exec can be slow on macOS: not in a timed case

failed=0
calls() { cat "$work/mock/$1" 2>/dev/null || echo 0; }
check() { # check <case> <what> <got> <want>
  if [[ "$3" == "$4" ]]; then echo "  ok   $1: $2 = $3"; else echo "  FAIL $1: $2 = $3, want $4"; failed=1; fi
}
apple() { rm -rf "$work/mock"; mkdir -p "$work/mock"; for s in "$@"; do echo "${s#*=}" >"$work/mock/status-${s%%=*}"; done; }
run() { # run <deadline-seconds> <cmd…>: sets rc
  local deadline="$1"
  shift
  set +e
  PATH="$work/bin:$PATH" MOCK_DIR="$work/mock" MOCK_CASE="${MOCK_CASE:-x}" APPLE_API_KEY_PATH=x APPLE_API_KEY=x APPLE_API_ISSUER=x \
    APPLE_SIGNING_IDENTITY=x KEYCHAIN=x CONE_DMG_TEXT_SIZE="$work/bin/textsize" \
    CONE_NOTARY_POLL_SECONDS=1 CONE_NOTARY_RETRY_SECONDS=0 CONE_NOTARY_DEADLINE=$(( $(date +%s) + deadline )) \
    "$@" >"$work/out" 2>&1
  rc=$?
  set -e
}

echo "notarize-test: notarize.sh"
touch "$work/file.dmg"
apple; MOCK_CASE=s run 30 bash "$here/notarize.sh" submit "$work/file.dmg"
check submit rc "$rc" 0
check submit "stdout is the id" "$(grep -x 's-1' "$work/out" || true)" s-1

apple sub-1=Accepted; run 30 bash "$here/notarize.sh" wait sub-1 "$work/file.dmg"
check accept rc "$rc" 0
check accept staples "$(calls staple-calls)" 1

apple sub-1=Accepted; MOCK_DROP_FIRST=1 run 30 bash "$here/notarize.sh" wait sub-1 "$work/file.dmg"   # killed by: no tolerance of a failed request
check dropped-request rc "$rc" 0
check dropped-request staples "$(calls staple-calls)" 1

apple sub-1=Invalid; run 30 bash "$here/notarize.sh" wait sub-1 "$work/file.dmg"   # killed by: stapling or passing a refused file
check invalid rc "$rc" 1
check invalid "notary log fetched" "$(calls log-calls)" 1
check invalid staples "$(calls staple-calls)" 0

apple; run 3 bash "$here/notarize.sh" wait sub-1 "$work/file.dmg"   # killed by: no deadline, or a deadline that looks like a refusal
check held rc "$rc" 3
check held "no resubmission" "$(calls submit-calls)" 0

echo "notarize-test: release-advance.sh"
# The label-size patch refuses an image it has already patched, as upstream's
# does when run twice (review of #5).
cat >"$work/bin/textsize" <<'MOCK'
#!/usr/bin/env bash
[[ -e "$1/.patched" ]] && { echo "textsize: already patched" >&2; exit 1; }
touch "$1/.patched"
MOCK
chmod +x "$work/bin/textsize"
mkdir -p "$work/app/Cone.app/Contents"
echo binary >"$work/app/Cone.app/Contents/exe"
fresh_state() { # fresh_state <dir>: a release as the build leaves it
  rm -rf "$1"; mkdir -p "$1/tauri.dmg/.background"
  (cd "$work/app" && ditto -c -k --keepParent Cone.app "$1/Cone.zip")
  echo old-app >"$1/tauri.dmg/Cone.app"                     # Tauri's DMG, with the unstapled app
  echo Cone_1.0.0_x64.dmg >"$1/dmg"; echo built >"$1/stage"
}
yes_no() { if "$@"; then echo yes; else echo no; fi; }
state="$work/state"
final="$state/Cone_1.0.0_x64.dmg"
fresh_state "$state"

apple; MOCK_CASE=a run 3 bash "$here/release-advance.sh" "$state"   # the app submitted, Apple holds it
check app-held rc "$rc" 3
check app-held stage "$(cat "$state/stage")" app-submitted
check app-held "app submissions" "$(calls submit-calls)" 1
check app-held app_id "$(cat "$state/app_id")" a-1

apple; MOCK_CASE=b run 3 bash "$here/release-advance.sh" "$state"   # resume, still held: killed by resubmitting the app
check app-still-held rc "$rc" 3
check app-still-held "no resubmission" "$(calls submit-calls)" 0

apple a-1=Accepted; MOCK_CASE=c run 3 bash "$here/release-advance.sh" "$state"   # resume: app accepted, Apple holds the DMG
check dmg-held rc "$rc" 3
check dmg-held stage "$(cat "$state/stage")" dmg-submitted
check dmg-held "DMG submissions" "$(calls submit-calls)" 1
check dmg-held dmg_id "$(cat "$state/dmg_id")" c-1
check dmg-held "stapled app kept in the state" "$(unzip -l "$state/Cone.zip" | grep -c 'Cone.app/stapled' || true)" 1
check dmg-held "stapled app inside the DMG" "$(yes_no test -e "$final/Cone.app/stapled")" yes
check dmg-held "DMG label size patched" "$(yes_no test -e "$final/.patched")" yes
check dmg-held "tauri.dmg untouched" "$(yes_no test ! -e "$state/tauri.dmg/.patched")" yes
check dmg-held "DMG signed" "$(calls codesign-calls)" 1
cp -R "$state" "$work/at-dmg-submitted"

apple c-1=Accepted; MOCK_CASE=d run 30 bash "$here/release-advance.sh" "$state"  # resume: killed by resubmitting what Apple has
check resume-done rc "$rc" 0
check resume-done stage "$(cat "$state/stage")" "done"
check resume-done "no resubmission" "$(calls submit-calls)" 0
check resume-done "DMG stapled" "$(calls staple-calls)" 1

apple; MOCK_CASE=e run 30 bash "$here/release-advance.sh" "$state"   # done stays done, without Apple
check "done" rc "$rc" 0
check "done" "status requests" "$(calls info-calls)" 0

# Interrupted between a step's files and its stage (review of #5).
fresh_state "$state"; echo i-9 >"$state/app_id"                   # the app's id saved, the stage still built
apple; MOCK_CASE=f run 3 bash "$here/release-advance.sh" "$state"   # killed by: built resubmits whatever app_id says
check app-id-saved rc "$rc" 3
check app-id-saved stage "$(cat "$state/stage")" app-submitted
check app-id-saved "no resubmission" "$(calls submit-calls)" 0
check app-id-saved app_id "$(cat "$state/app_id")" i-9

rm -rf "$state"; cp -R "$work/at-dmg-submitted" "$state"; echo app-stapled >"$state/stage"   # DMG submitted, id saved
apple; MOCK_CASE=g run 3 bash "$here/release-advance.sh" "$state"   # killed by: app-stapled ignoring a saved dmg_id
check dmg-id-saved rc "$rc" 3
check dmg-id-saved stage "$(cat "$state/stage")" dmg-submitted
check dmg-id-saved "no resubmission" "$(calls submit-calls)" 0
check dmg-id-saved "not signed again" "$(calls codesign-calls)" 0

rm -rf "$state"; cp -R "$work/at-dmg-submitted" "$state"; echo app-stapled >"$state/stage"; rm "$state/dmg_id"   # DMG made, not yet submitted
apple; MOCK_CASE=h run 3 bash "$here/release-advance.sh" "$state"   # killed by: the DMG made from the already patched one
check dmg-made rc "$rc" 3
check dmg-made stage "$(cat "$state/stage")" dmg-submitted
check dmg-made "DMG submissions" "$(calls submit-calls)" 1
check dmg-made dmg_id "$(cat "$state/dmg_id")" h-1
check dmg-made "tauri.dmg untouched" "$(yes_no test ! -e "$state/tauri.dmg/.patched")" yes

if (( failed )); then echo "notarize-test: FAILED"; cat "$work/out"; exit 1; fi
echo "notarize-test: ok (13 cases)"
