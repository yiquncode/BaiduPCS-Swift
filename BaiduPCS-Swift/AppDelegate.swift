import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        #if DEBUG
        if DemoData.isEnabled, let appearance = DemoData.appearance { NSApp.appearance = appearance }
        #endif
        Task { await model.start() }
    }

    /// 复制分享链接后切换到 Ferry，自动打开添加链接。
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await model.detectCopiedLink() }
    }

    /// 关闭主窗口不退出，下载继续。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 主窗口关闭后点击 Dock 图标，重新打开主窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let openMainWindow = model.openMainWindow {
            openMainWindow()
            return false
        }
        return true
    }

    /// 等下载引擎保存进度后再退出，下次启动才能从断点继续。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
