## Named TVs and persistent monitor numbers — 8 October 2026

## Individual sender connections — 8 October 2026

Connections now includes a native scrolling Senders table with one row per session, its name, presenting/idle state and Disconnect. Disconnected senders remain available with Allow Reconnect; receiver-side refusal prevents automatic retries from immediately undoing an operator disconnect. This refusal lasts for the current receiver process and survives Pause/Resume Receiving; it does not revoke saved pairing credentials. Actions use session IDs so a stale row cannot close a replacement session. Disconnecting an idle sender preserves the current source; disconnecting the owner clears Audience and Confidence text without stopping receiving.

Automated regression uses encrypted localhost connections with duplicate sender names, verifies idle/owner disconnection, refusal of reconnect attempts, allowing reconnection, and rejecting stale session actions. Native window checks exercise the actual Disconnect/Allow Reconnect buttons and render the sender list in compact/large light/dark appearances. All 82 selected regressions passed: 49 window, 21 network and 12 confidence tests.


## Native sidebar and shared Connections — 8 October 2026

The workspace uses an AppKit source-list sidebar in a split view. Outputs contains Audience and Confidence; Content contains Text only while Custom Text is enabled; Setup contains Connections. Audience Design opens through Edit Audience Design and keeps Audience selected, with Back to Audience returning to the live preview. Connections owns receiver status, sender names, pairing code and receiving controls for both outputs. AltView → Settings… (Command-comma) opens a separate window for general preferences; Command-5 opens Connections.

Validation: all 49 window tests passed, along with 12 confidence tests. The legacy display fixture was updated to assert the sidebar instead of segmented tabs, and the Audience/Confidence/Connections compact light/dark layout checks passed. The Custom Text opt-in, disable/draft preservation and shared-connection navigation tests passed again after Settings focus polish. The workspace minimum is now 1160 × 650 to retain usable content width beside the sidebar.

Manual rehearsal: select every sidebar destination, edit/back out of Audience Design, connect both sending apps through Connections, and confirm switching outputs preserves the connection. Open Settings while editing Design, enable Text, then disable it while its page is open; the sidebar should return to Audience and the draft should remain private. Check keyboard navigation and selected-row readability in light/dark appearances. Earlier entries below describe their historical interfaces.


**Name…** saves a monitor label such as Front Left TV or Stage TV against the macOS display UUID. AltView’s own monitor numbers now persist across discovery reordering, other TVs disconnecting and app relaunch; a new identity does not take an absent monitor’s number or name. The same label appears in both role menus, Identify and active/disconnected status. Names can change while output runs without changing its assignment. The dialog exposes the selectable UUID and supports restoring the model name by leaving the field empty.

Seven additional tests cover three identically named TVs with changed runtime IDs and discovery order, relaunch and missing-monitor number reservation, shared names across role changes, naming a live/disconnected monitor, unknown/ambiguous identities, Unicode/name validation and reset, saved labels on Identify overlays, and the real naming sheet’s Save/Cancel behavior. Compact light/dark fixtures include three identical model names with distinct operator names.

All **184 app tests passed** on 8 October, including the 22 monitor regressions. Native compact light/dark renders with saved names were inspected. The 104 offline release checks passed on 7 October; release tooling is unchanged in this revision.

Hardware rehearsal: connect all three TVs, identify and name each, then select Audience and Confidence by those labels. Unplug/replug and relaunch with one TV absent, confirming the other labels/numbers remain stable. Keep the cable-to-port mapping consistent; after changing cables, ports or adapters, use Identify again and reassign explicitly if macOS reports a new identity. These numbers are AltView’s, with no promised mapping to System Settings numbering.

## Audience and Confidence monitor controls — 7 October 2026

The former Output page is **Audience**; its appearance editor is **Audience Design**. Audience and Confidence share numbered monitor menus and **Open Display**, **Close Display**, and **Identify** actions. Settings retain the shared receiver and pairing controls.

Fifteen new monitor tests cover persistent/exclusive reservations with closed windows, independent preview windows, legacy migration, malformed preferences, duplicate names and identities, mirroring, display-number reuse, reconnection by UUID, immediate window closure on disconnect, cancellation of waiting output, locked live assignments, Identify overlay removal, confirmation on the controls screen, stale confirmation/selection checks, and 980 × 650 light/dark layouts with readable navigation labels. Fixtures use synthetic offscreen monitors and fresh defaults.

The full app suite passed all **177 tests**, and both offline release suites passed all **104 checks**. The final 15 monitor tests passed again after checking malformed storage types and refreshing native fixtures. Assigned-monitor controls were inspected in light/dark compact renders; navigation and monitor actions fit without truncation.

Hardware rehearsal:

1. Use extended displays and assign distinct Audience/Confidence monitors. Identify each while closed, then open both. Verify occupied choices are disabled in the other page, even after closing one window. Preview Window should free its previous physical reservation.
2. Try the monitor containing the controls; verify the confirmation can be cancelled and the Window menu closes each role independently. Close either live output before changing its monitor.
3. Unplug each assigned display. Its window should close immediately, the selected monitor should remain marked Disconnected, and the output should wait without covering another screen. Close Display must cancel restoration. Reconnect the same monitor and check the frame on the intended output; reassign explicitly if the hardware reports a different identity.
4. Switch to mirroring and back to extended displays. AltView should close/wait while mirrored, then restore the intended screen. Repeat using the production dock/adapter, including two identically named monitors.

## Confidence output — 7 October 2026

AltView’s independent Confidence output shows the local clock and current presented text. See [the operator workflow](confidence.md) and [the negotiated protocol extensions](protocol.md). The supporting sender changes live in the neighboring eucaly and ViewTheWord repositories.

Completed automated validation on 7 October 2026 (ViewTheWord’s full suite and review checks ran on 6 October):

| Checkout | Result |
| --- | --- |
| AltView | 177 app tests and 104 offline release tests passed on 7 October; the 15 monitor tests passed again after the final preference safeguard. |
| eucaly | 266 app tests and 104 offline release tests passed, including native Settings checks. |
| ViewTheWord | 145 Swift tests and 8 review regression checks passed on 6 October; its 2 confidence tests passed again on 7 October. |

AltView and eucaly’s local Release archive/export commands passed, as did ViewTheWord’s native Debug Xcode build. AltView’s exported executable contains both Intel and Apple Silicon architectures; eucaly’s contains Apple Silicon.

The real three-process TLS/Bonjour integration check passed, including dynamic loopback port recovery with settings absent. Lyric/Scripture render fixtures and compact Confidence/settings geometry were inspected. Native offscreen rendering does not establish physical input, native glass appearance or HDMI delivery.

Run the documented checks in each checkout:

```sh
# AltView
make test
make build
python3 scripts/test-confidence-integration.py

# eucaly
make test
make build

# ViewTheWord
swift test --scratch-path build/SwiftPM
python3 scripts/test-review-regressions.py
xcodebuild -project ViewTheWord.xcodeproj -scheme ViewTheWord -configuration Debug -derivedDataPath build/DerivedData build
```

The cross-repository integration command expects neighboring `eucaly` and `ViewTheWord` checkouts; `--eucaly` and `--viewtheword` accept other paths. It compiles the actual receiver and both actual sender transports, uses isolated fixture identities and TLS keys, and resolves real Bonjour advertisements into loopback connections on the current port. It does not load saved preferences/Keychain data or open projector windows. It covers connect-only privacy, lyric/Scripture takeover, blank/hidden text retention, Stop, changed-port receiver restart, connect-only sender reconnect, and Clear. Fixture processes are cleaned up after the run.

