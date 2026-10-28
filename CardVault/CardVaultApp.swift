import AppKit
import CardVaultCore
import SwiftUI

@main
struct CardVaultApp: App {
    @State private var model = Self.makeModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 960, minHeight: 760)
                .task { await captureReferenceScreenshotsIfRequested() }
        }
        .defaultSize(width: 1080, height: 800)
        // The window is sized by the user, never by the content: the transfer
        // screen's layout does not change with state, and a window that grows
        // as a transfer progresses moves what the user is watching.
        .windowResizability(.contentMinSize)
        .commands { CardVaultCommands(model: model) }

        Settings { SettingsView(model: model) }
    }

    private static func makeModel() -> AppModel {
        #if DEBUG
        // A capture run must never start against real bookmarks or real history,
        // so it is posed before the window ever appears.
        if UIStateGallery.isRequested {
            return AppModel(fixture: UIStateFixture.fixture(for: .noSource))
        }
        #endif
        return AppModel()
    }

    private func captureReferenceScreenshotsIfRequested() async {
        #if DEBUG
        guard UIStateGallery.isRequested else { return }
        await UIStateGallery.run(model: model)
        #endif
    }
}
