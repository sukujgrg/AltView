# AltView protocol v2 and implementation boundaries

## Roles

The receiver owns the display style, selected display, window lifecycle, and active sender lease. A sender supplies a generic `DisplayContent` snapshot containing `title`, `body`, `footer`, and `visible`, with optional `emptyRegions` spacing and `template` layout preferences. `body` and `visible` are required; omitted or null title/footer values become empty strings. Content is plain text; no markup, file paths, media, HTML, or remote commands.

`Core/ReceiverState.swift` is the pure ownership reducer. `ReceiverServer` confines it to a serial queue. `OutputCanvas` is shared by preview and output. The built-in Compose composer owns a `SenderClient` and is independent of ViewTheWord or eucaly. Automated tests exercise two simultaneous clients.

## eucaly and ViewTheWord integration

eucaly and ViewTheWord implement direct senders using the same discovery, pairing and text protocol as Compose. They can run on the receiver Mac (This Mac / loopback) or another Mac (Bonjour/LAN). A separate AltView process on the sending Mac is needed only when it is also the receiver. Compose is optional.

- Pairing starts in the sending app’s AltView connection settings: discover/select the receiving Mac, enter its code, and confirm the encrypted connection. The receiver stays ready without initiating a reverse connection.
- Keep connection and publication separate. Pairing alone must not take output; an explicit presentation action may connect and publish together when clearly labelled.
- Identify the app and sending Mac in the `hello` name so the receiver can show the current source, for example `ViewTheWord · Presentation Mac` or `eucaly · Presentation Mac`.
- Keep the sender service independent of composer UI, projection views, and local display lifecycle. Loss of the AltView connection must not block the presentation app’s ordinary operation.
- Keep appearance, lower-third artwork, and output-display selection on AltView. Both apps send generic content snapshots and follow the shared ownership/reconnection rules below.
- After template discovery, ViewTheWord should default to `"scripture"` when advertised, with the reference in `title`, verse text in `body` and translation name in `footer`. eucaly should default to `"lyrics"` for song lyrics when advertised. Populate any template picker from the receiver catalogue, using IDs for selection and names for display. Include the selected, supported ID on every snapshot, including hidden snapshots and reconnect restoration; omit it for generic messages or when discovery/the requested ID is unavailable.

Compose is an optional built-in sender for custom text and standalone validation. Receiver onboarding must describe the sending app generically, with Compose instructions presented only as an alternative.

## Discovery and pairing

The receiver advertises Bonjour service type `_altview._tcp` while receiving is active, using the receiver name, listening port, and a public `receiverID` UUID in its TXT record. Discovery requests TXT records and excludes the local receiver by UUID; no secret is included in discovery metadata. AltView requests an automatically allocated port (`0`) from macOS and advertises the assigned port. Senders must retain the Bonjour service endpoint and resolve it for each connection instead of pinning the resolved port or assuming the old fixed port 49721. `ReceiverDiscovery` uses `NWBrowser`, and the sender connects directly to the selected service endpoint. A manual host/port endpoint is also accepted; the current port is shown in receiver Settings and may change after Pause/Resume or restart. Existing saved manual endpoints need updating when the port changes; their credentials may need re-entering because manual pairing storage is keyed by host and port. No fixed-port setting is exposed to users. Most network tests disable advertising; dedicated Bonjour tests cover discovery and reconnecting after a port change. Discovery is local, with no central server or cloud account.

Pairing uses an 8-character code, visible and selectable on the Receiver page with a Copy Code button. Each character is chosen uniformly with `SecRandomCopyBytes` from `23456789ABCDEFGHJKLMNPQRSTUVWXYZ`, giving 40 bits of randomness. Senders may type or paste the code; parsing ignores whitespace and hyphens and accepts lowercase ASCII letters. The normalized eight uppercase ASCII bytes are the pre-shared key. Previous 64-character codes and 32-byte keys are not accepted; update both Macs and pair again with the displayed code. The receiver never advertises this secret. Both ends use Network.framework TLS with a pre-shared key, identity `AltView-v1`, TLS 1.2, and `TLS_PSK_WITH_AES_128_GCM_SHA256`. The secret is proved through the TLS handshake rather than transmitted as a JSON token. All trusted senders for this receiver share the secret and may explicitly take output.

