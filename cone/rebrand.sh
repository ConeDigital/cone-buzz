#!/usr/bin/env bash
# The in-app rebrand (cone-buzz-infra Slice 36, ADR-237): apply Cone's
# manifests under cone/rebrand/ to the working copy of upstream's tree right
# before a build, verify nothing is left, and put every file back.
#
#   cone/rebrand.sh apply     replacements (hash-checked), blocks, lines, the word rule (count-checked)
#   cone/rebrand.sh scan      after apply: no branded residue outside cone/rebrand/exceptions.tsv
#   cone/rebrand.sh bundle-scan  after a frontend build: no word Buzz in desktop/dist/assets/*.js, substrings only on bundle-allow.tsv identifiers
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

# The built frontend (desktop/dist/assets/*.js, what Tauri embeds compressed —
# invisible to `strings` on the binary): no whole-word Buzz, and every Buzz
# substring sits on an identifier listed in cone/rebrand/bundle-allow.tsv.
cmd_bundle_scan() {
  local js whole bad=0 ctx allowed
  ls desktop/dist/assets/*.js >/dev/null 2>&1 || die "no desktop/dist/assets/*.js: build the frontend first"
  # (every grep here may match nothing: that is the pass, not an errexit)
  whole="$( { grep -o -h -w 'Buzz' desktop/dist/assets/*.js || true; } | wc -l | tr -d ' ')"
  [[ "$whole" == 0 ]] || { echo "rebrand bundle-scan: the word Buzz $whole time(s) in desktop/dist/assets/*.js:" >&2; grep -o -h -E '.{0,40}\bBuzz\b.{0,40}' desktop/dist/assets/*.js | head -20 >&2; bad=1; }
  allowed="$(grep -v -E '^(#|$)' "$REBRAND/bundle-allow.tsv" | cut -f1 || true)"
  # every identifier token that carries Buzz, exactly as listed
  while IFS= read -r ctx; do
    [[ -n "$ctx" ]] || continue
    grep -qx -F "$ctx" <<<"$allowed" || { echo "rebrand bundle-scan: identifier '$ctx' carries Buzz and is not in bundle-allow.tsv" >&2; bad=1; }
  done < <(grep -o -h -E '[A-Za-z0-9_$]*Buzz[A-Za-z0-9_$]*' desktop/dist/assets/*.js | sort -u || true)
  (( bad == 0 )) || exit 1
  echo "rebrand bundle-scan: ok (whole-word Buzz 0; $( { grep -o -h -F 'Buzz' desktop/dist/assets/*.js || true; } | wc -l | tr -d ' ') substring(s), each on an allowed identifier; Cone $( { grep -o -h -w 'Cone' desktop/dist/assets/*.js || true; } | wc -l | tr -d ' '))"
}

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
    cmd_bundle_scan
    echo "rebrand check: typecheck and frontend build ok"
  fi
  echo "rebrand check: ok"
}

case "${1:-}" in
  apply) cmd_apply ;;
  restore) cmd_restore ;;
  scan) cmd_scan ;;
  bundle-scan) cmd_bundle_scan ;;
  measure) cmd_measure ;;
  check) shift; cmd_check "$@" ;;
  *) die "usage: cone/rebrand.sh apply|restore|scan|bundle-scan|measure|check [--build]" ;;
esac
