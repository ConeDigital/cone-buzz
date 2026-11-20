#!/usr/bin/env bash
# The Cone phone app overlay's selftest and mutation test (cone-buzz-infra
# Slice 43, criterion 2; the method of the Desktop overlays' rebrand-test.sh).
#
#   bash cone/mobile/apply-test.sh        (from anywhere; needs git, node, perl)
#
# Nothing runs in this checkout. Every case runs in a throwaway repository
# under $TMPDIR — never a worktree of this one, so this repository's .git is
# not touched: commit 1 holds mobile/ (and the root .gitignore) at HEAD, tagged
# with the name in cone/mobile/UPSTREAM; commit 2 holds the working tree's
# cone/. A case clones it, plants its change and COMMITS it (an uncommitted
# plant would meet the dirty-tree guard first, never the guard it targets),
# runs the command, and judges the output.
#
# 1. The selftest: apply → scan, measure, assert (identity, plists, pictures)
#    → restore → the tree is HEAD again and Cone's xcconfig gone; strings.tsv
#    is what `count` measures; the copy is shallow.
# 2. Mutants: each one names the assertion that must kill it and that
#    assertion's diagnostic with the planted path; failing some other way is
#    not a kill. After a failed `check`, the tree must still be restored.
# 3. Controls: changes the rebrand must NOT flag (comments, identifiers,
#    interpolated code, lower-case buzz).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
TAG="$(tr -d '[:space:]' < cone/mobile/UPSTREAM)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/cone-mobile-test.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
GIT=(git -c user.name=cone-test -c user.email=test@cone.digital -c commit.gpgsign=false -c tag.gpgsign=false -c init.defaultBranch=main)
XC=mobile/ios/Flutter/AppOverrides.xcconfig
APPICON=mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset
FILES=cone/mobile/rebrand/files

[[ -z "$(git status --porcelain -- cone)" ]] || echo "note: cone/ has uncommitted changes; this run tests the working tree's cone/"

BASE="$SCRATCH/base"
mkdir -p "$BASE"
git archive HEAD mobile .gitignore | tar -x -C "$BASE"
( cd "$BASE" && "${GIT[@]}" init -q && "${GIT[@]}" add -A && "${GIT[@]}" commit -q -m upstream && "${GIT[@]}" tag "$TAG" )
cp -R cone "$BASE/cone"
( cd "$BASE" && "${GIT[@]}" add -A && "${GIT[@]}" commit -q -m cone )

