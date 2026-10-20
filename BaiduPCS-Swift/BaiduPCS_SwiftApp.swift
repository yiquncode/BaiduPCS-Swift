import FerryCore
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
            SidebarCommands()
            InspectorCommands()
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
    @FocusedValue(\.jobSelection) private var selection

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("添加链接…") {
                openWindow(id: ContentView.windowID)
                model.presentAddLink()
            }
            .keyboardShortcut("n")
        }
        CommandMenu("任务") {
            // 主窗口不是当前窗口时没有选中的任务，这些操作都不可用。
            JobActionsMenu(jobs: selection?.jobs ?? [], showsUnavailable: true) { selection?.onRemove($0, $1) }
                .environment(model)
            Divider()
            let jobs = model.coordinator.jobs
            Button("全部暂停") { model.pauseAll(jobs) }
                .disabled(model.pausableJobs(in: jobs).isEmpty)
            Button("全部继续") { model.resumeAll(jobs) }
                .disabled(model.resumableJobs(in: jobs).isEmpty)
        }
    }
}
