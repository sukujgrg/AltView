## Shared layouts and output sleep prevention — 5 October 2026

- `make test` passed all **150 app tests** and **104 offline release regression tests**. Seven added regressions cover shared fitting across drawing/previews/accessibility/status, fitting-input invalidation, bounded cache eviction, retained exit layouts, hidden-preview catch-up, matching Text/Design drafts, and balanced presentation activity tokens.
- The universal Release build passed. Both Intel and Apple Silicon executables declare macOS **12.0** minimum. Output sleep prevention covers the keying background as well as visible text, and releases on close, minimization, display disconnection and controller teardown.
- Real HDMI disconnect/reconnect and idle-sleep behavior remain manual checks in the workflow below.

## Saved templates and compact lyrics

Automated validation: all **143 app tests** and **104 offline release regression tests** pass. Coverage includes migration, per-profile persistence and PNG reload, private drafts, output-profile artwork validation and recovery, healthy publication while editing an unavailable profile, alignment preservation during typography edits, reverting imports across profiles, sender-driven artwork changes, empty-Hide exit preservation, glyph-width joining boundaries, multilingual lyrics, measured/rendered/accessibility agreement, and compact workspace geometry in light/dark appearances. Separate eight-line and nine-line stanzas at a 93 pt preferred size now compact after the initial height fit; the final font is larger than the original fitted font, every joined row remains within its width, and both banner and full-canvas layouts fit their available height. Text is never shrunk to force joining. Physical HDMI/ATEM and VoiceOver checks remain below.

- In Design, use the persistent Editing template buttons to give Lyrics and Scripture different PNGs, fonts, line spacing, boxes and animations. Scroll to the bottom and switch templates: the selector must remain visible. The footer must name pending templates, shared key-colour changes and output-selection changes, including drafts in other templates. Switch profiles while dirty: edits must remain private, and Apply/Revert must cover all profiles. Switching Editing template must not alter Output template or the active sender.
- Set Custom lower-third alignment to Right, then change its font and size. Alignment must stay Right; repeat in full-canvas mode with Left alignment. Confirm the key-colour control is labelled as shared across all templates.
- With an unavailable Lyrics PNG, keep Editing template on Custom and force Lyrics under Output template. Apply must stay disabled and explain how to repair Lyrics; the current output stays unchanged. Repeat while following a Lyrics source, then recover by replacing its PNG, selecting Built-in banner, or hiding Artwork. Leave the unavailable Lyrics profile open and publish healthy Custom text: publication and its staged designs must still succeed.
- Apply, move/delete the original PNG files and restart. Each profile must reload its artwork. Replacing Lyrics artwork must retain any PNG still referenced by Custom or Scripture. Revert imports in several profiles and check that only unused draft copies are removed.
- Keep From sending app and alternate scripture/lyrics snapshots, including hidden/restored messages. Verify matching artwork and typography on the HDMI feed, with sender text and ownership unchanged. Force each output template and check older/unmarked snapshots use that saved design.
- In Lyrics, turn on Compact pairs with Space and Apply. Send one stanza at a time. Try four short lines, an eight-line stanza with long lines and a large preferred font, odd line counts, blank stanza breaks, punctuation, Malayalam/Hebrew and manual indentation. Only fitting adjacent pairs should join at the actual displayed size; joining should retain or increase that size. Test Comma and Middle dot; Preserve lines must restore the original breaks.
- Resize Design/Output previews: pairing must stay identical. On a Mac HDMI display set to 1920 × 1080 with a refresh rate matching the ATEM Mini Pro standard, inspect text edges, safe margins, two-row readability, key colour and animation. Check the small-text warning with long content.
- At 980 × 650 in light/dark appearances, ensure the inspector scrolls while the Editing template selector, 16:9 preview, pending-change summary, Apply and Revert remain visible. Verify Choose PNG and both Fit buttons are grouped in Artwork, and Reset This Template’s Positions sits beside the Layout grid. Check Editing template, line-layout/joiner controls and line-spacing controls with keyboard navigation and VoiceOver.

## Template button grouping — 4 October 2026

- Editing template now uses persistent Custom / Scripture / Lyrics buttons above the scrolling inspector. Output template has its own group. Choose PNG and the artwork Fit buttons share the Artwork card; Reset This Template’s Positions sits with the Layout grid.
- Revert All Changes explicitly restores the whole design library. The footer lists every pending template plus shared key colour and output selection, including drafts retained while another template is open.
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

This checklist intentionally uses only AltView. ViewTheWord and eucaly integrations are a separate step.

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
