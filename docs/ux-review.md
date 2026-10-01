# Status and destination UX review — 30 September 2026

The main failure was ambiguity about what a label described. Text could show DRAFT, LIVE, CLEAR, Source: None, and Output window closed at the same time. Those labels represented private edits, a remote publication, and the sending Mac’s unused receiver. The person presenting should not need to understand that internal separation to use the app.

## Findings and implemented changes

| Finding | Change |
| --- | --- |
| The permanent DRAFT badge looked like a status that had failed to update after publishing. | Removed the fixed badge from Text and Design. Text shows **Unpublished changes** only for changes to the message or a local design that the next publication will send. Remote text ignores local design changes. Design retains its actual Apply/Revert state. |
| The global CLEAR / Source: None strip contradicted a successful remote publication. | Removed the global footer. The receiving Mac’s content and source now appear only beside its preview on Output. Text reports only its selected destination. |
| LIVE suggested that an external display was showing text, even though the sender cannot know whether the other Mac has opened output. | Text uses **Published to [destination]**. Remote preview copy explains that it is the last text sent. For local publication, the output-window state and an action to open Output controls are shown. Output itself uses **TEXT VISIBLE**, **HIDDEN**, and **NO TEXT** beneath an explicitly local preview. |
| A temporary-pairing warning replaced the receiver’s identity. | The selected receiver has its own persistent name next to Send to; pairing notices have a separate line. |
| Destination controls scrolled away with the fields. The body stayed at a fixed height when the window grew. | Destination sits above the two columns. The body grows with the available height; compact windows can scroll the fields while keeping destination and publishing actions visible. |
| The remote sent-text preview silently cut off messages after twelve lines. Empty title/footer labels also introduced unexplained gaps. | The complete sent text is scrollable, and empty title/footer rows are removed. |
| After Hide, the only way to show text again also published whatever edits were in progress. | Hide becomes **Show Last Text**, restoring the previous publication without sending new edits. Publish remains the explicit way to send the edited message. Stop Presenting still releases control. |
| “Compose” and “Text” described the same editor. Design’s destination was implicit. | User-facing Design choices now say **Text draft** and **Open Text Draft**. Its subtitle and applied state explicitly refer to this Mac. |
| Another source’s ownership was shown without a clear consequence for Publish. | Text names the controlling source and says that publishing will replace its text. Opening or editing a private message does not take control. |

## Page responsibilities

- **Output:** receiving status on this Mac, the current source, output preview, and physical display/window controls. Receiving readiness and display-open state are separate because a Mac can receive without opening its display.
- **Settings (gear):** receiver name, pairing code, Copy/Reset Code, Pause/Resume Receiving, and Custom Text. Output and Settings name connected senders. The shortcut changes from **Pair a sender…** to **Pair another sender…** while connected, and the Output controls stay grouped at the top without an expanding gap.
- **Design:** appearance for this Mac. Preview changes remain private until Apply or a local Text publication. It cannot change another Mac’s design.
- **Text:** the editable message, its destination, the local message preview or complete remote sent-text copy, and publication controls. “Published” describes the submitted message, not proof of visibility on an external display.

## State checks

1. A saved message starts private with Unpublished changes. Publishing removes that indicator; typing brings it back without changing the receiver.
2. A local design change affects the Text change indicator only for This Mac. Choosing Another Mac never sends those appearance changes.
3. Hide and Show Last Text preserve later private edits. Stop Presenting releases the receiver while retaining the message.
4. A remote connection identifies the receiver even when pairing persistence is unavailable. Connection loss is OFFLINE rather than PUBLISHED.
5. Text and Design never show the sending Mac’s local receiver badge. Returning to Output shows local state again.
6. Long sent messages remain readable to their last line. At the minimum window size, destination, navigation, previews, and primary actions remain available. Enlarging the window gives space to the body editor.

## Validation

Automated checks exercise publication, ownership, local and remote destinations, dirty-state transitions, restoration of the last publication, full remote text, page scoping, and resizing. Final run results and the native visual-check outcome are recorded in manual-validation.md.

Physical two-Mac, Intel/Monterey, HDMI/ATEM, and VoiceOver checks remain hardware validation. Protocol v2 now reports snapshot acceptance and software output readiness asynchronously. The UI continues to avoid claiming rendered-frame or downstream HDMI delivery.
