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

    public init(downloadDirectoryBookmark: Data? = nil, transferFolder: String = "/Ferry", cleanupAfterDownload: Bool = false,
                maxConcurrentFiles: Int = 1, connectionsPerFile: Int = 1) {
        self.downloadDirectoryBookmark = downloadDirectoryBookmark
        self.transferFolder = transferFolder
        self.cleanupAfterDownload = cleanupAfterDownload
        self.maxConcurrentFiles = maxConcurrentFiles
        self.connectionsPerFile = connectionsPerFile
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
