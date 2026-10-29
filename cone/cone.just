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
    # The in-app rebrand (Slice 36, ADR-237): cone/rebrand.sh rewrites the
    # working copy — strings, assets, components, the tray mask — after the
    # shallowness check has judged the source, and the trap puts every file
    # back when the recipe exits, so the tree is clean after a build.
    root="$PWD"
    trap 'cd "$root" && cone/rebrand.sh restore' EXIT
    cone/rebrand.sh apply
    cone/rebrand.sh scan
    if [[ -n "$VERSION" ]]; then
      version_files=(desktop/package.json desktop/src-tauri/tauri.conf.json desktop/src-tauri/Cargo.toml desktop/src-tauri/Cargo.lock)
      trap 'cd "$root" && cone/rebrand.sh restore; git checkout -- "${version_files[@]}"' EXIT
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
    # The updater (merge 3): the plugin's key and feed as a second config delta,
    # written outside the tree from cone_build_env's values (RFC 7396 replaces
    # upstream's empty endpoints array). With the updater key in the
    # environment (a release run) Tauri also makes and signs its own
    # Cone.app.tar.gz — before notarization, so the release replaces it
    # (cone/updater-archive.sh); here it proves the key and password early.
    updater_conf="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cone-updater-conf.XXXXXX")/tauri.updater.conf.json"
    artifacts=false
    [[ -n "${TAURI_SIGNING_PRIVATE_KEY:-}" ]] && artifacts=true
    node -e 'const [file, pubkey, endpoint, artifacts] = process.argv.slice(1);
      require("fs").writeFileSync(file, JSON.stringify({ bundle: { createUpdaterArtifacts: artifacts === "true" },
        plugins: { updater: { pubkey, endpoints: [endpoint] } } }, null, 2) + "\n");' \
      "$updater_conf" "$BUZZ_UPDATER_PUBLIC_KEY" "$BUZZ_UPDATER_ENDPOINT" "$artifacts"
    echo "updater: $BUZZ_UPDATER_ENDPOINT, updater artifacts $artifacts"
    CI=true pnpm tauri build ${features[@]+"${features[@]}"} --target "$TARGET" --bundles app,dmg --config ../cone/tauri.cone.conf.json --config "$updater_conf"
    plist="src-tauri/target/$TARGET/release/bundle/macos/Cone.app/Contents/Info.plist"
    for k in CFBundleName CFBundleDisplayName CFBundleIdentifier CFBundleShortVersionString; do
      printf '%s = %s\n' "$k" "$(/usr/libexec/PlistBuddy -c "Print :$k" "$plist")"
    done
    ls -1 "src-tauri/target/$TARGET/release/bundle/dmg/"
    # The frontend Tauri just embedded (compressed, so `strings` on the binary
    # cannot see it): no word Buzz, substrings only on allowed identifiers.
    (cd "$root" && cone/rebrand.sh bundle-scan)
    # Put the tree back now (the trap stays for the failure paths) and prove it.
    cd "$root"
    cone/rebrand.sh restore
    [[ -z "$VERSION" ]] || git checkout -- "${version_files[@]}"
    trap - EXIT
    left="$(git status --porcelain --untracked-files=all -- desktop/ | sed '/^$/d' || true)"
    [[ -z "$left" ]] || { printf 'cone-desktop-build: desktop/ is not clean after the build:\n%s\n' "$left" >&2; exit 1; }
    echo "cone-desktop-build: desktop/ clean after the build"

# The build's configuration is exactly cone/build.env (review of
# ConeDigital/cone-buzz#1): with leftover values planted for every variable
# build.rs reads, cone_build_env must leave each one as cone/build.env sets it
# (the updater's public key as cone/updater.pub holds it), or unset.
cone-build-env-check:
    #!/usr/bin/env bash
    set -euo pipefail
    . cone/build-env.sh
    for v in $(cone_build_vars); do export "$v=leftover-$v"; done
    cone_build_env
    bad=0
    for v in $(cone_build_vars); do
      want="$(grep -E "^$v=" cone/build.env | tail -n 1 | cut -d= -f2- || true)"
      [[ "$v" == BUZZ_UPDATER_PUBLIC_KEY ]] && want="$(tr -d '[:space:]' < cone/updater.pub)"
      if [[ -n "$want" ]]; then
        [[ "${!v-}" == "$want" ]] || { echo "cone-build-env-check: $v is '${!v-<unset>}', not '$want'" >&2; bad=1; }
      else
        [[ -z "${!v+x}" ]] || { echo "cone-build-env-check: $v is '${!v}', but cone/build.env does not set it" >&2; bad=1; }
      fi
    done
    (( bad == 0 )) || exit 1
    echo "cone-build-env-check: ok ($(cone_build_vars | wc -l | tr -d ' ') build.rs variables, each as cone/build.env sets it or unset)"

# cone/updater-verify.sh against throwaway keys' signatures (cone/test/updater).
cone-updater-test:
    bash cone/updater-test.sh

# cone/notarize.sh against a mock xcrun: acceptance, a dropped request and a
# held copy, refusal, the copy cap with the deadline, and failing resubmissions.
cone-notarize-test:
    bash cone/notarize-test.sh

# The in-app rebrand is exact (Slice 36 criterion 1): every replacement's
# upstream hash matches, every block and line row matches once, the word
# rule's per-file counts hold, the residue scan over every production source
# file finds no "Buzz", "Block" or bee motif outside cone/rebrand/exceptions.tsv,
# the transformed frontend type-checks and builds, and the tree is restored.
# Refuses a dirty desktop/ (it would be restored to HEAD).
cone-rebrand-check:
    #!/usr/bin/env bash
    set -euo pipefail
    . bin/activate-hermit >/dev/null
    cone/rebrand.sh check --build

# Thirteen planted changes (an extra string, a "Block" string in a listed file, a
# string in an unlisted file, an embedded template line, a motif word, an
# edited line target, a deleted and an edited replacement target, an edited
# block, a new include_str! source, a block that would end a Rust raw string, two in a built bundle)
# each fail the check naming the path.
cone-rebrand-test:
    #!/usr/bin/env bash
    set -euo pipefail
    . bin/activate-hermit >/dev/null
    bash cone/rebrand-test.sh
