# Regenerating the reference screenshots

`Docs/ui-states/` holds one PNG per principal UI state, in light and dark
appearance. Regenerate the whole set with:

```sh
./Scripts/capture-ui-states.sh
```

The script builds the Debug app, runs it with `--capture-ui-states`, and copies
the result into `Docs/ui-states/`. Review the diff before committing: a change to
any of these files is a change to what the app shows.

## What the capture actually does

`CardVault/UIStateGallery.swift` (all inside `#if DEBUG`) walks
`UIStateFixture.all`, poses `AppModel` in each state, waits for layout and
materials to settle, and photographs the app's own window. States, wording and
fixture data come from `Sources/CardVaultCore/StatusPresentation.swift` and
`Sources/CardVaultCore/UIStateFixtures.swift`, so the screenshots and the
assertions in `CardVaultTests/UIStateTests.swift` describe the same states.

A posed model does no I/O: `AppModel.isPosed` short-circuits `refresh()` and
`refreshDetectedVolumes()`. A capture run cannot touch a card, a destination, the
bookmark store, or the history index.

## Two things the capture needs

**Screen recording.** The window is composited by the window server, so the app
cannot photograph itself from the inside: `cacheDisplay(in:to:)` and
`CALayer.render(in:)` both return the chrome over an empty content area, and
`ImageRenderer` draws `NavigationSplitView` and `List` as "not renderable"
placeholders. The harness uses ScreenCaptureKit and needs *Screen & System Audio
Recording* granted to the Debug build of `CardVault.app` in System Settings →
Privacy & Security. Without the grant the run prints how to fix it and exits
non-zero rather than writing 36 misleading files.

**The sandbox.** CardVault runs under App Sandbox and cannot write into the
repository. The harness writes into its container's temporary directory and
prints `CARDVAULT_UI_STATES_DIR=…`; the script copies from there. The sandbox is
part of the app under audit, so the harness lives inside it rather than being
given a hole.

## Adding a state

Add the case to `PrincipalUIState`, give it a presentation and a fixture, and
re-run the script. `UIStateFixtureTests.everyStateHasAFixture` fails if a state
is added without a fixture, which is what stops a state from quietly dropping out
of the reference set.