App tests additionally cover legacy capability negotiation, escaped frame limits, stale leases and acknowledgements, late grants after cancellation, primary text/reference/actual translation, independent appearance and visibility, multilingual fitting, rendered lyric/Scripture fixtures, settings geometry, and synthetic display removal/reappearance. Synthetic display tests cannot establish physical HDMI behavior.

Before using this in a service, complete these physical checks:

1. Attach the confidence monitor via USB-C/HDMI as an extended display. Pick distinct audience and confidence displays. Verify both directions of AltView’s assignment conflict warning and inspect the actual video outputs.
2. Pair both apps using This Mac with AltView on the presentation Mac, then rehearse Bonjour/LAN from a separate Mac. Pause/resume and restart AltView while Settings is closed; the discovered port must refresh. Connecting, focusing, opening tabs, searching and browsing must leave text unchanged.
3. Publish lyrics, then project Scripture. Verify reference, primary text and actual translation while advancing verses. Repeat with hidden lyric navigation and ViewTheWord’s primary-missing secondary fallback.
4. Hide/blank the audience while confidence stays readable. Independently hide/show and stop/restart Confidence. Clear/media, sender Stop, text-owner disconnect and Pause Receiving must clear confidence text. Restart AltView and confirm its output windows remain closed until explicitly opened. Reconnect must never replace another text owner without an explicit projection.
5. Unplug/replug the chosen confidence display, including rapid changes with three displays and fullscreen Spaces. It must wait for that identity and never relocate. Stop while unplugged must cancel restoration. Check screen/system idle sleep during a full rehearsal and after stopping or minimizing output.
6. Check long English, Malayalam and Hebrew text at the actual viewing distance, including the small-text notice. Check the clock after a timezone or clock-format change and leave the workflow running for a service-length rehearsal. Check keyboard and VoiceOver access to the new controls.

Physical USB-C/HDMI delivery, real display identity across replug, viewing-distance readability and a complete service rehearsal have not been validated by automated checks.

## Shared layouts and output sleep prevention — 5 October 2026

- `make test` passed all **150 app tests** and **104 offline release regression tests**. Seven added regressions cover shared fitting across drawing/previews/accessibility/status, fitting-input invalidation, bounded cache eviction, retained exit layouts, hidden-preview catch-up, matching Text/Design drafts, and balanced presentation activity tokens.
- The universal Release build passed. Both Intel and Apple Silicon executables declare macOS **12.0** minimum. Output sleep prevention covers the keying background as well as visible text, and releases on close, minimization, display disconnection and controller teardown.
- Real HDMI disconnect/reconnect and idle-sleep behavior remain manual checks in the workflow below.

## Saved templates and compact lyrics

Automated validation: all **143 app tests** and **104 offline release regression tests** pass. Coverage includes migration, per-profile persistence and PNG reload, private drafts, output-profile artwork validation and recovery, healthy publication while editing an unavailable profile, alignment preservation during typography edits, reverting imports across profiles, sender-driven artwork changes, empty-Hide exit preservation, glyph-width joining boundaries, multilingual lyrics, measured/rendered/accessibility agreement, and compact workspace geometry in light/dark appearances. Separate eight-line and nine-line stanzas at a 93 pt preferred size now compact after the initial height fit; the final font is larger than the original fitted font, every joined row remains within its width, and both banner and full-canvas layouts fit their available height. Text is never shrunk to force joining. Physical HDMI/ATEM and VoiceOver checks remain below.

- In Design, use the persistent Design buttons to give Lyrics and Scripture different PNGs, fonts, line spacing, boxes and animations. Scroll to the bottom and switch templates: the selector must remain visible. The footer must name pending templates, shared key-colour changes and design changes, including drafts in other templates. Switch profiles while dirty: edits must remain private, and Apply/Revert must cover all profiles. Switching Design must update the private preview and settings without changing Audience → Template or the active sender.
- Set Custom lower-third alignment to Right, then change its font and size. Alignment must stay Right; repeat in full-canvas mode with Left alignment. Confirm the key-colour control is labelled as shared across all templates.
- With an unavailable Lyrics PNG, keep Design on Custom and choose Lyrics under Audience → Template. Apply Template must stay disabled and explain how to repair Lyrics; the current output stays unchanged. Repeat while following a Lyrics source, then recover by replacing its PNG, selecting Built-in banner, or hiding Artwork. Leave the unavailable Lyrics profile open and publish healthy Custom text: publication and its staged designs must still succeed.
- Apply, move/delete the original PNG files and restart. Each profile must reload its artwork. Replacing Lyrics artwork must retain any PNG still referenced by Custom or Scripture. Revert imports in several profiles and check that only unused draft copies are removed.
- Keep From sending app and alternate scripture/lyrics snapshots, including hidden/restored messages. Verify matching artwork and typography on the HDMI feed, with sender text and ownership unchanged. Force each output template and check older/unmarked snapshots use that saved design.
- In Lyrics, turn on Compact pairs with Space and Apply. Send one stanza at a time. Try four short lines, an eight-line stanza with long lines and a large preferred font, odd line counts, blank stanza breaks, punctuation, Malayalam/Hebrew and manual indentation. Only fitting adjacent pairs should join at the actual displayed size; joining should retain or increase that size. Test Comma and Middle dot; Preserve lines must restore the original breaks.
- Resize Design/Output previews: pairing must stay identical. On a Mac HDMI display set to 1920 × 1080 with a refresh rate matching the ATEM Mini Pro standard, inspect text edges, safe margins, two-row readability, key colour and animation. Check the small-text warning with long content.
- At 980 × 650 in light/dark appearances, ensure the inspector scrolls while the Design selector, 16:9 preview, pending-change summary, Apply and Revert remain visible. Verify Choose PNG and both Fit buttons are grouped in Artwork, and Reset This Template’s Positions sits beside the Layout grid. Check Design, line-layout/joiner controls and line-spacing controls with keyboard navigation and VoiceOver.

## Audience template assignment and design editing — 8 October 2026

- On Audience, choose From sending app, Custom layout, Scripture, or Lyrics under Template. The Audience preview must update immediately using current sender text and show Not applied. The audience display and sender capabilities must stay unchanged until Apply Template. Incoming sender text must continue updating both the pending preview and live picture. Returning to the applied template restores the live preview. Pending design drafts must not be applied or discarded by that action.
- Open Audience Design while a sender is active: Design must select the design currently used by the audience. The status line must identify that design and sender. Choose another Design and check that settings and preview change immediately while sender text stays intact. Apply Changes saves design edits without changing audience assignment.
- Choose an explicit sample, visit another page, and return: the sample selection must stay intact. Revert All Changes affects saved-design drafts and the shared key colour; it must not undo template assignment on Audience.
- Choose a template with unavailable saved PNG artwork on Audience: Apply Template stays disabled. Repair its design by replacing the PNG, using the built-in banner, or hiding Artwork; return to Audience and apply the pending assignment.

## Template button grouping — 4 October 2026

