import Foundation

/// 下载一个文件：规划分片、并行下载、重试、保存进度，完成后移到目标路径。
///
/// 它在引擎的 actor 之外运行。数据块在 URLSession 的回调中直接写入临时文件，不经过 actor。
struct FileTransfer: Sendable {
    enum Outcome: Sendable {
        case completed(URL)
        case failed(DownloadFailure)
        case cancelled
    }

    let record: LiveRecord
    let session: URLSession
    let settings: SharedConfiguration
    let store: StateStore
    private let links: LinkProvider

    init(record: LiveRecord, source: any DownloadSource, session: URLSession, settings: SharedConfiguration, store: StateStore) {
        self.record = record
        self.session = session
        self.settings = settings
        self.store = store
        links = LinkProvider(source: source, request: record.request)
    }

    private var temporaryURL: URL { record.request.temporaryURL }
    /// 每次读取最新的设置，所以运行时调整的连接数和重试设置对进行中的下载也生效。
    private var configuration: DownloadConfiguration { settings.value }

    @concurrent func run() async -> Outcome {
        let checkpoints = Task {
            while (try? await Task.sleep(for: configuration.checkpointInterval)) != nil {
                checkpoint()
            }
        }
        let outcome: Outcome
        do {
            try prepareTemporaryFile()
            try await download()
            outcome = .completed(try finalize())
        } catch {
            outcome = Task.isCancelled ? .cancelled : .failed(FetchError(error).failure)
        }
        checkpoints.cancel()
        await checkpoints.value
        if case .completed(let url) = outcome {
            // 先停止检查点，再保存完成记录，所以旧的进度不会覆盖它。
            record.update { $0.completedURL = url }
            try? store.save(record.value)
        } else {
            checkpoint()
        }
        return outcome
    }

