import Foundation
import Synchronization

/// 通用分片下载引擎：队列、并发、断点续传和持久化。它不知道百度，只通过 `DownloadSource` 获取下载链接。
///
/// 目标路径要在应用持有访问权限的目录中。引擎不处理 security-scoped bookmark。
public actor DownloadEngine {
    private struct Entry {
        let record: LiveRecord
        var state: DownloadState
        /// 传输任务结束（包括取消后的收尾）前不为 nil。不为 nil 时，只有传输任务写状态文件。
        var worker: Task<Void, Never>?
        var meter = SpeedMeter()
    }

    private let store: StateStore
    private let source: any DownloadSource
    private let session: URLSession
    private let ownsSession: Bool
    private let settings: SharedConfiguration
    private var configuration: DownloadConfiguration { settings.value }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let broadcaster = EventBroadcaster()
    private var ticker: Task<Void, Never>?
    private var isShutDown = false

    /// - Parameter session: 为 nil 时引擎自己创建一个不使用缓存和 Cookie 存储的会话。
    public init(
        stateDirectory: URL,
        source: any DownloadSource,
        configuration: DownloadConfiguration = DownloadConfiguration(),
        session: URLSession? = nil
    ) {
        store = StateStore(directory: stateDirectory)
        self.source = source
        settings = SharedConfiguration(configuration)
        self.session = session ?? Self.makeSession()
        ownsSession = session == nil
    }

    deinit {
        if ownsSession {
            session.finishTasksAndInvalidate()
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Cookie 由 DownloadSource 通过请求头给出。
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        // 并发由引擎控制，不让 URLSession 再排队。
        configuration.httpMaximumConnectionsPerHost = 64
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }

    // MARK: - 公开接口

    /// 每次调用返回一个新的事件流。可以有多个订阅者。
    public nonisolated func events() -> AsyncStream<DownloadEvent> {
        broadcaster.stream()
    }

    /// 从状态目录恢复文件下载。已完成、但应用还没有用 `cancel(id:)` 确认的，恢复为 completed，不再下载。
    /// 暂停或失败过的恢复为 paused，其余恢复为 queued 并开始下载。
    /// 调用前，应用要先取得目标目录的访问权限。
    @discardableResult
    public func restore() throws -> [DownloadSnapshot] {
        let records = try store.loadAll().sorted { $0.createdAt < $1.createdAt }
        var restored: [DownloadSnapshot] = []
        for record in records where entries[record.request.id] == nil {
            let state: DownloadState = if let url = record.completedURL {
                .completed(url)
            } else {
                record.isPaused ? .paused : .queued
            }
            let entry = Entry(record: LiveRecord(record), state: state)
            add(entry)
            restored.append(snapshot(of: entry))
        }
        schedule()
        return restored
    }

    /// 加入队列。已有同一 id 的下载（包括已完成的）时不做任何事。
    public func enqueue(_ request: DownloadRequest) throws {
        guard entries[request.id] == nil else { return }
        let record = DownloadRecord(request: request)
        try store.save(record)
        add(Entry(record: LiveRecord(record), state: .queued))
        schedule()
    }

    /// 立即取消进行中的请求，保存进度后返回。
    public func pause(id: String) async {
        guard var entry = entries[id], entry.state == .queued || entry.state == .running else { return }
        entry.state = .paused
        entry.record.isPaused = true
        entries[id] = entry
        emit(.stateChanged(snapshot(of: entry)))
        if let worker = entry.worker {
            worker.cancel()
            await worker.value
        } else {
            try? store.save(entry.record.value)
        }
    }

    /// 让暂停或失败的下载重新排队，从断点继续。
    public func resume(id: String) {
        guard var entry = entries[id] else { return }
        switch entry.state {
        case .paused, .failed: break
        default: return
        }
        entry.state = .queued
        entry.record.isPaused = false
        entries[id] = entry
        if entry.worker == nil {
            try? store.save(entry.record.value)
        }
        emit(.stateChanged(snapshot(of: entry)))
        schedule()
    }

    /// 停止下载，删除临时文件和状态文件。
    ///
    /// 已完成的下载也要调用：引擎在完成后保留状态文件，`restore()` 时把它恢复为 completed，
    /// 直到应用保存了最终路径并调用这个方法确认。这时只删除状态文件，不删除下载好的文件。
    public func cancel(id: String) async {
        guard let entry = entries.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        if let worker = entry.worker {
            worker.cancel()
            await worker.value
        }
        if case .completed = entry.state {} else {
            try? FileManager.default.removeItem(at: entry.record.request.temporaryURL)
        }
        store.delete(id: id)
        emit(.removed(id: id))
        schedule()
    }

    /// 应用退出前调用：停止所有下载并保存进度。进行中的下载下次 `restore()` 时恢复为 queued。
    /// 之后引擎不再开始新的下载。
    public func shutdown() async {
        isShutDown = true
        let workers = entries.values.compactMap(\.worker)
        for worker in workers {
            worker.cancel()
        }
        for worker in workers {
            await worker.value
        }
        ticker?.cancel()
        ticker = nil
    }

    /// 立即生效。调小并发数时不打断进行中的请求，只是不再开始新的。分片大小只影响还没规划分片的下载。
    public func updateConfiguration(_ configuration: DownloadConfiguration) {
        settings.value = configuration
        schedule()
    }

    public func snapshot(id: String) -> DownloadSnapshot? {
        entries[id].map(snapshot(of:))
    }

    /// 按加入队列的顺序。
    public func snapshots() -> [DownloadSnapshot] {
        order.compactMap { entries[$0].map(snapshot(of:)) }
    }

    // MARK: - 调度

    private func add(_ entry: Entry) {
        let id = entry.record.request.id
        entries[id] = entry
        order.append(id)
        emit(.stateChanged(snapshot(of: entry)))
    }

    private func schedule() {
        guard !isShutDown else { return }
        var active = entries.values.count { $0.worker != nil }
        for id in order where active < configuration.maxConcurrentFiles {
            guard let entry = entries[id], entry.state == .queued, entry.worker == nil else { continue }
            start(id)
            active += 1
        }
    }

    private func start(_ id: String) {
        guard var entry = entries[id] else { return }
        let transfer = FileTransfer(
            record: entry.record,
            source: source,
            session: session,
            settings: settings,
            store: store
        )
        entry.state = .running
        entry.meter = SpeedMeter()
        entry.worker = Task {
            let outcome = await transfer.run()
            self.finish(id, outcome)
        }
        entries[id] = entry
        emit(.stateChanged(snapshot(of: entry)))
        startTicker()
    }

    private func finish(_ id: String, _ outcome: FileTransfer.Outcome) {
        guard var entry = entries[id] else { return }
        entry.worker = nil
        switch outcome {
        case .completed(let url):
            // 传输任务已经保存了完成记录。应用调用 cancel(id:) 确认后才删除它。
            entry.state = .completed(url)
        case .failed(let failure):
            entry.state = .failed(failure)
            entry.record.isPaused = true
            try? store.save(entry.record.value)
        case .cancelled:
            if entry.state == .running {
                entry.state = .queued
            }
            try? store.save(entry.record.value)
        }
        entries[id] = entry
        emit(.stateChanged(snapshot(of: entry)))
        schedule()
    }

    // MARK: - 进度

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while let interval = await self?.configuration.progressInterval {
                try? await Task.sleep(for: interval)
                guard let self, await self.tick() else { return }
            }
        }
    }

    /// 发出进行中下载的进度。没有进行中的下载时返回 false，停止计时。
    private func tick() -> Bool {
        let now = ContinuousClock.now
        var isActive = false
        for id in order {
            guard var entry = entries[id], entry.state == .running else { continue }
            isActive = true
            entry.meter.record(entry.record.value.receivedBytes, at: now)
            entries[id] = entry
            emit(.progress(snapshot(of: entry)))
        }
        if !isActive {
            ticker = nil
        }
        return isActive
    }

    private func snapshot(of entry: Entry) -> DownloadSnapshot {
        let record = entry.record.value
        return DownloadSnapshot(
            id: record.request.id,
            state: entry.state,
            totalBytes: record.totalBytes,
            receivedBytes: record.receivedBytes,
            bytesPerSecond: entry.state == .running ? entry.meter.bytesPerSecond : 0
        )
    }

    private func emit(_ event: DownloadEvent) {
        broadcaster.yield(event)
    }
}