pass=0; fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
no() { echo "FAIL $1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | tail -6 | sed 's/^/     /'; fail=$((fail + 1)); }
copy() { local d; d="$(mktemp -d "$SCRATCH/case.XXXXXX")"; rmdir "$d"; git clone -q "$BASE" "$d"; echo "$d"; }
commit() { "${GIT[@]}" add -A && "${GIT[@]}" commit -q -m "plant: $1"; }
restored() { # the copy is HEAD again and Cone's xcconfig is gone
  [[ -z "$(git -C "$1" status --porcelain --untracked-files=all)" ]] && [[ ! -e "$1/$XC" ]]
}

# ------------------------------------------------------------- selftest ----

d="$(copy)"
step() { # <name> <command…>: run in the copy, must pass
  local name="$1" out; shift
  if out="$(cd "$d" && "$@" 2>&1)"; then ok "selftest: $name — $(tail -1 <<<"$out")"; else no "selftest: $name" "$out"; fi
}
step "apply" cone/mobile/rebrand.sh apply
step "scan" cone/mobile/rebrand.sh scan
step "measure" node cone/mobile/rebrand/transform.mjs measure
step "assert" cone/mobile/rebrand.sh assert
if grep -q 'digital.cone.mobile' "$d/$XC" && [[ "$(git -C "$d" check-ignore "$XC")" == "$XC" ]]; then ok "selftest: identity file in place and ignored"; else no "selftest: identity file in place and ignored"; fi
step "restore" cone/mobile/rebrand.sh restore
if restored "$d" && git -C "$d" diff --quiet HEAD; then ok "selftest: the tree is HEAD again, $XC removed"; else no "selftest: clean after restore" "$(git -C "$d" status --porcelain --ignored -- mobile/ios/Flutter mobile/lib | head)"; fi
if out="$(cd "$d" && cone/mobile/rebrand.sh count 2>&1)" && diff <(grep -v '^#' "$d/cone/mobile/rebrand/strings.tsv") <(printf '%s\n' "$out") >/dev/null; then
  ok "selftest: strings.tsv is current ($(grep -vc '^#' "$d/cone/mobile/rebrand/strings.tsv") files)"
else no "selftest: strings.tsv is current" "$out"; fi
step "measure on a clean tree" cone/mobile/rebrand.sh measure
step "check" cone/mobile/rebrand.sh check
step "shallow" cone/mobile/shallow-check.sh
step "finish on a clean tree" cone/mobile/rebrand.sh finish
if out="$(cd "$d" && cone/mobile/build-env.sh 2>&1)" && [[ "$out" == "--dart-define=BUZZ_RELAY_URL=https://buzz.cone.digital" ]]; then ok "selftest: build.env gives exactly one define — $out"; else no "selftest: build.env gives exactly one define" "$out"; fi
rm -rf "$d"

# -------------------------------------------------------------- mutants ----

# mutant <name> <killer> <path that must be named> <diagnostic that must appear> <command> <plant>
mutant() {
  local name="$1" killer="$2" want_path="$3" want_diag="$4" cmd="$5" plant="$6" d out status=0
  d="$(copy)"
  if ! ( cd "$d" && "$plant" && commit "$name" ) >/dev/null 2>&1; then no "mutant $name: the plant changed nothing (fix the plant)"; rm -rf "$d"; return; fi
  out="$(cd "$d" && $cmd 2>&1)" || status=$?
  if [[ "$status" == 0 ]]; then no "mutant $name survived ($killer should kill it)" "$out"
  elif grep -qF "is not clean" <<<"$out"; then no "mutant $name: refused as dirty, not judged by $killer" "$out"
  elif ! grep -qF -- "$want_path" <<<"$out" || ! grep -qF -- "$want_diag" <<<"$out"; then no "mutant $name: failed without $killer's '$want_diag' on $want_path" "$out"
  elif [[ "$cmd" == *check* ]] && ! restored "$d"; then no "mutant $name: killed by $killer, but the tree was not restored after the failure" "$(git -C "$d" status --porcelain | head -5)"
  else ok "mutant $name — killed by $killer"
  fi
  rm -rf "$d"
}
CHECK="cone/mobile/rebrand.sh check"
append() { printf '%s\n' "$2" >> "$1"; }
L=mobile/lib

# the word rule (apply): every hit in string text is counted per file
m01() { append $L/features/channels/compose_bar/camera_preview.dart "const plantedOne = 'Planted Buzz string';"; }
mutant "extra Buzz string in a listed Dart file" "the word-rule count" $L/features/channels/compose_bar/camera_preview.dart "2 'Buzz' in string text, strings.tsv says 1" "$CHECK" m01
m02() { append $L/main.dart "const plantedTwo = 'Buzz here';"; }
mutant "Buzz string in an unlisted Dart file" "the word-rule count" $L/main.dart "strings.tsv says 0" "$CHECK" m02
m03() { append $L/main.dart "const plantedThree = '''"; append $L/main.dart "Hello \${1 + 1} Buzz"; append $L/main.dart "''';"; }
mutant "Buzz in a triple-quoted, interpolated Dart string" "the word-rule count" $L/main.dart "strings.tsv says 0" "$CHECK" m03
m04() { append mobile/ios/Runner/ToastLayer.swift 'let plantedFour = "Buzz here"'; }
mutant "Buzz string in an unlisted Swift file" "the word-rule count" mobile/ios/Runner/ToastLayer.swift "strings.tsv says 0" "$CHECK" m04
m05() { append mobile/ios/Runner/SceneDelegate.swift 'let plantedFive = """'; append mobile/ios/Runner/SceneDelegate.swift '\(1 + 1) Buzz'; append mobile/ios/Runner/SceneDelegate.swift '"""'; }
mutant "Buzz in a Swift multi-line, interpolated string" "the word-rule count" mobile/ios/Runner/SceneDelegate.swift "strings.tsv says 0" "$CHECK" m05
m06() { perl -0pi -e 's|(\t<key>NSUserActivityTypes</key>)|\t<key>NSContactsUsageDescription</key>\n\t<string>Buzz reads your contacts.</string>\n$1|' mobile/ios/Runner/Info.plist; }
mutant "a new permission prompt in Info.plist" "the word-rule count" mobile/ios/Runner/Info.plist "7 'Buzz' in string text, strings.tsv says 6" "$CHECK" m06
m07() { mkdir -p mobile/ios/Runner/en.lproj && printf '"CFBundleDisplayName" = "Buzz";\n' > mobile/ios/Runner/en.lproj/InfoPlist.strings; }
mutant "a new InfoPlist.strings" "the word-rule count" mobile/ios/Runner/en.lproj/InfoPlist.strings "strings.tsv says 0" "$CHECK" m07

# keep.tsv: a kept name's count is exact both ways
m08() { append $L/shared/relay/relay_websocket.dart "const plantedUa = 'Buzz-Mobile';"; }
mutant "a kept name used once more" "the keep count" $L/shared/relay/relay_websocket.dart "keep.tsv says 2" "$CHECK" m08
m09() { perl -pi -e 's/Buzz notification authorization request failed/Buzz notification permission request failed/' mobile/ios/Runner/AppDelegate.swift; }
mutant "a kept log line reworded upstream" "the keep count" mobile/ios/Runner/AppDelegate.swift "keep.tsv says 1" "$CHECK" m09
m10() { perl -pi -e '$done ||= s/PRODUCT_NAME = Buzz;/PRODUCT_NAME = Buzz2;/' mobile/ios/Runner.xcodeproj/project.pbxproj; }
mutant "the product name changed upstream" "the keep count" mobile/ios/Runner.xcodeproj/project.pbxproj "keep.tsv says 3" "$CHECK" m10

# the residue scan: what the word rule does not rewrite
m11() { append $L/main.dart "const plantedB = 'Block built this';"; }
mutant "a Block string" "the residue scan" "rebrand scan: $L/main.dart" ": Block:" "$CHECK" m11
m12() { append $L/main.dart "const plantedBee = 'a bee in the corner';"; }
mutant "a bee string" "the residue scan" "rebrand scan: $L/main.dart" ": bee:" "$CHECK" m12
m13() { append $L/main.dart "const plantedCaps = 'BUZZ ONLY';"; }
mutant "BUZZ in capitals" "the residue scan" "rebrand scan: $L/main.dart" ": BUZZ:" "$CHECK" m13
m14() { append $L/main.dart "const plantedWord = 'Buzzing along';"; }
mutant "a word made from Buzz" "the residue scan" "rebrand scan: $L/main.dart" ": Buzz…:" "$CHECK" m14
m15() { append mobile/ios/Runner/ToastLayer.swift 'let plantedId = "xyz.block.buzz.other"'; }
mutant "a new Block identifier" "the residue scan" "rebrand scan: mobile/ios/Runner/ToastLayer.swift" ": xyz.block:" "$CHECK" m15
m15b() { perl -pi -e '$done ||= s/"\$\(BUNDLE_IDENTIFIER\)\.NotificationService"/xyz.block.buzz.mobile.NotificationService/' mobile/ios/Runner.xcodeproj/project.pbxproj; }
mutant "Block's extension id hard-coded in the project" "the residue scan" "rebrand scan: mobile/ios/Runner.xcodeproj/project.pbxproj" ": xyz.block:" "$CHECK" m15b

# lines.tsv and replacements.tsv: pinned to upstream's exact content
m16() { printf '\n' >> "$APPICON/Icon-App-1024x1024@1x.png"; }
mutant "an app icon changed upstream" "the replacement hash" "$APPICON/Icon-App-1024x1024@1x.png" "upstream content changed" "$CHECK" m16
m17() { rm mobile/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png; }
mutant "a launch image deleted upstream" "the replacement hash" mobile/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png "replacement target missing upstream" "$CHECK" m17
m18() { printf 'mobile/lib/main.dart\t"const plantedNever = 1;"\t"const plantedNever = 2;"\n' >> cone/mobile/rebrand/lines.tsv; }
mutant "a lines.tsv row whose text is not upstream's" "the line count" $L/main.dart "found 0 times, expected 1" "$CHECK" m18

# assert [pictures] / [app icon]: every picture is Cone's or kept on purpose; icons opaque, at size
m19() { cp mobile/assets/images/buzz-icon.png mobile/assets/images/buzz-logo-2.png; }
mutant "a new picture upstream" "[pictures]" mobile/assets/images/buzz-logo-2.png "neither replaced" "$CHECK" m19
m20() { printf 'x' >> mobile/assets/images/shell-gradient.png; }
mutant "a kept picture changed upstream" "[pictures]" mobile/assets/images/shell-gradient.png "kept as upstream's, but its content changed" "$CHECK" m20
m21() {
  cp "$APPICON/Icon-App-1024x1024@1x.png" "$APPICON/Icon-App-Dark-1024.png"
  node -e 'const f=process.argv[1], fs=require("fs"); const c=JSON.parse(fs.readFileSync(f)); c.images.push({size:"1024x1024",idiom:"universal",platform:"ios",filename:"Icon-App-Dark-1024.png",appearances:[{appearance:"luminosity",value:"dark"}]}); fs.writeFileSync(f, JSON.stringify(c,null,2));' "$APPICON/Contents.json"
}
mutant "a dark app icon added upstream" "[app icon]" "$APPICON/Icon-App-Dark-1024.png" "not replaced by Cone's" "$CHECK" m21
m22() { node -e 'const f=process.argv[1], fs=require("fs"); const b=fs.readFileSync(f); b[25]=6; fs.writeFileSync(f,b);' "$FILES/$APPICON/Icon-App-20x20@1x.png"; }
mutant "Cone's icon with an alpha channel" "[app icon]" "$APPICON/Icon-App-20x20@1x.png" "has an alpha channel" "$CHECK" m22
m23() { cp "$FILES/$APPICON/Icon-App-20x20@2x.png" "$FILES/$APPICON/Icon-App-29x29@2x.png"; }
mutant "Cone's icon at the wrong size" "[app icon]" "$APPICON/Icon-App-29x29@2x.png" "40x40, Contents.json wants 58x58" "$CHECK" m23

# assert [identity]: the decided identity, through upstream's include chain and project
m24() { perl -pi -e 's/^BUNDLE_IDENTIFIER = digital\.cone\.mobile$/BUNDLE_IDENTIFIER = digital.cone.mobil/' cone/mobile/AppOverrides.xcconfig; }
mutant "a wrong bundle id in the template" "[identity]" "BUNDLE_IDENTIFIER resolves to 'digital.cone.mobil'" "not 'digital.cone.mobile'" "$CHECK" m24
m25() { perl -0pi -e 's/\n#include\? "AppOverrides.xcconfig"\n?$/\n/; s/(#include "Generated.xcconfig"\n)/$1#include? "AppOverrides.xcconfig"\n/' mobile/ios/Flutter/Release.xcconfig; }
mutant "upstream includes AppOverrides before its defaults" "[identity]" "Release: BUNDLE_IDENTIFIER resolves to 'xyz.block.buzz.mobile'" "Release.xcconfig and its includes" "$CHECK" m25
m26() { perl -pi -e '$done ||= s/"\$\(BUNDLE_IDENTIFIER\)\.NotificationService"/com.example.other.NotificationService/' mobile/ios/Runner.xcodeproj/project.pbxproj; }
mutant "a hard-coded, non-Cone extension id upstream" "[identity]" "project.pbxproj: PRODUCT_BUNDLE_IDENTIFIER" "outside digital.cone.mobile" "$CHECK" m26
m27() { perl -pi -e '$done ||= s/DEVELOPMENT_TEAM = "\$\(BUZZ_DEVELOPMENT_TEAM\)";/DEVELOPMENT_TEAM = EYF346PHUG;/' mobile/ios/Runner.xcodeproj/project.pbxproj; }
mutant "a hard-coded team upstream" "[identity]" "project.pbxproj: DEVELOPMENT_TEAM EYF346PHUG" "not 4M8BGHNU5W" "$CHECK" m27
m28() { perl -pi -e 's/AppOverrides.xcconfig$/AppOverrides.xcconfig.unused/ if /^Flutter\/AppOverrides/' mobile/ios/.gitignore; }
mutant "AppOverrides.xcconfig no longer gitignored" "the xcconfig guard" "$XC" "is not gitignored upstream any more" "$CHECK" m28

# assert [plists]
m29() { perl -0pi -e 's|(<key>CFBundleDisplayName</key>\s*<string>)\$\(APP_DISPLAY_NAME\)|$1\$(PRODUCT_NAME)|' mobile/ios/Runner/Info.plist; }
mutant "the display name no longer from the xcconfig" "[plists]" mobile/ios/Runner/Info.plist "CFBundleDisplayName is no longer" "$CHECK" m29
m30() { printf 'mobile/ios/Runner/Info.plist\t"<string>buzz</string>"\t"<string>cone</string>"\n' >> cone/mobile/rebrand/lines.tsv; }
mutant "a row that rewrites the buzz:// scheme" "[plists]" mobile/ios/Runner/Info.plist "the URL scheme 'buzz' is gone" "$CHECK" m30
m31() { perl -ni -e 'print unless /^mobile\/lib\/shared\/relay\/relay_websocket.dart\t/' cone/mobile/rebrand/keep.tsv; }
mutant "a keep row dropped (the User-Agent)" "the word-rule count" $L/shared/relay/relay_websocket.dart "2 'Buzz' in string text, strings.tsv says 0" "$CHECK" m31

# the shallow check
m32() { append $L/main.dart "// a committed upstream edit"; }
mutant "a committed edit to an upstream file" "the shallow check" $L/main.dart "outside cone/" cone/mobile/shallow-check.sh m32
m33() { echo "UPSTREAM pin" > cone/mobile/UPSTREAM; }
mutant "a pin that is not a mobile tag" "the shallow check" cone/mobile/UPSTREAM "not an upstream mobile tag" cone/mobile/shallow-check.sh m33

# build.env: one define, nothing else
m34() { printf 'BUZZ_PUSH_GATEWAY_URL=https://push.example\n' >> cone/mobile/build.env; }
mutant "a second define in build.env" "the build.env reader" "cone/mobile/build.env:" "BUZZ_PUSH_GATEWAY_URL is not an allowed define" cone/mobile/build-env.sh m34
m35() { perl -pi -e 's|^BUZZ_RELAY_URL=https://|BUZZ_RELAY_URL=http://|' cone/mobile/build.env; }
mutant "a plain-http relay in build.env" "the build.env reader" "cone/mobile/build.env:" "BUZZ_RELAY_URL is not an https URL" cone/mobile/build-env.sh m35

# guards on an uncommitted state (judged without a commit)
d="$(copy)"; append "$d/$L/main.dart" "// uncommitted work"; status=0
out="$(cd "$d" && cone/mobile/rebrand.sh check 2>&1)" || status=$?
if [[ "$status" != 0 ]] && grep -qF "is not clean under mobile/" <<<"$out" && grep -qF "$L/main.dart" <<<"$out" && grep -q "uncommitted work" "$d/$L/main.dart"; then ok "mutant uncommitted work in mobile/ — killed by the dirty-tree guard, the work kept"; else no "mutant uncommitted work in mobile/" "$out"; fi
rm -rf "$d"
d="$(copy)"; printf 'BUNDLE_IDENTIFIER = com.example.mine\n' > "$d/$XC"; status=0
out="$(cd "$d" && cone/mobile/rebrand.sh check 2>&1)" || status=$?
if [[ "$status" != 0 ]] && grep -qF "exists and is not Cone's" <<<"$out" && grep -q 'com.example.mine' "$d/$XC"; then ok "mutant a developer's own AppOverrides.xcconfig — killed by the xcconfig guard, the file kept"; else no "mutant a developer's own AppOverrides.xcconfig" "$out"; fi
rm -rf "$d"
d="$(copy)"; perl -pi -e 's/^COCOAPODS: .*/COCOAPODS: 1.16.2/' "$d/mobile/ios/Podfile.lock"
if out="$(cd "$d" && cone/mobile/rebrand.sh finish 2>&1)" && restored "$d"; then ok "control finish puts back pod install's version stamp"; else no "control finish puts back pod install's version stamp" "$out"; fi
rm -rf "$d"
d="$(copy)"; perl -pi -e 's/^PODFILE CHECKSUM: .*/PODFILE CHECKSUM: 0000/' "$d/mobile/ios/Podfile.lock"; status=0
out="$(cd "$d" && cone/mobile/rebrand.sh finish 2>&1)" || status=$?
if [[ "$status" != 0 ]] && grep -qF "mobile/ios/Podfile.lock: the build changed more than the CocoaPods version line" <<<"$out"; then ok "mutant a build that moved a dependency — killed by finish's lock guard"; else no "mutant a build that moved a dependency" "$out"; fi
rm -rf "$d"

# ------------------------------------------------------------- controls ----

# control <name> <command> <plant>: a change the overlay must accept
control() {
  local name="$1" cmd="$2" plant="$3" d out
  d="$(copy)"
  if ! ( cd "$d" && "$plant" && commit "$name" ) >/dev/null 2>&1; then no "control $name: the plant changed nothing (fix the plant)"; rm -rf "$d"; return; fi
  if out="$(cd "$d" && $cmd 2>&1)"; then ok "control $name — accepted"; else no "control $name: rejected" "$out"; fi
  rm -rf "$d"
}
c1() { append $L/main.dart "// Buzz in a line comment"; append $L/main.dart "/// Buzz in a doc comment, /* nested Buzz */"; append $L/main.dart "/* Buzz in a block /* nested Buzz */ comment */"; }
c2() { append $L/main.dart "class Buzz {}"; append $L/main.dart "String plantedSix(Object Buzz) => 'x \${Buzz} y \$Buzz z';"; }
c3() { append mobile/ios/Runner/ToastLayer.swift '// Buzz in a comment /* Buzz */'; append mobile/ios/Runner/ToastLayer.swift 'enum Buzz {}'; append mobile/ios/Runner/ToastLayer.swift 'let plantedSeven = "x \(Buzz.self) y"'; }
c4() { append $L/main.dart "const plantedLink = 'buzz://channel/abc';"; }
c5() { mkdir -p .github/workflows && printf 'name: cone-mobile\non: workflow_dispatch\n' > .github/workflows/cone-mobile.yml; }
control "Buzz in Dart comments" "$CHECK" c1
control "Buzz as a Dart identifier and in interpolated code" "$CHECK" c2
control "Buzz in a Swift comment, identifier and interpolation" "$CHECK" c3
control "a lower-case buzz:// link" "$CHECK" c4
control "the allowed workflow path" cone/mobile/shallow-check.sh c5

echo "apply-test: $pass passed, $fail failed"
(( fail == 0 ))
