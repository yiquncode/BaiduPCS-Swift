import BaiduKit
import FerryCore
import SwiftUI
import UniformTypeIdentifiers

/// 设置窗口。
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var isChoosingDirectory = false
    @State private var isConfirmingLogOut = false
    /// 转存目录的草稿。按回车或关闭设置时校验并保存。
    @State private var transferFolder = ""

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
                        Button("退出登录…") { isConfirmingLogOut = model.requestLogOut() }
                    }
                } else {
                    LabeledContent("状态", value: "未登录")
                    HStack {
                        Spacer()
                        Button("登录…", action: showLogin)
                    }
                }
            }

            Section {
                LabeledContent("下载目录") {
                    HStack {
                        Label(FileManager.default.displayName(atPath: model.downloadDirectory.path(percentEncoded: false)),
                              systemImage: "folder")
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
                    LabeledContent("每个文件的连接数", value: "\(model.settings.connectionsPerFile)")
                }
            } header: {
                Text("下载")
            } footer: {
                Text("非会员账号同时使用多个连接（同时下载多个文件或每个文件使用多个连接）会被百度限速，限速可能持续数小时到数天，并影响这个账号的所有客户端。建议两项都设为 1。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                TextField("转存目录", text: $transferFolder, prompt: Text("/Ferry"))
                    .autocorrectionDisabled()
                    .onSubmit(commitTransferFolder)
                Toggle("下载完成后删除网盘中的转存文件", isOn: $model.settings.cleanupAfterDownload)
            } header: {
                Text("网盘")
            } footer: {
                Text("网盘中的目录。每个任务转存到其中的一个子目录。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear { transferFolder = model.settings.transferFolder }
        .onDisappear(perform: commitTransferFolder)
        .fileImporter(isPresented: $isChoosingDirectory, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.chooseDownloadDirectory(url)
            }
        }
        .logOutConfirmation(isPresented: $isConfirmingLogOut)
    }

    /// 空值恢复为 /Ferry；其他值整理为以 / 开头、不以 / 结尾的路径。
    private func commitTransferFolder() {
        let trimmed = transferFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = RemotePath.normalized(trimmed)
        let folder = normalized == "/" && trimmed.isEmpty ? FerrySettings().transferFolder : normalized
        transferFolder = folder
        if model.settings.transferFolder != folder {
            model.settings.transferFolder = folder
        }
    }

    private func showLogin() {
        openWindow(id: ContentView.windowID)
        model.presentLogin()
    }
}
