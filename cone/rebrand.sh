#!/usr/bin/env bash
# The in-app rebrand (cone-buzz-infra Slice 36, ADR-237): apply Cone's
# manifests under cone/rebrand/ to the working copy of upstream's tree right
# before a build, verify nothing is left, and put every file back.
#
#   cone/rebrand.sh apply     replacements (hash-checked), blocks, lines, the word rule (count-checked)
#   cone/rebrand.sh scan      after apply: no branded residue outside cone/rebrand/exceptions.tsv
#   cone/rebrand.sh restore   every path apply may have written back to HEAD; new files removed
#   cone/rebrand.sh check     refuse a dirty tree, apply, scan, typecheck + frontend build, restore
#   cone/rebrand.sh measure   blocks + lines applied, the word counts printed as strings.tsv rows, restored
#
# Run from the repository root with hermit active (node, pnpm). cone/rebrand/
# transform.mjs does the text work; this script does the whole-file
# replacements and the git bookkeeping. Every failure names a path.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REBRAND=cone/rebrand
TRANSFORM="$REBRAND/transform.mjs"

die() { echo "rebrand: $*" >&2; exit 1; }

# replacements.tsv: path<TAB>sha256 — the upstream file's content, or "-" for a
# file that must not exist upstream. The replacement is files/<path>.
replacement_rows() { grep -v -E '^(#|$)' "$REBRAND/replacements.tsv" || true; }

verify_replacements() {
  local bad=0 rel sha have
  while IFS=$'\t' read -r rel sha; do
    [[ -f "$REBRAND/files/$rel" ]] || { echo "rebrand: $rel: no replacement at $REBRAND/files/$rel" >&2; bad=1; continue; }
    if [[ "$sha" == "-" ]]; then
      [[ ! -e "$rel" ]] || { echo "rebrand: $rel: listed as new but exists upstream" >&2; bad=1; }
      continue
    fi
    [[ -f "$rel" ]] || { echo "rebrand: $rel: replacement target missing upstream" >&2; bad=1; continue; }
    have="$(shasum -a 256 "$rel" | cut -d' ' -f1)"
    [[ "$have" == "$sha" ]] || { echo "rebrand: $rel: upstream content changed (sha256 $have, pinned $sha) — review the diff, carry it into $REBRAND/files/$rel, then update replacements.tsv" >&2; bad=1; }
  done < <(replacement_rows)
  (( bad == 0 )) || exit 1
}

apply_replacements() {
  local rel sha
  while IFS=$'\t' read -r rel sha; do
    mkdir -p "$(dirname "$rel")"
    cp "$REBRAND/files/$rel" "$rel"
  done < <(replacement_rows)
  echo "rebrand apply: $(replacement_rows | wc -l | tr -d ' ') files replaced"
}

all_paths() {
  { replacement_rows | cut -f1; node "$TRANSFORM" paths; } | sort -u
}

refuse_dirty() {
  local dirty
  dirty="$(git status --porcelain --untracked-files=all -- desktop/ | sed '/^$/d' || true)"
  [[ -z "$dirty" ]] || die "desktop/ is not clean; commit, stash or restore first:"$'\n'"$dirty"
}

cmd_apply() {
  verify_replacements
  apply_replacements
  node "$TRANSFORM" apply
}

cmd_restore() {
  local rel sha
  while IFS=$'\t' read -r rel sha; do
    if [[ "$sha" == "-" ]]; then rm -f "$rel"; fi
  done < <(replacement_rows)
  # shellcheck disable=SC2046
  git checkout --quiet -- $(all_paths | while read -r p; do git ls-files --error-unmatch "$p" >/dev/null 2>&1 && printf '%s ' "$p"; done)
  echo "rebrand restore: ok"
}

cmd_scan() { node "$TRANSFORM" scan; }

cmd_measure() {
  refuse_dirty
  trap 'cmd_restore >/dev/null' EXIT
  verify_replacements
  apply_replacements >/dev/null
  node "$TRANSFORM" apply-prefix >/dev/null
  node "$TRANSFORM" measure
}

cmd_check() {
  refuse_dirty
  trap 'cmd_restore' EXIT
  cmd_apply
  cmd_scan
  if [[ "${1:-}" == "--build" ]]; then
    (cd desktop && pnpm typecheck && pnpm build)
    echo "rebrand check: typecheck and frontend build ok"
  fi
  echo "rebrand check: ok"
}

case "${1:-}" in
  apply) cmd_apply ;;
  restore) cmd_restore ;;
  scan) cmd_scan ;;
  measure) cmd_measure ;;
  check) shift; cmd_check "$@" ;;
  *) die "usage: cone/rebrand.sh apply|restore|scan|measure|check [--build]" ;;
esac
