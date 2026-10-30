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
| `updater-verify.sh`, `promote-check.sh`, `updater-test.sh`, `test/updater/` | checks an archive's signature as an app does (key id, Ed25519 over BLAKE2b-512, trusted comment); refuses a promotion older than the feed; their test (two throwaway keys' signatures) |

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
   its workflow is the one that runs. Promotions run one at a time, and one
   refuses to move the feed to an older version than the bucket holds
   (`cone/promote-check.sh`): apps look only for newer versions, so an older
   feed would hide the newer release from them. Putting back a saved feed
   byte for byte is not a promotion; it is an upload with the bucket's token.

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

## The in-app rebrand (Slice 36, ADR-237)

Everything inside the window — every "Buzz" string, the theme defaults and
the Cone tile's gradients, the mark, the wordmark, the loading marks, the
menu-bar icon, the persona-card frame and its prompt — is Cone's through a
transform applied to the build's working copy, never to the tracked tree:
`cone/rebrand.sh apply` right before `pnpm tauri build` in
`cone-desktop-build`, `cone/rebrand.sh restore` when the recipe exits, and
the recipe proves `desktop/` clean afterwards. The manifests under
`cone/rebrand/`:

| File | What |
|------|------|
| `word` | the word that replaces "Buzz" in string text |
| `strings.tsv` | `path<TAB>count`: the exact number of "Buzz" hits in a file's string text (TS/TSX string literals, template text, JSX text; Rust string literals outside `#[cfg(test)]`, in the app crate and in every workspace crate it links; embedded templates whole) after the blocks and lines are applied |
| `lines.tsv` | exact text replacements (JSON strings), each matching exactly `count` times: theme defaults, the sidebar's bee emoji, the card prompt, an assertion that the window title is empty |
| `blocks.tsv` + `blocks/` | multi-line exact replacements: the tray icon function, the Builderlab page's mark |
| `replacements.tsv` + `files/` | whole-file replacements, each pinned to the SHA-256 of the upstream file it replaces |
| `exceptions.tsv` | the scan's allowed hits, each with a reason (the two nominative references to Block, the Welcome team's bee wordplay, an Objective-C class name) |
| `bundle-allow.tsv` | identifiers the built frontend (`desktop/dist/assets/*.js`, which Tauri embeds compressed, invisible to `strings` on the binary) may still carry around the letters Buzz (`isBuzzHost`, a property name); `cone/rebrand.sh bundle-scan` requires the whole word absent and every such token listed |
| `src-tauri/tray-mask.rgba` | the menu-bar mask the tray block embeds |
| `wordmark.svg`, `make-rebrand-assets.py` | the wordmark as delivered and the script that renders the PNG/RGBA assets from the SVGs |

`just cone-rebrand-check` applies, scans every production source file for
`Buzz`, `Block` and bee motifs outside the exceptions, type-checks and
builds the frontend, scans the built bundle, and restores; `just
cone-rebrand-test` plants thirteen changes, each committed in a disposable
worktree at `HEAD`, that must each fail with the intended diagnostic naming
the path (an uncommitted plant would only meet the dirty-tree guard). `cone-desktop-build` runs the bundle scan on the frontend Tauri just
embedded. Both run in the
workflow before the build.

**On an upstream update**, after the merge and `cone/UPSTREAM`:
`just cone-rebrand-check` names what moved — a count in `strings.tsv`
(re-measure into a temporary file and replace the manifest only on success —
`m=$(mktemp) && cone/rebrand.sh measure > "$m" && mv "$m" cone/rebrand/strings.tsv` —
then diff; a redirect straight into `strings.tsv` truncates it before a failing
measure runs), a line or block whose upstream text changed (update the row, or the
`.old` file), a replacement whose upstream content changed (`git diff
<old-tag> <new-tag> -- <path>`, carry the change into `files/<path>` or
record why not, then the new hash into `replacements.tsv`), or a new
branded string the scan found (a row, or an exception with a reason). The
pull request lists the rows changed.

**To change the brand later**: a new SVG into `files/desktop/public/buzz.svg`
or `wordmark.svg`, `bin/uv run --with resvg-py==0.5.0 --with Pillow==12.2.0
python cone/rebrand/make-rebrand-assets.py`, and a release; the word in
`word`; colours in the `lines.tsv` theme rows.
