# AltView

AltView turns a spare Mac into a clean text and lower-third output for an HDMI switcher or external display. It receives generic text snapshots, so the same receiver can later serve scripture, lyrics, captions, and other presentation apps.

This is a standalone **macOS Xcode application project** with Sparkle 2.9.6 for self-updates. ViewTheWord and eucaly are not integrated yet. Compose is a built-in custom-text presenter. It can show messages on this Mac or send them to another AltView receiver using the same encrypted connection as future integrations.

The intended setup has **eucaly or ViewTheWord running on the presentation Mac**, with **AltView running on a different Mac connected to the output display**. Each presentation app will discover and pair directly with AltView, using the code shown on the receiving Mac. Pairing starts inside the sending app. These integrations are planned; they will not require opening Compose or running a separate AltView app on the sending Mac. Compose is an optional built-in sender for custom messages and standalone testing.

## Run it

Open **AltView.xcodeproj**, choose the **AltView** scheme and **My Mac**, then press **Command-R**. The application targets macOS 12 Monterey and later. Release builds include Intel (`x86_64`) and Apple Silicon (`arm64`). Build on a current development Mac; the Air only needs the resulting application.

Debug builds use local ad-hoc signing, with no development team required. `make build` archives and exports a universal app into `~/Applications`; `make release` signs, notarizes and publishes using your local Keychain. Release signing uses the same Apple team as eucaly and ViewTheWord. See [releasing](docs/releasing.md) for Apple app-specific password setup, matching Make targets and recovery.

AltView checks for updates with Sparkle. Use **AltView → Check for Updates…** or click **Update Available** in the workspace. Automatic checks stay quiet; installation requires a click while output and presentation are stopped. See [self-updates](docs/self-updates.md).

Click the **gear beside the page tabs** to find **Receive on this Mac** in Settings. It shows an **8-character pairing code** in two groups of four, such as `ABCD-2345`, that you can read and type on the sending Mac, or copy with **Copy Code**. Codes use uppercase letters and digits, excluding confusing `0`, `1`, `I`, and `O`; lowercase input works and the hyphen is optional when typing. Pairing secrets are saved in the data-protection Keychain when the app's signing permits it. An ad-hoc build may instead explain that the code changes when AltView restarts and keep a fresh random secret in memory. In that mode, enter the receiver's new code after restarting it. No secrets are stored in preferences or Bonjour records. Both Macs need this version; previous 64-character codes are no longer accepted.

## Receive from a sending app

AltView opens on **Output** and starts receiving automatically. Leave it open on the Mac connected to your display; the **sending Mac initiates pairing**. The default navigation contains **Output** and **Design**. Output shows receiving readiness, the current sender, the live picture and display controls. Receiver name, pairing code, Copy Code, Reset Code and Pause/Resume Receiving live in the **gear → Settings** popover. Output and Settings identify connected senders by name, including senders that have connected without publishing text. **Pair a sender…** opens the same popover and becomes **Pair another sender…** while connected. **No sender connected** describes the current connection; saved pairings on the sending Mac can still reconnect without entering the code. Design contains font, key colour, full-screen layout and lower-third settings, with sample text or the current source for its preview. The source indicator identifies the app controlling this Mac’s output.

Custom Text is optional and hidden initially, including its draft preview choice and editing button in Design. Click the **gear beside the page tabs**, then turn on **Custom Text** to reveal **Text**, the built-in composer and sender. The same Settings popover is available from **AltView → Settings…** or **Command-comma**. AltView remembers the switch in either position. Turning it off stops Custom Text connections and returns to Output if Text was open, while keeping the saved draft and any other app’s live source. Enabling it only reveals the tools: it does not connect, publish, or take control from another app. Existing saved text drafts stay private and do not automatically enable the feature.

**Pause Receiving** disconnects senders and clears output; **Resume Receiving** makes this Mac available again. Restarting starts receiving on Output, with the saved text draft private and the output window closed. The **View** menu contains page-navigation commands: **Command-2/3** open Design/Output; **Command-1** opens Text after Custom Text is enabled. Changing pages keeps drafts and connections intact. Closing or quitting with design changes offers Keep Editing, Discard Design Changes or Apply Design to Output.

