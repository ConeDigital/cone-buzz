#!/usr/bin/env bash
# The fork stays shallow (cone-buzz-infra Slice 43 decision 2, criterion 2):
# every path that differs from the upstream tag in cone/mobile/UPSTREAM — in
# HEAD or in the working tree — is under cone/ or on the allow-list below.
# Never a committed change to an upstream file: rebranding happens in a
# build's working copy and is put back (cone/mobile/rebrand.sh).
#
#   cone/mobile/shallow-check.sh        (from anywhere in the repository)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# Paths a Cone commit may change outside cone/: the future release workflow.
ALLOWED='^(cone/.*|\.github/workflows/cone-mobile\.yml)$'

die() { echo "cone-mobile-shallow-check: $*" >&2; exit 1; }

base="$(tr -d '[:space:]' < cone/mobile/UPSTREAM)"
[[ "$base" =~ ^mobile-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.[0-9]+)?$ ]] || die "cone/mobile/UPSTREAM holds '$base', not an upstream mobile tag mobile-vX.Y.Z[-rc.N]"
git rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "$base is not a commit here (git fetch upstream tag $base --no-tags)"
paths="$( { git diff --name-only --no-renames "$base" HEAD; git status --porcelain --no-renames --untracked-files=all | cut -c4-; } | sed -e '/^$/d' -e 's/^"\(.*\)"$/\1/' | sort -u)"
bad="$(printf '%s\n' "$paths" | grep -Ev "$ALLOWED" | sed '/^$/d' || true)"
[[ -z "$bad" ]] || { printf 'cone-mobile-shallow-check: outside cone/:\n%s\n' "$bad" >&2; exit 1; }
echo "cone-mobile-shallow-check: ok ($(printf '%s\n' "$paths" | grep -c . || true) path(s) differ from $base, all Cone's)"
