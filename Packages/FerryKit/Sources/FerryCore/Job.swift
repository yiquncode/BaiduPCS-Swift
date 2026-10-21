import BaiduKit
import Foundation

/// 用户勾选条目并点击“下载”后产生的工作单元。分享任务先转存勾选的条目，再把它们下载到本地；网盘任务直接下载。
public struct Job: Codable, Sendable, Hashable, Identifiable {
    /// 任务的来源。创建任务时确定，以后不变。
    public enum Source: Sendable, Hashable {
        /// 分享链接。勾选的条目转存到任务子目录，再从那里下载。
        case share(ShareLink, password: String?, entries: [ShareEntry])
        /// 自己的网盘。直接下载勾选的条目。Ferry 不删除、不移动、不修改它们。
        case netdisk(entries: [NetdiskEntry])

        /// 勾选条目的名字，按勾选的顺序。
        public var names: [String] {
            switch self {
            case .share(_, _, let entries): entries.map(\.name)
            case .netdisk(let entries): entries.map(\.name)
            }
        }

        /// 只勾选了一个文件。
        public var isSingleFile: Bool {
            switch self {
            case .share(_, _, let entries): entries.count == 1 && !entries[0].isDirectory
            case .netdisk(let entries): entries.count == 1 && !entries[0].isDirectory
            }
        }
    }

    public enum Phase: Codable, Sendable, Hashable {
        /// 分享任务：转存中。网盘任务：准备中（列出勾选的目录）。
        case transferring
        case downloading
        case completed
        case failed(Step)
    }

    /// 失败发生的步骤。它决定重试从哪里开始。
    public enum Step: String, Codable, Sendable, Hashable {
        /// 分享任务：建目录、转存或列出转存后的文件。重试时删除任务子目录，重新转存。
        /// 网盘任务：列出勾选的目录（准备）。重试时只重新列出，不删除。
        case transfer
        /// 文件下载。重试时只继续没有完成的文件下载。
        case download
    }

    public var id: UUID
    public var title: String
    public let source: Source
    /// 网盘中这个任务的子目录：`<转存目录>/<短 ID>`。只有分享任务有，网盘任务为空。
    public let remoteDirectory: String
    public var phase: Phase
    /// 转存（网盘任务：准备）完成后才有内容。
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
    /// 创建任务时登录的账号的 uk。转存到的、或者下载的是这个账号的网盘。旧版本创建的任务为 nil。
    public var accountUK: Int64?

    /// 分享任务。
    public init(link: ShareLink, password: String?, entries: [ShareEntry], transferFolder: String,
                id: UUID = UUID(), createdAt: Date = .now) {
        self.init(source: .share(link, password: password, entries: entries),
                  remoteDirectory: RemotePath.join(RemotePath.normalized(transferFolder), Self.shortID(id)),
                  id: id, createdAt: createdAt)
    }

    /// 网盘任务。它没有任务子目录。
    public init(netdiskEntries entries: [NetdiskEntry], id: UUID = UUID(), createdAt: Date = .now) {
        self.init(source: .netdisk(entries: entries), remoteDirectory: "", id: id, createdAt: createdAt)
    }

    private init(source: Source, remoteDirectory: String, id: UUID, createdAt: Date) {
        self.id = id
        self.source = source
        title = Self.title(for: source.names)
        self.remoteDirectory = remoteDirectory
        phase = .transferring
        files = []
        isPaused = false
        self.createdAt = createdAt
        isCleanedUp = false
    }

    /// 来源的分享链接。网盘任务为 nil。
    public var link: ShareLink? {
        if case .share(let link, _, _) = source { link } else { nil }
    }

    /// 分享的提取码。网盘任务为 nil。
    public var password: String? {
        if case .share(_, let password, _) = source { password } else { nil }
    }

    /// 网盘中有这个任务的子目录：分享任务转存到它，清理时删除它。网盘任务没有，所以 Ferry 不对它调用 `Netdisk.delete`。
    public var hasJobDirectory: Bool {
        if case .share = source { !remoteDirectory.isEmpty } else { false }
    }

