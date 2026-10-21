import BaiduKit
import Foundation
import Observation

/// 文件树中的一个条目：分享中的条目，或网盘中的条目。
nonisolated protocol FileTreeEntry: Identifiable {
    var name: String { get }
    var isDirectory: Bool { get }
    /// 字节数。目录为 0。
    var size: Int64 { get }
}

extension ShareEntry: FileTreeEntry {}
extension NetdiskEntry: FileTreeEntry {}

/// 文件树中的一个目录或文件。目录的子项在展开时才加载。
@Observable
final class FileNode<Entry: FileTreeEntry>: Identifiable {
    /// 根目录为 `nil`。
    let entry: Entry?
    private(set) var children: [FileNode]?
    private(set) var isLoading = false
    private(set) var loadError: String?
    var isExpanded = false

    init(entry: Entry?) {
        self.entry = entry
    }

    /// 绕过编译器崩溃：Swift 6.3 用 `-O` 编译默认 MainActor 隔离的泛型类的隐式 deinit 时崩溃。
    nonisolated deinit {}

    var id: Entry.ID? { entry?.id }
    var isDirectory: Bool { entry?.isDirectory ?? true }

    /// 返回加载失败的错误。
    func load(using list: (Entry?) async throws -> [Entry]) async -> (any Error)? {
        guard children == nil, !isLoading else { return nil }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let entries = try await list(entry)
            children = entries.map(FileNode.init(entry:))
            return nil
        } catch {
            loadError = error.localizedDescription
            return error
        }
    }
}

/// 文件树和勾选状态。勾选目录表示包含它的全部内容。
@Observable
final class FileTree<Entry: FileTreeEntry> {
    /// 根目录第一次加载成功后的勾选状态。
    enum InitialSelection {
        /// 勾选根目录中的全部条目。
        case all
        case none
    }

    let root = FileNode<Entry>(entry: nil)
    private(set) var selection: Set<Entry.ID> = []
    /// 列出目录的子项。参数为 `nil` 时列出根目录。
    @ObservationIgnored private let list: (Entry?) async throws -> [Entry]
    @ObservationIgnored private let initialSelection: InitialSelection
    /// 加载失败时调用，例如让界面知道登录已失效。
    @ObservationIgnored private let onError: (any Error) -> Void

    init(initialSelection: InitialSelection,
         list: @escaping (Entry?) async throws -> [Entry],
         onError: @escaping (any Error) -> Void) {
        self.initialSelection = initialSelection
        self.list = list
        self.onError = onError
    }

    /// 见 `FileNode` 的 deinit。
    nonisolated deinit {}

    func load(_ node: FileNode<Entry>) async {
        let isFirstLoad = node.children == nil
        if let error = await node.load(using: list) {
            onError(error)
        } else if node === root, isFirstLoad, node.children != nil, initialSelection == .all {
            setAllSelected(true)
        }
    }

    func isSelected(_ node: FileNode<Entry>) -> Bool {
        node.id.map(selection.contains) ?? false
    }

    func setSelected(_ node: FileNode<Entry>, _ selected: Bool) {
        guard let id = node.id else { return }
        if selected {
            selection.insert(id)
            // 目录已经包含子项，不再单独记录。
            for child in node.descendants {
                if let childID = child.id { selection.remove(childID) }
            }
        } else {
            selection.remove(id)
        }
    }

    var isAllSelected: Bool {
        guard let children = root.children, !children.isEmpty else { return false }
        return children.allSatisfy(isSelected)
    }

    func setAllSelected(_ selected: Bool) {
        selection = selected ? Set(root.children?.compactMap(\.id) ?? []) : []
    }

    /// 勾选的最上层条目。已勾选目录中的条目不重复列出。
    var selectedEntries: [Entry] {
        var result: [Entry] = []
        func collect(_ node: FileNode<Entry>) {
            for child in node.children ?? [] {
                if let entry = child.entry, selection.contains(entry.id) {
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

private extension FileNode {
    var descendants: [FileNode] {
        (children ?? []).flatMap { [$0] + $0.descendants }
    }
}
