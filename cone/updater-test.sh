#!/usr/bin/env bash
# Tests for cone/updater-verify.sh against fixtures in cone/test/updater/:
# two throwaway keys made with `tauri signer generate` (a.pub, b.pub; the
# private halves were deleted), payload.bin and other.bin signed by key a,
# payload.bin signed by key b. No Cone key, no network. Run by `just
# cone-updater-test` and by the release workflow. Each case names the change
# to updater-verify.sh it must catch.
#
#   cone/updater-test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fx="$here/test/updater"
verify="$here/updater-verify.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/cone-updater-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

failed=0
expect() { # expect <case> <want: ok|refused> <stderr must contain> <verify args…>
  local name="$1" want="$2" needle="$3" rc=0
  shift 3
  "$verify" "$@" >"$work/out" 2>"$work/err" || rc=$?
  local got=ok
  (( rc == 0 )) || got=refused
  if (( rc > 1 )); then
    echo "  FAIL $name: tool error (rc $rc): $(cat "$work/err")"; failed=1; return
  fi
  if [[ "$got" != "$want" ]] || { [[ -n "$needle" ]] && ! grep -qF -- "$needle" "$work/err"; }; then
    echo "  FAIL $name: $got, want $want${needle:+ with \"$needle\"}: $(cat "$work/out" "$work/err")"; failed=1; return
  fi
  echo "  ok   $name: $got"
}

# A copy of payload.bin with one byte changed (criterion 5c's shape).
cp "$fx/payload.bin" "$work/tampered.bin"
printf 'X' | dd of="$work/tampered.bin" bs=1 seek=0 conv=notrunc 2>/dev/null
# payload.bin's signature with its trusted comment altered (the global
# signature no longer holds).
base64 -d <"$fx/payload.bin.sig" | sed 's/^trusted comment: \(.*\)$/trusted comment: \1 altered/' | base64 | tr -d '\n' >"$work/comment.sig"

echo "updater-verify:"
# Kills: a verifier that refuses everything; one that drops the BLAKE2b prehash.
expect "a signed archive" ok "" "$fx/payload.bin" "$fx/payload.bin.sig" "$fx/a.pub"
# Kills: the archive's signature not checked.
expect "one byte changed" refused "does not hold over this file" "$work/tampered.bin" "$fx/payload.bin.sig" "$fx/a.pub"
# Kills: the archive's signature not checked (criterion 5b: a real signature
# by the right key, of another file).
expect "another file's signature" refused "does not hold over this file" "$fx/payload.bin" "$fx/other.bin.sig" "$fx/a.pub"
# Kills: the key id not compared (with --key-id-only nothing else looks).
expect "another key, key id only" refused "signed by key" --key-id-only "$fx/payload.bin" "$fx/payload.bin.b.sig" "$fx/a.pub"
# Kills: the key id not compared, or the signature checked against the
# signature's own key (criterion 5a: a valid signature by someone else's key).
expect "another key" refused "signed by key" "$fx/payload.bin" "$fx/payload.bin.b.sig" "$fx/a.pub"
# Kills: the global signature (over the trusted comment) not checked.
expect "trusted comment altered" refused "trusted comment" "$fx/payload.bin" "$work/comment.sig" "$fx/a.pub"
# Kills: --key-id-only refusing a matching key.
expect "the right key, key id only" ok "" --key-id-only "$fx/payload.bin" "$fx/payload.bin.sig" "$fx/a.pub"

if (( failed )); then echo "updater-test: FAILED"; exit 1; fi
echo "updater-test: ok (7 cases)"