- Design now uses persistent Custom / Scripture / Lyrics buttons above the scrolling inspector. Template assignment is on Audience, with its own Apply Template button. Opening Audience Design selects the current audience design and shows its usage status. Choose PNG and the artwork Fit buttons share the Artwork card; Reset This Template’s Positions sits with the Layout grid.
- Revert All Changes explicitly restores the whole design library. The footer lists every pending design plus shared key colour, including drafts retained while another template is open.
- All **81 focused app tests passed** in `build/TemplateGroupingFinal.xcresult` (WindowTests, TemplateDesignTests and LowerThirdTests). The existing draft test now checks hidden-profile summaries and reverting shared settings. Compact layout coverage checks that template navigation and the change summary remain visible after scrolling in both appearances. Footer spacing was tightened to retain the existing preview-size requirement at 980 × 650.
- An isolated native preview verified artwork grouping, reset placement, switching templates while scrolled, multi-template pending summaries and Revert All Changes in light/dark appearances. The preview used synthetic data and separate preferences.

# Standalone validation

## Automatic receiving ports — 3 October 2026

- Normal app startup now requests an available port from macOS and advertises it through Bonjour. There is no fixed-port preference. Users choose the receiving Mac by name; receiver identity and pairing remain independent of its port.
- Settings shows the assigned port as a read-only detail for manual connections and hides it while receiving is stopped. The manual sender form no longer assumes 49721 and directs users to the receiver's current Settings. Existing manual connections need their port updated after it changes; Bonjour connections resolve it automatically.
- All **123 app tests passed**, including live Bonjour tests, in `build/AutomaticPortFullTests.xcresult`. New checks verify two app controllers can receive concurrently using their default ports, Settings tracks the active port through Pause/Resume, the local sender uses that port, and a Bonjour sender reconnects and restores accepted content after the same receiver moves to a different port. All 39 window tests passed; the new Settings test waits for its popover to close before the next test starts.
- The universal Release build passed in `build/automatic-port-release.log`. Intel and Apple Silicon slices were verified for the app and Sparkle helpers, with minimum macOS 12.0 retained. This build has not yet been installed on the second Mac or notarized.

## Automatic port recovery — 3 October 2026

- A two-Mac incident recorded receiver startup failure `posix:48` (`EADDRINUSE`). The receiving port later refused connections, and Resume Receiving restored operation. The process or socket that originally occupied the port was not identified.
- AltView now retries that specific startup failure once a second for up to 30 seconds, retaining the port, receiver identity, pairing key and template policy. Output and Settings show recovery status; Pause Receiving, shutdown or a newer start cancels pending retries. Other startup errors still report failure immediately. An ongoing conflict ends with an actionable error and allows manual Resume Receiving.
- Pending local publications wait through recovery. Recovery itself does not take ownership or publish text. Retry events and exhaustion are recorded in native logs without content or credentials.
- All **121 app tests passed** in `build/PortRecoveryFullTests.xcresult`, including five new tests using an actual occupied TCP port. They cover automatic recovery and encrypted publication, deadline exhaustion and manual resume, replacement of a pending start, keeping a local publication pending, and cancelling recovery/publication through Settings.
- The universal Release build passed in `build/port-recovery-release.log`; the app and Sparkle helper binaries contain both Intel and Apple Silicon slices, and the app retains minimum macOS 12.0. All **104 offline release/feed regressions** passed. The self-healing build has not yet been tested on the second Mac or notarized.

## Template discovery — 3 October 2026

- AltView now advertises `templates` and `templatePolicy` in its welcome and feedback messages. Sender status exposes the catalogue and applied override. IDs are extensible strings; older receivers and unavailable choices receive unmarked text, while the desired choice is retained for reconnects.
- The full 114-test suite passed in `build/TemplateDiscovery.xcresult`. Two additional integration checks passed in `build/TemplateDiscoveryUI.xcresult`; after preventing routine feedback from rebuilding an open menu, all 36 window tests passed in `build/TemplateDiscoveryWindowsVerified.xcresult` (116 distinct tests across the full and final window runs).
- Encrypted checks cover future IDs, live catalogue removal, legacy reconnect fallback, restoring a desired ID when it returns, policy broadcasts to owners and observers, and unchanged snapshot ownership/revisions. UI checks cover the discovered Template menu, duplicate display names with distinct IDs, unavailable selections, private choice changes, saved receiver policy, and Apply/Revert without publication. Catalogue bounds and malformed policies are validated separately.
- Manual integration: connect eucaly/ViewTheWord with their discovery adapters, verify the returned choices, choose a template and publish. Apply each receiver override while connected and confirm its status appears in the sender; editing/reverting a draft must remain private. Reconnect to an older receiver and confirm ordinary text is still sent. These adapters and physical two-Mac/HDMI checks are outside this receiver implementation.

## Content templates — 3 October 2026

- Added optional `content.template` requests for Scripture and Lyrics, plus receiver choices in Design: From sending app, Custom layout, Scripture and Lyrics. Existing unmarked messages retain their custom layout. Forced presets preserve custom alignment and Title/Footer switches.
- The full 108-test suite passed in `build/ContentTemplates.xcresult`. After correcting Composer's visibility notes for forced templates and adding a compact-workspace check, all 34 window tests passed in `build/ContentTemplateWindows.xcresult` (109 distinct tests across the two runs).
- Coverage includes framed JSON defaults and validation, real encrypted template changes/blank/release, pixel comparisons in both rendering modes, returning to an unmarked message, empty-row reservation, accessibility, guides, exit animation, old-design decoding, Apply/Revert and preserving custom settings. Compact workspace assertions verify the 16:9 preview and template/apply controls fit at 980 × 650.
- Manual integration check: publish a Scripture snapshot with reference/verse/translation, then Lyrics, then an unmarked announcement. Confirm the first is left aligned with labels, the second is centred without labels, and the announcement returns to the saved custom layout. Repeat with lower thirds enabled and `emptyRegions: "reserve"`.
- Check each receiver override, Apply, restart and confirm it persists. Choose Custom layout to restore editable alignment and label switches. Selecting preview samples must never publish them. Sender app changes and physical two-Mac/HDMI validation remain separate from these receiver tests.

## Snapshot feedback — 2 October 2026

Protocol v2 requires both apps to be updated. Feedback reports receiver snapshot acceptance and software output readiness; it does not certify rendered frames or physical HDMI delivery.

Validation completed:
- AltView: all 102 tests passed in `build/OutputFeedbackV2Tests.xcresult`.
- ViewTheWord: all 121 Swift tests and 8 review regression checks passed; the native Debug Xcode build succeeded.
- A separate-process loopback TLS check compiled the actual AltView receiver and actual ViewTheWord sender sources, and passed acceptance, output readiness changes, blanking and release.
- Regression coverage includes bounded feedback bursts, stale/future/previous-lease acknowledgements, continued sending while acknowledgements are suppressed, timeout recovery, takeover/disconnect resets, local submission identity, and native preview/open/close plus simulated screen-sleep/wake and missing-display states.

Still manual: two-Mac network behavior, real HDMI attach/detach, real display sleep/wake and minimization, and downstream switcher/projector output. A closed or unavailable output can still accept a snapshot; verify that both facts appear in the sending app's status details.

Earlier AltView-only checks below remain useful for audience output; the shared three-app workflow is covered above.

## Connected pairing feedback and spacing — 2 October 2026

