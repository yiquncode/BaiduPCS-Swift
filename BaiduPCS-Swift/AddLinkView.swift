import AppKit
import BaiduKit
import SwiftUI

/// 添加链接：输入链接和提取码，然后在文件树中勾选要下载的文件。
struct AddLinkView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var linkText = ""
    @State private var password = ""
    @State private var openTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var tree: ShareTree?
    @State private var isSubmitting = false

    private var isOpening: Bool { openTask != nil }

    var body: some View {
        Group {
            if let tree {
                ShareBrowser(tree: tree, isSubmitting: isSubmitting, onBack: { self.tree = nil }, onDownload: download)
            } else {
                linkForm
            }
        }
        .frame(width: 600)
        .frame(minHeight: tree == nil ? nil : 480)
        .task { await fillFromPasteboard() }
        // 关闭 sheet 时取消正在打开的分享。
        .onDisappear { openTask?.cancel() }
    }

    private var linkForm: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("分享链接") {
                        HStack {
                            TextField("分享链接", text: $linkText, prompt: Text("https://pan.baidu.com/s/1…"))
                                .labelsHidden()
                                .autocorrectionDisabled()
                                .onChange(of: linkText) { fillPassword() }
                            PasteButton(payloadType: String.self) { strings in
                                guard let text = strings.first else { return }
                                fill(from: text)
                            }
                            .labelStyle(.iconOnly)
                            .help("粘贴分享链接")
                        }
                    }
                    TextField("提取码", text: $password, prompt: Text("4 位字母或数字"))
                        .autocorrectionDisabled()
                } footer: {
                    Text("支持 https://pan.baidu.com/s/1… 和 https://pan.baidu.com/share/init?surl=… 两种格式。链接带提取码时自动填入。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .disabled(isOpening)

            HStack {
                if isOpening {
                    ProgressView().controlSize(.small)
                    Text("正在打开分享…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("下一步", action: openShare)
                    .keyboardShortcut(.defaultAction)
                    .disabled(linkText.trimmingCharacters(in: .whitespaces).isEmpty || isOpening)
            }
            .padding()
        }
    }

    /// 先只检测剪贴板中有没有网址（不会弹出隐私提示），有网址才读取内容。
    private func fillFromPasteboard() async {
        guard linkText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        guard let patterns = try? await pasteboard.detectedPatterns(for: [\.probableWebURL]),
              patterns.contains(\.probableWebURL),
              linkText.isEmpty,
              let text = pasteboard.string(forType: .string) else { return }
        fill(from: text)
    }

    private func fill(from text: String) {
        guard let link = ShareLink.parse(text) else { return }
        linkText = link.url.absoluteString
        password = link.password ?? ""
    }

    private func fillPassword() {
        if password.isEmpty, let found = ShareLink.parse(linkText)?.password {
            password = found
        }
    }

    /// 在启动任务之前就进入“正在打开”状态，连按也只打开一次。
    private func openShare() {
        guard !isOpening else { return }
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

    private func download(_ entries: [ShareEntry], session: ShareSession) {
        guard !isSubmitting else { return }
        isSubmitting = true
        model.addJob(session: session, entries: entries)
        dismiss()
    }
}

/// 分享的文件树。
private struct ShareBrowser: View {
    let tree: ShareTree
    let isSubmitting: Bool
    let onBack: () -> Void
    let onDownload: ([ShareEntry], ShareSession) -> Void
    @Environment(\.dismiss) private var dismiss

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
                Button("返回", action: onBack)
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("下载") { onDownload(tree.selectedEntries, tree.session) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(tree.selection.isEmpty || isSubmitting)
            }
            .padding()
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
