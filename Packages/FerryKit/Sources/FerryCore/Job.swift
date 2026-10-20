import BaiduKit
import Foundation

/// 一次提交分享链接产生的工作单元：转存勾选的条目，再把它们下载到本地。
public struct Job: Codable, Sendable, Hashable, Identifiable {
    public enum Phase: Codable, Sendable, Hashable {
        case transferring
        case downloading
        case completed
        case failed(Step)
    }

    /// 失败发生的步骤。它决定重试从哪里开始。
    public enum Step: String, Codable, Sendable, Hashable {
        /// 建目录、转存或列出转存后的文件。重试时删除任务子目录，重新转存。
        case transfer
        /// 文件下载。重试时只继续没有完成的文件下载。
        case download
    }

    public var id: UUID
    public var title: String
    public var link: ShareLink
    public var password: String?
    public var entries: [ShareEntry]
    /// 网盘中这个任务的子目录：`<转存目录>/<短 ID>`。
    public var remoteDirectory: String
    public var phase: Phase
    /// 转存完成后才有内容。
    public var files: [JobFile]
    /// 只在下载阶段有意义。
    public var isPaused: Bool
    /// 失败的原因。
    public var error: String?
    /// 不影响任务结果的问题，例如清理失败。
    public var warning: String?
    public var createdAt: Date
    /// 网盘中的任务子目录已删除。
    public var isCleanedUp: Bool
    /// 创建任务时的下载目录。之后修改设置中的下载目录不影响这个任务。旧版本创建的任务为 nil。
    public var downloadFolder: DownloadFolder?

    public init(link: ShareLink, password: String?, entries: [ShareEntry], transferFolder: String,
                id: UUID = UUID(), createdAt: Date = .now) {
        self.id = id
        self.link = link
        self.password = password
        self.entries = entries
        title = Self.title(for: entries)
        remoteDirectory = RemotePath.join(RemotePath.normalized(transferFolder), Self.shortID(id))
        phase = .transferring
        files = []
        isPaused = false
        self.createdAt = createdAt
        isCleanedUp = false
    }

    /// 缺少的字段用默认值，以后新增字段时，旧版本保存的任务列表仍能读取。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        link = try container.decode(ShareLink.self, forKey: .link)
        remoteDirectory = try container.decode(String.self, forKey: .remoteDirectory)
        password = try container.decodeIfPresent(String.self, forKey: .password)
        entries = try container.decodeIfPresent([ShareEntry].self, forKey: .entries) ?? []
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? Self.title(for: entries)
        // 不知道任务进行到哪里时，按转存失败处理，用户可以重试。
        phase = try container.decodeIfPresent(Phase.self, forKey: .phase) ?? .failed(.transfer)
        files = try container.decodeIfPresent([JobFile].self, forKey: .files) ?? []
        isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        error = try container.decodeIfPresent(String.self, forKey: .error)
        warning = try container.decodeIfPresent(String.self, forKey: .warning)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        isCleanedUp = try container.decodeIfPresent(Bool.self, forKey: .isCleanedUp) ?? false
        downloadFolder = try container.decodeIfPresent(DownloadFolder.self, forKey: .downloadFolder)
    }

    public static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).uppercased()
    }

    static func title(for entries: [ShareEntry]) -> String {
        guard let first = entries.first else { return "" }
        return entries.count == 1 ? first.name : "\(first.name) 等 \(entries.count) 项"
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// 在 Finder 中显示的位置：每个勾选条目在本地的顶层文件或目录。
    public var revealURLs: [URL] {
        var seen = Set<URL>()
        return files.compactMap { file -> URL? in
            guard let url = file.localURL else { return nil }
            // 最终文件名可能加了 " (1)"，所以从实际位置向上找，不用相对路径重新拼接。
            let depth = file.relativePath.split(separator: "/").count - 1
            var top = url
            for _ in 0..<max(depth, 0) { top.deleteLastPathComponent() }
            return seen.insert(top).inserted ? top : nil
        }
    }
}

/// 任务中的一个文件下载。
public struct JobFile: Codable, Sendable, Hashable, Identifiable {
    /// 也是 `DownloadRequest.id`。
    public var id: String
    public var remotePath: String
    /// 相对于下载目录的路径。它保留分享中的目录结构。
    public var relativePath: String
    public var size: Int64
    /// 下载完成后的实际位置。
    public var localURL: URL?

