# Principal UI state audit

macOS 26 (Tahoe), Xcode 26.6, native SwiftUI/AppKit app target. Reference set:
`Docs/ui-states/` — one PNG per state, light and dark. Regenerate with
`./Scripts/capture-ui-states.sh` (see `Docs/ui-state-capture.md`).

The states are named in `PrincipalUIState`, their wording lives in
`StatusPresentation`, their data lives in `UIStateFixture`, and the conclusions
below that can be checked mechanically are asserted in
`CardVaultTests/UIStateTests.swift`. That is deliberate: an audit that exists only
as prose stops being true the first time someone edits a view.

## Scope, honestly

Everything below about layout, wording, symbols, colour independence, keyboard
paths, accessibility labels, values, hints and status announcements was audited
against the captured states and the view code, and the fixes listed are in the
tree.

**Live VoiceOver behaviour was not driven programmatically.** Rotor order, actual
spoken output, and interaction with Full Keyboard Access have to be heard on real
hardware. The structural work that determines what VoiceOver *can* say is done
and asserted; the listening pass is the manual checklist at the end and is still
outstanding.

## State inventory

Each state links its light capture; the dark capture is the same name with
`-dark`. "Speaks" is the announcement posted when the app enters the state.

| State | Screenshot | Symbol | Tone | Speaks |
| --- | --- | --- | --- | --- |
| `noSource` | [png](ui-states/noSource-light.png) | `sdcard` | neutral | No source selected… |
| `sourceDetected` | [png](ui-states/sourceDetected-light.png) | `sdcard.fill` | neutral | A removable card was detected… |
| `scanning` | [png](ui-states/scanning-light.png) | `magnifyingglass` | in progress | Scanning the source. Nothing is being modified. |
| `noTransferableFiles` | [png](ui-states/noTransferableFiles-light.png) | `questionmark.folder` | attention | No transferable files were found… |
| `ready` | [png](ui-states/ready-light.png) | `checkmark.circle` | neutral | Ready to transfer… |
| `preflightWarning` | [png](ui-states/preflightWarning-light.png) | `exclamationmark.triangle.fill` | attention | Ready to transfer, with warnings… |
| `preflightBlocked` | [png](ui-states/preflightBlocked-light.png) | `exclamationmark.octagon.fill` | blocked | Cannot start… Nothing has been copied. |
| `copying` | [png](ui-states/copying-light.png) | `doc.on.doc.fill` | in progress | Copying. Do not remove the card yet. |
| `copyCompleteVerificationPending` | [png](ui-states/copyCompleteVerificationPending-light.png) | `hourglass.circle.fill` | in progress | Copy complete. Verification has not finished… |
| `verifying` | [png](ui-states/verifying-light.png) | `checkmark.shield` | in progress | Verifying copied files. Do not remove the card yet. |
| `finalizing` | [png](ui-states/finalizing-light.png) | `hourglass` | in progress | Finalizing the verified transfer. |
| `verified` | [png](ui-states/verified-light.png) | `checkmark.seal.fill` | success | Transfer fully verified. Safe to eject… |
| `primaryVerifiedBackupIncomplete` | [png](ui-states/primaryVerifiedBackupIncomplete-light.png) | `externaldrive.badge.exclamationmark` | attention | Primary verified. Backup incomplete… |
| `conflictPaused` | [png](ui-states/conflictPaused-light.png) | `hand.raised.fill` | attention | Paused. *n* files need a decision… |
| `interrupted` | [png](ui-states/interrupted-light.png) | `bolt.horizontal.circle.fill` | attention | Transfer interrupted… can be resumed. |
| `cancelled` | [png](ui-states/cancelled-light.png) | `stop.circle.fill` | attention | Transfer stopped… verified stays verified… safe to eject. |
| `needsAttention` | [png](ui-states/needsAttention-light.png) | `exclamationmark.circle.fill` | attention | Transfer needs attention… |
| `failed` | [png](ui-states/failed-light.png) | `xmark.octagon.fill` | blocked | Transfer failed. No destination was verified… |
| `safeToEject` | [png](ui-states/safeToEject-light.png) | `eject.fill` | success | Safe to eject. Safe to eject does not mean safe to erase. |
| `ejected` | [png](ui-states/ejected-light.png) | `eject.circle.fill` | success | Card ejected. Ready for the next transfer… |

`interrupted` is captured as the relaunch recovery sheet over the window, because
that sheet *is* the state a user meets it in. `cancelled` is captured behind that
sheet: stopping raises the same sheet, and this is the screen left once it has
been dismissed.

