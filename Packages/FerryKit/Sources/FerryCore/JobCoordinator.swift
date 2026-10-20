import BaiduKit
import DownloadKit
import Foundation
import Observation
import os

/// 一个任务的下载进度汇总。
public struct JobProgress: Sendable, Hashable {
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Double

    public var fractionCompleted: Double {
        totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0
    }

    public var remainingTime: Duration? {
        guard bytesPerSecond > 0, totalBytes > receivedBytes else { return nil }
        return .seconds(Double(totalBytes - receivedBytes) / bytesPerSecond)
    }
}

/// 推进任务：建任务子目录 → 转存 → 列出文件 → 下载 → 清理。它也保存任务列表，并在启动时恢复任务。
@MainActor @Observable
public final class JobCoordinator {
    /// 新任务在前。
    public private(set) var jobs: [Job] = []
    /// 引擎中文件下载的最新状态，键是文件下载 id。
    public private(set) var downloads: [String: DownloadSnapshot] = [:]
    public private(set) var settings: FerrySettings
    /// 新的文件下载保存到这里。已加入引擎的文件下载不受影响。
    public var downloadDirectory: URL
    /// 未登录时为 nil。
    public var netdisk: (any Netdisk)?
    @ObservationIgnored public var onJobCompleted: ((Job) -> Void)?

    @ObservationIgnored private let engine: DownloadEngine
    @ObservationIgnored private let store: JobStore
    @ObservationIgnored private let baseConfiguration: DownloadConfiguration
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var finishing: Set<UUID> = []
    @ObservationIgnored private let logger = Logger(subsystem: "Ferry", category: "jobs")

