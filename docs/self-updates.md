# Sparkle self-updates

AltView pins **Sparkle 2.9.6** through Xcode Swift Package Manager, matching eucaly
and ViewTheWord. The feed is:

`https://github.com/sukujgrg/AltView/releases/latest/download/appcast.xml`

The repository must be public before release. Until the first release publishes
this feed, a manual check may report that update information is unavailable.
Existing builds without Sparkle need one manual installation of the first
Sparkle-enabled version. Later versions update inside AltView.

## Behavior

- **AltView → Check for Updates…** opens Sparkle's native download, installation
  and relaunch interface.
- **AltView → Automatically Check for Updates** controls Sparkle's persisted
  preference. It starts enabled, using Sparkle's daily schedule.
- Scheduled checks show an **Update Available** button in the workspace and an
  update version in the app menu. They never open a scheduled dialog or take focus,
  including at launch. Click the reminder when ready to update.
- An open output window (including preview or waiting for a disconnected display),
  an active receiver source, or Custom Text publication blocks manual checks and
  update relaunch. Close Audience Display and stop presenting/release the source first.
  A check or dialog opened before presentation begins is guarded again before
  offering an update and before restarting.
- Automatic installation is disabled. Installation requires user action. Normal
  termination still confirms unapplied Design changes and shuts down connections
  and output. Test-host launches do not start the updater.

Sparkle verifies signed feeds and signed archives before extracting updates. The
public Ed25519 key is embedded in `AltView/Info.plist`; the private key stays in
Keychain account `com.suku.AltView`. The [release pipeline](releasing.md) signs and
verifies both feed and archive and preserves previous feed items.

## Sandboxing

The app enables `SUEnableInstallerLauncherService` and the `-spks` / `-spki` Mach
lookup exceptions, following the same sandbox installer approach as ViewTheWord.
AltView already has outgoing network access, so it does not enable Sparkle's
separate downloader service. Its existing incoming network and selected-file
permissions remain available. See [Sparkle's sandbox integration guide](https://sparkle-project.org/documentation/sandboxing/)
and [gentle reminder API](https://sparkle-project.org/documentation/gentle-reminders/).

The application owns one `AppUpdateController` and one `SparkleUpdateDriver`.
The controller manages menu state and presentation guards; Sparkle owns verification,
native update UI, installation and relaunch. Receiver and composer state notify the
workspace reminder when presentation activity changes.

## Validation before distribution

`make test` covers updater state with an injected driver, live presentation guards,
output-window activity, version generation and offline release/feed regressions.
Release verification checks both Intel and Apple Silicon app/helper binaries and
both slices' signatures and entitlements.

Before shipping broadly, test a real update between two notarized versions in
`/Applications`, including on the Monterey Intel receiver. Check a scheduled
reminder while presenting, explicit installation while idle, cancellation of
unapplied Design changes, and restart with the receiver ready and output closed.
Those end-to-end installer checks require published versions and are separate from
the offline suite.
