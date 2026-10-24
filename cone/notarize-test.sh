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
    APPLE_SIGNING_IDENTITY=x KEYCHAIN=x CONE_DMG_TEXT_SIZE=true \
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
state="$work/state"
rm -rf "$state"; mkdir -p "$state" "$work/app/Cone.app/Contents" "$state/Cone_1.0.0_x64.dmg/.background"
echo binary >"$work/app/Cone.app/Contents/exe"
(cd "$work/app" && ditto -c -k --keepParent Cone.app "$state/Cone.zip")
echo old-app >"$state/Cone_1.0.0_x64.dmg/Cone.app"            # Tauri's DMG, with the unstapled app
echo Cone_1.0.0_x64.dmg >"$state/dmg"; echo built >"$state/stage"

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
check dmg-held "stapled app inside the DMG" "$( [[ -e "$state/Cone_1.0.0_x64.dmg/Cone.app/stapled" ]] && echo yes || echo no)" yes
check dmg-held "DMG signed" "$(calls codesign-calls)" 1

apple c-1=Accepted; MOCK_CASE=d run 30 bash "$here/release-advance.sh" "$state"  # resume: killed by resubmitting what Apple has
check resume-done rc "$rc" 0
check resume-done stage "$(cat "$state/stage")" "done"
check resume-done "no resubmission" "$(calls submit-calls)" 0
check resume-done "DMG stapled" "$(calls staple-calls)" 1

apple; MOCK_CASE=e run 30 bash "$here/release-advance.sh" "$state"   # done stays done, without Apple
check "done" rc "$rc" 0
check "done" "status requests" "$(calls info-calls)" 0

if (( failed )); then echo "notarize-test: FAILED"; cat "$work/out"; exit 1; fi
echo "notarize-test: ok (10 cases)"