The receiver’s instructions apply to any compatible sending app. In the planned eucaly and ViewTheWord integrations, their own AltView connection settings will select this receiver, accept its pairing code, and report connection status. AltView controls appearance and the output display; the sending app controls which content it sends. See the [integration contract](docs/protocol.md#planned-eucaly-and-viewtheword-integration) for the agreed behavior.

Each page reports its own state. **Output** shows this Mac’s source and preview (**TEXT VISIBLE**, **HIDDEN**, or **NO TEXT**), with the output-window state beside the display controls. **Text** names the selected destination and reports **PUBLISHED**, **HIDDEN**, **NOT PRESENTING**, or **OFFLINE**; publication does not claim that the receiving Mac has opened its display. **Unpublished changes** appears only while text or applicable local Design edits differ from the last publication. Design reports **APPLIED** or **UNAPPLIED CHANGES** and explicitly applies to this Mac. Publishing and applying stay at the bottom.

The window supports a 980 × 650 content area. Design keeps its 16:9 preview and Apply/Revert actions visible while the inspector scrolls through Canvas, Typography, Artwork, Animation, and Layout. Text keeps its destination and publishing actions visible. Its body editor expands with the window, and the editor fields scroll when the window is compact. Remote sent-text history can scroll without truncating the message. Output keeps receiving status and display controls visible; pairing details are available in Settings.

## Compose custom text

1. Click the **gear**, turn on **Custom Text**, then open **Text** and leave **Show on → This Mac** selected. If already enabled, open Text directly or press **Command-1**.
2. Enter **Title**, **Body** and **Footer**. Empty Title/Footer rows automatically give their space to Body. Tick **Keep space for empty Title and Footer** to reserve those spaces; this choice travels with your text to another Mac too. Rows explicitly hidden in the receiver’s Design still give their space to Body. The **Message preview** uses your actual text and current Design draft. Text edits and the spacing choice are saved privately on this Mac.
3. Choose **Edit Design** to adjust font, key colour, artwork or layout in the same workspace. All appearance edits stay private. Title/Footer notes beside the text fields explain which regions are visible or hidden by the draft design; hidden text is retained.
4. Click **Publish Text & Design** to publish the composition. AltView connects locally, resuming receiving if paused, and explicitly replaces any other source. The button has the same meaning for subsequent updates. Design commits only when this receiver accepts the requested text from Compose; a failed/cancelled connection cannot apply a draft design to another source. Design controls wait for that acknowledgement, while later text edits remain private.
5. **Hide Text** hides the submitted text without publishing later edits. **Show Last Text** restores that same publication while keeping newer edits private; Publish sends the current draft. **Stop Presenting** cancels a pending publication or clears your owned output and releases it. Both retain the text draft.
6. **Open Output Controls** opens Output. Choose **Preview Window · 16:9** or an external display, then **Open Output**.

External text is edited in its sending app. Opening the local Compose draft never copies, edits or takes over external content; the current source remains identified beside the editor. **Publish Text & Design** is the deliberate takeover action.

For **Another Mac**, text and the selected template request are sent. **Connect & Publish Text** pairs and publishes; **Connect Only** keeps the draft private. After connecting, use **Publish Text** for updates. The preview says **Last text sent** because design and the live picture belong to the receiving Mac; local Design changes are never sent remotely. Switching destinations ends your previous presentation and preserves the draft. Restarting restores it privately with This Mac selected.

The receiver's **Clear & Release** clears whichever source is active. Quitting AltView stops all connections and output. There is no separate sender window, Sender A/B selector, or test controls in the normal interface; automated tests cover multiple sources and bursts.

## Test with the 2017 MacBook Air

1. Put AltView on both Macs. Open it on the Air. **Output** opens first and shows **Ready to receive** automatically.
2. Connect both Macs to the same local network. Allow local-network access if macOS requests it. Ethernet is preferable for live use when available.
3. On the sending Mac, click the **gear**, turn on **Custom Text**, then open **Text**, enter your message, and select **Another Mac**. If one other receiver is found, it is selected automatically; otherwise choose the Air. Type the 8-character **Pairing code** shown in **gear → Settings** on the Air and choose **Connect & Publish Text**. **Connect Only** connects while keeping your draft private. With an empty draft the button is simply **Connect**. Press Return for the primary action or Escape to cancel. The dialog stays open until connection succeeds and lets you correct a wrong code in place. Previously paired receivers can use a blank code field; successful pairing is also remembered for this app session when Keychain is unavailable.
4. If Bonjour discovery is unavailable, select **Connect using an address instead** and enter the Air’s local address and the current port shown in its **AltView → Settings**. The port is selected automatically and can change when receiving restarts, so update manual connections if needed. Switching back to discovery uses the chosen receiver, without a hidden address overriding it. Guest Wi-Fi isolation, VPNs, or a firewall can prevent discovery or connections.
5. Connect the Air's Thunderbolt 2 / Mini DisplayPort output to an ATEM HDMI input through a **Mini DisplayPort-to-HDMI adapter**. Set it as an extended display with a supported 1920 × 1080 mode, choose that display in AltView, and open the output. Keep the Air's controls on its built-in screen.

The 2017 Air has native Mini DisplayPort video output through its Thunderbolt 2 port and supports HDMI through an adapter. Its latest officially supported system is Monterey. See [Apple's hardware specifications](https://support.apple.com/en-za/111924) and [model/OS compatibility list](https://support.apple.com/en-gb/102869).

## Using the HDMI feed with ATEM

AltView produces a single opaque HDMI picture: white text and optional lower-third artwork on a selectable background. It sends neither video over the network nor a separate alpha/key signal.

- **Black · Luma key:** use the text's luminance as the key, including an appropriate downstream luma-key setup.
- **Green / Blue · Chroma key:** use the ATEM's upstream chroma keyer and sample the chosen background. Downstream keying does not provide chroma keying.
- **Custom colour:** available for an existing keying setup.

AltView is a generic canvas, with optional position and content-height controls. For a downstream lower third, position the text near the bottom in AltView; a DSK mask crops rather than moving the source. Use the upstream flying-key controls where supported if you want to position the source in ATEM. Follow the settings for your exact model in the [ATEM Mini manual](https://documents.blackmagicdesign.com/UserManuals/ATEM_Mini_Manual.pdf).

The output contains only the composition and the keying background. App status, pairing, and controls stay on the receiver window. **Command-Shift-O** closes the output. A disconnected output display does not cause the app to cover another display; it waits for the chosen display to return. Prefer 16:9: other display shapes retain the same keying colour around the 16:9 content area.

An open output window prevents idle system and display sleep, including while text is hidden and the keying background remains on screen. Closing or minimizing output, disconnecting its selected display, or quitting releases sleep prevention. Restoring output resumes it. Receiving alone and private Text/Design previews allow normal idle sleep.

## Reusable lower thirds

### Text templates for sending apps

In **Design → Output template**, **From sending app** automatically uses the saved template requested with each message. The initial designs are:

- **Scripture:** left-aligned text, with the Bible reference in Title, the verse in Body and the translation name in Footer.
- **Lyrics:** centred Body, with Title and Footer hidden and their space given to Body, even if the sender reserves empty rows.

The sender supplies the actual reference, verse and translation; AltView does not infer them from text or the app's name. **Editing template** stays visible above the scrolling settings. Select **Custom**, **Scripture**, or **Lyrics** to edit independently of **Output template**. Each saves its own PNG, font, size, line spacing, alignment, visible rows, full-canvas settings, lower-third boxes and animation. Key colour and output-display selection are shared across templates. Both templates work in full-canvas and lower-third layouts. A message without a template uses Custom.

Choose **Scripture** or **Lyrics** in **Output template** to force a template for all incoming messages, including older senders. Choose **Custom layout** to use your own alignment and Title/Footer switches for every message. Changing **Editing template** keeps all private drafts and does not change the output policy or live picture. Select matching sample text or your current source, then choose **Apply Design to Output** to save the designs and output policy together. The footer names every template with pending changes, plus changes to shared key colour or output selection. **Revert All Changes** restores all three designs, shared key colour and output selection; preview samples never publish themselves. Existing designs migrate to all three templates with their previous appearance and saved PNG intact.

Apply checks the artwork needed by the output template, even when you are editing another profile. If its PNG is unavailable, the warning names the template to repair and output stays unchanged. **Publish Text & Design** checks the template used by the submitted text; opening an unrelated profile with missing artwork does not block publication. **Shared key colour · all templates** applies to Custom, Scripture and Lyrics together.

Automatic selection requires the sending app to include `content.template: "scripture"` or `"lyrics"` in each snapshot. Sender integration changes are separate from this receiver feature; see the [template contract](docs/protocol.md#content-templates).

AltView advertises its available template IDs and names when a sender connects and reports whether it follows the sender, forces a template, or uses its custom layout. Connected senders receive updated status when an override is applied. The built-in **Text → Template** menu uses the receiving Mac's advertised choices; **Receiver’s layout** sends no request. Choosing a template stays private until Publish. A saved choice that is unavailable remains visible, but is omitted when sending; reconnecting refreshes the list. Older receivers without discovery receive ordinary text with no template request. eucaly and ViewTheWord can use the same [discovery contract](docs/protocol.md#template-discovery-and-receiver-overrides).

### Compact lyric lines

Choose **Editing template → Lyrics**, then **Typography → Lyrics lines → Compact pairs**. **Preserve lines** is the default. Each received stanza is fitted independently. Compact pairs first finds the font size needed for the original lines, then joins up to two adjacent lines when their rendered text fits on one row with a small width margin. The freed height allows larger text, up to the selected font size, while joined rows stay within the width. Text is never made smaller just to force a join. It never joins across blank stanza lines or manually indented/tabbed lines. Choose **Space** (default), **Comma**, or **Middle dot** as the joiner; comma avoids adding another punctuation mark after existing punctuation. Words, capitalization and the original sender snapshot stay unchanged.

Joining is measured against the lyric text box on the fixed **1920 × 1080** canvas before the complete text block is fitted to its height. Design, Text, Output and HDMI use the same display text; resizing a preview does not change pairing. Long pairs keep their original breaks, and the existing small-text warning still applies. **Extra line spacing** adjusts spacing independently for each template. Apply saves these choices with Lyrics.

### Layout and artwork

Open **Design** in the main workspace. Enable **Use lower-third layout** to place text in the saved boxes near the bottom, with optional built-in navy/gold artwork or an imported PNG. Turn it off to arrange text across the full canvas. Artwork, box positions, guides and animation controls appear only in lower-third mode; Title and Footer visibility work in both modes. Font, size, key colour, enable state, layout and imported artwork share one draft and one **Revert All Changes** action. Nothing changes output as you edit.

The **Built-in banner** follows the active text template. **Lyrics** uses a single navy panel with a subtle blue outline and centred gold accents at the top and bottom, leaving the expanded body area clear. Scripture and Custom layout keep the titled banner. Each template remembers its own imported PNG. Replacing one template’s image keeps any PNG still used by another template.

**Apply Design to Output** (Command-S in Design) applies appearance to this Mac’s current source without changing its text or ownership. For local Compose, **Publish Text & Design** in Text sends the composition together. Design previews your Compose draft by default, or the current source when another app takes output. The preview menu also offers explicit samples for fitting checks. It is labelled **not live**; inspect Output for this Mac’s current picture. External text is read-only here, and **Open Text Draft…** clearly opens a separate local draft.
AltView copies each validated PNG into its private application storage, so the original file can be moved or removed afterward. Reverting or cancelling an import keeps the applied PNG and removes the unused draft copy. Switching to the built-in banner keeps the saved PNG available. A failed import preserves the previous design. If a saved PNG is missing, Edit Design explains how to replace it or apply the built-in banner.

- **Artwork → Placement → Fit to Banner** and **Fit to Canvas** affect only the artwork box. The first suits a cropped strip; the second suits a transparent 1920 × 1080 composition. **Layout → Reset This Template’s Positions** restores all four boxes only in the template being edited. Revert undoes that reset before applying.
- In any **Editing template** profile, untick **Title** or **Footer** in **Layout** to hide that text in either mode and give its space to Body, even if the sender reserves empty rows. Text is kept for when you turn the row on again. In lower-third mode, the saved boxes determine the expanded area. Untick both for body-only text spanning all three text areas. Body’s Y and Height fields show the automatically expanded area; X and Width remain editable. Tick both rows again to restore and edit the saved base body position. The title/footer boxes are kept, and Apply Design to Output saves the choices and updates output. Scripture initially shows both labels; Lyrics initially hides both. These switches control AltView text, not text baked into imported artwork.
- Untick **Artwork** beside its row in **Layout** to show text directly on the key colour, without a banner or PNG behind it. Text stays in its current positions. The selected artwork and its placement are kept for when you tick it again. **Apply Design to Output** saves the choice; a missing PNG does not block text-only output while Artwork is off.
- Empty or whitespace-only Title/Footer text also frees its space automatically, unless the sender requests `emptyRegions: "reserve"`. Returning text restores the saved boxes. The numeric layout fields describe the saved design; preview guides show the actual boxes after empty rows collapse. Full-screen mode also honors this preference, reserving one label line and its gap when requested. Update the receiving Mac to this version for sender-controlled spacing.
- **Show layout guides** outlines and names the artwork, title, body, and footer boxes in the editor only. The preview-content menu offers a speaker, announcement, and longer message to check text fitting. Neither guides nor sample text appear on output.
- Set **X / Y / Width / Height** as percentages of the full canvas, measured from its top left. PNG artwork keeps its proportions. Invalid numbers remain visible and block Apply until corrected or reverted; out-of-range values are adjusted with an explanation. Text shrinks to fit its box, with a preview warning when the preview’s body becomes very small.
- Font and key colour are in Design. Full-screen position, alignment and maximum height appear when Use lower-third layout is off. Lower-third placement and alignment use its saved boxes.
- Choose **Slide**, **Reveal**, or **None**, with a 0.1–2 second full transition. Show / Hide and Clear animate artwork and text together. Updating visible text does not replay the entrance. Rapid visibility changes reverse from the current position. Release, disconnection, and Pause Receiving clear immediately.
- **Preview Animation** replays only the selected draft/sample preview. Live receiver preview and output share one timeline; the design editor has a separate clock. macOS Reduce Motion makes transitions immediate.
- The workspace can be resized and Design scrolled on smaller screens; Apply and Revert stay visible at the bottom.

PNG limits: one frame, at most 20 MiB, 16,384 pixels per side, and 40 megapixels. Decoding and file copying happen off the UI/network queues; the decoded image is reduced to at most 1920 pixels on its longest side. There is no animated-PNG, video-loop, general image, or PDF projection in this version.

A transparent PNG does **not** create alpha on HDMI: its transparent pixels reveal the receiver's selected key colour. Use green/blue with the ATEM upstream chroma keyer for coloured banners. Black luma key can remove dark artwork along with the black background. Check semi-transparent edges and branding colours on the actual switcher.

## Connection behaviour

AltView lets macOS choose an available receiving port and advertises it through Bonjour. Choose the receiving Mac by name; no port configuration is needed. Bonjour connections resolve the current port again when reconnecting, while pairing still identifies the same receiver. Settings shows the current port only for the manual-address fallback. Older saved manual connections to port 49721 must use discovery or be updated to the current port.

If startup still reports a temporary port conflict, AltView retries automatically once a second for up to 30 seconds with the same pairing code. Output and Settings show the retry status; **Pause Receiving** cancels recovery. A pending local publication continues once receiving starts. A persistent conflict ends with an error and allows **Resume Receiving** to try again.

Initial connection setup allows up to 30 seconds for discovery and macOS Local Network access. If macOS asks, allow AltView to access your local network. If setup stalls, AltView automatically tries a fresh connection while keeping the dialog and your original Connect or Publish action active. Cancel stops these attempts; an unavailable receiver still times out. Rejected pairing codes remain editable immediately.

One sender owns the output at a time. **Publish Text & Design** locally, or **Publish Text** remotely, explicitly transfers ownership when Compose is not already active; subsequent publishing keeps the current ownership. Old updates and releases from an inactive sender cannot change the active output. Owner disconnection or a silent connection immediately clears artwork and text, preserving the background; the timeout is approximately five seconds. Sleep can delay timers until the Mac wakes.

A disconnected sender retries with bounded backoff. The previous owner may restore its latest snapshot when it reconnects, only if the receiver is still unowned. Connecting to an already occupied receiver never steals it automatically.

Protocol v2 adds asynchronous snapshot acceptance and receiver output-readiness feedback. Update both AltView and ViewTheWord together; v1 connections are rejected. Remote Compose status shows whether the latest sent snapshot was accepted and whether the receiver output is open, preview-only, closed, disconnected, minimized, asleep, or unavailable. Acceptance does not confirm a rendered frame or downstream HDMI delivery. Delayed acknowledgements show a notice while sending continues.

Network I/O, encoding, decoding, heartbeats, and retries use private queues. Text submissions retain only the newest pending snapshot; control queues and connection counts are bounded. A future ViewTheWord or eucaly integration can submit without waiting for the receiver, while the presentation app continues independently.

## Build and test

```sh
make build
make test
make release-check
```

`make test-release` runs only offline release regressions. `make release-notarize`
prepares local artifacts; `make release-publish` publishes them. `make release`
runs both stages. `make clean` preserves saved releases. See the
[release guide](docs/releasing.md) before the first release.

The app's deployment target is macOS 12. The test bundle targets macOS 14 to match current Xcode's XCTest runtime; this does not raise the app's minimum OS. Automated coverage includes framing, Unicode limits, bounded queues, ownership, real TLS sockets, reconnection, invalid pairing, timeouts, text fitting, background/PNG pixels, image import and reload, lower-third placement, reversible motion, stable text updates, immediate ownership-loss clearing, Reduce Motion, draft/published-text separation, cancellation during connection/takeover, native view/window initialization, automatic receiver startup, local-receiver exclusion from discovery, wrong-code recovery, Connect Only privacy, one-step connection/publishing, cancellation during pairing lookup, actual draft rendering, staged font/key colour, combined local publication, external-source identity/design application, and publication cancellation.

The checked-in Xcode project opens directly. `scripts/generate-project.py` is an optional maintenance helper to regenerate its file references after adding sources; it requires only Python's standard library. There is no `Package.swift`.

See [manual validation](docs/manual-validation.md) for the hardware checks and [protocol/architecture](docs/protocol.md) for later sender integrations.
