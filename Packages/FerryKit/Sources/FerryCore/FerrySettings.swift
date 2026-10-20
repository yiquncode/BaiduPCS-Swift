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
        limitConcurrency()
    }

    public static let concurrentFilesRange = 1...10
    public static let connectionsRange = 1...16
    /// 同时下载文件数乘以每个文件的连接数的上限。
    public static let totalConnectionsLimit = 20

    /// 按当前的每个文件的连接数，同时下载文件数可以取的值。
    public var allowedConcurrentFiles: ClosedRange<Int> {
        Self.concurrentFilesRange.clamped(to: 1...max(1, Self.totalConnectionsLimit / max(1, connectionsPerFile)))
    }

    /// 按当前的同时下载文件数，每个文件的连接数可以取的值。
    public var allowedConnections: ClosedRange<Int> {
        Self.connectionsRange.clamped(to: 1...max(1, Self.totalConnectionsLimit / max(1, maxConcurrentFiles)))
    }

    /// 两项超出范围时先保留同时下载文件数，再减少每个文件的连接数。
    public mutating func limitConcurrency() {
        maxConcurrentFiles = maxConcurrentFiles.clamped(to: Self.concurrentFilesRange)
        connectionsPerFile = connectionsPerFile.clamped(to: allowedConnections)
    }

    /// 当前两项等于的预设。不等于任何预设时为 `nil`。
    public var concurrencyPreset: ConcurrencyPreset? {
        ConcurrencyPreset.allCases.first {
            $0.maxConcurrentFiles == maxConcurrentFiles && $0.connectionsPerFile == connectionsPerFile
        }
    }

    public mutating func apply(_ preset: ConcurrencyPreset) {
        maxConcurrentFiles = preset.maxConcurrentFiles
        connectionsPerFile = preset.connectionsPerFile
    }

    /// 只覆盖并发设置，其余沿用 `base`。
    public func downloadConfiguration(base: DownloadConfiguration = DownloadConfiguration()) -> DownloadConfiguration {
        var limited = self
        limited.limitConcurrency()
        var configuration = base
        configuration.maxConcurrentFiles = limited.maxConcurrentFiles
        configuration.segmentsPerFile = limited.connectionsPerFile
        return configuration
    }
}

/// 按网盘会员类型给出的同时下载文件数和每个文件的连接数。
public enum ConcurrencyPreset: CaseIterable, Sendable {
    /// 非超级会员（包括普通会员）。使用多个连接会被限速。
    case regular
    /// 超级会员。参考实现建议同时下载 1 到 2 个文件，总连接数不超过 12。
    case svip

    public var maxConcurrentFiles: Int {
        switch self {
        case .regular: 1
        case .svip: 2
        }
    }

    public var connectionsPerFile: Int {
        switch self {
        case .regular: 1
        case .svip: 6
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
