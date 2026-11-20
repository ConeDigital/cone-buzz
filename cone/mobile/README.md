# Cone for iPhone

Cone's build of upstream's Buzz phone app (Flutter, `mobile/` in `block/buzz`)
at the tag in `UPSTREAM`: named **Cone**, bundle id `digital.cone.mobile`,
signed by Cone's team, Cone's icon and pictures, and no "Buzz" a person can
read. The plan and its record are in `cone-buzz-infra`,
`slices/43-cone-mobile.md` (ADR-274, amended by ADR-428). iOS only for now;
Android is deferred (below).

**The rule: the fork stays shallow.** Everything Cone adds is under `cone/`
(plus, later, `.github/workflows/cone-mobile.yml`). No upstream file is ever
changed in a commit: a build rebrands its working copy, builds, puts every
file back, and proves `mobile/` clean. `cone/mobile/shallow-check.sh`
refuses any other path.

| Path | What |
|------|------|
| `UPSTREAM` | the pinned upstream tag (`mobile-vX.Y.Z[-rc.N]`) |
| `AppOverrides.xcconfig` | the iOS identity — bundle id, display name, team `4M8BGHNU5W`, automatic signing; copied to upstream's gitignored `mobile/ios/Flutter/AppOverrides.xcconfig`, which Debug and Release include last |
| `build.env`, `build-env.sh` | the one `--dart-define` (`BUZZ_RELAY_URL=https://buzz.cone.digital`); the reader refuses any other name |
| `rebrand.sh`, `rebrand/` | the transform and its manifests (below) |
| `make-assets.py`, `icons/source.png`, `rebrand/wordmark.svg`, `rebrand/mark.svg` | the pictures and their sources (copies of the Desktop overlays') |
| `apply-test.sh` | selftest + mutation test, in throwaway repositories |
| `shallow-check.sh` | the shallowness rule |
| `cone-mobile.just` | the recipes |

## Build

Upstream's root `Justfile` is not edited; call this file with upstream's
pinned just, from the repository root:

```bash
. bin/activate-hermit
just -f cone/mobile/cone-mobile.just cone-mobile-test          # selftest + mutants (git, node, perl; ~1 min)
just -f cone/mobile/cone-mobile.just cone-mobile-check         # apply, scan, measure, assert, restore
just -f cone/mobile/cone-mobile.just cone-mobile-measure       # user-visible "Buzz" left after apply (0)
just -f cone/mobile/cone-mobile.just cone-mobile-shallow-check
just -f cone/mobile/cone-mobile.just cone-mobile-build-sim     # simulator debug build → mobile/build/ios/iphonesimulator/Buzz.app
just -f cone/mobile/cone-mobile.just cone-mobile-dev           # signed, installed on the connected iPhone (mode=debug|profile|release)
just -f cone/mobile/cone-mobile.just cone-mobile-apply         # by hand: apply …
just -f cone/mobile/cone-mobile.just cone-mobile-restore       # … and put back
```

| Recipe | Notes |
|--------|-------|
| `cone-mobile-build-sim` | unsigned; unsets every `BUZZ_*` in the environment (upstream's Xcode phase turns an exported `BUZZ_PUSH_GATEWAY_URL` into a define) |
| `cone-mobile-dev` | `flutter build ios --config-only` (defines, pods), then `xcodebuild … -allowProvisioningUpdates` (never `-allowProvisioningDeviceRegistration`, which `flutter build ios` adds) and `xcrun devicectl device install app`. Needs Xcode signed in with the Cone developer account, the App IDs `digital.cone.mobile` and `.NotificationService` with their capabilities, and the iPhone already registered. A `debug` build runs only while Xcode or `flutter attach` is attached (every Flutter debug build on iOS); `profile`/`release` open from the home screen |
| both | `trap` runs `rebrand.sh finish` on every exit, Ctrl-C included: restore, put back `mobile/ios/Podfile.lock`'s `COCOAPODS:` line (upstream writes it with CocoaPods 1.17.0, Homebrew's 1.16.2 restamps it; any other lock change fails, named), prove `mobile/` clean |

Never run upstream's `just mobile-dev` for Cone: it writes
`WorktreeOverrides.xcconfig` (a Block dev bundle id); Cone's
`AppOverrides.xcconfig` would still win, but nothing else of it is Cone's.
`pubspec.yaml` says `0.0.0+1`: release builds will pass `--build-name` /
`--build-number` (merge 2).

## The rebrand

`rebrand.sh apply` refuses a dirty `mobile/` (restore checks out from
HEAD), writes the xcconfig (never over a developer's own), copies the
pictures (each pinned to the upstream file's SHA-256), applies `lines.tsv`,
then replaces every capitalised `Buzz` in **string text** with the word in
`rebrand/word`, by exact count per file. String text is: Dart and Swift
string literals (interpolated code excluded), plist `<string>` values,
storyboards/strings files and the Xcode project and scheme whole.
Comments, identifiers, `buzz://`, `nostrpair://` and every lower-case
`buzz` are never touched. Every replacement is `Buzz` → `Cone`: the same
length, so no string changes size.

| Manifest | What |
|----------|------|
| `scope.tsv` | `text` roots (word rule + scans) and `images` roots (picture inventory) |
| `strings.tsv` | path + exact count of the word in its string text; written by `rebrand.sh count` |
| `keep.tsv` | a `Buzz` that stays, with count and reason: the relay User-Agent `Buzz-Mobile`, the huddle marker, log lines, the product name `Buzz.app` (not shown; renaming it renames the Swift module), Builderlab's callback scheme |
| `lines.tsv` | exact text replacements (none needed at this tag) |
| `replacements.tsv` + `files/` | whole pictures: app icon (every size, opaque RGB), launch image, `buzz-icon.png`, `buzz-wordmark.png`, `welcome-bee.svg` |
| `kept-images.tsv` | upstream pictures left on purpose, pinned to their hash, with a reason |
| `exceptions.tsv` | residue-scan hits that stay (widget keys, Block's "Buzzies" avatar pack, queue labels) |
| `identity.tsv` | what every identity setting must resolve to, Debug and Release |

`rebrand.sh scan` finds what the rule does not rewrite (`Buzz…` words,
`BUZZ`, `Block`, bees, honey, 🐝, `xyz.block` ids); `assert` checks the
identity through upstream's own xcconfig include chain and project, the
plists (`plutil -lint`, names, permission prompts, the `buzz` scheme), and
that every picture in the inventory is Cone's or kept on purpose, each app
icon opaque at its size.

**Pictures:** `bin/uv run --with resvg-py==0.5.0 --with Pillow==12.2.0 python cone/mobile/make-assets.py`,
then update `replacements.tsv` if a target's upstream hash moved.

## Upstream update

1. Branch `cone-mobile-update/<tag>` from the current Cone branch; `git fetch upstream tag <tag> --no-tags`; `git merge <tag>` (merge, never rebase).
2. Set `UPSTREAM`; `cone/mobile/shallow-check.sh`.
3. `cone/mobile/rebrand.sh check` names what moved:
   - a count in `strings.tsv`: `m=$(mktemp) && cone/mobile/rebrand.sh count > "$m"`, then `head -1 cone/mobile/rebrand/strings.tsv | cat - "$m" > cone/mobile/rebrand/strings.tsv`; read the diff and each new hit (`rebrand.sh hits`): a wire/protocol name or a log line → `keep.tsv` with a reason, everything else is rebranded;
   - a `keep.tsv` count: upstream added or dropped a use — decide which;
   - a hash in `replacements.tsv` or `kept-images.tsv`: `git diff <old> <new> -- <path>`, regenerate (`make-assets.py`) or say why not, update the hash;
   - an `[identity]` / `[plists]` / `[pictures]` / `[app icon]` assertion: upstream changed the include chain, the project, Info.plist or a catalogue — read it before changing a row;
   - a residue: a row or an exception with a reason.
4. `cone/mobile/apply-test.sh` (mutants name the planted paths: adjust a plant whose upstream text moved), then a simulator build.
5. Workflows: a merge can add workflow files the fork has never seen; they register **active** on the first push. Read each new file's `on:` before pushing and disable it after (`gh workflow disable -R ConeDigital/cone-buzz <name>`).

## Android (deferred)

Nothing is built for Android. Its part adds rows, nothing moves: `text`
and `images` roots under `mobile/android/` in `scope.tsv`, pictures under
`rebrand/files/mobile/android/…` in `replacements.tsv`, the Gradle identity
lines in `lines.tsv`, and the define list stays `build.env`'s.