- Output and Settings now show **Connected to [sender]**, including Connect Only sessions. Output distinguishes **Sender connected** from **Receiving text**, and its shortcut becomes **Pair another sender…**. **No sender connected** does not imply that a saved pairing has been forgotten.
- Reproduced the growing gap around the pairing shortcut with real encrypted clients. Its horizontal spacer was expanding vertically; the row now follows the button’s height and the inspector keeps its controls at the top.
- All **41 selected tests** passed in `build/ConnectedPairing-Verified.xcresult`: 30 window tests, 10 text-session tests and the encrypted connection/ownership/reconnection regression. The new check covers connecting while Settings is open, two named senders, publishing, releasing without disconnecting, and disconnecting. It measures the control gaps at 980 × 650 and 1280 × 900 in light and dark appearances. AppKit-rendered test attachments were also inspected for connected-state text and spacing.

## Pairing in Settings — 2 October 2026

- Receiver name, pairing code, Copy/Reset Code and Pause/Resume Receiving now live in the gear popover alongside Custom Text. Output keeps receiving status and display controls, with **Pair a sender…** visible while no sender is connected.
- All **29 window tests** and **10 text-session tests** passed in `build/PairingSettings-Complete.xcresult`. Checks cover opening Settings from the shortcut and gear, readable pairing controls, pause/resume across page changes, receiver-name persistence, shortcut visibility after connecting/disconnecting, and compact light/dark layouts.
- Native inspection verified the compact popover, reopening it, and the Output layout. The temporary Debug instance reported an occupied receiver port while another local instance was listening; the automated receiver checks used ephemeral ports. The temporary instance was closed after inspection.

## Status and destination revision — 30 September 2026

- Text now scopes all state to its selected destination; this Mac’s receiver status appears only on Output. Fixed DRAFT badges are replaced by an actual unpublished-change indicator, and Design explicitly applies to this Mac.
- Send to stays visible outside the editor scroll area. The body editor grows with the window; the entire last-sent remote message is readable. Empty sent title/footer rows collapse. Hide offers Show Last Text without publishing newer edits.
- Automated validation: all **26 window tests** and **10 text-session tests** passed in `build/UXClarity-Verified.xcresult`. These include compact light/dark layouts, destination changes, private edits, Design scoping, remote messages longer than twelve lines, offline state, local connection errors, and safe restoration of the last publication.
- Full suite: **85 of 86 tests passed**. `NetworkTests.testInitialRetriesStopAtTheOverallDeadline` failed because the test receiver accepted one connection while the assertion expected multiple attempts. Networking implementation files are unchanged in this revision; the retry-test failure remains unresolved.
- Native visual inspection is pending. Automatic approval review blocked launching the isolated, locally built app used for sample-data inspection and requested explicit user approval. No claim of a completed visual pass is made.
- Review findings and resulting page responsibilities are in [UX review](ux-review.md). Physical two-Mac, Intel/Monterey, HDMI/ATEM and VoiceOver validation remain separate hardware checks.

## Optional Custom Text

- With fresh preferences, launch into Output with only Output and Design in navigation. Receiving and the pairing code remain available. A saved text draft from an older version must not reveal Text automatically.
- Open Design before enabling Custom Text: sample previews and the current external source are available, with no Compose draft choice or Edit Text button. Choosing samples must not publish them.
- Click the gear beside the page tabs: Settings opens with a Custom Text switch. Turn it on: Text appears while the current page, live source and receiving state stay unchanged. No connection or output window opens. Open Text to see the saved private draft.
- Turn Custom Text off again while it is presenting: its session stops, Text disappears, and Output opens. Re-enable it: the draft remains private until explicitly published. Turning it off must leave an external app’s live source untouched.
- Verify File contains only Close Window; View contains Show Output and Show Design, plus Show Text only while enabled. AltView → Settings… and Command-comma open the same gear popover. Close Output belongs in Window.
- Restart: Output still opens first, Text remains available, and the saved text stays private until explicitly published. Command-2/3 still open Design/Output.
- At 980 × 650 in light and dark appearances, reveal Text and switch between pages. Navigation, preview and publishing actions must remain visible without enlarging the window.

Gear settings revision, 30 September 2026: all 24 window tests passed in `build/WorkspaceSettingsWindows-Final.xcresult` after fixing compact preview sizing. The other 59 tests passed in `build/WorkspaceSettingsTests.xcresult`. Coverage includes the real Settings popover, remembered on/off state, stopping a live Custom Text session, private draft restoration, preserving another app’s ownership, and publication after re-enabling. Native inspection confirmed the gear popover, switch in both directions, return from Text to Output when disabled, File containing window-closing commands, and View containing Show Output/Show Design plus Show Text only when enabled. The universal release and signature were verified; the preceding package is preserved in `build/before-workspace-settings/`.

Earlier opt-in implementation, 30 September 2026: all 82 tests passed (`build/CustomTextOptInTests-Final.xcresult`), including opt-in persistence, saved-draft privacy, sample previews, external-source ownership, and compact layouts. An isolated native app copy confirmed the initial two-page navigation, visible receiver pairing, Enable Custom Text action, private Text page, and updated Show Custom Text menu. Its receiver port was occupied by another AltView instance; encrypted networking was verified by the automated tests on ephemeral ports. The universal release and local code signature passed verification. Updated `build/AltView.app`, ZIP, and SHA-256; the preceding package is preserved in `build/before-custom-text-opt-in/`.

## Receiver-first UX validation — 30 September 2026

- Full suite: 47 tests passed, including real encrypted sockets and Bonjour discovery (`build/ReceiverUXTests-Verified.xcresult`). The final five window/connection regressions passed again after layout and manual-entry fixes (`build/ReceiverUXWindows-Complete.xcresult`), without constraint warnings.
- Native app: verified Receiver is first, starts automatically, shows a readable receiver name and pairing instructions, excludes this Mac from Another Mac, provides optional manual addressing, dismisses pairing with Escape, and updates instructions when paused/resumed. The packaged app was reopened and left on Ready to receive with no active sender.
- Release: both x86_64 and arm64 slices have minimum macOS 12.0; code signature verification passed. Updated `build/AltView.app`, `build/AltView.zip`, and the SHA-256 file. Previous sources and package are preserved in `build/before-receiver-ux/`.
- Physical two-Mac, Intel Air/Monterey, HDMI/ATEM, developer-signed Keychain persistence, and VoiceOver checks remain outstanding. See [UX review](ux-review.md) for findings and the revised flow.

## One Mac — current Text / Design / Output workflow

