import CardVaultCore
import SwiftUI

@main
struct CardVaultApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1080, height: 720)
        .commands { CardVaultCommands(model: model) }

        Settings { SettingsView() }
    }
}
