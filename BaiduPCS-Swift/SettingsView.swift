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

    /// “下载目录”菜单中的一项。
    private enum DirectoryChoice: Hashable {
        case downloads
        case chosen
        /// 打开面板选择目录，不改变当前选择。
        case other
    }

    private var directoryChoice: Binding<DirectoryChoice> {
        Binding {
            model.usesDefaultDownloadDirectory ? .downloads : .chosen
        } set: { choice in
            switch choice {
            case .downloads:
                // 同时清除无法访问的旧目录的 bookmark 和提示。
                if model.settings.downloadDirectoryBookmark != nil {
                    model.useDefaultDownloadDirectory()
                }
            case .chosen: break
            case .other: isChoosingDirectory = true
            }
        }
    }

    /// 两项中有一项大于 1 时，非会员账号会被限速。
    private var usesMultipleConnections: Bool {
        model.settings.maxConcurrentFiles > 1 || model.settings.connectionsPerFile > 1
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                // 和 Safari 的“文件下载位置”相同：系统的“下载”目录、选择的目录和“其他…”。
                Picker("下载目录", selection: directoryChoice) {
                    FolderLabel(url: AppModel.defaultDownloadDirectory).tag(DirectoryChoice.downloads)
                    if !model.usesDefaultDownloadDirectory {
                        FolderLabel(url: model.downloadDirectory).tag(DirectoryChoice.chosen)
                    }
                    Divider()
                    Text("其他…").tag(DirectoryChoice.other)
                }
                .help(model.downloadDirectory.path(percentEncoded: false))
                if let problem = model.downloadDirectoryProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
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

/// 目录菜单中的一项：目录的显示名称和文件夹图标。
struct FolderLabel: View {
    let url: URL

    var body: some View {
        Label(FileManager.default.displayName(atPath: url.path(percentEncoded: false)), systemImage: "folder")
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
