import Foundation

/// 任务的下载目录。用户选择的目录带 app-scope 的 security-scoped bookmark；系统的“下载”目录只记路径。
public struct DownloadFolder: Codable, Sendable, Hashable {
    public var url: URL
    public var bookmark: Data?

    public init(url: URL, bookmark: Data? = nil) {
        self.url = url
        self.bookmark = bookmark
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(URL.self, forKey: .url)
        bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
    }

    func isSameLocation(as other: DownloadFolder) -> Bool {
        url.standardizedFileURL.path == other.url.standardizedFileURL.path
    }
}

/// 取得一个下载目录的访问权限后得到的结果。`close` 时交回。
public struct OpenedFolder: Sendable, Hashable {
    /// 目录的当前位置。bookmark 解析后可能和保存的路径不同（目录被移动过）。
    public var url: URL
    /// bookmark 过期时重新生成的 bookmark。
    public var renewedBookmark: Data?
    /// 是否调用过 `startAccessingSecurityScopedResource()`。
    public var isSecurityScoped: Bool

    public init(url: URL, renewedBookmark: Data? = nil, isSecurityScoped: Bool = false) {
        self.url = url
        self.renewedBookmark = renewedBookmark
        self.isSecurityScoped = isSecurityScoped
    }
}

/// 下载目录的访问权限。应用使用 `SecurityScopedFolderAccess`；测试用假实现。
public protocol DownloadFolderAccess: Sendable {
    /// 解析 bookmark 并开始访问。目录不存在或无法访问时抛出 `DownloadFolderError`。
    func open(_ folder: DownloadFolder) throws -> OpenedFolder
    func close(_ folder: OpenedFolder)
}

public struct SecurityScopedFolderAccess: DownloadFolderAccess {
    public init() {}

    public func open(_ folder: DownloadFolder) throws -> OpenedFolder {
        var opened = OpenedFolder(url: folder.url)
        if let bookmark = folder.bookmark {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
            else { throw DownloadFolderError.inaccessible(folder.url) }
            guard url.startAccessingSecurityScopedResource() else { throw DownloadFolderError.inaccessible(folder.url) }
            opened.url = url
            opened.isSecurityScoped = true
            if isStale {
                opened.renewedBookmark = try? url.bookmarkData(options: .withSecurityScope)
            }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: opened.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            close(opened)
            throw DownloadFolderError.inaccessible(folder.url)
        }
        return opened
    }

    public func close(_ folder: OpenedFolder) {
        if folder.isSecurityScoped {
            folder.url.stopAccessingSecurityScopedResource()
        }
    }
}

public enum DownloadFolderError: LocalizedError, Equatable {
    case inaccessible(URL)

    public var errorDescription: String? {
        switch self {
        case .inaccessible(let url):
            "下载目录“\(url.path(percentEncoded: false))”不可访问。请在设置中重新选择这个目录，然后重试。"
        }
    }
}
