# shellcheck shell=bash
# Sourced by cone/cone.just. The build's configuration is cone/build.env and
# nothing else (review of ConeDigital/cone-buzz#1): `just` loads the root
# .env (`set dotenv-load`), and a shell may export anything, so every variable
# desktop/src-tauri/build.rs reads is cleared first — the list is read from
# build.rs's own `rerun-if-env-changed` lines, so a variable upstream adds is
# cleared too — and then cone/build.env is loaded, and the updater's public key
# from cone/updater.pub (merge 3). A leftover
# BUZZ_BUILD_DEMO_SLUG would give the app another keychain identity and make it
# refuse buzz:// links (Slice 29 decision 3).

cone_build_vars() { # the variables build.rs reads, one per line
  grep -o 'rerun-if-env-changed=[A-Z0-9_]*' desktop/src-tauri/build.rs | cut -d= -f2
}

cone_updater_pubkey() { # the updater's public key, as build.rs and Tauri take it
  tr -d '[:space:]' < cone/updater.pub
}

cone_build_env() { # clear every build.rs variable, then load cone/build.env and cone/updater.pub
  local vars v
  vars="$(cone_build_vars)"
  [[ -n "$vars" ]] || { echo "cone_build_env: no rerun-if-env-changed line in build.rs; refusing to guess" >&2; return 1; }
  for v in $vars; do unset "$v"; done
  set -a
  # shellcheck source=cone/build.env
  . cone/build.env
  set +a
  BUZZ_UPDATER_PUBLIC_KEY="$(cone_updater_pubkey)"
  # Without either, build.rs leaves the updater out without a word.
  [[ -n "$BUZZ_UPDATER_PUBLIC_KEY" && -n "${BUZZ_UPDATER_ENDPOINT:-}" ]] \
    || { echo "cone_build_env: the updater needs cone/updater.pub and BUZZ_UPDATER_ENDPOINT in cone/build.env" >&2; return 1; }
  export BUZZ_UPDATER_PUBLIC_KEY
}