    /// - Parameter baseConfiguration: 设置不覆盖的下载参数（分片大小、重试等）。
    public init(engine: DownloadEngine, store: JobStore, settings: FerrySettings, downloadDirectory: URL,
                baseConfiguration: DownloadConfiguration = DownloadConfiguration()) {
        self.engine = engine
        self.store = store
        self.settings = settings
        self.downloadDirectory = downloadDirectory
        self.baseConfiguration = baseConfiguration
        let events = engine.events()
        Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    // MARK: - 启动与退出

    /// 读取任务列表，恢复引擎中的文件下载。调用前要取得下载目录的访问权限。
    public func start() async {
        var loaded: [Job]
        do {
            loaded = try store.load()
        } catch {
            logger.error("cannot read jobs: \(error.localizedDescription)")
            loaded = []
        }
        for index in loaded.indices where loaded[index].phase == .transferring {
            loaded[index].phase = .failed(.transfer)
            loaded[index].error = "应用退出时转存没有完成。"
        }
        jobs = loaded

        await engine.updateConfiguration(settings.downloadConfiguration(base: baseConfiguration))
        let restored: [DownloadSnapshot]
        do {
            restored = try await engine.restore()
        } catch {
            logger.error("cannot restore downloads: \(error.localizedDescription)")
            restored = []
        }
        let known = Set(jobs.flatMap { $0.files.map(\.id) })
        for snapshot in restored {
            if known.contains(snapshot.id) {
                downloads[snapshot.id] = snapshot
            } else {
                await engine.cancel(id: snapshot.id)
            }
        }
        // 文件列表已保存、但还没交给引擎的文件下载。
        for job in jobs where job.phase == .downloading {
            let missing = job.files.filter { !$0.isCompleted && downloads[$0.id] == nil }
            do {
                try await enqueue(missing, paused: job.isPaused)
            } catch {
                fail(job.id, step: .download, error)
            }
            evaluate(job.id)
        }
        save()
    }

    /// 应用退出前调用：停止下载并保存进度。
    public func shutdown() async {
        await engine.shutdown()
        save()
    }

    public func updateSettings(_ settings: FerrySettings) async {
        self.settings = settings
        await engine.updateConfiguration(settings.downloadConfiguration(base: baseConfiguration))
    }

    // MARK: - 任务操作

    /// 创建任务并开始转存。`session` 是添加链接时打开的分享会话。
    @discardableResult
    public func addJob(session: ShareSession, entries: [ShareEntry]) -> Job {
        let job = Job(link: session.link, password: session.password, entries: entries, transferFolder: settings.transferFolder)
        jobs.insert(job, at: 0)
        save()
        startTransfer(job.id, session: session, removingExisting: false)
        return job
    }

    public func pause(_ id: Job.ID) async {
        guard let job = job(id), job.phase == .downloading, !job.isPaused else { return }
        update(id) { $0.isPaused = true }
        save()
        for file in job.files where !file.isCompleted {
            await engine.pause(id: file.id)
        }
    }

    public func resume(_ id: Job.ID) async {
        guard let job = job(id), job.phase == .downloading, job.isPaused else { return }
        update(id) { $0.isPaused = false }
        save()
        await continueDownloads(of: job)
    }

    public func retry(_ id: Job.ID) async {
        guard let job = job(id), case .failed(let step) = job.phase else { return }
        switch step {
        case .transfer:
            update(id) {
                $0.phase = .transferring
                $0.error = nil
                $0.files = []
            }
            save()
            // 上次转存可能已经转存了一部分，留下来会产生同名冲突。
            startTransfer(id, session: nil, removingExisting: true)
        case .download:
            update(id) {
                $0.phase = .downloading
                $0.error = nil
                $0.isPaused = false
            }
            save()
            await continueDownloads(of: job)
        }
    }

    /// 移除任务，取消没有完成的文件下载。已下载的文件留在本地。
    public func remove(_ id: Job.ID) async {
        guard let job = job(id) else { return }
        if let task = tasks.removeValue(forKey: id) {
            task.cancel()
            await task.value
        }
        jobs.removeAll { $0.id == id }
        save()
        for file in job.files {
            await engine.cancel(id: file.id)
        }
        if settings.cleanupAfterDownload, !job.isCleanedUp, let netdisk {
            do {
                try await netdisk.delete(paths: [job.remoteDirectory])
            } catch {
                logger.error("cannot delete \(job.remoteDirectory): \(error.localizedDescription)")
            }
        }
    }

    public func progress(of job: Job) -> JobProgress {
        var received: Int64 = 0
        var speed = 0.0
        for file in job.files {
            if file.isCompleted {
                received += file.size
            } else if let snapshot = downloads[file.id] {
                received += snapshot.receivedBytes
                speed += snapshot.bytesPerSecond
            }
        }
        return JobProgress(receivedBytes: received, totalBytes: job.totalBytes, bytesPerSecond: speed)
    }

    // MARK: - 转存

    private func startTransfer(_ id: Job.ID, session: ShareSession?, removingExisting: Bool) {
        tasks[id] = Task {
            await transfer(id, session: session, removingExisting: removingExisting)
        }
    }

    private func transfer(_ id: Job.ID, session: ShareSession?, removingExisting: Bool) async {
        guard let job = job(id) else { return }
        do {
            guard let netdisk else { throw CoordinatorError.notLoggedIn }
            if removingExisting {
                try await netdisk.delete(paths: [job.remoteDirectory])
            }
            let share: ShareSession
            if let session {
                share = session
            } else {
                share = try await netdisk.openShare(job.link, password: job.password)
            }
            try await netdisk.createDirectory(job.remoteDirectory)
            try await netdisk.transfer(share, entries: job.entries, to: job.remoteDirectory)
            let remoteFiles = try await netdisk.listFilesRecursively(job.remoteDirectory)
            try Task.checkCancellation()

            let files = remoteFiles.compactMap { file in
                RemotePath.relativePath(of: file.path, in: job.remoteDirectory)
                    .map { JobFile(remotePath: file.path, relativePath: $0, size: file.size) }
            }
            update(id) {
                $0.files = files
                $0.phase = .downloading
                $0.isCleanedUp = false
            }
            save()
            do {
                try await enqueue(files, paused: false)
            } catch {
                fail(id, step: .download, error)
                return
            }
            evaluate(id)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            fail(id, step: .transfer, error)
        }
    }

    // MARK: - 下载

    private func enqueue(_ files: [JobFile], paused: Bool) async throws {
        for file in files {
            try await engine.enqueue(DownloadRequest(
                id: file.id,
                destination: downloadDirectory.appending(path: file.relativePath),
                expectedSize: file.size,
                context: BaiduDownloadSource.context(forRemotePath: file.remotePath)
            ))
            if paused {
                await engine.pause(id: file.id)
            }
        }
    }

    /// 继续没有完成的文件下载：引擎中的从断点继续，不在引擎中的重新加入。
    private func continueDownloads(of job: Job) async {
        var missing: [JobFile] = []
        for file in job.files where !file.isCompleted {
            if downloads[file.id] == nil {
                missing.append(file)
            } else {
                await engine.resume(id: file.id)
            }
        }
        do {
            try await enqueue(missing, paused: false)
        } catch {
            fail(job.id, step: .download, error)
        }
    }

    private func handle(_ event: DownloadEvent) {
        switch event {
        case .progress(let snapshot):
            guard locate(snapshot.id) != nil else { return }
            downloads[snapshot.id] = snapshot
        case .stateChanged(let snapshot):
            guard let (jobIndex, fileIndex) = locate(snapshot.id) else { return }
            downloads[snapshot.id] = snapshot
            if case .completed(let url) = snapshot.state, jobs[jobIndex].files[fileIndex].localURL == nil {
                jobs[jobIndex].files[fileIndex].localURL = url
                save()
            }
            evaluate(jobs[jobIndex].id)
        case .removed(let id):
            downloads[id] = nil
        }
    }

    /// 根据文件下载的状态更新任务的阶段。
    private func evaluate(_ id: Job.ID) {
        guard let job = job(id), job.phase == .downloading, !finishing.contains(id) else { return }
        let pending = job.files.filter { !$0.isCompleted }
        if pending.isEmpty {
            finish(id)
            return
        }
        guard !job.isPaused else { return }
        let states = pending.compactMap { downloads[$0.id]?.state }
        guard !states.contains(where: { $0 == .queued || $0 == .running }) else { return }
        let failure = states.lazy.compactMap { state -> DownloadFailure? in
            if case .failed(let failure) = state { failure } else { nil }
        }.first
        if let failure {
            fail(id, step: .download, failure)
        }
    }

    /// 全部文件下载完成后，按设置清理，然后标记为已完成。清理失败只记录警告。
    private func finish(_ id: Job.ID) {
        finishing.insert(id)
        tasks[id] = Task {
            defer { finishing.remove(id) }
            if settings.cleanupAfterDownload, let job = job(id), !job.isCleanedUp {
                do {
                    guard let netdisk else { throw CoordinatorError.notLoggedIn }
                    try await netdisk.delete(paths: [job.remoteDirectory])
                    update(id) { $0.isCleanedUp = true }
                } catch {
                    guard !Task.isCancelled else { return }
                    update(id) { $0.warning = "没有删除网盘中的转存文件：" + Self.message(for: error) }
                }
            }
            guard self.job(id) != nil else { return }
            update(id) {
                $0.phase = .completed
                $0.isPaused = false
            }
            save()
            if let job = job(id) {
                onJobCompleted?(job)
            }
        }
    }

    // MARK: - 辅助

    private func fail(_ id: Job.ID, step: Job.Step, _ error: any Error) {
        guard job(id) != nil else { return }
        update(id) {
            $0.phase = .failed(step)
            $0.error = Self.message(for: error)
        }
        save()
    }

    private func job(_ id: Job.ID) -> Job? {
        jobs.first { $0.id == id }
    }

    private func update(_ id: Job.ID, _ body: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        body(&jobs[index])
    }

    private func locate(_ fileID: String) -> (Int, Int)? {
        for (jobIndex, job) in jobs.enumerated() {
            if let fileIndex = job.files.firstIndex(where: { $0.id == fileID }) {
                return (jobIndex, fileIndex)
            }
        }
        return nil
    }

    private func save() {
        do {
            try store.save(jobs)
        } catch {
            logger.error("cannot save jobs: \(error.localizedDescription)")
        }
    }

    static func message(for error: any Error) -> String {
        switch error {
        case let failure as DownloadFailure: failure.message
        case let error as LocalizedError: error.errorDescription ?? error.localizedDescription
        default: error.localizedDescription
        }
    }
}

enum CoordinatorError: LocalizedError {
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: "未登录百度网盘。"
        }
    }
}

extension DownloadFailure {
    public var message: String {
        switch self {
        case .network(let code): "网络错误：" + URLError(code).localizedDescription
        case .httpStatus(let status, _): "服务器返回 HTTP \(status)。"
        case .invalidResponse(let reason): "下载的数据不正确（\(reason)）。"
        case .resolveFailed(let reason): "没有取得下载链接：\(reason)"
        case .fileSystem(let reason): "写入文件失败：\(reason)"
        }
    }
}
