#!/usr/bin/env bash
# Prints the build's --dart-define arguments, one per line, from cone/mobile/build.env
# (cone-buzz-infra Slice 43 decision 4): exactly the names allowed below, each once, an
# https URL each. Anything else in build.env is refused, naming the line.
#
#   defines=(); while IFS= read -r d; do defines+=("$d"); done < <(cone/mobile/build-env.sh)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

ALLOWED=(BUZZ_RELAY_URL)
die() { echo "cone/mobile/build-env.sh: $*" >&2; exit 1; }

seen=" "
n=0
while IFS= read -r line || [[ -n "$line" ]]; do
  n=$((n + 1))
  [[ -z "$line" || "$line" == \#* ]] && continue
  [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || die "cone/mobile/build.env:$n: not NAME=value"
  name="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
  [[ " ${ALLOWED[*]} " == *" $name "* ]] || die "cone/mobile/build.env:$n: $name is not an allowed define (${ALLOWED[*]})"
  [[ "$seen" != *" $name "* ]] || die "cone/mobile/build.env:$n: $name set twice"
  [[ "$value" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/.*)?$ ]] || die "cone/mobile/build.env:$n: $name is not an https URL"
  seen+="$name "
  printf -- '--dart-define=%s=%s\n' "$name" "$value"
done < cone/mobile/build.env
for name in "${ALLOWED[@]}"; do [[ "$seen" == *" $name "* ]] || die "cone/mobile/build.env: $name is missing"; done
