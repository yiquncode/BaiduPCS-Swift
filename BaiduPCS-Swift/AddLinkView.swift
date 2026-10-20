import AppKit
import BaiduKit
import SwiftUI

/// 添加链接：输入链接和提取码，然后在文件树中勾选要下载的文件。
struct AddLinkView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var linkText = ""
    @State private var password = ""
    @State private var isOpening = false
    @State private var errorMessage: String?
    @State private var tree: ShareTree?

    var body: some View {
        Group {
            if let tree {
                ShareBrowser(tree: tree, onBack: { self.tree = nil }, onDownload: download)
            } else {
                linkForm
            }
        }
        .frame(width: 600)
        .frame(minHeight: tree == nil ? nil : 480)
        .onAppear(perform: fillFromPasteboard)
    }

    private var linkForm: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("分享链接", text: $linkText, prompt: Text("https://pan.baidu.com/s/1…"))
                        .onChange(of: linkText) { fillPassword() }
                    TextField("提取码", text: $password, prompt: Text("4 位字母或数字"))
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
                Button("下一步") { Task { await openShare() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(linkText.trimmingCharacters(in: .whitespaces).isEmpty || isOpening)
            }
            .padding()
        }
    }

    private func fillFromPasteboard() {
        guard linkText.isEmpty,
              let text = NSPasteboard.general.string(forType: .string),
              let link = ShareLink.parse(text) else { return }
        linkText = link.url.absoluteString
        password = link.password ?? ""
    }

    private func fillPassword() {
        if password.isEmpty, let found = ShareLink.parse(linkText)?.password {
            password = found
        }
    }

    private func openShare() async {
        guard let client = model.client else {
            errorMessage = BaiduError.loginExpired.localizedDescription
            return
        }
        guard let link = ShareLink.parse(linkText) else {
            errorMessage = BaiduError.invalidShareLink.localizedDescription
            return
        }
        isOpening = true
        errorMessage = nil
        defer { isOpening = false }
        do {
            let session = try await client.openShare(link, password: password)
            let tree = ShareTree(client: client, session: session)
            self.tree = tree
            await tree.load(tree.root)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func download(_ entries: [ShareEntry], session: ShareSession) {
        model.addJob(session: session, entries: entries)
        dismiss()
    }
}

/// 分享的文件树。
private struct ShareBrowser: View {
    let tree: ShareTree
    let onBack: () -> Void
    let onDownload: ([ShareEntry], ShareSession) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("全选", isOn: Binding(get: { tree.isAllSelected }, set: { tree.setAllSelected($0) }))
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
                    .disabled(tree.selection.isEmpty)
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
        let size = entries.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
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
