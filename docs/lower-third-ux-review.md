# Lower-third UX review — 30 September 2026

Reviewed Receiver → Appearance, the native design editor, PNG import/recovery, numeric placement, sample rendering, animation, and the code paths that publish designs.

| Finding | Fix |
| --- | --- |
| Every edit and successful PNG import immediately changed the receiver’s design. Experimenting could alter live output. | Private draft with **Apply to Receiver** and **Revert Changes**. Apply commits the template and artwork together; Command-S also applies. The editor’s enable checkbox is staged. The main Receiver checkbox remains an immediate output control. |
| Closing had no clear save/discard boundary; layout reset could not be reversed. | Closing an edited draft offers Keep Editing, Discard Changes, or Apply. Revert restores the applied layout, including after Reset All Positions. |
| Sixteen percentage fields had no visual reference. | Optional named layout guides outline artwork, title, body and footer in the editor only. Focusing a coordinate field highlights its box. |
| A single fixed sample gave little indication of how real text would fit. | Speaker, Announcement and Long message samples; small body text produces a readability warning. |
| “Banner area” and “Full canvas” appeared beside all placement controls, obscuring their scope. | **Fit to Banner** and **Fit to Canvas** sit under **Artwork only**. **Reset All Positions** is separately labelled. |
| Invalid numbers were silently discarded; out-of-range values were silently changed. | Invalid fields remain visible, are marked, explain what needs correction, and block Apply. Canvas/range adjustments show feedback. Choosing None clears an irrelevant invalid duration. |
| Imported PNG status could be confused with the currently selected design. Missing artwork had a narrow recovery path. | The current artwork is named, saved PNG availability is explained, and missing PNG instructions offer replacement or the built-in banner. Importing/cancelling/reverting a draft preserves the applied asset. |
| The fixed window offered no way to keep actions accessible on smaller screens. | Resizable editor with scrolling settings and a persistent Apply/Revert footer. |
| The receiver entry point and disabled layout controls offered little explanation. | **Edit Design…** and contextual text explain where lower-third placement/alignment are set. |

## Validation

The complete 54-test suite passed (`build/LowerThirdUXTests-Final.xcresult`). Seven added tests cover draft privacy across refreshes, Apply/Revert, numeric validation and None recovery, receiver enable-state merging, missing PNG recovery, minimum-window action visibility, and asynchronous PNG import ownership/cancellation. Existing rendering, animation, text fitting, socket, ownership and composer tests also passed.

Native checks covered layout, guides, private preset changes, invalid input, Revert, the close sheet and Command-S while a numeric field is still active. The packaged universal app was opened and its editor left ready, with the original applied design restored and no sample text published. Intel/macOS 12 hardware, HDMI/ATEM keying and VoiceOver still need physical validation.

Source/package backups are in `build/before-lower-third-ux/`. Usage and hardware checks are updated in README and manual-validation.md.

## Follow-up: crowded guide labels

The screenshot with Body at Y 70%, Height 1% exposed overlapping Artwork/Body labels. Region outlines drawn later could also paint through an earlier label. Guide labels are now laid out together with a minimum gap and bounded to the preview. Short leaders identify the associated box when a label moves. All opaque labels are drawn after every outline and leader.

The 24 lower-third and window tests passed (`build/GuideLabelTests.xcresult`), including a new regression using the screenshot’s geometry, all regions crowded at the top or bottom, and smaller/letterboxed previews.

## Follow-up: layout switches and body expansion

Title and Footer now have checkboxes in their own Layout rows. Hiding either gives its vertical span to Body, including the intervening gap. Body X and Width stay unchanged. The displayed Body Y/Height and its guide show the expanded area; those two fields are calculated until both rows are enabled again. Saved rectangles remain intact, so enabling both restores the base layout without accumulated changes.

All 33 lower-third, rendering and window tests passed (`build/BodyExpansionTests.xcresult`). Preview/output fitting and animation use the same effective body rectangle. The workflow still previews privately until Apply.

## Follow-up: finding the actual text fields

The design window showed sample strings without explaining where to edit real text, and Compose called the Title field “Heading”. The editor now has an **Edit Text…** button that opens Compose and focuses Title, plus a source explanation and an explicit **Sample preview** label. Compose uses **Title**, **Body** and **Footer** consistently. Navigation preserves the open design draft and does not publish text or apply a design; text supplied by another app is still edited in that app.

All 61 tests passed (`build/TextDiscoveryTests.xcresult`), including draft preservation when opening Compose. The Release build, code signature and ZIP integrity passed. Native checks verified the shortcut, Title focus, visible Footer field, unchanged blank output, and the user's retained unapplied layout draft. The updated app was left on Compose.


## Fresh workflow review — Text, Design and Output

The shortcut treated the symptom: it helped find Compose but left text, appearance and preview describing different objects. The task-oriented organization is appropriate because operators need to prepare a composition, inspect it, then deliberately send it. Receiver/Compose remain the underlying transport roles.

| Finding | Implemented behavior |
| --- | --- |
| Compose’s preview was live output, while Design showed fictional text. | Text previews the actual local draft in the staged design. Design defaults to that draft, or the external source when one takes output; samples are explicit menu choices. Output alone is labelled live. |
| Related editing was scattered across two pages and another window. | One workspace has Text, Design and Output. Font, colour, layout and artwork are together in Design, with direct navigation from Text. |
| Font, background and the main lower-third switch changed live output immediately. | Every appearance control stages changes. Apply Design updates current output appearance; local Publish Text & Design applies the requested composition together. |
| Local text could be published against an unapplied or invalid design. | Local publish includes the design, waits for receiver acceptance, and blocks invalid geometry/imports. Failed or cancelled publishing preserves the staged design. Later text edits stay private. |
| Hidden Title/Footer accepted input without explanation. | Visibility appears beside each content field, including pending visibility changes. Hidden text remains saved. Existing row checkboxes, automatic Body expansion and saved base geometry remain intact. |
| Edit Text could imply it edited an external sender. | Persistent source identity uses the sender ID, not its name. External Design text is a read-only preview; the shortcut says Open Compose Draft and explains that external text is edited in its own app. Opening it never takes output. |
| Moving Design into the workspace could lose close/cancel protection. | Close and Quit from any page offer Keep Editing, Discard Design Changes or Apply. Imported PNG ownership, Revert and cancellation remain protected. |
| Remote text cannot promise the local receiver’s styling. | Another Mac publishes text only and shows Last text sent. Design controls explicitly apply to this Mac; remote pairing and ownership behavior remain unchanged. |

Validation: 65 tests passed in `build/WorkspaceUXTests-Final.xcresult`, including real encrypted loopback publication, external-source design application without takeover, and deterministic cancellation. Native CUA inspection caught and fixed a collapsed embedded scroll area; the regression now checks its visible height. Native checks also verified draft previews, staged colour, visibility notes, unchanged live output and the close sheet. A separate native fixture also verified external-source navigation and deliberate Compose takeover using synthetic text and an isolated receiver. No real draft was published. Hardware/VoiceOver checks remain listed in manual-validation.md.
