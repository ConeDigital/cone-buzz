# Cone Desktop

Cone's build of the Buzz Desktop: upstream's app at the `desktop-v*` tag in
`cone/UPSTREAM`, renamed, iconed and configured for `buzz.cone.digital`, signed
with Cone's Developer ID. The plan and its record are in `cone-buzz-infra`,
`slices/29-branded-desktop.md` (ADR-0059).

**The fork stays shallow:** everything Cone adds is under `cone/`, plus one
`import 'cone/cone.just'` line in the root `Justfile` and
`.github/workflows/cone-desktop.yml`. `just cone-shallow-check` refuses any
other path, locally and in every release run. Never change an upstream file.

| Path | What |
|------|------|
| `UPSTREAM` | the pinned upstream tag |
| `build.env` | the build-time configuration (no secret), the update feed's URL among it |
| `updater.pub` | the updater's public key (minisign `A11AAB7556EB3BE2`), compiled into every build; the private half is in 1Password `Cone Buzz Backup Keys` and the `cone-release` environment only. Never change it: an app accepts updates signed by this key alone |
| `build-env.sh` | clears every variable `build.rs` reads, then loads `build.env` and `updater.pub` |
| `tauri.cone.conf.json` | the Tauri config delta: name, identifier, icons, `Info.plist`, DMG background, macOS 10.15 floor |
| `Info.plist`, `icons/`, `make-assets.py` | the menu-bar name and usage strings; the icons and DMG background, generated from `icons/source.png` |
| `cone.just` | `cone-desktop-build`, `cone-shallow-check`, `cone-build-env-check`, `cone-notarize-test` |
| `notarize.sh`, `release-advance.sh`, `notarize-test.sh` | the release run's notarization (submit; wait through dropped requests, staple), the resumable stages of one architecture's release, and their test against mocks of `xcrun`, `hdiutil` and `codesign` |
| `updater-archive.sh` | the updater archive (`Cone_<version>_<arch>.app.tar.gz` + `.sig`) made from the stapled app and signed with the updater key; tested in `notarize-test.sh` |
| `updater-verify.sh`, `updater-test.sh`, `test/updater/` | checks an archive's signature as an app does (key id, Ed25519 over BLAKE2b-512, trusted comment); its test against two throwaway keys' signatures |

## Build locally (unsigned)

```bash
. bin/activate-hermit
just cone-desktop-build aarch64-apple-darwin      # or x86_64-apple-darwin
# → desktop/src-tauri/target/<target>/release/bundle/{macos/Cone.app,dmg/Cone_<version>_<arch>.dmg}
```

Ad-hoc signed, unstyled DMG (Tauri's Finder layout needs an Automation grant
on a workstation). The updater is built in (Cone's feed and key), so a local
build offers the newest promoted release. Never distribute a local build.

## Release

1. Merge to `cone` by pull request (`gh pr create -R ConeDigital/cone-buzz`:
   in this fork `gh` defaults to `block/buzz`).
2. Tag the merge commit and push the tag:
   `git tag cone-desktop-vX.Y.Z origin/cone && git push origin cone-desktop-vX.Y.Z`.
   `0.x` releases were prereleases for testers, without an updater; from
   `1.0.0` every release carries one.
3. The owner approves the run (Actions → the run → *Review deployments* →
   `cone-release`). Both builds wait for it; no one approves through the API.
4. The run builds Apple silicon and Intel, signs and notarizes the app and the
   DMG, verifies them (`codesign`, `spctl`, `stapler`, entitlements, Team ID,
   hardened runtime and `lipo` on every binary; Cone's feed and key compiled
   in, Block's endpoint absent), makes each updater archive from the stapled
   app and signs it with the updater key, and creates the GitHub Release with
   both DMGs, both `.app.tar.gz`, both `.sig` and `SHA256SUMS`.
5. If Apple is still working when the run's time is up (it has taken hours),
   the run fails with the command that resumes it, and its state — the signed
   app and DMG, Apple's submission ids, the stage — is an artifact for 14 days:
   `gh workflow run cone-desktop.yml -R ConeDigital/cone-buzz --ref cone-desktop-vX.Y.Z -f resume_run_id=<run>`.
   The owner approves the resume like any run; it continues where the run
   stopped, never rebuilding or resubmitting what Apple already has. A resume
   that stops again is resumed from its own run id.

6. **Promote** — the release reaches installed apps only now:
   `gh workflow run cone-desktop.yml -R ConeDigital/cone-buzz --ref cone-desktop-vX.Y.Z -f promote=cone-desktop-vX.Y.Z`,
   approved by the owner. It verifies both archives against `cone/updater.pub`
   and `SHA256SUMS`, writes `latest.json` with upstream's
   `desktop/scripts/generate-oss-latest-json.sh` and uploads it to the R2
   bucket `cone-desktop-updates`, then reads it back through
   `https://buzz.cone.digital/desktop/latest.json` (it prints the feed's
   `sha256` before and after). Any `cone-desktop-v*` tag can be the `--ref`;
   its workflow is the one that runs.

Secrets are in the environment `cone-release` only (deployments from tags
`cone-desktop-v*`, the owner a required reviewer); their sources are in
1Password `Cone Buzz Backup Keys`.

## Upstream update

Not yet run (Slice 29 close-out, criterion 6). Merge the next upstream
`desktop-v*` tag into a branch `cone-update/<tag>` (merge, never rebase), set
`cone/UPSTREAM` to it, `just cone-shallow-check`, build locally, then a pull
request to `cone` that lists any workflow the merge adds; right after it
merges, disable each (`gh workflow disable -R ConeDigital/cone-buzz <name>`):
every upstream workflow stays disabled.
