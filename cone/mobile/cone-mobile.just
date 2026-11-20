# The Cone phone app's recipes (cone-buzz-infra Slice 43). Upstream's root
# Justfile is never edited, so this file is invoked on its own, from the
# repository root, with upstream's pinned just (bin/just, hermit):
#
#   just -f cone/mobile/cone-mobile.just <recipe>
#
# Recipes run from the repository root. No recipe leaves a tracked file outside
# cone/ changed: the rebrand is applied to the working copy and put back.

set working-directory := "../.."

# List the recipes.
default:
    @just -f cone/mobile/cone-mobile.just --list

# Rebrand the working copy of mobile/ (identity xcconfig, pictures, strings). Refuses a dirty mobile/.
cone-mobile-apply:
    cone/mobile/rebrand.sh apply

# Put mobile/ back: every path apply wrote, Cone's AppOverrides.xcconfig removed.
cone-mobile-restore:
    cone/mobile/rebrand.sh restore

# On a clean tree: apply, print every user-visible "Buzz" no keep row covers (target 0), restore.
cone-mobile-measure:
    cone/mobile/rebrand.sh measure

# Apply, scan, measure, assert identity, plists and pictures, restore: one verdict.
cone-mobile-check:
    cone/mobile/rebrand.sh check

# The selftest and the mutation test, in throwaway copies (never this checkout).
cone-mobile-test:
    bash cone/mobile/apply-test.sh

# Every path that differs from the tag in cone/mobile/UPSTREAM is Cone's.
cone-mobile-shallow-check:
    cone/mobile/shallow-check.sh

# A simulator debug build of the Cone app (unsigned), with upstream's pinned toolchain.
cone-mobile-build-sim:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "$(uname -s)" == Darwin ]] || { echo "cone-mobile-build-sim: macOS only" >&2; exit 2; }
    . bin/activate-hermit >/dev/null
    cone/mobile/shallow-check.sh
    # The one define is cone/mobile/build.env's; nothing else reaches the build.
    # (Upstream's Xcode phase turns an exported BUZZ_PUSH_GATEWAY_URL into a
    # define: scripts/require-push-gateway-origin.sh.)
    defines=(); while IFS= read -r d; do defines+=("$d"); done < <(cone/mobile/build-env.sh)
    for v in $(compgen -e | grep '^BUZZ_' || true); do unset "$v"; done
    unset GIT_DIR GIT_WORK_TREE
    trap 'exit 130' INT TERM
    trap 'cone/mobile/rebrand.sh finish' EXIT
    cone/mobile/rebrand.sh apply
    (cd mobile && flutter pub get && flutter build ios --simulator --debug "${defines[@]}")
    app="$(ls -d mobile/build/ios/iphonesimulator/*.app)"
    for k in CFBundleDisplayName CFBundleName CFBundleIdentifier; do
      printf '%s = %s\n' "$k" "$(/usr/libexec/PlistBuddy -c "Print :$k" "$app/Info.plist")"
    done
    trap - EXIT
    cone/mobile/rebrand.sh finish
    echo "cone-mobile-build-sim: $app"

# (debug: the app runs while Xcode or `flutter attach` is attached, as every Flutter debug build on iOS; profile and release open from the home screen.)
# Sign (automatic, Cone's team), build and install on the connected iPhone; `mode` debug|profile|release. Restores on any exit.
cone-mobile-dev mode="debug" device="":
    #!/usr/bin/env bash
    set -euo pipefail
    MODE={{quote(mode)}}
    DEVICE={{quote(device)}}
    [[ "$(uname -s)" == Darwin ]] || { echo "cone-mobile-dev: macOS only" >&2; exit 2; }
    case "$MODE" in debug) CONFIG=Debug ;; profile) CONFIG=Profile ;; release) CONFIG=Release ;;
      *) echo "cone-mobile-dev: mode is debug, profile or release, not '$MODE'" >&2; exit 2 ;; esac
    . bin/activate-hermit >/dev/null
    cone/mobile/shallow-check.sh
    defines=(); while IFS= read -r d; do defines+=("$d"); done < <(cone/mobile/build-env.sh)
    for v in $(compgen -e | grep '^BUZZ_' || true); do unset "$v"; done
    unset GIT_DIR GIT_WORK_TREE
    if [[ -z "$DEVICE" ]]; then
      DEVICE="$(cd mobile && flutter devices --machine 2>/dev/null | node -e '
        let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
          const list = JSON.parse(s.slice(s.indexOf("[")));
          const phone = list.find((d) => String(d.targetPlatform).startsWith("ios") && !d.emulator);
          if (phone) process.stdout.write(phone.id);
        });')"
      [[ -n "$DEVICE" ]] || { echo "cone-mobile-dev: no iPhone connected (flutter devices); unlock it, trust this Mac, turn on Developer Mode" >&2; exit 1; }
    fi
    trap 'exit 130' INT TERM
    trap 'cone/mobile/rebrand.sh finish' EXIT
    cone/mobile/rebrand.sh apply
    team="$(sed -nE 's/^BUZZ_DEVELOPMENT_TEAM *= *([A-Z0-9]+).*/\1/p' cone/mobile/AppOverrides.xcconfig)"
    echo "cone-mobile-dev: $CONFIG for device $DEVICE, automatic signing, team $team"
    # Flutter writes Generated.xcconfig (the defines, the build mode) and runs
    # pod install; xcodebuild then signs with -allowProvisioningUpdates only —
    # `flutter build ios` would add -allowProvisioningDeviceRegistration.
    (cd mobile && flutter pub get && flutter build ios --config-only "--$MODE" "${defines[@]}")
    derived="mobile/build/cone-dev"
    xcodebuild -workspace mobile/ios/Runner.xcworkspace -scheme Runner -configuration "$CONFIG" \
      -destination "id=$DEVICE" -derivedDataPath "$derived" -allowProvisioningUpdates build
    app="$(ls -d "$derived/Build/Products/$CONFIG-iphoneos/"*.app)"
    for k in CFBundleDisplayName CFBundleIdentifier; do
      printf '%s = %s\n' "$k" "$(/usr/libexec/PlistBuddy -c "Print :$k" "$app/Info.plist")"
    done
    codesign -dvv "$app" 2>&1 | grep -E '^(Authority|TeamIdentifier)=' | head -2
    xcrun devicectl device install app --device "$DEVICE" "$app"
    trap - EXIT
    cone/mobile/rebrand.sh finish
    echo "cone-mobile-dev: installed $app on $DEVICE"
