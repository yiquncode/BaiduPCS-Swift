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
    public static func relativePath(of path: String, in directory: String) -> String? {
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}
