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
| `build.env` | the build-time configuration (no secret) |
| `build-env.sh` | clears every variable `build.rs` reads, then loads `build.env` |
| `tauri.cone.conf.json` | the Tauri config delta: name, identifier, icons, `Info.plist`, DMG background, macOS 10.15 floor |
| `Info.plist`, `icons/`, `make-assets.py` | the menu-bar name and usage strings; the icons and DMG background, generated from `icons/source.png` |
| `cone.just` | `cone-desktop-build`, `cone-shallow-check`, `cone-build-env-check` |
| `notarize.sh` | the release run's notarization: submit, poll through dropped requests, staple |

## Build locally (unsigned)

```bash
. bin/activate-hermit
just cone-desktop-build aarch64-apple-darwin      # or x86_64-apple-darwin
# → desktop/src-tauri/target/<target>/release/bundle/{macos/Cone.app,dmg/Cone_<version>_<arch>.dmg}
```

Ad-hoc signed, unstyled DMG (Tauri's Finder layout needs an Automation grant
on a workstation). Never distribute a local build.

## Release

1. Merge to `cone` by pull request (`gh pr create -R ConeDigital/cone-buzz`:
   in this fork `gh` defaults to `block/buzz`).
2. Tag the merge commit and push the tag:
   `git tag cone-desktop-vX.Y.Z origin/cone && git push origin cone-desktop-vX.Y.Z`.
   `0.x` releases are prereleases for testers (no updater before 1.0).
3. The owner approves the run (Actions → the run → *Review deployments* →
   `cone-release`). Both builds wait for it; no one approves through the API.
4. The run builds Apple silicon and Intel, signs and notarizes the app and the
   DMG, verifies them (`codesign`, `spctl`, `stapler`, entitlements, Team ID,
   hardened runtime and `lipo` on every binary), and creates the GitHub Release
   with both DMGs and `SHA256SUMS`.

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