- Launch: Output opens, Ready to receive appears, no saved text is published, and no output window opens. Pause receiving, change pages, and confirm it stays paused; resume without restarting.
- Text: inspect the saved draft rendered with its design. Edit Title/Body/Footer and verify the draft preview updates while Output keeps the last published snapshot.
- Design: stage font, size, key colour, lower-third enablement and placement. Check the same draft in Text. Apply Design to Output updates appearance only; Publish Text & Design publishes local text and design together.
- Untick Title/Footer beside their Layout rows. Their text remains saved; Text explains hidden regions. Re-enable and verify saved geometry and automatic Body expansion.
- While an external sender owns output, Design previews its text and identifies its source. Open Compose Draft must leave that source untouched. Apply Design keeps the external owner and content; publishing Compose deliberately takes over.
- Stop Presenting during connection/takeover. No late text or draft design may appear. Hide during publication must not leave Design locked. Subsequent text edits during connection stay private.
- Invalid geometry or a required missing PNG blocks local publishing with an explanation. Revert restores all design properties and applied artwork. Closing/quitting from any page protects the draft.
- Output: select Preview Window or the intended external display and Open Output. Only the live composition should appear. Drafts and samples never go to that window.
- With output open, check `pmset -g assertions` for AltView's idle system/display sleep prevention. Hide Text and confirm the keying background stays awake. Close or minimize output, disconnect the selected display, and quit; confirm AltView releases its assertions each time. Reopen, restore or reconnect output and confirm sleep prevention resumes. Receiving and private previews alone must not hold assertions.
- With long text or compact lyrics, switch between Output, Design and Text, minimize/restore the workspace, and cover/uncover it. Each preview and its readability/accessibility text must catch up to the latest content when visible, without changing the HDMI output or restarting its transition.
- Another Mac: discovery excludes this receiver, optional manual host/port works, wrong-code retry stays in the sheet, Return/Escape work, Connect Only preserves privacy, and Connect & Publish Text sends only text. Local Design changes remain local.
- Inspect minimum window size, multilingual text, keyboard navigation and VoiceOver on the intended machine.

## Lower-third UX validation — 30 September 2026

- Full suite: **54 tests passed**, including seven new regressions for private design drafts, receiver refreshes, external enable changes, validation, missing-PNG recovery, import apply/revert/cancellation, and action visibility at minimum size. Result: `build/LowerThirdUXTests-Final.xcresult`.
- Native inspection: verified the 900 × 800 content layout, explicit Apply/Revert state, named layout guides, invalid number feedback, reverting to the applied artwork rectangle, and the Keep Editing / Discard / Apply close sheet. No constraint warnings appeared in the test run.
- Packaged app: verified guide labels and Command-S while a numeric field is still active. The original design was restored after the checks; sample text was not published. The editor was left open without unapplied changes.
- Release: rebuilt `build/AltView.app` and `build/AltView.zip`; x86_64 and arm64 both declare macOS 12.0 minimum, and strict code-signature verification passed. Previous sources/package are in `build/before-lower-third-ux/`.

## Optional title and footer — 30 September 2026

- Full suite: **59 tests passed** (`build/OptionalTextTests.xcresult`). Added coverage verifies old-design decoding, visibility persistence, pixels for all four switch combinations, accessibility matching visible text, source-content preservation, guide/motion bounds, and Apply/Revert with disabled fields.
- In Edit Design → Layout, untick Title and Footer. Only body text and its expanded guide should remain alongside the artwork. Title/footer fields disable without losing their values. Body Y/Height show calculated values; X/Width remain editable. Apply, restart, and verify both choices persist; re-enable both rows to restore sender text and the saved base body box. Normal text mode should still show all supplied fields.
- Automatic body expansion: **33 rendering, lower-third and window tests passed** (`build/BodyExpansionTests.xcresult`). Default layout: title off → Y 74%, height 16%; footer off → Y 79%, height 15%; both off → Y 74%, height 20%; both on → original Y 79%, height 11%. Tests also cover custom positions, matching guide/render bounds, saved-design round trips, checkbox placement, Apply/Revert and recovery from invalid fields that become automatic.

## Lower-third artwork and motion

- Open Design. Change layout, alignment, enable state, and PNG artwork while text is live: output must keep the applied design until Apply Design to Output (Command-S). Revert All Changes restores the applied design. Check all three close-sheet choices.
- Use lower third is staged with all other appearance changes. Toggling it must leave Output unchanged until Apply Design or local Publish.
- Try Slide, Reveal and None, apply each, and test rapid Hide / Show reversal. Release, owner disconnect, Pause Receiving and Clear & Release must clear immediately. Text updates must keep the banner in place.
- Preview Animation, Show layout guides, and the three sample-text choices must affect only the editor. Receiver preview and Preview Output must move together. macOS Reduce Motion makes transitions immediate.
- Import a transparent PNG through Choose PNG. Inspect orientation and transparency over green, blue, black and a custom colour. Fit to Canvas suits a full-frame composition; Fit to Banner suits a cropped strip. Both affect artwork only. Check semitransparent edges on the ATEM.
- Edit the artwork/title/body/footer rectangles. Test an empty field, letters, non-finite values, and out-of-range numbers. Invalid input stays visible and blocks Apply; clamping is explained. None animation must not remain blocked by an invalid disabled duration. Revert clears invalid input.
- Select Long message and reduce the Body box: check the small-text warning. Validate layout, scrolling, keyboard navigation and guides on the Air’s 1440 × 900 display. Apply/Revert must remain visible when the window is shorter. Draft font and size are used in the preview.
- Import a replacement, then Revert or discard it before import finishes: the applied PNG must remain available. After applying an import, move the original PNG, quit and reopen: the copied artwork and placement must return. Switch to Built-in and back without losing the saved PNG. Invalid/oversized/animated PNGs must preserve the previous design.
- If saved artwork is missing, the selected custom output remains blank with a recovery message. Edit Design must allow importing a replacement or applying Built-in banner.
- In Design → Layout, untick Artwork for both the built-in banner and an imported PNG. The draft shows only text on the key colour, without changing text positions; the artwork guide, coordinates and fit controls turn off. Apply and restart to verify the choice persists, then tick Artwork to restore the image and placement. With a missing saved PNG, hiding Artwork must allow Apply and Publish Text & Design, and live text must remain visible. Re-enabling the missing PNG must block Apply until it is replaced or Built-in banner is chosen. Revert must restore the applied visibility choice.
- Disable Lower Third: the original text-only positions and height return. General image/PDF projection and video loops remain deferred.

## Two Macs and the Air

- Run the universal app on the 2017 Intel Air with macOS 12 Monterey. Confirm the app launches before attaching HDMI.
- Open **gear → Settings → Receive on this Mac** and confirm the pairing code visibly shows eight characters, with no `0`, `1`, `I`, or `O`. Type the displayed code on the main Mac (also try lowercase), and choose Connect & Publish Text. Copy Code must match the visible code. Repeat using a manual host/port. If the app says the code changes when AltView restarts, enter the new code after each receiver restart.
- Reset Code: existing connections and output must clear, the visible code must update, and an active receiver must resume automatically. A paused receiver must stay paused. Only the new code may connect. Both Macs must use this version; old 64-character codes are rejected.
- Wrong pairing code must not connect. An explicitly re-paired receiver is accepted; a changed receiver identity must not silently replace a previously pinned receiver.
- Turn the sender's network off while it owns output. The receiver should clear in about five seconds. Controls on both Macs remain responsive.
- Reconnect: current state restores only when output is unowned. Repeat while the other sender is live; it must remain in control.
- Test sleep/wake, app quit, receiver restart, reconnect and repeated take/release. Sleep suspends normal timer execution, so check the wake transition.

## HDMI and ATEM Mini

- Use Mini DisplayPort-to-HDMI from the 2017 Air. Extend the desktop; choose a 1920 × 1080 mode compatible with the ATEM setup. Keep receiver controls on the Air's built-in display.
- Select the HDMI display in AltView, Open Output, and inspect ATEM preview before putting the key on air.
- Check white-on-black with luma key and green/blue with the upstream chroma key. Tune clip/gain or chroma controls for crisp antialiased text. Confirm the clear/blank background keys out completely.
- For downstream lower thirds, place content in AltView. Confirm placement in ATEM preview; a DSK mask does not move the incoming picture.
- Disconnect/reconnect HDMI repeatedly. The output must not move onto the control display. Restoring the same display resumes output; Close Output cancels that restoration.
- Move the pointer away from the HDMI display; confirm no cursor, menus, notifications, or macOS overlays enter the program. The app cannot suppress every system overlay.
- Keep the Air awake and powered during a service. Test a realistic service-length run on the intended network and adapter.