    /// 保存当前进度。先把已写入的数据同步到磁盘，所以保存的进度不会超过磁盘上的数据。
    func checkpoint() {
        let snapshot = record.value
        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            defer { try? handle.close() }
            try handle.synchronize()
            try store.save(snapshot)
        } catch {
            // 下次检查点再保存。
        }
    }

    // MARK: - 步骤

    private func prepareTemporaryFile() throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: temporaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw FetchError.disk(error.localizedDescription)
        }
        // 已保存的进度不能超过临时文件的实际长度（例如临时文件被删除了）。
        let resumable = record.value.acceptsRanges != false
        let available = resumable ? Self.fileSize(at: temporaryURL) ?? 0 : 0
        record.update { record in
            guard let segments = record.segments else { return }
            record.segments = segments.map { segment in
                var segment = segment
                segment.received = min(segment.received, max(0, available - segment.start))
                return segment
            }
        }
        if record.value.receivedBytes == 0 {
            guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
                throw FetchError.disk("cannot create \(temporaryURL.path)")
            }
        }
    }

    private func download() async throws {
        while true {
            if record.value.segments == nil {
                try await planSegments()
            }
            do {
                try await downloadSegments()
                return
            } catch FetchError.rangeIgnored {
                // 服务器不支持 Range：退化为单连接，从头下载。
                record.update { record in
                    record.acceptsRanges = false
                    record.segments = [Segment(start: 0, end: record.totalBytes)]
                }
            }
        }
    }

    private func planSegments() async throws {
        var current = record.value
        if current.totalBytes == nil {
            let result = try await retrying { link in try await probe(link) }
            current.totalBytes = result.totalBytes
            current.acceptsRanges = result.acceptsRanges
        }
        let segments = Segment.plan(
            totalBytes: current.totalBytes,
            acceptsRanges: current.acceptsRanges,
            size: configuration.segmentSize
        )
        record.update { record in
            record.totalBytes = current.totalBytes
            record.acceptsRanges = current.acceptsRanges
            record.segments = segments
        }
    }

    /// 最多 `segmentsPerFile` 个连接。一个连接完成一个分片后，领取下一个未完成的分片。
    private func downloadSegments() async throws {
        let pending = record.update { record in
            (record.segments ?? []).indices.filter { !record.segments![$0].isComplete }
        }
        var next = pending.makeIterator()
        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            while true {
                while running < max(1, configuration.segmentsPerFile), let index = next.next() {
                    group.addTask { try await downloadSegment(index) }
                    running += 1
                }
                guard try await group.next() != nil else { return }
                running -= 1
            }
        }
    }

    private func downloadSegment(_ index: Int) async throws {
        try await retrying(progress: { record.segment(index).received }) { link in
            try await fetch(index, link: link)
        }
    }

    private func finalize() throws -> URL {
        let current = record.value
        let expected = current.totalBytes ?? current.receivedBytes
        let size = Self.fileSize(at: temporaryURL)
        guard size == expected else {
            // 无法确定哪部分数据有问题，下次从头下载。
            record.update { record in
                record.segments = nil
                record.totalBytes = record.request.expectedSize
            }
            throw FetchError.invalidResponse("file size \(size ?? 0) does not match \(expected)")
        }
        do {
            return try FileManager.default.moveItem(temporaryURL, toAvailable: record.request.destination)
        } catch {
            throw FetchError.disk(error.localizedDescription)
        }
    }

    // MARK: - 请求

    private func probe(_ link: ResolvedURL) async throws -> (totalBytes: Int64?, acceptsRanges: Bool) {
        let request = makeRequest(link, range: "bytes=0-0")
        let response = try await DataTaskRunner.run(request, session: session, onResponse: { _ in false })
        switch response.statusCode {
        case 206:
            guard let header = response.value(forHTTPHeaderField: "Content-Range"),
                  let range = ContentRange(header), range.first == 0
            else { throw FetchError.invalidResponse("unexpected Content-Range in probe") }
            return (range.total, true)
        case 200:
            let length = response.expectedContentLength
            return (length >= 0 ? length : nil, false)
        default:
            throw FetchError.invalidResponse("unexpected status \(response.statusCode)")
        }
    }

    private func fetch(_ index: Int, link: ResolvedURL) async throws {
        let usesRange = record.value.acceptsRanges != false
        if !usesRange {
            record.update { $0.segments![index].received = 0 }
        }
        let segment = record.segment(index)
        let totalBytes = record.value.totalBytes
        let handle = try openTemporaryFile(at: segment.offset, truncating: !usesRange)
        defer { try? handle.close() }

        let range = usesRange ? "bytes=\(segment.offset)-\(segment.end.map { String($0 - 1) } ?? "")" : nil
        try await DataTaskRunner.run(makeRequest(link, range: range), session: session) { response in
            try Self.validate(response, for: segment, usesRange: usesRange, totalBytes: totalBytes)
            return true
        } onData: { data in
            let count = Int64(data.count)
            if let end = segment.end, record.segment(index).offset + count > end {
                throw FetchError.invalidResponse("response is longer than the requested range")
            }
            do {
                try handle.write(contentsOf: data)
            } catch {
                throw FetchError.disk(error.localizedDescription)
            }
            record.advance(index, by: count)
        }

        let finished = record.segment(index)
        if let end = finished.end {
            guard finished.offset == end else {
                throw FetchError.invalidResponse("response is shorter than the requested range")
            }
        } else {
            record.update { record in
                record.segments![index].end = finished.offset
                record.totalBytes = record.totalBytes ?? finished.offset
            }
        }
    }

    static func validate(_ response: HTTPURLResponse, for segment: Segment, usesRange: Bool, totalBytes: Int64?) throws {
        switch response.statusCode {
        case 206 where usesRange:
            guard let header = response.value(forHTTPHeaderField: "Content-Range"), let range = ContentRange(header) else {
                throw FetchError.invalidResponse("missing Content-Range")
            }
            guard range.first == segment.offset, segment.end.map({ range.last == $0 - 1 }) ?? true else {
                throw FetchError.invalidResponse("unexpected Content-Range \(header)")
            }
            if let total = range.total, let totalBytes, total != totalBytes {
                throw FetchError.invalidResponse("file size changed to \(total)")
            }
        case 200:
            let isWholeFile = segment.offset == 0 && (segment.end == nil || segment.end == totalBytes)
            if usesRange && !isWholeFile {
                // 响应长度等于整个文件，才认为服务器不支持 Range；否则多半是一个错误页面。
                if let totalBytes, response.expectedContentLength == totalBytes {
                    throw FetchError.rangeIgnored
                }
                throw FetchError.invalidResponse("status 200 for a ranged request")
            }
        default:
            throw FetchError.invalidResponse("unexpected status \(response.statusCode)")
        }
        if let end = segment.end, response.expectedContentLength >= 0, response.expectedContentLength != end - segment.offset {
            throw FetchError.invalidResponse("unexpected Content-Length \(response.expectedContentLength)")
        }
    }

    private func makeRequest(_ link: ResolvedURL, range: String?) -> URLRequest {
        var request = URLRequest(url: link.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (field, value) in link.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        // 压缩传输会让收到的字节数和 Range 对不上。
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        return request
    }

    private func openTemporaryFile(at offset: Int64, truncating: Bool) throws -> FileHandle {
        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            if truncating {
                try handle.truncate(atOffset: 0)
            }
            try handle.seek(toOffset: UInt64(offset))
            return handle
        } catch {
            throw FetchError.disk(error.localizedDescription)
        }
    }

    // MARK: - 重试

    /// 运行 `attempt`，失败时按策略重试。`progress` 增加说明这次收到了数据，失败计数重新开始。
    private func retrying<T: Sendable>(
        progress: () -> Int64 = { 0 },
        _ attempt: (ResolvedURL) async throws -> T
    ) async throws -> T {
        var failures = 0
        while true {
            let before = progress()
            var link: LinkProvider.Link?
            do {
                let current = try await links.link()
                link = current
                return try await attempt(current.resolved)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                let error = FetchError(error)
                guard error.isRetryable else { throw error }
                failures = progress() > before ? 1 : failures + 1
                guard failures <= configuration.maxRetries else { throw error }
                if error.invalidatesLink, let link {
                    await links.invalidate(link)
                }
                try await Task.sleep(for: retryDelay(after: failures, throttled: error.isThrottled))
            }
        }
    }

    private func retryDelay(after failures: Int, throttled: Bool) -> Duration {
        let delay = min(configuration.retryBaseDelay * (1 << min(failures - 1, 16)), configuration.retryMaxDelay)
        return throttled ? delay * max(1, configuration.throttleBackoffMultiplier) : delay
    }

    private static func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

