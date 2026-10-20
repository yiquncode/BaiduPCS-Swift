import SwiftUI

@main
struct FerryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Ferry", id: ContentView.windowID) {
            ContentView()
                .environment(appDelegate.model)
        }
        .commands {
            FerryCommands(model: appDelegate.model)
        }

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
    }
}

private struct FerryCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("添加链接…") {
                openWindow(id: ContentView.windowID)
                model.presentAddLink()
            }
            .keyboardShortcut("n")
        }
    }
}