/// 最近几秒内的平均速度。
struct SpeedMeter {
    private static let window: Duration = .seconds(5)
    private var samples: [(time: ContinuousClock.Instant, bytes: Int64)] = []

    mutating func record(_ bytes: Int64, at time: ContinuousClock.Instant) {
        samples.append((time, bytes))
        while samples.count > 2, time - samples[1].time >= Self.window {
            samples.removeFirst()
        }
    }

    var bytesPerSecond: Double {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
        return Double(last.bytes - first.bytes) / ((last.time - first.time) / .seconds(1))
    }
}

/// 引擎和进行中的传输任务共用的设置。
final class SharedConfiguration: Sendable {
    private let storage: Mutex<DownloadConfiguration>

    init(_ configuration: DownloadConfiguration) {
        storage = Mutex(configuration)
    }

    var value: DownloadConfiguration {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

/// 把事件发给所有订阅者。
final class EventBroadcaster: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<DownloadEvent>.Continuation]>([:])

    func stream() -> AsyncStream<DownloadEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: DownloadEvent.self)
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { $0[id] = nil }
        }
        continuations.withLock { $0[id] = continuation }
        return stream
    }

    func yield(_ event: DownloadEvent) {
        for continuation in continuations.withLock({ Array($0.values) }) {
            continuation.yield(event)
        }
    }

    deinit {
        for continuation in continuations.withLock({ Array($0.values) }) {
            continuation.finish()
        }
    }
}
