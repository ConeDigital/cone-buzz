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

# Build the Cone Desktop for one Apple target (merge 1: unsigned, ad-hoc signed,
# no updater). Uses upstream's pinned toolchain (bin/activate-hermit).
cone-desktop-build target="aarch64-apple-darwin":
    #!/usr/bin/env bash
    set -euo pipefail
    TARGET={{target}}
    [[ "$(uname -s)" == Darwin && "$TARGET" == *-apple-darwin ]] || { echo "cone-desktop-build: macOS Apple targets only" >&2; exit 2; }
    . bin/activate-hermit >/dev/null
    just cone-shallow-check
    set -a; . cone/build.env; set +a
    # Ad-hoc signature unless a release run supplies the Developer ID (merge 2).
    export APPLE_SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:--}"
    cargo build --release --target "$TARGET" \
      -p buzz-acp -p buzz-agent -p buzz-backend-kubernetes -p buzz-dev-mcp \
      -p git-credential-nostr -p buzz-cli
    ./scripts/bundle-sidecars.sh "$TARGET"
    pnpm install --frozen-lockfile
    cd desktop
    # CI=true makes Tauri's bundle_dmg.sh skip its Finder AppleScript (the
    # window layout), which needs an Automation grant locally and cannot run on
    # a CI runner at all. The DMG is unstyled until merge 2 styles it without
    # Finder.
    CI=true pnpm tauri build --features mesh-llm --target "$TARGET" --bundles app,dmg --config ../cone/tauri.cone.conf.json
    plist="src-tauri/target/$TARGET/release/bundle/macos/Cone.app/Contents/Info.plist"
    for k in CFBundleName CFBundleDisplayName CFBundleIdentifier CFBundleShortVersionString; do
      printf '%s = %s\n' "$k" "$(/usr/libexec/PlistBuddy -c "Print :$k" "$plist")"
    done
    ls -1 "src-tauri/target/$TARGET/release/bundle/dmg/"
