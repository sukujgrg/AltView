# Releasing AltView

AltView uses the same local release workflow as eucaly and ViewTheWord. Signing,
notarization credentials and the Sparkle signing key stay in your Mac's Keychain.
GitHub Actions validates source; it does not sign or publish releases.

## Commands

| Command | Result |
| --- | --- |
| `make build` | Archive and export a universal app into `~/Applications/AltView.app` for local use |
| `make test` | App tests plus offline version, feed and release regressions |
| `make test-release` | Only the offline release regressions |
| `make release-check` | Check clean source, public destination, tags and CI |
| `make release-notarize` | Prepare signed, notarized artifacts locally; do not tag or publish |
| `make release-publish` | Publish the already prepared artifacts |
| `make release` | Validate, build, sign, notarize, tag and publish |
| `make clean` | Remove build caches while preserving `build/release/` |

`VERSION` is the single marketing-version source (initially `1.0`). Edit it directly
or run `scripts/set-version.sh 1.1`. Xcode generates the app's Info.plist in DerivedData
before signing; do not edit the version in the project or in a built app. Release
build numbers advance automatically beyond all entries in the previous feed.

The app remains sandboxed and supports **macOS 12+, Intel and Apple Silicon**.
Release verification checks both architecture slices, the signing team, hardened
runtime, sandbox/network/Sparkle entitlements, source commit and version. Debug
builds use ad-hoc signing with a Debug-only library-validation exception. Release
builds use team `E5N29VFW8T`, automatic signing and full library validation. Archive
export re-signs Sparkle and its helper tools with your Developer ID certificate.

## One-time setup on the release Mac

1. Install/select Xcode and sign in with the developer account for team
   `E5N29VFW8T`. The Keychain needs the **Developer ID Application** certificate
   and its private key, as well as the development identity used for archiving.
2. Install GitHub CLI and authenticate with `gh auth login`.
3. Make `sukujgrg/AltView` public before the first release. The feed and archives
   must be downloadable without a GitHub login. Release preflight checks this;
   no GitHub credential is embedded in the app.
4. Store your Apple app-specific password in a separate local notary profile:

   ```sh
   xcrun notarytool store-credentials AltViewNotary \
     --apple-id 'YOUR_APPLE_ID_EMAIL' \
     --team-id E5N29VFW8T
   ```

   Enter the app-specific password at the secure terminal prompt. Do not put it
   in a command, source file, Makefile, release notes, or GitHub secret. Subsequent
   releases use this Keychain profile automatically. To use a different existing
   profile, pass `NOTARY_PROFILE=YourProfile` to `make release` or
   `make release-notarize`.
5. Preserve the Sparkle key in Keychain account **`com.suku.AltView`**. It was
   generated for AltView during setup. Only the public key is in `AltView/Info.plist`.
   Follow [Sparkle's key transfer instructions](https://sparkle-project.org/documentation/#3-set-up-code-signing)
   when moving release machines. Do not generate a replacement for an app already
   distributed to users.

An Apple app-specific password authenticates notarization; it does not replace
the Developer ID certificate or the Sparkle update-signing key.

## Publish a version

1. Update `VERSION`, run `make test`, commit the changes and merge or push them to
   `main`. Keep the checkout clean, including untracked files.
2. Run `make release`. The script requires the newest successful **Validate**
   push run on `main` for the exact source commit. It waits for that run if needed.
3. The script archives and exports the universal app, submits it to Apple,
   checks Apple's acceptance and archive hash, staples a copy, then produces the
   signed archive and appcast. Only after preparation does it push `v<VERSION>`
   and create a GitHub draft. It verifies all uploads before publishing the draft
   as the latest release.

Optional release notes must be outside the checkout:

```sh
make release NOTES_FILE=/tmp/altview-notes.md
```

To review artifacts before publishing:

```sh
make release-notarize
# Inspect build/release/v<VERSION>/
make release-publish NOTES_FILE=/tmp/altview-notes.md
```

Each release contains:

- `AltView-<VERSION>-notarized.zip`
- `AltView-<VERSION>-notarized.zip.sha256`
- `AltView-<VERSION>-notarized.zip.source.txt`
- `appcast.xml` (signed feed containing this and previous updates)

The notarized `.app`, logs, work files and `state.json` are retained locally under
`build/release/v<VERSION>/`. The first release creates a feed from scratch because
AltView has no existing releases. Every later release requires and verifies the
previous signed feed. Archives and feeds are both signed with the AltView key;
feed generation retains earlier items and their OS/hardware eligibility.

## Resume interrupted work

Rerun the same command from the same clean commit and version. Preparation verifies
saved file hashes and resumes after completed work instead of repeating signing,
notarization or uploads. Never edit the saved state or overwrite published assets.
A repository-wide lock prevents concurrent release and cleanup commands, including
from linked worktrees. `make clean` preserves all saved release work.

If Apple's submission succeeded but its response was lost, inspect
`build/release/v<VERSION>/work/notary-submission.json` and your notary history.
Recover that submission only with its actual ID:

```sh
python3 scripts/release.py --no-publish --notary-profile AltViewNotary \
  --resume-notarization SUBMISSION_UUID
```

The script checks that Apple's log matches the exact saved archive hash. If source,
feed history or artifacts changed, it stops and preserves the files. Resolve the
reported mismatch or move the saved release directory aside and use a new version.
Do not force tags or manually replace release assets to bypass these checks.

## Tooling layout

`Makefile` and `VERSION` are the entry points. `scripts/build.sh` is the local
build/export command. `scripts/release.py` is adapted from eucaly's resumable
pipeline, with AltView's universal and sandbox verification. `scripts/update-feed.py`
generates and verifies Sparkle feeds. `scripts/generate-info-plist.sh` applies
`VERSION` before signing. `scripts/generate-project.py` owns the checked-in Xcode
project, including its pinned Sparkle dependency and version phase. Regenerate it
when adding Swift files or changing build settings; CI checks it stays in sync.

The release regressions use fake Apple/GitHub commands and temporary repositories.
They exercise interrupted work, source/CI/tag mismatches, signatures, architecture
and entitlement checks, history preservation and publication without real uploads.

App layout tests use windows that can exceed the runner's display size, so compact
and tall layouts are checked at their requested dimensions. Hosted CI explicitly
sets `TEST_RUNNER_ALTVIEW_SKIP_BONJOUR_TEST=1` (forwarded by Xcode as
`ALTVIEW_SKIP_BONJOUR_TEST`) to skip only the live multicast discovery tests;
receiver identity parsing/filtering and real loopback TLS tests still run.
Window regressions disable Bonjour advertising explicitly and continue to use
real loopback TLS, including when receivers pause, resume or recover their port.
`make test` locally includes live Bonjour discovery by default and needs local
network access. Two-Mac discovery remains part of the manual hardware checks.
