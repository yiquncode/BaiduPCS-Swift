import BaiduKit
import FerryCore
import SwiftUI
import UniformTypeIdentifiers

/// 设置窗口：下载、网盘、网络和账号四个标签页。
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("下载", systemImage: "arrow.down.circle") {
                DownloadSettingsView()
            }
            Tab("网盘", systemImage: "cloud") {
                NetdiskSettingsView()
            }
            Tab("网络", systemImage: "network") {
                NetworkSettingsView()
            }
            Tab("账号", systemImage: "person.crop.circle") {
                AccountSettingsView()
            }
        }
        .frame(width: 480)
    }
}

/// 下载目录、并发数和剪贴板检测。
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

    /// 选择预设时填入它的两项。两项不等于任何预设时显示“自定义”。
    private var concurrencyPreset: Binding<ConcurrencyPreset?> {
        Binding {
            model.settings.concurrencyPreset
        } set: { preset in
            if let preset { model.settings.apply(preset) }
        }
    }

    @ViewBuilder private var concurrencyFooter: some View {
        switch model.settings.concurrencyPreset {
        case .regular:
            Text("非超级会员（包括普通会员）同时使用多个连接会被百度限速，所以两项都是 1。")
                .foregroundStyle(.secondary)
        case .svip:
            Text("超级会员下载不限速。两项相乘最多为 \(FerrySettings.totalConnectionsLimit)，建议不超过 12。")
                .foregroundStyle(.secondary)
        case nil:
            Label("只有超级会员可以同时使用多个连接。其他账号会被百度限速，限速可能持续数小时到数天，并影响这个账号的所有客户端。",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
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
                Picker("网盘会员", selection: concurrencyPreset) {
                    Text("非超级会员").tag(ConcurrencyPreset?.some(.regular))
                    Text("超级会员").tag(ConcurrencyPreset?.some(.svip))
                    if model.settings.concurrencyPreset == nil {
                        Text("自定义").tag(ConcurrencyPreset?.none)
                    }
                }
                Stepper(value: $model.settings.maxConcurrentFiles, in: model.settings.allowedConcurrentFiles) {
                    LabeledContent("同时下载文件数", value: "\(model.settings.maxConcurrentFiles)")
                }
                Stepper(value: $model.settings.connectionsPerFile, in: model.settings.allowedConnections) {
                    LabeledContent("每个文件的连接数", value: "\(model.settings.connectionsPerFile)")
                }
            } footer: {
                concurrencyFooter
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("检测剪贴板中的分享链接", isOn: $model.settings.detectsCopiedLinks)
            } footer: {
                Text("复制分享链接后切换到 Ferry，自动打开“添加链接”并填入链接和提取码。")
                    .foregroundStyle(.secondary)
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

/// 代理。
private struct NetworkSettingsView: View {
    @Environment(AppModel.self) private var model
    /// 文本框的草稿。按回车、焦点离开全部文本框、切换标签页或关闭设置时一起提交，输入过程中不换代理，不打断下载。
    @State private var host = ""
    @State private var port = ""
    @State private var username = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case host, port, username, password
    }

    /// 切换模式时同时提交草稿，所以只换一次代理。
    private var mode: Binding<ProxySettings.Mode> {
        Binding {
            model.settings.proxy.mode
        } set: { mode in
            commit(mode: mode)
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("代理", selection: mode) {
                    Text("使用系统设置").tag(ProxySettings.Mode.system)
                    Text("SOCKS5").tag(ProxySettings.Mode.socks5)
                }
                if model.settings.proxy.mode == .socks5 {
                    TextField("服务器", text: $host, prompt: Text("127.0.0.1"))
                        .focused($focusedField, equals: .host)
                    TextField("端口", text: $port, prompt: Text("1080"))
                        .focused($focusedField, equals: .port)
                    TextField("用户名", text: $username, prompt: Text("可选"))
                        .focused($focusedField, equals: .username)
                    SecureField("密码", text: $password, prompt: Text("可选"))
                        .focused($focusedField, equals: .password)
                }
                if let problem = model.proxyProblem {
                    Label("\(problem)Ferry 暂时使用系统设置。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let problem = model.proxyPasswordProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("网盘请求、文件下载和网页登录都使用这个代理。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .autocorrectionDisabled()
        .onSubmit { commit() }
        // 在文本框之间切换时不提交：例如填了用户名还没填密码时，设置不完整，会先退回系统设置再换回代理。
        .onChange(of: focusedField) { _, field in
            if field == nil { commit() }
        }
        .onAppear {
            let proxy = model.settings.proxy
            host = proxy.host
            port = proxy.port.map(String.init) ?? ""
            username = proxy.username
            password = model.proxyPassword
        }
        .onDisappear { commit() }
    }

    /// 端口不是数字时提交为未填写，由 `proxyProblem` 提示。
    private func commit(mode: ProxySettings.Mode? = nil) {
        var proxy = model.settings.proxy
        if let mode { proxy.mode = mode }
        proxy.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        proxy.port = Int(port.trimmingCharacters(in: .whitespacesAndNewlines))
        proxy.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        model.setProxy(proxy, password: password)
        host = proxy.host
        port = proxy.port.map(String.init) ?? ""
        username = proxy.username
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
                        if model.isLoginExpired {
                            Button("重新登录…", action: showLogin)
                        }
                        Button("退出登录") { isConfirmingLogOut = model.requestLogOut() }
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
