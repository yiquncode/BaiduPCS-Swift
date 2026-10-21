import BaiduKit
import FerryCore
import SwiftUI

/// 从我的网盘下载：在网盘的文件树中勾选文件或目录，然后下载。打开时不勾选任何条目。
///
/// “重新加载”换一棵新的文件树，从根目录重新读取，勾选清空。
struct NetdiskDownloadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tree: FileTree<NetdiskEntry>?
    /// 每次重新加载加一。它变化时 `.task` 取消上一次读取，重新读取。
    @State private var generation = 0
    /// 没有文件树的原因，例如未登录。
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    /// nil 表示设置中的下载目录。
    @State private var selectedFolder: DownloadFolder?
    @State private var folderError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding()
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding()
        }
        .frame(minWidth: 600, idealWidth: 640, minHeight: 460, idealHeight: 540)
        .task(id: generation) { await load() }
    }

    private var header: some View {
        HStack {
            Text("从我的网盘下载")
                .font(.headline)
            Spacer()
            Button {
                generation += 1
            } label: {
                Label("重新加载", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .help("重新加载")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let tree {
            NetdiskBrowser(tree: tree, transferFolder: model.settings.transferFolder)
        } else if let errorMessage {
            ContentUnavailableView {
                Label("无法读取网盘", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            }
        } else {
            ProgressView("正在读取网盘…")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading) {
            if let folderError {
                Label(folderError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            HStack {
                DownloadFolderPicker(selection: $selectedFolder, error: $folderError)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("下载", action: download)
                    .keyboardShortcut(.defaultAction)
                    .disabled(tree?.selection.isEmpty ?? true || isSubmitting)
            }
        }
    }

    private func load() async {
        guard let list = listDirectory() else {
            tree = nil
            errorMessage = "未登录百度网盘。"
            return
        }
        errorMessage = nil
        let tree = FileTree<NetdiskEntry>(initialSelection: .none, list: list) { model.noteError($0) }
        self.tree = tree
        await tree.load(tree.root)
    }

    /// 列出目录的一层。根目录（`nil`）是 `/`。未登录时为 nil。
    private func listDirectory() -> ((NetdiskEntry?) async throws -> [NetdiskEntry])? {
        #if DEBUG
        if DemoData.isEnabled {
            return { DemoData.netdiskListing($0?.path ?? "/") }
        }
        #endif
        guard let client = model.client else { return nil }
        return { try await client.listDirectory($0?.path ?? "/") }
    }

    private func download() {
        guard let tree, !tree.selection.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        model.addNetdiskJob(entries: tree.selectedEntries, downloadFolder: selectedFolder)
        dismiss()
    }
}

/// 网盘的文件树：名称、修改日期和大小三列。
private struct NetdiskBrowser: View {
    let tree: FileTree<NetdiskEntry>
    /// 设置中的转存目录。树中的这个目录显示“转存目录”标签。
    let transferFolder: String
    @ScaledMetric private var dateWidth = 110
    @ScaledMetric private var sizeWidth = 72

    var body: some View {
        let root = tree.root
        if let children = root.children {
            if children.isEmpty {
                ContentUnavailableView("网盘中没有文件", systemImage: "folder")
            } else {
                List {
                    Section {
                        ForEach(children) { node in
                            FileTreeRow(node: node, tree: tree, isIncluded: false, badge: badge, columns: columns)
                        }
                    } header: {
                        columnHeaders
                    }
                }
            }
        } else if let error = root.loadError {
            ContentUnavailableView {
                Label("无法读取网盘", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("重试") { Task { await tree.load(root) } }
            }
        } else {
            ProgressView("正在读取网盘…")
        }
    }

    private var columnHeaders: some View {
        HStack {
            Text("名称")
            Spacer()
            Text("修改日期")
                .frame(width: dateWidth, alignment: .leading)
            Text("大小")
                .frame(width: sizeWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func badge(_ entry: NetdiskEntry) -> some View {
        if entry.isDirectory, RemotePath.normalized(entry.path) == RemotePath.normalized(transferFolder) {
            Text("转存目录")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: .rect(cornerRadius: 4))
                .fixedSize()
        }
    }

    private func columns(_ entry: NetdiskEntry) -> some View {
        HStack {
            Text(entry.modifiedAt?.formatted(date: .abbreviated, time: .omitted) ?? "")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: dateWidth, alignment: .leading)
            FileSizeText(entry: entry)
                .frame(width: sizeWidth, alignment: .trailing)
        }
    }
}