    /// 任务列表中 `source` 键的值。没有这个键时（旧版本保存的任务）是分享任务。
    private enum SourceKind: String, Codable {
        case share
        case netdisk
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, source, link, password, entries, remoteDirectory, phase, files, isPaused, error, warning,
             createdAt, isCleanedUp, downloadFolder, accountUK
    }

    /// 缺少的字段用默认值，以后新增字段时，旧版本保存的任务列表仍能读取。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        switch try container.decodeIfPresent(SourceKind.self, forKey: .source) ?? .share {
        case .share:
            let link = try container.decode(ShareLink.self, forKey: .link)
            let password = try container.decodeIfPresent(String.self, forKey: .password)
            let entries = try container.decodeIfPresent([ShareEntry].self, forKey: .entries) ?? []
            source = .share(link, password: password, entries: entries)
            remoteDirectory = try container.decode(String.self, forKey: .remoteDirectory)
        case .netdisk:
            source = .netdisk(entries: try container.decodeIfPresent([NetdiskEntry].self, forKey: .entries) ?? [])
            // 网盘任务没有任务子目录。不读取文件中的值，所以 `remoteDirectory` 一定为空。
            remoteDirectory = ""
        }
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? Self.title(for: source.names)
        // 不知道任务进行到哪里时，按转存失败处理，用户可以重试。
        phase = try container.decodeIfPresent(Phase.self, forKey: .phase) ?? .failed(.transfer)
        files = try container.decodeIfPresent([JobFile].self, forKey: .files) ?? []
        isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        error = try container.decodeIfPresent(String.self, forKey: .error)
        warning = try container.decodeIfPresent(String.self, forKey: .warning)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        isCleanedUp = try container.decodeIfPresent(Bool.self, forKey: .isCleanedUp) ?? false
        downloadFolder = try container.decodeIfPresent(DownloadFolder.self, forKey: .downloadFolder)
        accountUK = try container.decodeIfPresent(Int64.self, forKey: .accountUK)
    }

    /// 分享任务的 `link`、`password`、`entries` 和 `remoteDirectory` 仍在顶层，和旧版本相同，只多了 `source`。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        switch source {
        case .share(let link, let password, let entries):
            try container.encode(SourceKind.share, forKey: .source)
            try container.encode(link, forKey: .link)
            try container.encodeIfPresent(password, forKey: .password)
            try container.encode(entries, forKey: .entries)
            try container.encode(remoteDirectory, forKey: .remoteDirectory)
        case .netdisk(let entries):
            try container.encode(SourceKind.netdisk, forKey: .source)
            try container.encode(entries, forKey: .entries)
        }
        try container.encode(title, forKey: .title)
        try container.encode(phase, forKey: .phase)
        try container.encode(files, forKey: .files)
        try container.encode(isPaused, forKey: .isPaused)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(warning, forKey: .warning)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isCleanedUp, forKey: .isCleanedUp)
        try container.encodeIfPresent(downloadFolder, forKey: .downloadFolder)
        try container.encodeIfPresent(accountUK, forKey: .accountUK)
    }

    public static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).uppercased()
    }

    static func title(for names: [String]) -> String {
        guard let first = names.first else { return "" }
        return names.count == 1 ? first : "\(first) 等 \(names.count) 项"
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
    /// 相对于下载目录的路径。分享任务保留分享中的目录结构；网盘任务从勾选的条目开始，不含它在网盘中的上层目录。
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

    /// 网盘路径去掉 `directory` 前缀（任务子目录，或网盘任务中勾选条目的上层目录），得到本地相对路径。
    /// 不在 `directory` 中时返回 nil。
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

    /// 上层目录。`/a/b` → `/a`，`/a` → `/`。
    public static func parent(of path: String) -> String {
        "/" + components(of: path, omittingEmpty: true).dropLast().joined(separator: "/")
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