/// 一个文件下载的所有分片共用的下载链接。多个分片同时发现链接失效时，只重新获取一次。
actor LinkProvider {
    struct Link: Sendable {
        var resolved: ResolvedURL
        var generation: Int
    }

    private let source: any DownloadSource
    private let request: DownloadRequest
    private var current: Link?
    private var pending: Task<Link, any Error>?
    private var generation = 0

    init(source: any DownloadSource, request: DownloadRequest) {
        self.source = source
        self.request = request
    }

    func link() async throws -> Link {
        if let current { return current }
        let task: Task<Link, any Error>
        if let pending {
            task = pending
        } else {
            generation += 1
            task = Task { [source, request, generation] in
                do {
                    return Link(resolved: try await source.resolve(request), generation: generation)
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    throw FetchError.resolve(message, permanent: error is any PermanentDownloadSourceError)
                }
            }
            pending = task
        }
        do {
            let link = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            if link.generation == generation {
                current = link
            }
            if pending == task { pending = nil }
            return link
        } catch {
            if pending == task { pending = nil }
            throw error
        }
    }

    func invalidate(_ link: Link) {
        if current?.generation == link.generation {
            current = nil
        }
    }
}

extension FileManager {
    /// 把文件移到 `destination`。目标已存在时不覆盖，改用 "name (1).ext"、"name (2).ext" 等。
    ///
    /// 用 `renamex_np` 的 `RENAME_EXCL`：检查和移动是一个原子操作。`moveItem(at:to:)` 先检查再移动，
    /// 两个目标路径相同的下载同时完成时，后移动的文件会覆盖先移动的。临时文件和目标在同一目录，所以不跨卷。
    func moveItem(_ source: URL, toAvailable destination: URL) throws -> URL {
        let directory = destination.deletingLastPathComponent()
        let base = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        var candidate = destination
        var number = 0
        while true {
            if renamex_np(source.path, candidate.path, UInt32(RENAME_EXCL)) == 0 {
                return candidate
            }
            let code = errno
            guard code == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            number += 1
            let name = ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)"
            candidate = directory.appendingPathComponent(name)
        }
    }
}