## Findings and what was done

### Fixed

1. **Status changes were silent to VoiceOver.** Nothing the user was focused on
   changed when the app moved from copying to verifying to verified, so a
   VoiceOver user got no notice of "do not remove card yet" or of completion.
   Each state now posts an `AccessibilityNotification.Announcement` on entry
   (`View.announcesStatus`, `CardVault/StatusStyle.swift`).
2. **Status wording lived in five places.** `AppModel` built status strings
   inline in `beginTransfer`, `resume`, `receive`, `scan` and `ejectSource`, and
   the header picked its own symbol and colour. Consolidated into
   `StatusPresentation`, one entry per state, so what is shown and what is spoken
   cannot drift.
3. **Preflight severity was carried by colour and an easily-confused symbol.**
   Red octagon versus orange triangle is the difference between "cannot start"
   and "read this first". Issues now read `Blocking: …` / `Warning: …`.
4. **Verification state in History was carried by colour.** Green versus orange
   badges now read `Verified` / `Not fully verified` in words as well.
5. **A finished copy kept claiming verification was in progress after the
   transfer had ended.** `PhaseProgress` showed "Copy complete — verification
   still in progress" whenever the copy phase was complete, including on a
   finished transfer. It is now suppressed once an outcome exists.
6. **The result of a transfer sat below the fold.** In a default 1080×720 window
   the Result card was under the source, scan and preflight cards, so a finished
   transfer showed no result without scrolling. Result and conflicts now render
   directly beneath the status header.
7. **`Start Transfer` was offered during a running transfer.** It was disabled,
   but a prominent, full-width button that refuses the click is worse than no
   button. It is hidden while an operation is running.
8. **A disabled `Start Transfer` explained nothing.** The blocking reason is now
   written under the button and used as its help text and accessibility hint —
   the same rule the rest of the app already followed for unavailable actions.
9. **Destination results claimed a fraction they could not know.** "7 of 7 files"
   on a paused transfer counted only verified plus failed, silently dropping the
   files still awaiting a decision. Results are now stated as counts.
10. **The pause was announced twice.** The status header and the conflicts card
    repeated the same title and the same reassurance, pushing the actual file
    list down. The card is now titled "Files awaiting your decision".
11. **"Safe to eject" with an unverified destination said nothing about what
    ejecting costs.** It now adds that completing the unverified destination
    later needs the card again.
12. **Progress bars had no accessible value, and animated under reduced motion.**
    Bars now carry "*n* percent, *x* of *y* files", the copy/verify bar honours
    `accessibilityReduceMotion`, and the indeterminate scan spinner is replaced
    by the word "Scanning…" under reduced motion.
13. **Source, name, mode and destinations stayed editable during a transfer.**
    The running coordinator holds the plan it was started with, so an edit made
    mid-transfer changed only the screen — the name field could read one thing
    while a differently named folder was being written. Those three cards, the
    toolbar's Choose Source, and the three Choose… menu items are now disabled
    while an operation runs, with the reason written beneath the cards.
14. **Half the keyboard paths existed only on toolbar buttons.** Menu items were
    added for every shortcut (see below), so they are discoverable and reachable
    from the menu bar.
15. **A running transfer could not be stopped.** The coordinator has always
    stopped cleanly on cancellation — discarding the partial write, recording
    `cancelled` in the manifest, leaving the transfer resumable — but nothing in
    the UI held the task, so the only way out of a mistaken transfer was to
    quit the app or pull the card, which is the one thing every other state
    tells the user not to do. `Stop Transfer` now sits in the toolbar (replacing
    `Start Transfer` while work runs), under the progress bars, and in the menu
    at ⌘. — and the state it lands in is `cancelled`, named for the user's own
    decision rather than folded into `interrupted`, which describes something
    going wrong.

### Accepted as-is

- **Initial focus lands on the transfer-name field** in every capture. It is the
  only free-text field and a reasonable first stop; the status header carries
  `accessibilitySortPriority(100)` so VoiceOver reads the state before the form.
- **`safeToEject` is reported even when a destination failed.** The card is
  genuinely safe to remove — the source is never written to — and both the
  status header and the result state that a destination is unverified. Finding 11
  covers the consequence.
- **`ejected` clears the screen the finished transfer left behind.** Source,
  scan, preflight, progress and outcome all described a card that is no longer
  mounted, so they go; the record of the run stays in History, and the chosen
  destinations stay because they outlive any one transfer. The confirmation
  holds until another card is detected rather than being wiped by the unmount it
  caused.
