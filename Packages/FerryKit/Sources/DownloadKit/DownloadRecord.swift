import Foundation
import Synchronization

/// 文件中的一段字节范围 `[start, end)`。
struct Segment: Codable, Sendable, Hashable {
    var start: Int64
    /// nil 表示一直读到服务器关闭连接（文件大小未知）。
    var end: Int64?
    var received: Int64 = 0

    var offset: Int64 { start + received }
    var isComplete: Bool { end.map { offset >= $0 } ?? false }

    static func plan(totalBytes: Int64?, acceptsRanges: Bool?, size: SegmentSize) -> [Segment] {
        guard let totalBytes, acceptsRanges != false else {
            return [Segment(start: 0, end: totalBytes)]
        }
        let length = size.bytes(forFileSize: totalBytes)
        return stride(from: 0, to: totalBytes, by: Int(length)).map {
            Segment(start: $0, end: min($0 + length, totalBytes))
        }
    }
}

/// 一个文件下载的持久化状态，以 JSON 保存在状态目录中。
struct DownloadRecord: Codable, Sendable {
    var request: DownloadRequest
    var createdAt: Date
    var totalBytes: Int64?
    /// nil 表示还不知道服务器是否支持 Range。
    var acceptsRanges: Bool?
    /// nil 表示还没有规划分片。
    var segments: [Segment]?
    var isPaused: Bool

    init(request: DownloadRequest) {
        self.request = request
        createdAt = .now
        totalBytes = request.expectedSize
        isPaused = false
    }

    var receivedBytes: Int64 {
        segments?.reduce(0) { $0 + $1.received } ?? 0
    }
}

extension DownloadRequest {
    var temporaryURL: URL { destination.appendingPathExtension("ferrydownload") }
}

/// 线程安全的 `DownloadRecord`。下载进行中时，传输任务每收到一块数据就更新它，引擎读取它报告进度。
final class LiveRecord: Sendable {
    let request: DownloadRequest
    private let storage: Mutex<DownloadRecord>

    init(_ record: DownloadRecord) {
        request = record.request
        storage = Mutex(record)
    }

    var value: DownloadRecord { storage.withLock { $0 } }

    var isPaused: Bool {
        get { storage.withLock { $0.isPaused } }
        set { storage.withLock { $0.isPaused = newValue } }
    }

    func update<T: Sendable>(_ body: (inout DownloadRecord) -> T) -> T {
        storage.withLock { body(&$0) }
    }

    func segment(_ index: Int) -> Segment {
        storage.withLock { $0.segments![index] }
    }

    func advance(_ index: Int, by count: Int64) {
        storage.withLock { $0.segments![index].received += count }
    }
}

/// 状态目录中每个文件下载一个 JSON 文件。
struct StateStore: Sendable {
    let directory: URL

    func save(_ record: DownloadRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: fileURL(for: record.request.id), options: .atomic)
    }

    func delete(id: String) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    /// 读不出的文件跳过。
    func loadAll() throws -> [DownloadRecord] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(DownloadRecord.self, from: Data(contentsOf: $0)) }
    }

    func fileURL(for id: String) -> URL {
        // 十六进制编码：任意 id 都能做文件名，在不区分大小写的文件系统上也不会冲突。
        let name = id.utf8.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }
}
