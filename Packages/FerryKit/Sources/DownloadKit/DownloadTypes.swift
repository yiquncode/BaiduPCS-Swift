import Foundation

/// 一个文件下载。引擎把它原样保存在状态文件中。
public struct DownloadRequest: Codable, Sendable, Hashable {
    /// 由应用层分配，全局唯一。它也决定状态文件名，所以不要太长（UUID 即可）。
    public var id: String
    /// 最终文件路径。已有同名文件时，引擎在文件名后加 " (1)" 等后缀。
    public var destination: URL
    /// 已知就填；未知时引擎先探测。
    public var expectedSize: Int64?
    /// 应用层自定义的数据。应用重启后，`DownloadSource` 用它重新获取下载链接。
    public var context: Data

    public init(id: String, destination: URL, expectedSize: Int64? = nil, context: Data = Data()) {
        self.id = id
        self.destination = destination
        self.expectedSize = expectedSize
        self.context = context
    }
}

/// 一个可用的下载链接，以及每个请求都要带上的请求头（例如 Cookie、User-Agent）。
public struct ResolvedURL: Sendable, Hashable {
    public var url: URL
    public var headers: [String: String]

    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }
}

public protocol DownloadSource: Sendable {
    /// 返回当前可用的下载链接。下载链接失效时，引擎会再次调用。
    func resolve(_ request: DownloadRequest) async throws -> ResolvedURL
}

/// `DownloadSource.resolve` 抛出遵循这个协议的错误时，重试也不会成功（例如登录失效、文件不存在）。
/// 引擎不再重试，文件下载直接进入 failed。
public protocol PermanentDownloadSourceError: Error {}

/// 分片大小。分片是领取式的：一个连接下载完一个分片，就领取下一个未完成的分片。
public enum SegmentSize: Sendable, Hashable {
    /// 按文件大小选择：小于 5 MB 用 256 KB，5–10 MB 用 512 KB，10–15 MB 用 1 MB，更大用 4 MB。
    case automatic
    case fixed(Int64)

    func bytes(forFileSize size: Int64) -> Int64 {
        switch self {
        case .fixed(let bytes):
            return max(1, bytes)
        case .automatic:
            let megabyte: Int64 = 1 << 20
            switch size {
            case ..<(5 * megabyte): return 256 << 10
            case ..<(10 * megabyte): return 512 << 10
            case ..<(15 * megabyte): return megabyte
            default: return 4 * megabyte
            }
        }
    }
}

public struct DownloadConfiguration: Sendable, Hashable {
    /// 同时下载的文件数。
    public var maxConcurrentFiles: Int
    /// 每个文件的并发连接数。百度对非会员的多连接下载会长时间限速，所以默认是 1。
    public var segmentsPerFile: Int
    public var segmentSize: SegmentSize
    /// 连续失败多少次后放弃。收到数据后重新计数。
    public var maxRetries: Int
    public var retryBaseDelay: Duration
    public var retryMaxDelay: Duration
    /// 服务器限流（429、509）时，退避时间乘以这个倍数。
    public var throttleBackoffMultiplier: Int
    public var progressInterval: Duration
    /// 下载中保存进度的间隔。
    public var checkpointInterval: Duration

    public init(
        maxConcurrentFiles: Int = 1,
        segmentsPerFile: Int = 1,
        segmentSize: SegmentSize = .automatic,
        maxRetries: Int = 5,
        retryBaseDelay: Duration = .seconds(1),
        retryMaxDelay: Duration = .seconds(30),
        throttleBackoffMultiplier: Int = 10,
        progressInterval: Duration = .milliseconds(500),
        checkpointInterval: Duration = .seconds(3)
    ) {
        self.maxConcurrentFiles = maxConcurrentFiles
        self.segmentsPerFile = segmentsPerFile
        self.segmentSize = segmentSize
        self.maxRetries = maxRetries
        self.retryBaseDelay = retryBaseDelay
        self.retryMaxDelay = retryMaxDelay
        self.throttleBackoffMultiplier = throttleBackoffMultiplier
        self.progressInterval = progressInterval
        self.checkpointInterval = checkpointInterval
    }
}

public enum DownloadFailure: Error, Sendable, Hashable {
    case network(URLError.Code)
    /// `message` 是响应体的开头。百度出错时会在这里给出 error_code 和 error_msg。
    case httpStatus(Int, message: String)
    case invalidResponse(String)
    case resolveFailed(String)
    case fileSystem(String)
}

public enum DownloadState: Sendable, Hashable {
    case queued
    case running
    case paused
    /// 关联值是最终文件路径。它可能和 `destination` 不同（见 `DownloadRequest.destination`）。
    case completed(URL)
    /// 临时文件和进度都保留。`resume(id:)` 从断点继续。
    case failed(DownloadFailure)
}

public struct DownloadSnapshot: Sendable, Hashable {
    public var id: String
    public var state: DownloadState
    public var totalBytes: Int64?
    public var receivedBytes: Int64
    public var bytesPerSecond: Double
}

public enum DownloadEvent: Sendable, Hashable {
    case stateChanged(DownloadSnapshot)
    case progress(DownloadSnapshot)
    /// `cancel(id:)` 后发出。
    case removed(id: String)
}