The short code has less entropy than the previous 256-bit secret. This PSK cipher does not provide forward secrecy or protect short secrets against offline guessing from a captured handshake ([RFC 4279, section 7.2](https://www.rfc-editor.org/rfc/rfc4279.html#section-7.2)). This version is intended for a trusted local production network, not Internet exposure.

Secrets use Apple's data-protection Keychain. Invalid or obsolete receiver keys are replaced with a new eight-character code at launch. If signing or Keychain availability prevents persistence, the receiver uses a fresh in-memory key and explains that the code changes when AltView restarts. Restarting then requires entering the new code. A successful connection attempts to save the sender's secret and receiver UUID; a persistence error is visible. No fallback writes a secret to UserDefaults or disk.

A normal launch opens Receiver and starts its listener once pairing is prepared. It does not open a full-screen output or publish a saved draft. Pause Receiving stops connections and clears output; navigating between pages does not resume it. Show Text with This Mac selected resumes a paused receiver as part of the explicit presentation operation. Reset Code stops connections, clears output, generates a new secret, and resumes only if receiving was active before the reset. Shutdown prevents a pending pairing callback from starting a listener.

The sender’s connection sheet stays open through authentication. Connect Only never requests ownership; Connect & Show Text captures the current draft and requests output after a successful connection. Transient initial transport failures retry within a 30-second setup budget, keeping the same UI connection UUID and pending publication. A stalled transport is replaced after ten seconds, with a one-second delay before retrying. Authentication, identity and application-handshake failures, or expiry of the total setup budget, stop initial retry, cancel pending publication, and keep the code editable. Cancel and destination changes invalidate queued retries. Established connections retain normal reconnection behavior. UI attempts carry a local connection UUID to discard late status callbacks after cancellation or switching destinations. This identifier is not part of the wire protocol. Successful pairings are remembered in memory for the current app session and saved in Keychain where available.

## Framing

Every message is UTF-8 JSON preceded by a four-byte unsigned big-endian payload length. Valid lengths are 1…65,536 bytes, excluding the header. Receives are incremental and tolerate fragmented and combined frames. Reject malformed JSON, unknown kinds, unsupported versions, invalid lengths, and invalid required fields by closing the connection.

All messages carry `version: 2` and a `kind` string. Optional fields omitted by Swift's encoder need not be sent as JSON null. UUIDs use standard strings. Revisions are unsigned 64-bit integers; integrations in JavaScript should keep revisions within its exact integer range or handle them without lossy number conversions.

Example state payload (framing header omitted):

```json
{
  "version": 2,
  "kind": "state",
  "lease": "8D25A6AC-E5B5-42FC-BA0B-2EAA1F2E5F88",
  "revision": 1,
  "content": {
    "title": "PSALM 23:1",
    "body": "The LORD is my shepherd;\nI shall not want.",
    "footer": "King James Version",
    "visible": true
  }
}
```

### Content templates

`content.template` optionally selects a stable ID advertised by the receiver. This receiver provides `"scripture"` and `"lyrics"`. Omitted or null means no sender template request, without retaining any previous snapshot's template. IDs contain 1–64 ASCII letters, digits, dots, underscores or hyphens; malformed IDs and non-string values are rejected. Well-formed IDs unknown to this receiver fall back to its custom layout, subject to any receiver override. This is an optional v2 extension; older receivers ignore fields they do not recognize. Senders must discover support before requesting a template.

| Initial template | Alignment | Title | Body | Footer |
| --- | --- | --- | --- | --- |
| `scripture` | Left | Bible reference | Verse text | Translation name |
| `lyrics` | Centre | Hidden | Lyrics | Hidden |

The sender supplies the fields; the receiver does not parse references or identify templates from sender names. The initial Scripture design enables both label rows, which still collapse when empty unless `emptyRegions` is `"reserve"`. The initial Lyrics design hides both labels and reclaims their vertical space even with `"reserve"`. Hidden labels remain in the source snapshot. Templates select complete receiver-local saved designs in both full-canvas and lower-third layouts. The receiver can customize alignment, row visibility, typography, artwork, animation and geometry independently for Custom, Scripture and Lyrics; the key background and display selection remain shared. Senders must supply all relevant fields even if the receiving design currently hides them.

Receiver **Design → Text template** defaults to **From sending app**. **Custom layout** ignores sender template requests and uses the saved alignment and visibility controls. **Scripture** and **Lyrics** force that preset for all messages, including senders that omit `template`. These choices are private drafts until Apply and persist with the designs. Design’s separate Edit template selector changes only the profile being edited; it does not change the output policy. Applying saves all three profile drafts together. The preview offers Scripture and Lyrics samples. The same resolution drives preview, output, fitting, guides and accessibility. Exits keep the last visible content's template until the animation finishes.

Scripture content object:

```json
{"template":"scripture","title":"PSALM 23:1","body":"The LORD is my shepherd;\nI shall not want.","footer":"King James Version","visible":true}
```

Lyrics content object:

```json
{"template":"lyrics","body":"Amazing grace! How sweet the sound\nThat saved a wretch like me!","visible":true}
```

These objects belong inside the `content` field of a framed `state` message. Template requests follow the same ownership, lease and revision checks as text; connecting alone never changes the layout.

### Template discovery and receiver overrides

After authentication, `welcome.templates` supplies the receiver's ordered template catalogue as `{ "id": "…", "name": "…" }` entries. Treat IDs as opaque strings rather than a closed enum. Names are display labels, may repeat, and must never be used as identifiers. Catalogue limits are 64 entries, unique IDs, and nonblank names of at most 128 UTF-8 bytes. The existing 65,536-byte frame limit still applies. Invalid catalogues or policies close the connection.

Example welcome (normal ownership fields omitted):

```json
{
  "version": 2,
  "kind": "welcome",
  "receiverID": "F3465073-A824-4D86-BE4D-8E450117095A",
  "templates": [
    { "id": "scripture", "name": "Scripture" },
    { "id": "lyrics", "name": "Lyrics" }
  ],
  "templatePolicy": { "mode": "sender" }
}
```

`templatePolicy` describes the **applied** receiver setting:

| Policy | Meaning |
| --- | --- |
| `{ "mode": "sender" }` | Honor supported sender requests; unmarked or unavailable IDs use the receiver's custom layout. |
| `{ "mode": "custom" }` | Ignore sender requests and use the receiver's custom layout for every message. |
| `{ "mode": "fixed", "template": "lyrics" }` | Force the advertised template with this ID for every message. |

A fixed policy requires an ID present in `templates`. Other modes must omit `template`. A policy requires a catalogue; a catalogue without policy is allowed and means override status is unknown.

Every `feedback` message repeats the complete catalogue and policy. Applying a different receiver policy sends feedback to all authenticated senders, including connected observers that do not own output. Editing or reverting a Design draft never advertises it. Catalogue/policy updates do not publish text, take ownership, or alter snapshot revision numbers. They use the existing single replaceable feedback slot, so status bursts remain bounded. Future receivers can update their catalogue through the same messages; this receiver's two built-in entries remain fixed for its running version.

Sender behavior:

1. Read discovery from `welcome` before publishing or restoring a snapshot. Replace it with each `feedback` report and refresh any template menu. Clear discovery on disconnect; use the next receiver's welcome when reconnecting.
2. Missing/null `templates` means discovery is unavailable on an older receiver. An empty array means discovery is supported but no templates are offered. In either case, omit `content.template` when sending. Missing/null policy means override status is unknown.
3. Select known defaults such as Scripture or Lyrics only if their IDs are advertised. Menus must also accept future IDs without needing an app update. Include a receiver-layout choice that omits the field.
4. Retain the user's desired choice privately if it disappears. Mark it unavailable, omit it from subsequent snapshots, and explain the fallback. Do not publish text merely because discovery changes. Resolve the choice again before every send, including hide/show and reconnect restoration.
5. Show receiver overrides separately from the requested choice. Preserve a supported request in the snapshot even while an override is active, so returning the receiver to sender mode can restore it.

`SenderStatus.templateCapabilities` exposes the latest catalogue and policy. `contentForSending(_:)` strips unsupported requests from a copy, retaining the desired snapshot for reconnection. `templateDetail` reports overrides or fallback. The built-in Text composer populates its Template menu from the selected receiver and keeps changes private until Publish. These APIs and fields are available for the separate eucaly/ViewTheWord integrations; the receiver does not install changes into those apps.

### Empty title and footer space

`content.emptyRegions` accepts `"collapse"` (default when omitted or null) or `"reserve"`. Unknown values are rejected. Empty, omitted, null, and whitespace-only title/footer fields count as unused. Each state is a complete snapshot: omitting a label clears the previous label rather than retaining it.

- **Collapse:** Body reclaims unused title/footer space automatically. In a lower third, its vertical span extends into the unused boxes, retaining the saved body X and width. Full-screen text omits empty label rows and their gaps.
- **Reserve:** Keep empty title/footer boxes in a lower third. Full-screen text reserves one line at the label’s font size and its normal gap for each empty label. This does not retain the previous label’s multiline height.
- With no active content template, receiver Design switches remain authoritative: a row explicitly hidden by `showsTitle` or `showsFooter` still gives its space to Body, even with `"reserve"`. Each active saved design determines its own row visibility; the table above describes initial defaults. The spacing preference does not change saved geometry, artwork, fonts, or colours. When labels return, their saved boxes are used again.

Body-only content with automatic expansion:

```json
{"body":"Welcome everyone","visible":true}
```

The same content with empty spaces preserved:

```json
{"body":"Welcome everyone","visible":true,"emptyRegions":"reserve"}
```

These are content objects inside a framed `state` message, not HTTP request bodies. Protocol v2 requires updating both sender and receiver; v1 connections are rejected. Template discovery is an optional extension within v2 and does not make v1 compatible.

## Handshake and ownership

| Direction | Kind | Fields and effect |
| --- | --- | --- |
| Sender → receiver | `hello` | `senderID`, nonempty `name` (up to 128 UTF-8 bytes). Identify once per connection. |
| Receiver → sender | `welcome` | `receiverID`, optional `ownerID` and `ownerName`, plus optional `templates` and `templatePolicy` discovery fields. Connection is ready; no ownership is granted. |
| Sender → receiver | `take` | Explicitly take output. Generates a fresh lease and clears the old content. |
| Sender → receiver | `resume` | Reconnect-only request. Grants a fresh lease only if output is unowned when processed. Otherwise returns current ownership. |
| Receiver → sender | `granted` | New `lease`. Start revision numbering again and send a complete current state. |
| Receiver → all | `ownership` | Optional `ownerID`, `ownerName`, and `lease`; absent owner fields mean unowned. |
| Sender → receiver | `state` | `lease`, increasing `revision`, complete `content`. Apply only from the owning connection with the current lease. |
| Sender → receiver | `release` | Current `lease`. Clears only that connection's own output and revokes ownership. |
| Receiver → sender | `feedback` | Required `outputReadiness`; optional matching `lease` and positive `revision` acknowledge the latest accepted snapshot for this owning connection. Also carries the complete current `templates` and `templatePolicy` when discovery is supported. |
| Both | `heartbeat` | Keeps liveness observable even while content is unchanged. |
| Receiver → sender | `error` | Optional human-readable `detail`; the current receiver usually closes invalid sessions instead. |

A lease belongs to the socket as well as the sender UUID. Two sockets presenting the same sender UUID do not share ownership. Reject stale revisions and stale leases without republishing. A disconnected owner clears output; an inactive disconnect has no effect on content.

Blank is a full state with `visible: false`, retaining its text. Clear is empty title/body/footer and `visible: false`. Both preserve receiver style and sender ownership. Release clears and relinquishes ownership.

The sender pins the receiver UUID after connection and refuses automatic reconnection to a different identity. A newly entered pairing code constitutes explicit pairing and can accept a new receiver UUID. Automatic reconnect uses 1, 2, 4, then 8-second delays. Only the former owner requests `resume`; explicit Release/Disconnect cancels restoration.

## Snapshot acknowledgements and output readiness

After `welcome`, every sender receives `feedback`. The receiver also sends it after accepting a newer snapshot, when ownership changes, and when output readiness changes. Feedback is a complete current report: `lease` and `revision` are both absent if this connection owns no accepted snapshot. Stale revisions and leases never generate a new acknowledgement. Other senders receive readiness without another owner's revision.

`outputReadiness` is `closed`, `ready` (full-screen output window open), `preview` (windowed preview only), `displayMissing`, `minimized`, `unavailable` (required artwork missing/loading), or `asleep`. It describes the active output target, not an unapplied selection in the display picker. Acceptance means the receiver's ownership reducer accepted the content. It does **not** certify a rendered frame, finished animation, HDMI signal, switcher selection, or projector image. A snapshot can be accepted while output is closed or unavailable.

Feedback has one replaceable outbox slot and cannot grow the control queue. It includes the latest accepted revision, so intermediate acknowledgements can be skipped during bursts. Senders never wait for it before sending another state or projecting locally. After five seconds without acknowledgement progress, the sender shows a delayed-acknowledgement notice while continuing to send; this does not release ownership, resend text, or reconnect. Valid progress clears the notice. Release/takeover clears snapshot confirmation; disconnect clears all feedback, and reconnect starts with a new lease and revision sequence. ViewTheWord also correlates status with its current local submission so a previous acknowledgement cannot confirm a newer verse or blank.

Example feedback payload:

```json
{"version":2,"kind":"feedback","lease":"8D25A6AC-E5B5-42FC-BA0B-2EAA1F2E5F88","revision":12,"outputReadiness":"closed"}
```

## Bounds and UI isolation

- Maximum 8 simultaneous receiver connections.
- Sender names must be nonempty after trimming and fit within 128 UTF-8 bytes. `SenderClient` trims and truncates locally generated names at whole-character boundaries, with a nonempty fallback; receiver validation remains strict.
- Content limits in UTF-8 bytes: title 512, body 24,000, footer 1,024. Frame encoding is also capped; JSON escaping counts toward the frame size.
- `SnapshotMailbox` retains one latest submission and at most one queued drain job. Its lock protects a small value swap; it never holds a lock during encoding, drawing, or network work.
- `MessageOutbox` retains at most 16 controls, one newest state, one newest feedback report, and one heartbeat, in addition to one in-flight send. Overflow closes the slow connection.
- Socket reads are bounded. Sender connection setup allows 30 seconds for discovery, Local Network consent and TLS; temporary network waits can recover within that budget. Once TLS is ready, the sender allows five seconds for `welcome`. Accepted receiver connections must identify themselves within five seconds. Established peers use a five-second liveness and stuck-send deadline, checked approximately once per second.
- Receiver status delivery to the main thread is coalesced. Rendering never performs socket work.
- Sender status retains the last granted lease across ownership loss, so coalescing a grant and takeover still completes the composer's pending publication without automatically taking output again. This is local status metadata, not a wire-protocol change.
- A waiting receiver listener retains its socket and resumes when Network.framework reports ready. A failed listener that previously received successfully is recreated on the same port with the same identity and pairing key, using retry delays capped at eight seconds. Stop or a newer start cancels recovery. Initial occupied-port retries retain their 30-second limit.

Future integrations should retain a single sender service outside projection views. On an explicit app-level output intent, submit a complete snapshot and request ownership as needed. Navigation, text fetching, database readers, and local projector lifecycle must not wait on AltView. Do not add side effects to ViewTheWord's `ProjectorView` or tie remote socket lifetime to an individual view/tab. Audience primary-only selection and the committed secondary Confidence text belong in ViewTheWord’s projection adapter; AltView does not query Bible databases.

## Display lifecycle

The receiver retains separate Audience and Confidence output controllers, with one shared `DisplayAssignments` authority. Preview Window is a normal resizable 16:9 window; hardware output is a borderless, noninteractive window on the selected display. Both pages use the same monitor controls. Saved physical assignments are exclusive even when closed; active or waiting assignments cannot be changed until closed. Identify is available only on the selected, unused monitor, and its overlay closes before output opens or screen topology changes. Opening on the controls monitor requires confirmation; selection and current inventory are checked again after the response.

Assignments use the UUID from Apple’s [CGDisplayCreateUUIDFromDisplayID](https://developer.apple.com/documentation/colorsync/cgdisplaycreateuuidfromdisplayid(_:)) instead of persisting only a [CGDirectDisplayID](https://developer.apple.com/documentation/coregraphics/cgdirectdisplayid). A target resolves only to a single matching identity; duplicate identities, mirroring and unknown identities are rejected. Disconnect or mirroring closes the physical window immediately, then screen changes coalesce before repositioning. The controller waits for that same UUID even if its runtime ID changes, and ignores a different monitor reusing the old ID. Adapter or hardware changes that produce a new UUID require explicit reassignment. Close Display cancels restoration and retains the saved assignment. Command-Shift-O closes Audience; Command-Option-Shift-O closes Confidence.

`monitorLabelsV1` stores a receiver-local number and optional operator name per macOS UUID, independent of role assignments. First discovery allocates the next number; records for disconnected monitors remain reserved, so new identities cannot take their number or alias. Both menus sort by these remembered numbers, and Identify displays the same number/name. Names are shared between Audience and Confidence and can change without switching or reopening output. Empty names restore the hardware model label. Ambiguous/unknown identities cannot be named or identified. The Name sheet exposes the selectable UUID and validates a single line of up to 40 characters.

These are explicitly AltView numbers. Apple’s [NSScreen screens documentation](https://developer.apple.com/documentation/appkit/nsscreen/screens) specifies the primary screen at index zero and a dynamic inventory; it does not guarantee a numbering contract with System Settings. No assignment or alias uses an array position or localized model name as identity. A UUID change requires an explicit assignment and new name; the receiver cannot guarantee physical-TV identity across cable/port/adapter changes if macOS reports different or indistinguishable identities.

Legacy numeric preferences migrate to the connected monitor’s UUID once. An absent legacy monitor or unreadable new preference stays unavailable until the operator chooses a monitor or Preview Window. Explicit Preview Window is saved as null, so an older monitor preference cannot be revived on the next launch. Both outputs start closed.

The renderer uses an sRGB keying background, white text, native font fallback and natural writing direction. Layout uses a 1920 × 1080 coordinate system and shrinks title, body, footer, and gaps together until content fits the chosen height. The preview warns when fitting makes text small. Actual HDMI colour/range, text-edge quality, and hardware key thresholds must be checked on the ATEM.

## Receiver-local lower thirds

The wire protocol is version 2 and carries text with optional empty-row spacing and content-template preferences. `TemplateDesignLibrary` is saved under `templateDesignLibrary`, with independent Custom, Scripture and Lyrics designs, a receiver selection policy and shared key background. On first use, the previous `lowerThirdTemplate` and `outputStyle` preferences seed all three profiles, retaining artwork IDs and previous preset appearance; compact lines defaults to off and line spacing defaults to the previous 12%. The previous keys remain readable for older builds. Template IDs and discovery do not change, and senders do not send artwork or wait for image processing.

Each profile stores a `LowerThirdTemplate` and typography/full-canvas `OutputStyle`. Its `customized` flag allows saved alignment and Title/Footer choices to override the initial preset defaults. Hidden rows reclaim space even with `emptyRegions: "reserve"`; `effectiveBodyRegion` preserves the saved Body X/width and expands vertically into hidden rows. Returning labels restores saved geometry. Rendering and accessibility filter text only in a display copy.

Lyrics optionally uses `LyricCompactor` to join adjacent source lines in pairs within each received stanza. The original block is fitted first; actual AppKit glyph layout, that fitted font size, effective text width and a small safety margin determine eligibility. A second fit uses the freed height for larger text while constraining each joined row to one complete line. It never reduces the original fitted font size to force joining. Whitespace-only stanza separators, indentation and tabs are retained. `CanvasTextLayout.bodyText` is used for both measurement and drawing. Source snapshots and wire acknowledgements retain the original body. Joining uses fixed output coordinates, independent of preview size.

`PNGArtworkStore` reads bounded data, verifies ImageIO's PNG type/frame count/dimensions, decodes a thumbnail on its private queue, then atomically saves an app-owned UUID-named copy. The user-selected read-only sandbox entitlement and scoped access permit asynchronous import. Only app-owned superseded copies are removed; the user's original file is untouched. Completion tokens prevent stale imports/loads from replacing newer state. An unavailable selected custom asset suppresses the composition only while artwork is shown, and shows a reimport route with no silent branding fallback. Hidden artwork does not require its PNG to apply a design or publish text.

`LowerThirdWindowController` keeps an applied baseline and a private draft, including a pending imported asset. Only Apply calls the receiver with the complete template and artwork. Revert, discard, cancellation and shutdown invalidate the import token and remove only the pending app-owned copy; the receiver discards a superseded applied copy only after committing its replacement and confirming that no saved profile references it. Draft imports in other profiles are also retained until Apply or Revert. Receiver refreshes preserve draft edits and active field editors. The editor’s guides and sample selector are independent of `OutputCanvas` and never enter an output snapshot.

`CanvasPresentation` shares one reversible smooth timeline between receiver preview and output. Visible snapshots update the displayed content without restarting motion. Hidden snapshots preserve the last visible composition for the exit, then release it. Losing ownership bypasses animation and immediately clears. Template animation/source settings and artwork are local; changing a style doesn't create network messages. The editor owns a separate sample presentation, so replay has no on-air effect.

`OutputCanvas` rasterizes a transparent 1920 × 1080 composition only when content/design revisions change. Animation frames move or clip that cached layer over an unchanged sRGB key colour; there is no repeated image decoding or text fitting on animation ticks. Timers run only during transitions and respect Reduce Motion. Imported PNGs aspect-fit the artwork rectangle. Title, body and footer fit their own rectangles. Normal text mode keeps its existing layout.

## Built-in custom-text composer

`TextComposerViewController` is embedded in the main control window alongside the Receiver page. It retains one client independent of page visibility. `TextComposerSession` keeps the editable, locally saved draft separate from the last submitted snapshot. Editing never calls `submit`. Show Text publishes a visible snapshot and takes ownership only when not already owner; Update Live Text calls only `submit`. Hide submits the last published snapshot with `visible: false`, preserving unsent edits. Stop Presenting releases ownership while keeping the draft. Cancelling an in-flight take disconnects so a late grant cannot show text after Stop.

A Show Text click made before the local connection is ready freezes that requested snapshot. Later edits remain private until another publish. Switching destination or cancelling preparation invalidates callbacks. Neither connecting to a remote receiver nor changing pages automatically takes ownership. The existing wire protocol, queue isolation, ownership reducer and bounds are unchanged.

The This Mac preview uses the receiver's shared `CanvasPresentation`; another Mac shows only the last submitted text, clearly labelled. The protocol does not stream back remote pixels or remote style. Reopening restores a private draft with This Mac selected, without starting a presentation.


## Confidence snapshots

The sender advertises `hello.capabilities`. The receiver returns their intersection with its supported IDs in `welcome.capabilities`. Negotiation is per authenticated connection and reset on reconnect. The receiver advertises `confidenceTextV1` for presenter integrations, but the current ViewTheWord and AltView senders always preserve the complete Confidence object. There is no separate secondary-translation capability or older-receiver downgrade. Ownership, acknowledgements and template discovery retain their existing contract.

`content.confidence: {title, body, footer, secondary?}` is the complete last explicitly presented text, with no visibility or template fields. Each primary string has the same UTF-8 bound as its audience equivalent (512 / 24,000 / 1,024 bytes), and the complete escaped JSON must fit the existing 65,536-byte frame. It shares the text lease/revision/acceptance. Hide/Blank retains it; explicit Clear/media clears it, and Stop/release/disconnect clears receiver confidence text. eucaly keeps this object during hidden Current navigation; ViewTheWord sends its committed reference and both selected texts with their actual translation names. Custom text without a separate Confidence object uses the current snapshot's Audience text fields, including while Audience is hidden; the receiver never retains obsolete text based on visibility.

Confidence clock/visibility/layout and both display assignments are receiver-local. Snapshot acceptance still reports only software acceptance and audience output readiness, not confidence-window or physical HDMI delivery.

Optional `content.confidence.secondary: {body, footer}` is part of the standard Confidence snapshot. `body` is the committed secondary verse (up to 24,000 UTF-8 bytes), and `footer` is its actual translation name (up to 1,024 bytes). Confidence's title/body/footer remain the shared reference and primary text/name. The complete escaped snapshot, including Audience and both Confidence translations, must still fit the 65,536-byte frame. Missing/null secondary clears it on the next complete snapshot. Blank retains both; Clear, release, disconnect, media and takeover clear both. Selecting no secondary or projecting a verse missing from that translation uses one full-width column. The existing missing-primary fallback supplies one column with the available secondary's actual name.

Example Confidence object:

```json
{"title":"John 3:16","body":"Primary verse","footer":"Primary translation","secondary":{"body":"Secondary verse","footer":"Secondary translation"}}
```

AltView renders the two bodies at one shared fitted size in equal columns, with separate translation labels and a common reference below its clock. Audience reads only the top-level content title/body/footer and never includes the secondary Confidence text.

Senders validate the complete escaped Confidence frame after resolving templates and optional local-projection metadata, and check again after welcome when publication was queued during setup. Oversized text clears or releases that sender’s text channel with a local notice. This failure does not close an otherwise healthy encrypted connection or truncate content.

### This Mac routing and dynamic ports

When ready, the existing Bonjour listener also advertises its actual assigned `port` and a public `localMarker`, a SHA-256 namespaced hash of `kern.bootsessionuuid`. The marker is only a same-Mac discovery hint, never an authentication credential. If the marker matches the sending process’s current boot and the record has a valid receiver UUID and port, sender discovery offers **This Mac · receiver name** and routes the unchanged TLS protocol to `127.0.0.1:advertisedPort`. Local destinations store the stable receiver UUID as their pairing identity; their saved port is refreshed by discovery during setup and reconnect, even with Settings closed. A stopped/cancelled sender cannot restart from delayed discovery. Remote receivers continue to use their Bonjour service endpoints. Missing/nonmatching metadata remains ordinary LAN discovery; manual loopback connections use the actual port shown in AltView Settings. The receiver remains a LAN listener: selecting loopback changes the client destination, not listener access.

## Local projection extension (optional v2 capability)

`localProjectionV1` is negotiated alongside `confidenceTextV1`. It adds optional fields to existing messages; it creates no message kind, media transport, playback service or new ownership channel. Old peers ignore unknown JSON keys, and senders omit `content.projection` unless negotiated. Audience text, templates, leases and acknowledgement semantics remain unchanged. ViewTheWord is unchanged.

Eucaly includes `hello.localProcess: {processID, startTime, bootMarker}`. `startTime` is the process start in microseconds from `proc_pidinfo(PROC_PIDTBSDINFO)`; `bootMarker` uses the existing same-boot local-discovery marker. AltView accepts this identity only when the authenticated TCP peer address is IPv4 loopback (127/8), IPv6 loopback or IPv4-mapped IPv6 loopback, the boot marker matches and the live PID start time matches. Missing or failed local verification leaves text usable but supplies no capture source. The receiver retains the reported identity for loopback peers and verifies it when accepting a snapshot. If process information is temporarily unavailable, sender heartbeats retry verification of the current media report without changing its lease, revision or presentation; Clear, takeover and disconnect prevent restoration. Operator status and native logs distinguish a remote connection from local identity failures. The marker is public metadata, not authentication. A paired local sender’s identity report is trusted; this is not a security boundary against malicious apps on the same Mac.

`content.projection` is a complete optional presentation report:

```json
{"sessionID":"A550840D-5711-4EFD-977B-1BF420E729C5","mode":"media","windowID":77,"windowGeneration":"96C7F34B-1B92-46A2-AD56-8CDC7FE56F6E"}
```

- `sessionID` identifies Eucaly’s Current presentation session. `mode` is `lyrics` or `media` (image, PDF, video, webpage or captured-window slide). Eucaly chooses it only on explicit Project/Show; hidden navigation and background refreshes retain the last explicit mode. Preview and Connect Only never publish or take ownership.
- The optional window fields are a pair: positive `windowID` is the exact projection `NSWindow.windowNumber`, and a fresh `windowGeneration` UUID accompanies every window creation. Missing fields mean the projection window is not yet available. Window recreation may refresh this pair without publishing private Current content. No window title, monitor choice or pixel classification selects a source.
- A report shares the owning connection, lease and increasing revision of its enclosing state. Stale snapshots cannot alter mode or source. Switching sessions, windows, owners, leases or connections cancels the previous capture. A newer control revision for the exact same source retains its live picture and stream: unchanged content can emit only idle callbacks, without a new pixel buffer. Frames belong to the source lifetime, rather than a particular control revision.
- Media replaces the complete Confidence lyrics area. Its live picture includes Eucaly’s Hide/Blank, background and projection overlays, while AltView draws its own clock outside the picture. Lyrics retain the established readable primary text on audience Hide and hidden navigation. Omitted `projection` is a complete clear of the media report. Clear, release, owner disconnect, Pause Receiving and takeover clear obsolete media immediately.

Before capturing, AltView matches ScreenCaptureKit’s exact `SCWindow.windowID` to the reported ID and verifies its owning PID and `com.suku.eucaly` bundle ID against the live local process. Source monitoring rechecks PID start time and window existence. Eucaly controls the session/window pairing; captured frames carry the receiver’s current acceptance lifetime through mailbox invalidation and timestamp checks. A missing source retries only that identity until a new accepted report arrives; it never chooses another window.

Screen Recording permission is requested only through **Enable Local Media** / **Retry Capture**. A macOS user stop, refusal or entitlement failure stays stopped until explicit Retry; visibility changes, wake and new reports cannot undo it. A stopped sample has no error reason, so it also waits for Retry to avoid racing the delegate's operator-stop error. Transient failures retry the same identity with bounded 2/4/8/15-second backoff. ScreenCaptureKit is availability-gated at macOS 12.3; macOS 12.0–12.2 retain lyrics/clock with an unavailable-media status. A remote sender, denied permission or missing window shows a clear media area and operator status, never retained lyrics alongside media. Existing output/display controls remain local and independent.

One desktop-independent window stream serves Confidence preview and physical output. BGRA sRGB SDR capture buffers retain their IOSurface backing through direct Core Animation `contents` display; no per-frame CPU pixel read, screenshot conversion, encoding or network video exists. Dimensions aspect-fit within 1920×1080, use reported pixel scale on macOS 14+, and request 1/60-second intervals. Shadows are excluded where supported. A source-size/backing-scale change updates configuration in place, without restarting the stream. Queue depth is six; at most one pending picture/clear event and one queued drain are retained. Startup buffers the first still frame until capture succeeds; source invalidation cancels pending events, and timestamps reject out-of-order frames. Started/complete samples can supply pictures, idle samples carry no new surface, blank/suspended samples clear, and stopped samples end capture. An initial-picture timeout handles an empty startup. After a valid picture, missing callbacks alone cannot distinguish static content from a silent framework stall: preserve the picture, show a waiting status and offer Retry. Source identity/window checks and stream errors drive automatic recovery.

Window occlusion, minimization, hiding and close notifications promptly release inactive view surfaces. Capture pauses when Confidence is hidden, no preview/output can draw, or the system/displays sleep, and resumes the accepted report when demand returns. Retina views use their current backing scale. Both canvases update in one outer Core Animation transaction. The minute clock invalidates only its strip when its displayed value changes; control-only reports do not rebuild the text canvas. No audio output is registered; audio capture is explicitly disabled where the SDK exposes it. Unified logs record requested dimensions, elapsed capture time, committed-frame count, replaced pending events and maximum capture-to-software-commit age without content or credentials. These metrics do not measure GPU completion or physical display latency.

Apple references: [window-only filter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(desktopindependentwindow:)), [bounded capture queue](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth), [capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos). Requested fps and software commits do not certify measured capture throughput, display scanout or HDMI delivery.
