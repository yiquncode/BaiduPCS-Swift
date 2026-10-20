import AppKit
import BaiduKit
import FerryCore
import SwiftUI
import UniformTypeIdentifiers

/// 添加链接：输入链接和提取码并打开分享，在文件树中勾选要下载的文件，然后下载。
///
/// 打开分享前，回车触发“打开”；打开后，回车触发“下载”。打开后修改链接或提取码，文件树清空。
struct AddLinkView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var linkText = ""
    @State private var password = ""
    /// 从剪贴板自动填入的链接和提取码。用户改了链接以后不再显示提示。
    @State private var pasted: (link: String, password: String)?
    @State private var openTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var tree: ShareTree?
    @State private var isSubmitting = false
    /// 用户在“保存到”菜单中用“其他…”选择的目录。只用于这个任务，不修改设置。
    @State private var chosenFolders: [DownloadFolder] = []
    /// nil 表示设置中的下载目录。
    @State private var selectedFolder: DownloadFolder?
    @State private var isChoosingFolder = false
    @State private var folderError: String?

    private var isOpening: Bool { openTask != nil }
    private var canOpen: Bool { !linkText.trimmingCharacters(in: .whitespaces).isEmpty && !isOpening }

    var body: some View {
        VStack(spacing: 0) {
            linkFields
                .padding()
            Divider()
            shareContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding()
        }
        .frame(minWidth: 600, idealWidth: 640, minHeight: 460, idealHeight: 540)
        .task { await fillFromPasteboard() }
        // 关闭 sheet 时取消正在打开的分享。
        .onDisappear { openTask?.cancel() }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                chooseFolder(url)
            }
        }
    }

    private var linkFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("分享链接", text: $linkText, prompt: Text("https://pan.baidu.com/s/1…"))
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .onChange(of: linkText) {
                        fillPassword()
                        closeShare()
                    }
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    fill(from: text)
                }
                .labelStyle(.iconOnly)
                .help("粘贴分享链接")
                Text("提取码")
                    .accessibilityHidden(true)
                TextField("提取码", text: $password, prompt: Text("4 位"))
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .frame(width: 64)
                    .onChange(of: password) { closeShare() }
                Button("打开", action: openShare)
                    .keyboardShortcut(tree == nil ? .defaultAction : nil)
                    .disabled(!canOpen)
            }
            .disabled(isOpening)
            if let pasteHint {
                Label(pasteHint, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pasteHint: String? {
        guard let pasted, pasted.link == linkText else { return nil }
        return !pasted.password.isEmpty && pasted.password == password ? "已从剪贴板填入链接和提取码" : "已从剪贴板填入链接"
    }

    @ViewBuilder
    private var shareContent: some View {
        if let tree {
            ShareBrowser(tree: tree)
        } else if isOpening {
            ProgressView("正在打开分享…")
        } else if let errorMessage {
            ContentUnavailableView {
                Label("无法打开分享", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                // 未登录或链接无效时，重试不会成功。
                if model.client != nil, ShareLink.parse(linkText) != nil {
                    Button("重试", action: openShare)
                        .disabled(!canOpen)
                }
            }
        } else {
            ContentUnavailableView {
                Label("输入分享链接后按回车打开", systemImage: "link")
            } description: {
                Text("支持 https://pan.baidu.com/s/1… 和 https://pan.baidu.com/share/init?surl=… 两种格式。链接带提取码时自动填入。")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading) {
            if let folderError {
                Label(folderError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            HStack {
                folderPicker
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("下载", action: download)
                    .keyboardShortcut(tree == nil ? nil : .defaultAction)
                    .disabled(tree?.selection.isEmpty ?? true || isSubmitting)
            }
        }
    }

    /// “保存到”菜单中的一项。
    private enum Destination: Hashable {
        /// 设置中的下载目录。
        case settings
        case chosen(DownloadFolder)
        /// “其他…”：打开面板选择目录，不改变当前选择。
        case other
    }

    private var destination: Binding<Destination> {
        Binding {
            selectedFolder.map(Destination.chosen) ?? .settings
        } set: { destination in
            switch destination {
            case .settings: selectedFolder = nil
            case .chosen(let folder): selectedFolder = folder
            case .other: isChoosingFolder = true
            }
        }
    }

    private var folderPicker: some View {
        Picker("保存到", selection: destination) {
            FolderLabel(url: model.currentFolder.url).tag(Destination.settings)
            ForEach(chosenFolders, id: \.self) { folder in
                FolderLabel(url: folder.url).tag(Destination.chosen(folder))
            }
            Divider()
            Text("其他…").tag(Destination.other)
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help((selectedFolder ?? model.currentFolder).url.path(percentEncoded: false))
    }

    /// 选择的目录加入菜单并选中。它和菜单中已有的目录是同一位置时，选中已有的那一项。
    private func chooseFolder(_ url: URL) {
        folderError = nil
        func isSameLocation(_ folder: DownloadFolder) -> Bool {
            folder.url.standardizedFileURL.path == url.standardizedFileURL.path
        }
        if isSameLocation(model.currentFolder) {
            selectedFolder = nil
        } else if let existing = chosenFolders.first(where: isSameLocation) {
            selectedFolder = existing
        } else {
            do {
                let folder = try model.makeDownloadFolder(for: url)
                chosenFolders.append(folder)
                selectedFolder = folder
            } catch {
                folderError = "无法取得“\(url.lastPathComponent)”的访问权限：\(error.localizedDescription)"
            }
        }
    }

    /// 先只检测剪贴板中有没有网址（不会弹出隐私提示），有网址才读取内容。填入后不自动打开。
    private func fillFromPasteboard() async {
        guard linkText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        guard let patterns = try? await pasteboard.detectedPatterns(for: [\.probableWebURL]),
              patterns.contains(\.probableWebURL),
              linkText.isEmpty,
              let text = pasteboard.string(forType: .string),
              fill(from: text) else { return }
        pasted = (linkText, password)
    }

    /// 返回是否找到了分享链接。
    @discardableResult
    private func fill(from text: String) -> Bool {
        guard let link = ShareLink.parse(text) else { return false }
        linkText = link.url.absoluteString
        password = link.password ?? ""
        return true
    }

    private func fillPassword() {
        if password.isEmpty, let found = ShareLink.parse(linkText)?.password {
            password = found
        }
    }

    /// 链接或提取码变了，已打开的分享不再对应它们：清空文件树，回到打开前的状态。
    private func closeShare() {
        tree = nil
        errorMessage = nil
    }

    /// 在启动任务之前就进入“正在打开”状态，连按也只打开一次。
    private func openShare() {
        guard !isOpening else { return }
        tree = nil
        guard let client = model.client else {
            errorMessage = "未登录百度网盘。"
            return
        }
        guard let link = ShareLink.parse(linkText) else {
            errorMessage = BaiduError.invalidShareLink.localizedDescription
            return
        }
        errorMessage = nil
        let password = password
        openTask = Task {
            defer { openTask = nil }
            do {
                let session = try await client.openShare(link, password: password)
                try Task.checkCancellation()
                let tree = ShareTree(client: client, session: session, onError: { model.noteError($0) })
                self.tree = tree
                await tree.load(tree.root)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                model.noteError(error)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func download() {
        guard let tree, !tree.selection.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        model.addJob(session: tree.session, entries: tree.selectedEntries, downloadFolder: selectedFolder)
        dismiss()
    }
}

/// 分享的文件树：表头的全选、文件列表和已选摘要。
private struct ShareBrowser: View {
    let tree: ShareTree

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                // 两个来源：全部勾选、有勾选。只勾选了一部分时，复选框显示为混合状态。
                Toggle("全选", sources: [
                    Binding(get: { tree.isAllSelected }, set: { tree.setAllSelected($0) }),
                    Binding(get: { !tree.selection.isEmpty }, set: { tree.setAllSelected($0) }),
                ], isOn: \.self)
                    .toggleStyle(.checkbox)
                    .disabled(tree.root.children?.isEmpty ?? true)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Text(summary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var content: some View {
        let root = tree.root
        if let children = root.children {
            if children.isEmpty {
                ContentUnavailableView("分享中没有文件", systemImage: "folder")
            } else {
                List {
                    ForEach(children) { node in
                        ShareNodeRow(node: node, tree: tree, isIncluded: false)
                    }
                }
            }
        } else if let error = root.loadError {
            ContentUnavailableView {
                Label("无法读取分享", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("重试") { Task { await tree.load(root) } }
            }
        } else {
            ProgressView("正在加载…")
        }
    }

    private var summary: String {
        let entries = tree.selectedEntries
        let folders = entries.count { $0.isDirectory }
        if folders > 0 {
            return "已选 \(entries.count) 项（含 \(folders) 个文件夹，大小在转存后确定）"
        }
        let size = entries.reduce(Int64(0)) { $0 + $1.size }
        return "已选 \(entries.count) 项，共 \(size.byteCount)"
    }
}

/// 文件树中的一行。目录展开时加载子项。
private struct ShareNodeRow: View {
    let node: ShareNode
    let tree: ShareTree
    /// 上层目录已勾选，这一项随目录一起下载。
    let isIncluded: Bool

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: expansion) {
                if let children = node.children {
                    if children.isEmpty {
                        Text("空目录").foregroundStyle(.secondary)
                    }
                    ForEach(children) { child in
                        ShareNodeRow(node: child, tree: tree, isIncluded: isIncluded || tree.isSelected(node))
                    }
                } else if let error = node.loadError {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Button("重试") { Task { await tree.load(node) } }
                    }
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在加载…").foregroundStyle(.secondary)
                    }
                }
            } label: {
                label
            }
        } else {
            label
        }
    }

    private var expansion: Binding<Bool> {
        Binding {
            node.isExpanded
        } set: { expanded in
            node.isExpanded = expanded
            if expanded { Task { await tree.load(node) } }
        }
    }

    private var label: some View {
        let entry = node.entry
        return HStack {
            Toggle(isOn: Binding(get: { isIncluded || tree.isSelected(node) }, set: { tree.setSelected(node, $0) })) {
                Label {
                    Text(entry?.name ?? "")
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: FileIcon.systemName(for: entry?.name ?? "", isDirectory: node.isDirectory))
                        .foregroundStyle(node.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(isIncluded)
            Spacer()
            if let entry, !entry.isDirectory {
                Text(entry.size.byteCount)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}
