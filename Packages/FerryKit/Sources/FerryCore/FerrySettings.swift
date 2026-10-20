import DownloadKit
import Foundation

/// 用户设置。
public struct FerrySettings: Codable, Sendable, Hashable {
    /// 用户选择的下载目录的 security-scoped bookmark。nil 表示使用系统的“下载”目录。
    public var downloadDirectoryBookmark: Data?
    public var transferFolder: String
    /// 下载完成后删除网盘中的任务子目录。
    public var cleanupAfterDownload: Bool
    public var maxConcurrentFiles: Int
    public var connectionsPerFile: Int
    public var proxy: ProxySettings
    /// 切换到 Ferry 时，剪贴板中有新复制的分享链接就打开“添加链接”。
    public var detectsCopiedLinks: Bool

    public init(downloadDirectoryBookmark: Data? = nil, transferFolder: String = "/Ferry", cleanupAfterDownload: Bool = false,
                maxConcurrentFiles: Int = 1, connectionsPerFile: Int = 1, proxy: ProxySettings = ProxySettings(),
                detectsCopiedLinks: Bool = true) {
        self.downloadDirectoryBookmark = downloadDirectoryBookmark
        self.transferFolder = transferFolder
        self.cleanupAfterDownload = cleanupAfterDownload
        self.maxConcurrentFiles = maxConcurrentFiles
        self.connectionsPerFile = connectionsPerFile
        self.proxy = proxy
        self.detectsCopiedLinks = detectsCopiedLinks
    }

    /// 缺少或无法解码的字段用默认值，一个字段出错不会丢掉其他设置（例如下载目录的 bookmark）。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil
        }
        let defaults = FerrySettings()
        downloadDirectoryBookmark = value(.downloadDirectoryBookmark)
        transferFolder = value(.transferFolder) ?? defaults.transferFolder
        cleanupAfterDownload = value(.cleanupAfterDownload) ?? defaults.cleanupAfterDownload
        maxConcurrentFiles = value(.maxConcurrentFiles) ?? defaults.maxConcurrentFiles
        connectionsPerFile = value(.connectionsPerFile) ?? defaults.connectionsPerFile
        proxy = value(.proxy) ?? defaults.proxy
        detectsCopiedLinks = value(.detectsCopiedLinks) ?? defaults.detectsCopiedLinks
    }

    public static let concurrentFilesRange = 1...10
    public static let connectionsRange = 1...16

    /// 只覆盖并发设置，其余沿用 `base`。
    public func downloadConfiguration(base: DownloadConfiguration = DownloadConfiguration()) -> DownloadConfiguration {
        var configuration = base
        configuration.maxConcurrentFiles = maxConcurrentFiles.clamped(to: Self.concurrentFilesRange)
        configuration.segmentsPerFile = connectionsPerFile.clamped(to: Self.connectionsRange)
        return configuration
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
