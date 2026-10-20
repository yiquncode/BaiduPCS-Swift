import BaiduKit
import Foundation
import Observation

/// 分享中的一个目录或文件。目录的子项在展开时才加载。
@Observable
final class ShareNode: Identifiable {
    let entry: ShareEntry?
    private(set) var children: [ShareNode]?
    private(set) var isLoading = false
    private(set) var loadError: String?
    var isExpanded = false

    init(entry: ShareEntry?) {
        self.entry = entry
    }

    var id: Int64 { entry?.fsID ?? -1 }
    var isDirectory: Bool { entry?.isDirectory ?? true }

    func load(using client: BaiduClient, session: ShareSession) async {
        guard children == nil, !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let entries = try await client.listShare(session, directory: entry)
            children = entries.map(ShareNode.init(entry:))
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// 文件树和勾选状态。勾选目录表示包含它的全部内容。
@Observable
final class ShareTree {
    let client: BaiduClient
    let session: ShareSession
    let root = ShareNode(entry: nil)
    private(set) var selection: Set<Int64> = []

    init(client: BaiduClient, session: ShareSession) {
        self.client = client
        self.session = session
    }

    func load(_ node: ShareNode) async {
        await node.load(using: client, session: session)
    }

    func isSelected(_ node: ShareNode) -> Bool {
        selection.contains(node.id)
    }

    func setSelected(_ node: ShareNode, _ selected: Bool) {
        if selected {
            selection.insert(node.id)
            // 目录已经包含子项，不再单独记录。
            for child in node.descendants { selection.remove(child.id) }
        } else {
            selection.remove(node.id)
        }
    }

    var isAllSelected: Bool {
        guard let children = root.children, !children.isEmpty else { return false }
        return children.allSatisfy(isSelected)
    }

    func setAllSelected(_ selected: Bool) {
        selection = selected ? Set(root.children?.map(\.id) ?? []) : []
    }

    /// 勾选的最上层条目。已勾选目录中的条目不重复列出。
    var selectedEntries: [ShareEntry] {
        var result: [ShareEntry] = []
        func collect(_ node: ShareNode) {
            for child in node.children ?? [] {
                if let entry = child.entry, selection.contains(child.id) {
                    result.append(entry)
                } else {
                    collect(child)
                }
            }
        }
        collect(root)
        return result
    }
}

private extension ShareNode {
    var descendants: [ShareNode] {
        (children ?? []).flatMap { [$0] + $0.descendants }
    }
}
