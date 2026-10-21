import SwiftUI

/// 文件树中的一行。目录展开时加载子项。
struct FileTreeRow<Entry: FileTreeEntry>: View {
    let node: FileNode<Entry>
    let tree: FileTree<Entry>
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
                        FileTreeRow(node: child, tree: tree, isIncluded: isIncluded || tree.isSelected(node))
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
