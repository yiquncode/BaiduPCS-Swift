/// 转存的拆分逻辑，与网络代码分开以便单测。
///
/// - 保留条目在分享中的相对目录：根目录条目转存到目标目录，`a/b` 中的条目转存到 `目标目录/a/b`。
/// - 同一目标目录的条目一次请求。
/// - 超过数量上限时把这一组拆小重试；单个目录超限时，在目标处建同名目录，再转存它的子条目。
struct TransferPlanner: Sendable {
    var makeDirectory: @Sendable (String) async throws -> Void
    var listChildren: @Sendable (ShareEntry) async throws -> [ShareEntry]
    /// 转存一组条目到一个目录。超限时抛出 `BaiduError.transferLimitExceeded`。
    var transferBatch: @Sendable ([ShareEntry], String) async throws -> Void

    func transfer(_ entries: [ShareEntry], to root: String) async throws {
        var created: Set<String> = [root]
        try await makeDirectory(root)

        for (relativeDirectory, group) in Self.grouped(Self.removingNested(entries)) {
            var destination = root
            for component in relativeDirectory.split(separator: "/") {
                destination = Path.join(destination, String(component))
                if created.insert(destination).inserted {
                    try await makeDirectory(destination)
                }
            }
            try await send(group, to: destination)
        }
    }

    private func send(_ entries: [ShareEntry], to destination: String) async throws {
        do {
            try await transferBatch(entries, destination)
        } catch let BaiduError.transferLimitExceeded(count, limit) {
            if entries.count > 1 {
                // 上限按文件总数计算，目录内的文件也算。先按上限切分，已经不超过上限时对半分。
                let size = limit > 0 && entries.count > limit ? limit : (entries.count + 1) / 2
                for start in stride(from: 0, to: entries.count, by: size) {
                    try await send(Array(entries[start..<min(start + size, entries.count)]), to: destination)
                }
            } else if let directory = entries.first, directory.isDirectory {
                let target = Path.join(destination, directory.name)
                try await makeDirectory(target)
                let children = try await listChildren(directory)
                if !children.isEmpty {
                    try await send(children, to: target)
                }
            } else {
                throw BaiduError.transferLimitExceeded(count: count, limit: limit)
            }
        }
    }

    /// 按相对目录分组，保持首次出现的顺序。
    static func grouped(_ entries: [ShareEntry]) -> [(String, [ShareEntry])] {
        var order: [String] = []
        var groups: [String: [ShareEntry]] = [:]
        for entry in entries {
            if groups[entry.relativeDirectory] == nil { order.append(entry.relativeDirectory) }
            groups[entry.relativeDirectory, default: []].append(entry)
        }
        return order.map { ($0, groups[$0]!) }
    }

    /// 已勾选目录内的条目会随目录一起转存。再单独转存会产生同名冲突，所以去掉。
    static func removingNested(_ entries: [ShareEntry]) -> [ShareEntry] {
        let directories = Set(entries.filter(\.isDirectory).map(\.relativePath))
        return entries.filter { entry in
            var parent = entry.relativeDirectory
            while !parent.isEmpty {
                if directories.contains(parent) { return false }
                parent = parent.split(separator: "/").dropLast().joined(separator: "/")
            }
            return true
        }
    }
}
