#!/usr/bin/env bash
# The Cone phone app's rebrand (cone-buzz-infra Slice 43; Slice 36's mechanism,
# ADR-237, as ported for the Desktop 1.0 line): apply Cone's manifests under
# cone/mobile/rebrand/ to the working copy of upstream's mobile/ right before a
# build, prove the result, and put every file back.
#
#   cone/mobile/rebrand.sh apply     refuse a dirty mobile/; write the iOS identity
#                                    (mobile/ios/Flutter/AppOverrides.xcconfig);
#                                    replacements (hash-checked), lines, the word rule (count-checked)
#   cone/mobile/rebrand.sh restore   every path apply may have written back to HEAD; Cone's xcconfig removed
#   cone/mobile/rebrand.sh finish    after a build: restore, put back Podfile.lock's CocoaPods version line, prove mobile/ clean
#   cone/mobile/rebrand.sh scan      after apply: no Buzz, BUZZ, Block or bee outside keep.tsv / exceptions.tsv
#   cone/mobile/rebrand.sh measure   on a clean tree: apply, print the user-visible "Buzz" left (target 0), restore
#   cone/mobile/rebrand.sh assert    after apply: identity, plists, pictures
#   cone/mobile/rebrand.sh check     apply, scan, measure, assert, restore — one verdict
#   cone/mobile/rebrand.sh count     on a clean tree: lines applied, strings.tsv rows printed, restored
#   cone/mobile/rebrand.sh hits      every hit the word rule would rewrite, with its text (for review)
#
# Run from anywhere; needs git and node (any current Node; no packages). The
# transform (cone/mobile/rebrand/transform.mjs) does the text work; this script
# does the whole-file replacements, the xcconfig and the git bookkeeping.
# Every failure names a path.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
REBRAND=cone/mobile/rebrand
TRANSFORM="$REBRAND/transform.mjs"
TEMPLATE=cone/mobile/AppOverrides.xcconfig
XCCONFIG=mobile/ios/Flutter/AppOverrides.xcconfig

die() { echo "rebrand: $*" >&2; exit 1; }

# replacements.tsv: path<TAB>sha256 — the upstream file's content at
# cone/mobile/UPSTREAM. The replacement is files/<path>.
replacement_rows() { grep -v -E '^(#|$)' "$REBRAND/replacements.tsv" || true; }

verify_replacements() {
  local bad=0 rel sha have
  while IFS=$'\t' read -r rel sha; do
    [[ -f "$REBRAND/files/$rel" ]] || { echo "rebrand: $rel: no replacement at $REBRAND/files/$rel" >&2; bad=1; continue; }
    [[ -f "$rel" ]] || { echo "rebrand: $rel: replacement target missing upstream" >&2; bad=1; continue; }
    have="$(shasum -a 256 "$rel" | cut -d' ' -f1)"
    [[ "$have" == "$sha" ]] || { echo "rebrand: $rel: upstream content changed (sha256 $have, pinned $sha) — review the diff, carry it into $REBRAND/files/$rel, then update replacements.tsv" >&2; bad=1; }
  done < <(replacement_rows)
  (( bad == 0 )) || exit 1
}

apply_replacements() {
  local rel sha
  while IFS=$'\t' read -r rel sha; do
    cp "$REBRAND/files/$rel" "$rel"
  done < <(replacement_rows)
  echo "rebrand apply: $(replacement_rows | wc -l | tr -d ' ') files replaced"
}

all_paths() {
  { replacement_rows | cut -f1; node "$TRANSFORM" paths; } | sed '/^$/d' | sort -u
}

# Restore checks out every path apply wrote from HEAD, so apply refuses to start
# on uncommitted work it would erase (review of ConeDigital/cone-buzz#8).
refuse_dirty() {
  local dirty
  dirty="$(git status --porcelain --untracked-files=all -- mobile | sed '/^$/d' || true)"
  [[ -z "$dirty" ]] || die "the tree is not clean under mobile/; commit, stash or restore first:"$'\n'"$dirty"
}

