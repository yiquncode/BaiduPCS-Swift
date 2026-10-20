import BaiduKit
import FerryCore
import SwiftUI
import UniformTypeIdentifiers

/// 设置窗口：下载、网盘和账号三个标签页。
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("下载", systemImage: "arrow.down.circle") {
                DownloadSettingsView()
            }
            Tab("网盘", systemImage: "cloud") {
                NetdiskSettingsView()
            }
            Tab("账号", systemImage: "person.crop.circle") {
                AccountSettingsView()
            }
        }
        .frame(width: 480)
    }
}

/// 下载目录和并发数。
private struct DownloadSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isChoosingDirectory = false

    /// 两项中有一项大于 1 时，非会员账号会被限速。
    private var usesMultipleConnections: Bool {
        model.settings.maxConcurrentFiles > 1 || model.settings.connectionsPerFile > 1
    }

    var body: some View {
        @Bindable var model = model
        Form {
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
            }

            Section {
                Stepper(value: $model.settings.maxConcurrentFiles, in: FerrySettings.concurrentFilesRange) {
                    LabeledContent("同时下载文件数", value: "\(model.settings.maxConcurrentFiles)")
                }
                Stepper(value: $model.settings.connectionsPerFile, in: FerrySettings.connectionsRange) {
                    LabeledContent("每个文件的连接数", value: "\(model.settings.connectionsPerFile)")
                }
            } footer: {
                Group {
                    if usesMultipleConnections {
                        Label("非会员账号同时使用多个连接（同时下载多个文件或每个文件使用多个连接）会被百度限速，限速可能持续数小时到数天，并影响这个账号的所有客户端。建议两项都设为 1。",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text("非会员账号建议两项都设为 1。会员账号可以调高。")
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isChoosingDirectory, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.chooseDownloadDirectory(url)
            }
        }
    }
}

/// 转存目录和清理。
private struct NetdiskSettingsView: View {
    @Environment(AppModel.self) private var model
    /// 转存目录的草稿。按回车、切换标签页或关闭设置时校验并保存。
    @State private var transferFolder = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("转存目录", text: $transferFolder, prompt: Text("/Ferry"))
                    .autocorrectionDisabled()
                    .onSubmit(commitTransferFolder)
                Toggle("下载完成后删除网盘中的转存文件", isOn: $model.settings.cleanupAfterDownload)
            } footer: {
                Text("网盘中的目录。每个任务转存到其中的一个子目录。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { transferFolder = model.settings.transferFolder }
        .onDisappear(perform: commitTransferFolder)
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
}

/// 用户名、登录状态和登录操作。
private struct AccountSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var isConfirmingLogOut = false

    var body: some View {
        Form {
            Section {
                if let account = model.account {
                    LabeledContent("用户名", value: account.username.isEmpty ? "未知" : account.username)
                    LabeledContent("状态") {
                        if model.isLoginExpired {
                            Label("登录已失效", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        } else {
                            Text("已登录")
                        }
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
        }
        .formStyle(.grouped)
        .logOutConfirmation(isPresented: $isConfirmingLogOut)
    }

    private func showLogin() {
        openWindow(id: ContentView.windowID)
        model.presentLogin()
    }
}
