#!/usr/bin/env bash
# Tests for cone/notarize.sh against a mock `xcrun` (no Apple, no network,
# no credential). Run by `just cone-notarize-test` and by the release workflow
# before it touches a secret.
#
#   cone/notarize-test.sh [path/to/notarize.sh]
set -euo pipefail

script="${1:-$(cd "$(dirname "$0")" && pwd)/notarize.sh}"
[[ -f "$script" ]] || { echo "notarize-test: no $script" >&2; exit 2; }
work="$(mktemp -d "${TMPDIR:-/tmp}/cone-notarize-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# The mock records every call in $MOCK_DIR. MOCK_MODE picks Apple's behaviour:
#   accept        the first copy is accepted on its second status request
#   drop-hedge    the first status request fails; copy 1 never finishes, copy 2 is accepted
#   invalid       Apple refuses the file
#   stuck         no copy ever finishes
#   fail-resubmit copy 1 never finishes and every later submission fails
cat >"$work/bin/xcrun" <<'MOCK'
#!/usr/bin/env bash
d="$MOCK_DIR"
count() { local n; n=$(( $(cat "$d/$1" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$d/$1"; echo "$n"; }
case "$1 $2" in
  "notarytool submit")
    n="$(count submit-calls)"
    if [[ "$MOCK_MODE" == fail-resubmit && "$n" -gt 1 ]]; then exit 1; fi
    echo "{\"id\":\"sub-$(count submitted)\"}" ;;
  "notarytool info")
    n="$(count info-calls)"
    case "$MOCK_MODE:$3" in
      accept:sub-1) [[ "$n" -ge 2 ]] && echo '{"status":"Accepted"}' || echo '{"status":"In Progress"}' ;;
      drop-hedge:sub-1) [[ "$n" -eq 1 ]] && exit 1; echo '{"status":"In Progress"}' ;;
      drop-hedge:sub-2) echo '{"status":"Accepted"}' ;;
      invalid:*) echo '{"status":"Invalid"}' ;;
      *) echo '{"status":"In Progress"}' ;;
    esac ;;
  "notarytool log") count log-calls >/dev/null; echo "mock log" ;;
  "stapler staple") count staple-calls >/dev/null ;;
  "stapler validate") ;;
  *) echo "mock xcrun: unexpected $*" >&2; exit 9 ;;
esac
MOCK
chmod +x "$work/bin/xcrun"
"$work/bin/xcrun" stapler validate x # first exec of a new file can be slow on macOS: not inside a timed case
touch "$work/file.dmg"

failed=0
calls() { cat "$work/state/$1" 2>/dev/null || echo 0; }
check() { # check <case> <what> <got> <want>
  if [[ "$3" == "$4" ]]; then echo "  ok   $1: $2 = $3"; else echo "  FAIL $1: $2 = $3, want $4"; failed=1; fi
}
run() { # run <mode> <deadline-seconds>: sets rc
  rm -rf "$work/state"; mkdir -p "$work/state"
  set +e
  PATH="$work/bin:$PATH" MOCK_DIR="$work/state" MOCK_MODE="$1" \
    APPLE_API_KEY_PATH=x APPLE_API_KEY=x APPLE_API_ISSUER=x \
    CONE_NOTARY_POLL_SECONDS=1 CONE_NOTARY_RESUBMIT_SECONDS=2 CONE_NOTARY_RETRY_SECONDS=0 \
    CONE_NOTARY_MAX_SUBMISSIONS=3 CONE_NOTARY_TIMEOUT_SECONDS="$2" \
    bash "$script" "$work/file.dmg" >"$work/out" 2>&1
  rc=$?
  set -e
}

echo "notarize-test: $script"
run accept 60
check accept rc "$rc" 0
check accept copies "$(calls submitted)" 1
check accept staples "$(calls staple-calls)" 1

run drop-hedge 60          # killed by: no tolerance of a failed request, no resubmission
check drop-hedge rc "$rc" 0
check drop-hedge copies "$(calls submitted)" 2
check drop-hedge staples "$(calls staple-calls)" 1

run invalid 60             # killed by: resubmitting after a refusal, stapling a refused file
check invalid rc "$rc" 1
check invalid copies "$(calls submitted)" 1
check invalid "notary log fetched" "$(calls log-calls)" 1
check invalid staples "$(calls staple-calls)" 0

run stuck 10               # killed by: no cap on copies, no deadline
check stuck rc "$rc" 1
check stuck copies "$(calls submitted)" 3
check stuck staples "$(calls staple-calls)" 0

run fail-resubmit 10       # killed by: counting only accepted copies (review of #4: 286 attempts)
check fail-resubmit rc "$rc" 1
check fail-resubmit "submission attempts (1 + 2 copies x 3 tries)" "$(calls submit-calls)" 7
check fail-resubmit "still polling after the budget" "$( (( $(calls info-calls) > 7 )) && echo yes || echo no)" yes

if (( failed )); then echo "notarize-test: FAILED"; exit 1; fi
echo "notarize-test: ok (5 cases)"