    public init(id: String = UUID().uuidString, remotePath: String, relativePath: String, size: Int64, localURL: URL? = nil) {
        self.id = id
        self.remotePath = remotePath
        self.relativePath = relativePath
        self.size = size
        self.localURL = localURL
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        remotePath = try container.decode(String.self, forKey: .remotePath)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        localURL = try container.decodeIfPresent(URL.self, forKey: .localURL)
    }

    public var isCompleted: Bool { localURL != nil }
    public var name: String { (relativePath as NSString).lastPathComponent }
}

/// 网盘路径的拼接和映射。
public enum RemotePath {
    /// 以 `/` 开头，不以 `/` 结尾（根目录除外）。
    public static func normalized(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return "/" + components.joined(separator: "/")
    }

    public static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// 网盘路径去掉任务子目录前缀，得到本地相对路径。不在子目录中时返回 nil。
    ///
    /// 按 UTF-8 的 `/` 切分路径，逐个比较 Unicode 规范化（NFC）后的分量。不用 `hasPrefix`：
    /// 它按字符簇比较，分量开头的组合字符会和前面的 `/` 合成一个字符簇。
    public static func relativePath(of path: String, in directory: String) -> String? {
        let prefix = components(of: directory, omittingEmpty: true)
        var parts = components(of: path, omittingEmpty: false)
        guard parts.first?.isEmpty == true else { return nil }
        parts.removeFirst()
        guard parts.count > prefix.count else { return nil }
        for (expected, actual) in zip(prefix, parts) where !isSameComponent(expected, actual) {
            return nil
        }
        return parts[prefix.count...].joined(separator: "/")
    }

    static func components(of path: String, omittingEmpty: Bool) -> [String] {
        path.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: omittingEmpty)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    static func isSameComponent(_ a: String, _ b: String) -> Bool {
        a.precomposedStringWithCanonicalMapping.utf8.elementsEqual(b.precomposedStringWithCanonicalMapping.utf8)
    }
}

/// 本地相对路径的校验和去重。
public enum LocalPath {
    /// 没有空分量、`.`、`..` 和 NUL。
    public static func isSafe(_ relativePath: String) -> Bool {
        let parts = RemotePath.components(of: relativePath, omittingEmpty: false)
        return !parts.isEmpty && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && !part.utf8.contains(0)
        }
    }

    /// 相对路径在 `directory` 中的位置。路径不安全或不在 `directory` 之内时返回 nil。
    public static func destination(for relativePath: String, in directory: URL) -> URL? {
        guard isSafe(relativePath) else { return nil }
        var url = directory
        for part in RemotePath.components(of: relativePath, omittingEmpty: false) {
            url.append(component: part, directoryHint: .notDirectory)
        }
        let base = directory.standardizedFileURL.pathComponents
        let target = url.standardizedFileURL.pathComponents
        guard target.count > base.count,
              zip(base, target).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }) else { return nil }
        return url
    }

    /// 忽略大小写和 Unicode 规范化后相同的路径在 macOS 上是同一个文件。后出现的文件改名为 "name (1).ext" 等。
    /// 文件和另一个文件所在的目录同名时，文件改名。
    public static func deduplicated(_ paths: [String]) -> [String] {
        var directories = Set<String>()
        for path in paths {
            let parts = RemotePath.components(of: path, omittingEmpty: false)
            for end in parts.indices.dropLast() {
                directories.insert(key(parts[...end].joined(separator: "/")))
            }
        }
        var used = Set<String>()
        return paths.map { path in
            var candidate = path
            var number = 1
            while directories.contains(key(candidate)) || used.contains(key(candidate)) {
                candidate = numbered(path, number)
                number += 1
            }
            used.insert(key(candidate))
            return candidate
        }
    }

    static func key(_ path: String) -> String {
        path.decomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
            .decomposedStringWithCanonicalMapping
    }

    /// `a/b.tar.gz` → `a/b.tar (1).gz`。以点开头且没有其他点的名字没有扩展名。
    static func numbered(_ path: String, _ number: Int) -> String {
        var parts = RemotePath.components(of: path, omittingEmpty: false)
        let name = parts.removeLast()
        let renamed: String
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            renamed = "\(name[..<dot]) (\(number))\(name[dot...])"
        } else {
            renamed = "\(name) (\(number))"
        }
        return (parts + [renamed]).joined(separator: "/")
    }
}