## Automated verification

Latest local check — 30 September 2026: all 65 tests passed in `build/WorkspaceUXTests-Final.xcresult`. Four new integration/window tests cover actual draft rendering, staged appearance, combined local publishing, external-source preview and ownership, deterministic cancellation, invalid-design blocking, Revert and the embedded Design scroll area.

Native checks covered Text/Design/Output navigation, the actual saved draft, draft colour changes with unchanged live output, Footer visibility notes, scrolling Layout controls, Revert and Keep Editing from the close sheet. An isolated native fixture with fresh preferences and an ephemeral receiver also verified the external-source banner, read-only source preview, Open Compose Draft navigation, deliberate Compose takeover and the resulting live composition. Only synthetic fixture text was published; user text was not. The fixture was closed after verification. At initial inspection the packaged app had Title and Footer off and no unapplied design changes (different from the earlier handoff observation). The saved text and applied design were preserved. The updated universal package is `build/AltView.app`, with ZIP and SHA-256 alongside; prior sources/package are in `build/before-workspace-ux/`.

Run the Xcode test action as documented in the README. Tests use ephemeral ports and fresh in-memory pairing keys, and do not read the user's pairing secrets. They cover real encrypted loopback communication as well as deterministic framing, ownership, mailbox, renderer and window regressions.

Intel binary generation and a macOS 12 deployment target establish build compatibility, not an actual Monterey/ATEM hardware pass. Physical Air, HDMI, network-loss, colour-key and VoiceOver checks require the intended equipment.

## Local run record — 29 September 2026

- Xcode 27.0: 34 XCTest tests passed from the final standalone project directory, including 12 lower-third regressions added to the original 22 tests. Result bundle: `build/LowerThirdTests-Complete.xcresult`.
- Release build: verified both x86_64 and arm64 slices, each with minimum macOS 12.0; local ad-hoc code signature verified.
- Native UI: opened the receiver and test sender, discovered the receiver using Bonjour, connected both test clients, published A, transferred to B, blanked B, and observed the final snapshot after the 1,000-update burst. The receiver preview and opening the test-output window were inspected.
- Lower-third native UI: built-in banner, live text update, Blank / Show, separate Preview Output, immediate Clear & Release, Slide/Reveal selection, animated sample preview, text-box editing and reset, PNG import through the native picker, invalid-import recovery, and saved PNG reload after moving its original were checked. Custom artwork orientation, transparency and partial-alpha compositing were visually inspected. New output views expose existing text to accessibility immediately.
- The final local package is `build/AltView.app` with `build/AltView.zip` and its SHA-256 file. Prior sources and package are preserved under `build/before-lower-third-*`. No baseline conflicts were found. The release was launched locally; the editor was left on the built-in banner with default placement and 0.45-second Slide.
- Temporary pairing was verified on the local ad-hoc build; persistence with a developer-signed build remains a separate check.
- Pending: running on the physical Intel Air/Monterey, a second-Mac network session, HDMI/ATEM keying and disconnects, VoiceOver, and a long live-use run.

## Custom-text UX validation — 29 September 2026

The former Test Sender window was replaced by Write Text inside the main control window. Native checks covered automatic local connection, private edits, Hide/Show, Stop Presenting preserving the draft, switching pages while live, Bonjour discovery in the optional remote connection sheet, validation and cancellation. The previous lower-third build and source files are retained under `build/before-compose-*`. The universal package is rebuilt for both Intel and Apple Silicon with macOS 12 minimum deployment.

## Visible pairing code validation — 29 September 2026

- All 43 XCTest tests passed, including eight-character generation and validation, lowercase and formatted input, rejection of old codes, encrypted loopback pairing/reconnection, and rejection of a one-character typo. Result bundle: `build/PairingCodeTests-Full.xcresult`.
- The rebuilt release was opened on Receiver. The large eight-character code and adjacent Copy button are visible, and the output and appearance controls still fit in the window. Temporary pairing is reported for this ad-hoc build.
- `build/AltView.app` and `build/AltView.zip` were rebuilt with both x86_64 and arm64 slices; the local code signature was verified and `build/AltView.zip.sha256` updated. Both Macs must use this version and pair with the new code.
- Keychain persistence with developer signing and typing the code across two physical Macs remain hardware/manual checks.

## Pairing input layout — 29 September 2026

- Reproduced secure-entry dots overlapping the pairing-code placeholder in the connection sheet. The field now has a separate visible label and helper text, a fixed 30-point height, and a monospaced font, with no in-field placeholder.
- Verified typing, pasting eight characters, moving focus away, and clearing the field in an isolated native preview app; no text overlaps. The user's existing app session was preserved during this check.
- Debug and universal Release builds succeeded. The rebuilt `build/AltView.app` and `build/AltView.zip` include the fix. No protocol or pairing-validation changes were made.

- Final verification: all 42 XCTest tests passed in `build/ComposerTests-Final.xcresult`. Both x86_64 and arm64 Release slices target macOS 12.0; the local code signature and ZIP integrity verified. Draft restoration after restart and the final Receiver page layout were checked natively.

## Local Eucaly projection on Confidence — 8 October 2026

Implemented the negotiated `localProjectionV1` metadata extension and one shared ScreenCaptureKit / IOSurface / Core Animation path. The main Confidence region switches between primary lyrics and Eucaly’s reported projection window; AltView’s clock stays outside the media surface. Eucaly playback/audio, text ownership and Audience output remain independent. Operator setup is in [Confidence](confidence.md), and the complete wire/lifetime contract is in [protocol](protocol.md).

Validation completed on this Mac:

- AltView full suite: **202 tests passed**. After final preview-window visibility handling and two additional checks, the focused Confidence suites passed **22 tests**. Coverage includes negotiation/text regressions, ownership/stale updates, Clear/release/disconnect, nonlocal fallback, lazy permission actions, pause/resume/shutdown, aspect-preserving sizes, clock/media layout, direct IOSurface layer contents, capture-buffer retention and release, and newest-frame coalescing/cancellation.
- Eucaly full suite: **266 tests passed**; final focused Confidence suite: **6 tests passed**, including two added tests covering every media family, inactive sessions, hidden Current navigation, source-window recreation, Connect Only, lyrics restoration, Clear and legacy optional-field filtering. Existing ownership, reconnect, pending takeover, parser/primary-only and projection flow tests passed in the full suite.
- Offline release/feed checks: **7 feed + 97 workflow tests passed in each repository**. The sandboxed AltView app-test invocation initially failed because Xcode could not write dependency caches; rerunning with cache access passed. No signed distribution or installed app was replaced.
- Actual-source three-process TLS/Bonjour integration passed against the unchanged ViewTheWord sender and updated Eucaly sender / AltView receiver. Checks include connect-only privacy, explicit text takeover, hidden navigation, dynamic loopback-port reconnect, verified local process identity on media reports, Hide retaining media mode, exact source-window replacement, Clear, text-over-media takeover and owner disconnect. The fixture reports synthetic window IDs and does **not** capture an actual window.
- Compact Confidence UI fixtures were rendered and visually inspected in light/dark appearances. The enable/retry controls and status wrap within the scrolling inspector. The executable weak-links ScreenCaptureKit; availability checks preserve AltView’s macOS 12.0 minimum. Running the fallback on macOS 12.0–12.2 remains a rehearsal check.