- **The disabled prominent `Start Transfer` button stays visibly blue** in dark
  mode. That is the system's own disabled styling for `.borderedProminent`; the
  reason line beneath it carries the meaning.

## Keyboard

| Action | Shortcut | Where |
| --- | --- | --- |
| Choose Source… | ⌘O | Menu + toolbar + Source card |
| Choose Primary Destination… | ⌘D | Menu + Destinations card |
| Choose Backup Destination… | ⇧⌘D | Menu + Destinations card |
| Start Transfer | ⌘↩ | Menu + toolbar + main button |
| Stop Transfer | ⌘. | Menu + toolbar + button under the progress bars |
| Eject Card | ⌘E | Menu + header button (enabled when verified, or after a stop) |
| Dismiss recovery sheet | Esc | "Decide Later" is the cancel action |
| Dismiss error alert | ↩ | "OK" is the default button |

Every control on the transfer screen is a standard SwiftUI control, so tabbing
follows the visual order — sidebar, source, transfer, destinations, start, then
the result and progress cards. Reaching non-text controls with Tab requires
macOS's Full Keyboard Access (System Settings → Keyboard); that is a system
setting, not something the app can opt into.

## Colour independence

No status is distinguished by colour alone. Every status carries a distinct SF
Symbol *and* distinct wording, and `StatusTone` is the only thing that becomes a
colour (`CardVault/StatusStyle.swift`). Two machine checks enforce it:
states sharing a tone must differ in symbol and in title, and every state's title
must be unique. Grepping for `foregroundStyle(.red`, `.orange`, `.green` in
`CardVault/` should always land next to a symbol and a word.

## Native macOS behaviour

- **Enlarged-iPhone layout: not applicable.** CardVault is a native macOS target
  (`NavigationSplitView`, `Table`, `GroupBox`, `Settings` scene, `NSOpenPanel`,
  standard About panel). There is no Catalyst or iOS-idiom layer to inspect.
- **Liquid Glass legibility:** checked in both appearances across all 18 states.
  The toolbar glass sits over the window background with no content beneath it in
  any state, and no status text or symbol is drawn over the glass. Nothing in the
  captured set washes out in either appearance.
- **Toolbar grouping:** `Choose Source` and `Start Transfer` are separated by a
  fixed `ToolbarSpacer`, so the destructive-adjacent action is not adjacent to
  the browsing action.
- **Resizing:** the window has `minWidth: 900, minHeight: 620` and the content is
  a `ScrollView`; the three top cards share width evenly and the current path in
  the progress row truncates in the middle rather than overflowing.
- **Tables, sheets, dialogs:** the History table is a real `Table` with a context
  menu and a primary action; recovery is a sheet with a cancel-role dismissal;
  abandonment is an `alert` whose destructive option is marked
  `role: .destructive` and is offered only when something can actually be
  removed.
- **About:** the standard AppKit About panel, showing `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` from the Info.plist.

## Manual checklist

Still to be run by a human, on hardware, in both appearances. Same spirit as
`Docs/manual-removable-media-test.md`: these are the parts a test cannot assert.

1. **VoiceOver, transfer screen.** VO-A over the whole window. Confirm the status
   header reads first and reads as one sentence; the three cards read as
   Source/Transfer/Destinations with their current values; the Start button reads
   its reason when disabled.
2. **VoiceOver, status announcements.** Start a transfer with VoiceOver on.
   Confirm each transition is spoken once and that "do not remove the card yet"
   is heard at copy, copy-complete and verification.
3. **VoiceOver, progress.** Focus a progress bar mid-copy; confirm the percentage
   and the file counts are both spoken, and that it does not chatter on every
   throttled update.
4. **VoiceOver, results.** On a primary-verified/backup-incomplete run, confirm
   each destination is read as its own item with its own verification state.
5. **Full Keyboard Access.** Turn it on. Reach every control on the transfer
   screen, the recovery sheet and the abandon alert with Tab and arrow keys, and
   confirm focus never leaves a sheet while it is up.
6. **Reduced motion.** Turn it on. Confirm the copy bar advances without sliding
   and the scan spinner is replaced by text.
7. **Increased contrast and larger text.** Confirm no card clips its content and
   no status line truncates.
8. **Resizing.** Drag from 900×620 to full screen and back; confirm the card row
   reflows and the result stays visible without scrolling at the default size.
