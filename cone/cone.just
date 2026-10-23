# Cone Desktop recipes (Slice 29, cone-buzz-infra slices/29-branded-desktop.md).
# Imported by the root Justfile with one line; everything else Cone adds lives
# under cone/ (decision 1). No recipe here changes a file outside cone/.

# Paths a Cone commit may change, relative to the pinned upstream tag.
cone_allowed := "^(cone/.*|\\.github/workflows/cone-desktop\\.yml|Justfile)$"

# The fork stays shallow (criterion 2): every path that differs from the pinned
# upstream tag is under cone/, is the Cone workflow, or is the Justfile with
# exactly the one import line added. Judges HEAD and the working tree.
cone-shallow-check:
    #!/usr/bin/env bash
    set -euo pipefail
    base="$(tr -d '[:space:]' < cone/UPSTREAM)"
    git rev-parse --verify --quiet "$base^{commit}" >/dev/null || { echo "cone-shallow-check: $base is not a commit here (git fetch upstream --tags)" >&2; exit 1; }
    paths="$( { git diff --name-only --no-renames "$base" HEAD; git status --porcelain --untracked-files=all | cut -c4-; } | sed '/^$/d' | sort -u)"
    bad="$(printf '%s\n' "$paths" | grep -Ev '{{cone_allowed}}' || true)"
    if [[ -n "$bad" ]]; then printf 'cone-shallow-check: outside cone/:\n%s\n' "$bad" >&2; exit 1; fi
    if printf '%s\n' "$paths" | grep -qx Justfile; then
      added="$(git diff --no-renames "$base" -- Justfile | grep '^+' | grep -v '^+++' || true)"
      removed="$(git diff --no-renames "$base" -- Justfile | grep '^-' | grep -v '^---' || true)"
      if [[ -n "$removed" || "$added" != "+import 'cone/cone.just'" ]]; then
        printf 'cone-shallow-check: the Justfile may only gain the import line; diff:\n%s\n%s\n' "$removed" "$added" >&2; exit 1
      fi
    fi
    echo "cone-shallow-check: ok ($(printf '%s\n' "$paths" | grep -c . || true) path(s) differ from $base, all Cone's)"

# Build the Cone Desktop for one Apple target. Uses upstream's pinned toolchain
# (bin/activate-hermit). Without a Developer ID in the environment the app is
# ad-hoc signed (a local build); the release workflow supplies
# APPLE_SIGNING_IDENTITY and the notarization key (merge 2). `version`, when
# given, is written into the build's copy of upstream's version files after the
# shallowness check has judged the source, and restored when the recipe exits.
cone-desktop-build target="aarch64-apple-darwin" version="":
    #!/usr/bin/env bash
    set -euo pipefail
    TARGET={{quote(target)}}
    VERSION={{quote(version)}}
    [[ "$(uname -s)" == Darwin && "$TARGET" =~ ^(aarch64|x86_64)-apple-darwin$ ]] || { echo "cone-desktop-build: aarch64-apple-darwin or x86_64-apple-darwin, on macOS" >&2; exit 2; }
    . bin/activate-hermit >/dev/null
    just cone-shallow-check
    just cone-build-env-check
    . cone/build-env.sh
    cone_build_env
    if [[ -n "$VERSION" ]]; then
      version_files=(desktop/package.json desktop/src-tauri/tauri.conf.json desktop/src-tauri/Cargo.toml desktop/src-tauri/Cargo.lock)
      root="$PWD"
      trap 'git -C "$root" checkout -- "${version_files[@]}"' EXIT
      (cd desktop && node scripts/set-version-from-tag.mjs "$VERSION")
      (cd desktop/src-tauri && cargo update --workspace)
    fi
    rustup target add "$TARGET" >/dev/null
    export APPLE_SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:--}"
    # As upstream's release.yml: macOS 10.15 floor (with bundle.macOS.
    # minimumSystemVersion in tauri.cone.conf.json), and the mesh-llm feature on
    # Apple silicon only — upstream's Intel release builds without it.
    export MACOSX_DEPLOYMENT_TARGET=10.15 CMAKE_OSX_DEPLOYMENT_TARGET=10.15 CMAKE_POLICY_VERSION_MINIMUM=3.5
    features=()
    [[ "$TARGET" == aarch64-apple-darwin ]] && features=(--features mesh-llm)
    cargo build --release --target "$TARGET" \
      -p buzz-acp -p buzz-agent -p buzz-backend-kubernetes -p buzz-dev-mcp \
      -p git-credential-nostr -p buzz-cli
    ./scripts/bundle-sidecars.sh "$TARGET"
    pnpm install --frozen-lockfile
    cd desktop
    # CI=true makes Tauri's bundle_dmg.sh skip its Finder AppleScript (the
    # window layout and cone/'s background), which needs an Automation grant on
    # a workstation. The release workflow sets TAURI_BUNDLER_DMG_IGNORE_CI=true,
    # as upstream's release.yml does: a GitHub macOS runner's Finder runs it.
    CI=true pnpm tauri build ${features[@]+"${features[@]}"} --target "$TARGET" --bundles app,dmg --config ../cone/tauri.cone.conf.json
    plist="src-tauri/target/$TARGET/release/bundle/macos/Cone.app/Contents/Info.plist"
    for k in CFBundleName CFBundleDisplayName CFBundleIdentifier CFBundleShortVersionString; do
      printf '%s = %s\n' "$k" "$(/usr/libexec/PlistBuddy -c "Print :$k" "$plist")"
    done
    ls -1 "src-tauri/target/$TARGET/release/bundle/dmg/"

# The build's configuration is exactly cone/build.env (review of
# ConeDigital/cone-buzz#1): with leftover values planted for every variable
# build.rs reads, cone_build_env must leave each one as cone/build.env sets it,
# or unset.
cone-build-env-check:
    #!/usr/bin/env bash
    set -euo pipefail
    . cone/build-env.sh
    for v in $(cone_build_vars); do export "$v=leftover-$v"; done
    cone_build_env
    bad=0
    for v in $(cone_build_vars); do
      want="$(grep -E "^$v=" cone/build.env | tail -n 1 | cut -d= -f2- || true)"
      if [[ -n "$want" ]]; then
        [[ "${!v-}" == "$want" ]] || { echo "cone-build-env-check: $v is '${!v-<unset>}', cone/build.env says '$want'" >&2; bad=1; }
      else
        [[ -z "${!v+x}" ]] || { echo "cone-build-env-check: $v is '${!v}', but cone/build.env does not set it" >&2; bad=1; }
      fi
    done
    (( bad == 0 )) || exit 1
    echo "cone-build-env-check: ok ($(cone_build_vars | wc -l | tr -d ' ') build.rs variables, each as cone/build.env sets it or unset)"