# The iOS identity goes through upstream's supported, gitignored override.
# A developer's own AppOverrides.xcconfig is never overwritten or removed.
write_xcconfig() {
  if [[ -e "$XCCONFIG" ]] && ! cmp -s "$XCCONFIG" "$TEMPLATE"; then
    die "$XCCONFIG exists and is not Cone's ($TEMPLATE); move it away first — apply never overwrites it"
  fi
  git check-ignore -q "$XCCONFIG" || die "$XCCONFIG is not gitignored upstream any more; the identity would show as a change"
  cp "$TEMPLATE" "$XCCONFIG"
  echo "rebrand apply: $XCCONFIG written from $TEMPLATE"
}

remove_xcconfig() {
  if [[ -e "$XCCONFIG" ]]; then
    if cmp -s "$XCCONFIG" "$TEMPLATE"; then rm -f "$XCCONFIG"
    else echo "rebrand restore: $XCCONFIG is not Cone's; left in place" >&2
    fi
  fi
}

cmd_apply() {
  refuse_dirty
  verify_replacements
  write_xcconfig
  apply_replacements
  node "$TRANSFORM" apply
}

cmd_restore() {
  local paths=()
  while IFS= read -r p; do
    git ls-files --error-unmatch "$p" >/dev/null 2>&1 && paths+=("$p")
  done < <(all_paths)
  (( ${#paths[@]} == 0 )) || git checkout --quiet -- "${paths[@]}"
  remove_xcconfig
  echo "rebrand restore: ok (${#paths[@]} paths)"
}

# After a build: restore, then put back the one tracked file a build is known to
# touch — `pod install` stamps its own version into the last line of
# mobile/ios/Podfile.lock (upstream wrote it with CocoaPods 1.17.0; Homebrew's
# 1.16.2 rewrites it). Only that line: any other change to the lock is a real
# dependency difference and fails, named. Then mobile/ must be exactly HEAD.
PODLOCK=mobile/ios/Podfile.lock
cmd_finish() {
  local changed left
  cmd_restore
  if ! git diff --quiet -- "$PODLOCK"; then
    changed="$(git diff --unified=0 --no-color -- "$PODLOCK" | grep -E '^[-+]' | grep -v -E '^(\+\+\+|---) ' || true)"
    if grep -v -q -E '^[-+]COCOAPODS: [0-9.]+$' <<<"$changed"; then
      die "$PODLOCK: the build changed more than the CocoaPods version line — a dependency moved; review it:"$'\n'"$changed"
    fi
    git checkout --quiet -- "$PODLOCK"
    echo "rebrand finish: $PODLOCK put back (pod install stamped $(grep -E '^\+COCOAPODS' <<<"$changed" | cut -d' ' -f2), upstream has $(grep -E '^-COCOAPODS' <<<"$changed" | cut -d' ' -f2))"
  fi
  left="$(git status --porcelain --untracked-files=all -- mobile | sed '/^$/d' || true)"
  [[ -z "$left" ]] || die "mobile/ is not clean after the build:"$'\n'"$left"
  [[ ! -e "$XCCONFIG" ]] || die "$XCCONFIG is still there after the build"
  echo "rebrand finish: mobile/ is clean"
}

cmd_measure() {
  refuse_dirty
  trap 'cmd_restore >/dev/null' EXIT
  cmd_apply >/dev/null
  node "$TRANSFORM" measure
}

cmd_count() {
  refuse_dirty
  trap 'cmd_restore >/dev/null' EXIT
  verify_replacements
  node "$TRANSFORM" apply-prefix >/dev/null
  node "$TRANSFORM" count
}

cmd_check() {
  refuse_dirty
  trap 'cmd_restore' EXIT
  cmd_apply
  node "$TRANSFORM" scan
  node "$TRANSFORM" measure
  node "$TRANSFORM" assert
  echo "rebrand check: ok"
}

case "${1:-}" in
  apply) cmd_apply ;;
  restore) cmd_restore ;;
  scan) node "$TRANSFORM" scan ;;
  assert) node "$TRANSFORM" assert ;;
  measure) cmd_measure ;;
  count) cmd_count ;;
  hits) node "$TRANSFORM" hits ;;
  check) cmd_check ;;
  finish) cmd_finish ;;
  *) die "usage: cone/mobile/rebrand.sh apply|restore|finish|scan|measure|assert|check|count|hits" ;;
esac