Measured CPU-only mailbox results: 10,000 offers while the drain was held produced exactly **one scheduled drain, 9,999 replacements and the newest frame**. Two debug measurement runs of 10,000 immediate offer/commit cycles averaged **5.4 ms and 9.9 ms**, with individual samples from **5.2 to 19.0 ms** (warm-up/host variation). They used one synthetic 16×16 IOSurface buffer and an empty consumer. These measure mailbox overhead only, not capture, Core Animation, source responsiveness, memory under video, GPU completion, end-to-end latency or real display fps. Tests verified that the layer retains its CVPixelBuffer until cleared and that replaced pending buffers are released before a UI drain.

Expected operating target, **not measured delivery**: aspect-preserving dimensions within 1920×1080, 1/60-second requested capture interval, six capture-queue buffers and one pending latest-frame slot. At full BGRA 1080p, six pixel buffers alone are about 47.5 MiB; compositor/framework overhead and retained display references are additional and have not been measured. `confidenceCapture` unified logs expose configured width/height, elapsed seconds, displayed software commits and pending replacements; commit count is not display scanout. Static content can produce fewer complete samples, so use moving content when measuring.

Required paired-app / physical rehearsal:

1. Use the built signed AltView and Eucaly apps on one Mac, connect through **This Mac**, and start with Local Media off. Launch, restore pairing, browse Preview and change backgrounds while another presenter owns output: no permission prompt, publication or takeover. Turn on **Show Eucaly media** explicitly; test deny, grant, restart if macOS requires it, Retry and revoke. **Permission needed** offers **Open Screen Recording Settings…**; returning to AltView checks access automatically without requesting it or overriding macOS Stop. Relaunch with Local Media enabled and existing permission: fresh accepted local media resumes capture when Confidence is visible, while output windows remain closed initially. Relaunch without permission: enablement is remembered, setup instructions appear, and no permission prompt is raised automatically. Turn **Show Eucaly media** off and relaunch: it remains off. Check that On/Off is separate from readiness, Retry appears only in recovery states, and empty-preview guidance appears only in the operator workspace. Confirm the sandboxed app can validate the source PID/start time and acquire the exact reported projection window. Test the unsupported-OS and remote-Mac fallback.
2. With distinct Audience/Confidence monitor assignments, explicitly present each media family, including a moving video/webpage and a captured-window slide. Confirm no lyrics remain alongside it, aspect/orientation/colour are correct, AltView’s clock remains visible, and Eucaly alone supplies audio. Hide/Blank must show precisely Eucaly’s projection background/blank/overlays. Hidden Current navigation must retain mode and must retain lyrics when lyrics were last explicit. Explicit Show switches to the new Current mode.
3. Test Clear, Stop, sender Disconnect, receiver Clear & Release / Pause Receiving and text takeover. Repeat during permission approval, source enumeration, stream startup and rapid lyrics/media switching. No stale surface or private Preview picture may reappear. Stop/recreate Eucaly’s projection window and reconnect both apps; only fresh accepted session/window identity may restore capture.
4. Hide/show Confidence, close/reopen its output and its controls window, minimize/restore controls, leave/return to the Confidence page, and unplug/replug the assigned monitor. Capture must pause with no visible consumer and resume the accepted source; closing physical output while the visible preview remains keeps their shared stream. Close Display must cancel physical-display restoration. No second stream should start for a second Confidence canvas.
5. Rehearse moving 1080p content on the actual 60 Hz stage display for a sustained service-length run. Inspect Instruments / Activity Monitor and `confidenceCapture` logs for capture/display cadence, CPU/GPU load, bounded memory, latency and replaced frames. Deliberately stall or minimize Confidence; Eucaly’s projection/navigation/audio must remain responsive and stale queued frames must not replay. Confirm no duplicate audio and no WindowServer buffer churn or growing memory. Record hardware/macOS/display mode with results before calling delivered 60 fps verified.

### Reliability and CPU review — 8 October 2026

The review preserves native ScreenCaptureKit hardware capture/scaling and direct IOSurface-to-Core Animation display. There is no new CPU image conversion or encoder. Improvements:

- Buffer startup events until capture succeeds, so a still image arriving before `startCapture` returns is not lost. Retain the live picture across control revisions for the exact same source; reject retired sources and out-of-order frames. A terminal stopped event cannot be replaced by a late frame.
- Handle started/complete, idle, blank, suspended and stopped samples explicitly. A quiet valid still image stays visible. Callback silence alone is not a reliable stall signal: status offers Retry while source checks and delegate errors drive recovery. Missing initial pictures still time out.
- Respect macOS Stop, denial and entitlement failure until explicit Retry. Transient failures use 2/4/8/15-second backoff. Preflight permission before enumeration and during monitoring so revocation cannot become an automatic permission request. Clean up partially started streams and serialize start/stop/configuration operations.
- Update source dimensions/backing scale in place; use sRGB SDR BGRA and exclude shadows where supported. Native visibility and sleep notifications pause capture and release inactive surfaces. Overlapping sleep/wake notifications do not discard a valid still frame twice.
- Batch preview/output surfaces into one Core Animation transaction. Avoid a full-size bitmap behind media, duplicate frame-metadata parsing, control-only canvas rebuilds, and once-per-second redraws of a minute-only clock. Eucaly playback progress now publishes only changed position/duration values rather than republishing a constant duration four times per second.

Validation: AltView's full suite passed **215 tests** during the review; final focused capture/Confidence checks passed **35 tests** after the last lifecycle refinements. Eucaly's required `make test` passed **270 app tests plus 7 feed / 97 workflow checks**, including playback notification, seek/reset and invalid-time regressions. An optimized universal AltView Release build passed for arm64 and x86_64; both slices weak-link ScreenCaptureKit. Native Confidence/lyric fixture renders were inspected after the layer/clock changes.

Live baseline on **Apple M1, macOS 27.0.1**, using the user's existing installed apps (AltView 1.4 build 1; Eucaly 1.36 build 260208.0706), **before these review edits were installed**:

- A five-second active-video sample recorded AltView at **2.1–3.6% CPU**, with about **122 MiB physical footprint**. Its capture log configured 1920×1080, requested 60 fps, and audio off. Sampled work included native ScreenCaptureKit/Core Media sample handling and Core Animation IOSurface commits; most sampled thread time was waiting.
- During the user's repeated playback, five one-second CPU intervals recorded AltView at **0–3.0%** and Eucaly at **0–10.8%**, including idle intervals. Footprints were roughly **123 MiB / 172 MiB**. Eucaly's stacks included native VideoToolbox remote decoder calls, decoded-frame callbacks and SwiftUI layout. These stacks establish use of Apple's decoder path, not hardware-decoder selection for every codec.
- The reported AltView **23%** was not reproduced in these short windows. These are baseline observations, not a before/after improvement claim, a sustained playback average, or measurements of GPU utilization, delivered fps or physical HDMI latency. Rebuild both apps before comparing the review changes using the same video, visible canvases and display modes.

