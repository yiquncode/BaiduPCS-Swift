import BaiduKit
import FerryCore
import SwiftUI
import UniformTypeIdentifiers

/// 设置窗口。
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var isChoosingDirectory = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("账号") {
                if let account = model.account {
                    LabeledContent("用户名", value: account.username.isEmpty ? "未知" : account.username)
                    if model.isLoginExpired {
                        Label("登录已失效，请重新登录。", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Spacer()
                        Button("重新登录…", action: showLogin)
                        Button("退出登录") { model.logOut() }
                    }
                } else {
                    LabeledContent("状态", value: "未登录")
                    HStack {
                        Spacer()
                        Button("登录…", action: showLogin)
                    }
                }
            }

            Section("下载") {
                LabeledContent("下载目录") {
                    HStack {
                        Label(model.downloadDirectory.lastPathComponent, systemImage: "folder")
                            .help(model.downloadDirectory.path(percentEncoded: false))
                        Button("选择…") { isChoosingDirectory = true }
                    }
                }
                if let problem = model.downloadDirectoryProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if model.settings.downloadDirectoryBookmark != nil {
                    HStack {
                        Spacer()
                        Button("使用“下载”目录") { model.useDefaultDownloadDirectory() }
                    }
                }
                Stepper(value: $model.settings.maxConcurrentFiles, in: FerrySettings.concurrentFilesRange) {
                    LabeledContent("同时下载文件数", value: "\(model.settings.maxConcurrentFiles)")
                }
                Stepper(value: $model.settings.connectionsPerFile, in: FerrySettings.connectionsRange) {
                    LabeledContent {
                        Text("\(model.settings.connectionsPerFile)")
                    } label: {
                        Text("每个文件的连接数")
                        Text("非会员账号使用多个连接会被百度限速，可能持续数小时到数天。")
                    }
                }
            }

            Section("网盘") {
                TextField("转存目录", text: $model.settings.transferFolder, prompt: Text("/Ferry"))
                Toggle("下载完成后删除网盘中的转存文件", isOn: $model.settings.cleanupAfterDownload)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fileImporter(isPresented: $isChoosingDirectory, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.chooseDownloadDirectory(url)
            }
        }
    }

    private func showLogin() {
        openWindow(id: ContentView.windowID)
        model.isShowingLogin = true
    }
}