Remaining rehearsal includes sustained moving content and long static images, source minimization/resume, permission revocation/macOS Stop, Retina/non-Retina moves, physical display reconnects and a service-length run. See Apple's [hardware capture and configuration guidance](https://developer.apple.com/videos/play/wwdc2022/10155/) and [sample-status explanation](https://developer.apple.com/videos/play/wwdc2022/10156/).

### Local media startup and UX review — 9 October 2026

Local Media now saves the operator's On/Off choice across launches. Restore checks existing Screen Recording access without requesting permission or calling Retry; capture still needs a fresh accepted local source and a visible Confidence consumer. Disabling persists, while shutdown clears capture without overwriting the saved choice. The card explains setup before enabling, uses a native **Show Eucaly media** switch, and separates readiness from enablement. Permission failures offer **Open Screen Recording Settings…**; stopped/retrying/held-picture states offer **Retry Capture**. Returning from Settings rechecks access automatically. An explicit Settings action can register a first permission request, but returning or relaunching cannot.

Empty-preview guidance belongs to the workspace stage, never to the output canvas. It explains waiting media, permission, a nonlocal source and intentional hiding, and disappears for presented text or an available picture. Self-review corrected initial zero-size overlay layout conflicts and stale hidden-output guidance after reopening a display. Permission, source identity, capture recovery, display visibility and per-frame update paths were reviewed; status controls update on state/picture-presence changes, not on every video frame.

Validation: **224 app tests passed** in `build/LocalMediaUX-Final.xcresult`, with no preview constraint conflicts reported. The focused review also passed **44 tests**, including preference restoration, disabling across launches, missing access, return-from-Settings checks, nonlocal enablement without a permission request, contextual actions, output pixels free of operator hints, presented-text visibility, output reopening and preview shapes at different window sizes. Native Off, Permission needed, Waiting for media and nonlocal-source fixtures were inspected in light/dark appearances; six setup previews are saved in `build/LocalMediaUXPreview`. The universal local Release build passed, its code signature verified, and both arm64/x86_64 slices retain a macOS 12.0 minimum. The app is at `build/LocalMediaUXRelease/Build/Products/Release/AltView.app`.

The permission-opening action uses a test replacement during automated checks; actual permission granting/revocation, Settings pane navigation, live paired-app capture and physical-display rehearsal remain the checks listed above. This local build was not installed over the running app or distributed as a signed/notarized release.

### Local media startup crash correction — 9 October 2026

The reported crash occurred in `SCStreamConfiguration.copyWithZone:` → `CGColorCreateCopy` during native stream creation. `backgroundColor` is an unsafe borrowed reference, and assigning a temporary `NSColor.black.cgColor` left it pointing at released storage. An isolated optimized reproducer failed in the same native colour-copy path without starting screen capture. The production configuration now uses a retained static black `CGColor`, shared safely across stream creation and subsequent resize copies. The configuration factory is exercised directly by a regression test that drains autorelease pools and repeatedly copies initial and resized configurations.

Validation: **225 XCTest cases passed with zero failures** in the full app run. Xcode stalled after the test host had exited while finalizing its result bundle; the idle exporter was terminated, and the complete case-pass log is preserved at `build/LocalMediaCrashVerification/tests.log`. The incomplete `build/LocalMediaCrash-Full.xcresult` is not a usable result bundle. A subsequent focused run completed successfully with **10 local-projection tests**, including the native colour-lifetime regression; its result bundle is `build/DerivedData/Logs/Test/Test-AltView-2026.10.09_07-59-02-+1100.xcresult`. An independent Release-optimized check of the production factory passed **10,000 startup/resize copy cycles**. The universal Release build succeeded, both slices target macOS 12.0, and the Apple Development signature passed strict verification using macOS trust services.

The corrected app was installed at `/Users/suku/Applications/AltView.app` after checking that both displays were closed and no sender was active. The previous app is preserved at `build/LocalMediaCrashBackup/AltView.app`. Reopening the installed app retained **Show Eucaly media: On**, the selected Confidence monitor and the closed output windows. Live Eucaly playback and physical-display capture remain to be exercised; no Eucaly presentation or projection was changed during this correction.

### Connection and capture stability corrections — 10 October 2026

Temporary listener waits now retain the listener and recover when Network.framework reports ready. Failure after a successful start recreates the listener on its existing port with the same identity, pairing and policy; retry delays cap at eight seconds, and Stop/new starts cancel recovery. Initial occupied-port recovery keeps its existing deadline.

Sender status retains the last granted lease even when a takeover follows before UI delivery. Custom Text can finish that publication, release its pending Design lock and accept another explicit Publish without automatically taking output. Locally generated sender names are trimmed and bounded to 128 UTF-8 bytes at whole-character boundaries, including Unicode computer names.

Capture callbacks must match both the output and source epoch. Retired errors cannot stop the replacement source. Setup/start/configuration waits have eight-second deadlines, and cleanup has a three-second deadline; Retry and shutdown interrupt pending setup. Late-created or late-started streams are stopped, in-flight stops are shared, and unfinished framework work retains a bounded slot until cleanup completes.

Validation: the final full app run passed **241 tests with zero failures**, including **16 new regressions**, in `build/DerivedData/Logs/Test/Test-AltView-2026.10.10_06-46-15-+1100.xcresult`. The offline suites passed **7 feed and 97 release-workflow checks**. Real-source encrypted integration with the neighboring Eucaly and ViewTheWord checkouts passed **21 checks**. Regression coverage includes actual TLS coalescing, listener waiting/recreation/cancellation, Unicode pairing, the local Design lock, stalled capture setup/start/stop/configuration, late completion/error rejection and repeated Retry resource bounds.

Native framework stalls are simulated in lifecycle tests; actual network-interface loss/recovery and live ScreenCaptureKit/physical-display behavior still need rehearsal. These source corrections have not replaced the installed app.

### Dual Scripture translations on Confidence — 10 October 2026

ViewTheWord now sends both committed translation texts and their actual names in every Confidence snapshot, without an older-receiver downgrade or a separate secondary-translation capability. Audience retains the primary reference, text and name. Confidence uses two equal columns beneath its shared reference and local clock, with a shared fitted text size. Secondary None, a missing secondary verse or an empty secondary clears the second column and restores the full-width layout. The existing missing-primary fallback remains a single translation.

Final validation after removing compatibility: the full AltView app suite passed **245 tests with zero failures** in `build/DerivedData/Logs/Test/Test-AltView-2026.10.10_07-38-07-+1100.xcresult`. ViewTheWord passed **179 tests** and its **8 review-regression checks**. Real-source encrypted integration passed **25 checks**, including dual-text delivery, primary-only Audience, Blank, secondary removal, reconnect, Stop and media/text takeovers. Encrypted tests verify that Confidence snapshots are never filtered by advertised Confidence capabilities and that oversized escaped frames are rejected before taking ownership. Custom-text tests verify that hidden snapshots replace obsolete text. The English/Malayalam fixture was visually checked for labels, alignment and clipping; layout code was unchanged when removing compatibility.

The installed apps were not replaced. Rebuild both apps, then rehearse bilingual verses, Secondary None and the missing-primary fallback on the assigned physical displays; automated rendering and TLS acceptance do not verify physical HDMI output.
