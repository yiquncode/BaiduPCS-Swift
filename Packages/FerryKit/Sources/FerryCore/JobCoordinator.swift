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
///
/// 同一任务对下载引擎的操作（加入、暂停、继续）按顺序执行，每个操作执行时重新读取任务的当前状态，
/// 所以暂停和继续交错时，引擎中的状态最终和任务的 `isPaused` 一致。
@MainActor @Observable
public final class JobCoordinator {
    /// 新任务在前。
    public private(set) var jobs: [Job] = []
    /// 引擎中文件下载的最新状态，键是文件下载 id。
    public private(set) var downloads: [String: DownloadSnapshot] = [:]
    public private(set) var settings: FerrySettings
    /// 新任务的下载目录。已有任务使用创建时记录的目录。
    public var downloadFolder: DownloadFolder
    /// 未登录时为 nil。
    public var netdisk: (any Netdisk)?
    /// 启动时任务列表无法读取的说明。界面显示它，用户关闭后清空。
    public private(set) var loadWarning: String?
    /// `start()` 完成前为 false。在此之前，任务操作等待它完成。
    public private(set) var isStarted = false
    /// 正在移除的任务。移除完成前它们仍在 `jobs` 中，但不再接受操作。
    public private(set) var removingJobs: Set<Job.ID> = []
    @ObservationIgnored public var onJobCompleted: ((Job) -> Void)?
    /// 测试用：每个文件下载加入引擎之前调用。
    @ObservationIgnored var willEnqueue: (@MainActor (JobFile) async -> Void)?

    @ObservationIgnored private let engine: DownloadEngine
    @ObservationIgnored private let store: JobStore
    @ObservationIgnored private let baseConfiguration: DownloadConfiguration
    @ObservationIgnored private let folderAccess: any DownloadFolderAccess
    /// 已取得访问权限的任务下载目录。任务完成或移除后交回。
    @ObservationIgnored private var openedFolders: [UUID: OpenedFolder] = [:]
    /// 每个任务的转存或收尾任务。
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// 每个任务最后一个引擎操作。新的操作等它结束后再执行。
    @ObservationIgnored private var lanes: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var reconciling: Set<UUID> = []
    @ObservationIgnored private var finishing: Set<UUID> = []
    @ObservationIgnored private var startWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private let logger = Logger(subsystem: "Ferry", category: "jobs")
    /// 读取任务列表之前不写入，避免覆盖还没读取的文件。
    @ObservationIgnored private var hasLoaded = false
    /// 任务列表无法读取、也无法备份时为 false：这次启动不写入，保留原文件。
    @ObservationIgnored private var canSave = true

    /// - Parameter baseConfiguration: 设置不覆盖的下载参数（分片大小、重试等）。
    public init(engine: DownloadEngine, store: JobStore, settings: FerrySettings, downloadFolder: DownloadFolder,
                folderAccess: any DownloadFolderAccess = SecurityScopedFolderAccess(),
                baseConfiguration: DownloadConfiguration = DownloadConfiguration()) {
        self.engine = engine
        self.store = store
        self.settings = settings
        self.downloadFolder = downloadFolder
        self.folderAccess = folderAccess
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

    /// 读取任务列表，取得未完成任务的下载目录的访问权限，然后恢复引擎中的文件下载。
    public func start() async {
        guard !hasLoaded else { return }
        defer {
            isStarted = true
            let waiters = startWaiters
            startWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        var loaded: [Job]
        var isLoaded = true
        do {
            loaded = try store.load()
        } catch {
            logger.error("cannot read jobs: \(error.localizedDescription)")
            loaded = []
            isLoaded = false
            if let backup = store.moveAsideUnreadableFile() {
                loadWarning = "无法读取任务列表，原文件已备份为“\(backup.lastPathComponent)”。之前的下载进度保留在磁盘上，这次启动不继续也不删除它们。"
            } else {
                canSave = false
                loadWarning = "无法读取任务列表。这次启动不修改任务列表文件，之前的下载进度保留在磁盘上。"
            }
        }
        for index in loaded.indices where loaded[index].phase == .transferring {
            loaded[index].phase = .failed(.transfer)
            loaded[index].error = "应用退出时转存没有完成。"
        }
        // 启动完成前添加的任务排在前面。
        jobs += loaded
        hasLoaded = true

        await engine.updateConfiguration(settings.downloadConfiguration(base: baseConfiguration))
        // 任务列表读不出来时，不知道引擎中的文件下载属于谁。不恢复它们，也不取消它们。
        guard isLoaded else {
            save()
            return
        }
        // 引擎恢复的文件下载要写入这些目录，所以先取得访问权限。
        for job in jobs where job.phase != .completed {
            do {
                _ = try folderURL(for: job.id)
            } catch {
                if job.phase == .downloading {
                    fail(job.id, step: .download, error)
                } else {
                    update(job.id) { $0.error = Self.message(for: error) }
                }
            }
        }
        let restored: [DownloadSnapshot]
        do {
            restored = try await engine.restore()
        } catch {
            logger.error("cannot restore downloads: \(error.localizedDescription)")
            restored = []
        }
        var finished: [String] = []
        for snapshot in restored {
            guard let (jobIndex, fileIndex) = locate(snapshot.id) else {
                await engine.cancel(id: snapshot.id)
                continue
            }
            if case .completed(let url) = snapshot.state {
                // 上次完成后、写入任务列表前应用退出了。
                if jobs[jobIndex].files[fileIndex].localURL == nil {
                    jobs[jobIndex].files[fileIndex].localURL = url
                }
                finished.append(snapshot.id)
            } else {
                downloads[snapshot.id] = snapshot
            }
        }
        save()
        // 完成状态已写入任务列表，引擎不用再保留它们。
        for id in finished {
            await engine.cancel(id: id)
        }
        // 文件列表已保存、但还没交给引擎的文件下载重新加入；任务没暂停时，暂停的文件下载继续。
        for job in jobs where job.phase == .downloading {
            await serially(job.id) { await self.continueDownloads(job.id, resumingFailed: false) }
            evaluate(job.id)
        }
        save()
    }

    public func dismissLoadWarning() {
        loadWarning = nil
    }

    /// 应用退出前调用：停止下载，把已完成的文件下载记入任务，然后保存。
    public func shutdown() async {
        await engine.shutdown()
        for snapshot in await engine.snapshots() {
            if case .completed(let url) = snapshot.state, let (jobIndex, fileIndex) = locate(snapshot.id),
               jobs[jobIndex].files[fileIndex].localURL == nil {
                jobs[jobIndex].files[fileIndex].localURL = url
            }
        }
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
        var job = Job(link: session.link, password: session.password, entries: entries, transferFolder: settings.transferFolder)
        job.downloadFolder = downloadFolder
        jobs.insert(job, at: 0)
        save()
        startTransfer(job.id, session: session, removingExisting: false)
        return job
    }

    public func pause(_ id: Job.ID) async {
        await waitUntilStarted()
        guard let job = activeJob(id), job.phase == .downloading, !job.isPaused else { return }
        update(id) { $0.isPaused = true }
        save()
        await serially(id) { await self.pauseDownloads(id) }
    }

    public func resume(_ id: Job.ID) async {
        await waitUntilStarted()
        guard let job = activeJob(id), job.phase == .downloading, job.isPaused else { return }
        update(id) { $0.isPaused = false }
        save()
        await serially(id) { await self.continueDownloads(id, resumingFailed: false) }
        evaluate(id)
    }

    public func retry(_ id: Job.ID) async {
        await waitUntilStarted()
        guard let job = activeJob(id), case .failed(let step) = job.phase else { return }
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
            await serially(id) { await self.continueDownloads(id, resumingFailed: true) }
            evaluate(id)
        }
    }

    /// 移除任务，取消没有完成的文件下载。已下载的文件留在本地。
    public func remove(_ id: Job.ID) async {
        await waitUntilStarted()
        guard job(id) != nil, !removingJobs.contains(id) else { return }
        removingJobs.insert(id)
        defer { removingJobs.remove(id) }
        if let task = tasks.removeValue(forKey: id) {
            task.cancel()
            await task.value
        }
        // 等已开始的引擎操作结束。之后的操作看到任务正在移除，不再修改引擎。
        await serially(id) {}
        lanes[id] = nil
        // 转存可能在结束前写入了文件列表，所以重新读取任务。
        guard let job = job(id) else { return }
        for file in job.files {
            await engine.cancel(id: file.id)
        }
        jobs.removeAll { $0.id == id }
        save()
        closeFolder(of: id)
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
            await waitUntilStarted()
            await transfer(id, session: session, removingExisting: removingExisting)
        }
    }

    private func transfer(_ id: Job.ID, session: ShareSession?, removingExisting: Bool) async {
        guard let job = activeJob(id) else { return }
        do {
            // 先确认下载目录可以写入，再在网盘中转存。
            _ = try folderURL(for: id)
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
            var warning: String?
            if remoteFiles.isEmpty {
                // 刚转存的文件可能还没出现在列表中。只有确认勾选的都是空目录时，才没有文件需要下载。
                guard try await !containsFiles(job.entries, share: share, netdisk: netdisk) else {
                    throw TransferCheckError.noFiles
                }
                warning = "勾选的目录中没有文件，不需要下载。"
            }
            try Task.checkCancellation()
            guard activeJob(id) != nil else { return }
            let files = try Self.jobFiles(for: remoteFiles, in: job.remoteDirectory)
            update(id) {
                $0.files = files
                $0.phase = .downloading
                $0.isCleanedUp = false
                $0.warning = warning
            }
            save()
            await serially(id) { await self.continueDownloads(id, resumingFailed: false) }
            evaluate(id)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            fail(id, step: .transfer, error)
        }
    }

    /// 转存后的网盘文件 → 文件下载。任何一个文件不在任务子目录中或路径不安全时抛出错误，不静默丢掉文件。
    static func jobFiles(for remoteFiles: [RemoteFile], in remoteDirectory: String) throws -> [JobFile] {
        let relativePaths = try remoteFiles.map { file in
            guard let relativePath = RemotePath.relativePath(of: file.path, in: remoteDirectory) else {
                throw TransferCheckError.outsideJobDirectory(file.path)
            }
            guard LocalPath.isSafe(relativePath) else { throw TransferCheckError.unsafePath(file.path) }
            return relativePath
        }
        return zip(remoteFiles, LocalPath.deduplicated(relativePaths)).map { file, relativePath in
            JobFile(remotePath: file.path, relativePath: relativePath, size: file.size)
        }
    }

    /// 勾选的条目中是否有文件。目录逐层列出，找到第一个文件就停止。
    private func containsFiles(_ entries: [ShareEntry], share: ShareSession, netdisk: any Netdisk) async throws -> Bool {
        var directories: [ShareEntry] = []
        for entry in entries {
            guard entry.isDirectory else { return true }
            directories.append(entry)
        }
        while let directory = directories.popLast() {
            try Task.checkCancellation()
            for child in try await netdisk.listShare(share, directory: directory) {
                guard child.isDirectory else { return true }
                directories.append(child)
            }
        }
        return false
    }

    // MARK: - 下载

    /// 在任务的引擎操作队列中执行 `operation`，等它结束后返回。
    private func serially(_ id: Job.ID, _ operation: @escaping @MainActor () async -> Void) async {
        let previous = lanes[id]
        let task = Task {
            await previous?.value
            await operation()
        }
        lanes[id] = task
        await task.value
    }

    /// 让引擎中的文件下载和任务一致：不在引擎中的加入引擎；任务没暂停时，暂停的继续。
    /// `resumingFailed` 为 true 时失败的也继续（重试）。每处理一个文件都重新读取任务，任务暂停、移除或失败时停止。
    private func continueDownloads(_ id: Job.ID, resumingFailed: Bool) async {
        guard let job = activeJob(id), job.phase == .downloading else { return }
        let files = job.files
        if files.contains(where: { !$0.isCompleted }) {
            do {
                _ = try folderURL(for: id)
            } catch {
                fail(id, step: .download, error)
                return
            }
        }
        for file in files where !file.isCompleted {
            guard !Task.isCancelled, let job = activeJob(id), job.phase == .downloading else { return }
            let state = await engine.snapshot(id: file.id)?.state
            do {
                switch state {
                case nil:
                    try await enqueue(file, of: id)
                case .paused where !job.isPaused:
                    await engine.resume(id: file.id)
                case .failed where resumingFailed && !job.isPaused:
                    await engine.resume(id: file.id)
                default:
                    continue
                }
            } catch {
                fail(id, step: .download, error)
                return
            }
            await refreshSnapshot(file.id)
        }
    }

    /// 事件稍后才到。先记下引擎的当前状态，随后的 `evaluate` 才不会按旧状态判断。
    private func refreshSnapshot(_ fileID: String) async {
        guard let snapshot = await engine.snapshot(id: fileID) else { return }
        if case .completed = snapshot.state { return }
        downloads[fileID] = snapshot
    }

    /// 暂停任务的文件下载。任务在此期间被继续时停止。
    private func pauseDownloads(_ id: Job.ID) async {
        guard let files = activeJob(id)?.files else { return }
        for file in files where !file.isCompleted {
            guard activeJob(id)?.isPaused == true else { return }
            await engine.pause(id: file.id)
            await refreshSnapshot(file.id)
        }
    }

    /// 加入引擎。加入期间任务被暂停时，立即暂停它。
    private func enqueue(_ file: JobFile, of id: Job.ID) async throws {
        await willEnqueue?(file)
        guard activeJob(id) != nil else { return }
        guard let destination = LocalPath.destination(for: file.relativePath, in: try folderURL(for: id)) else {
            throw TransferCheckError.unsafePath(file.relativePath)
        }
        try await engine.enqueue(DownloadRequest(
            id: file.id,
            destination: destination,
            expectedSize: file.size,
            context: BaiduDownloadSource.context(forRemotePath: file.remotePath)
        ))
        if activeJob(id)?.isPaused ?? false {
            await engine.pause(id: file.id)
        }
    }

    private func handle(_ event: DownloadEvent) {
        switch event {
        case .progress(let snapshot):
            guard locate(snapshot.id) != nil else { return }
            downloads[snapshot.id] = snapshot
        case .stateChanged(let snapshot):
            guard let (jobIndex, fileIndex) = locate(snapshot.id) else { return }
            let jobID = jobs[jobIndex].id
            if case .completed(let url) = snapshot.state {
                if jobs[jobIndex].files[fileIndex].localURL == nil {
                    jobs[jobIndex].files[fileIndex].localURL = url
                    save()
                }
                // 完成状态写入任务列表后，引擎才删除这个文件下载的状态。
                let fileID = snapshot.id
                Task { await engine.cancel(id: fileID) }
            }
            downloads[snapshot.id] = snapshot
            evaluate(jobID)
        case .removed(let id):
            downloads[id] = nil
        }
    }

    /// 根据文件下载的状态更新任务的阶段。
    private func evaluate(_ id: Job.ID) {
        guard let job = activeJob(id), job.phase == .downloading, !finishing.contains(id) else { return }
        let pending = job.files.filter { !$0.isCompleted }
        if pending.isEmpty {
            finish(id)
            return
        }
        guard !job.isPaused else { return }
        let states = pending.compactMap { downloads[$0.id]?.state }
        if states.contains(.paused) {
            // 任务没暂停，文件下载却暂停了（例如启动时恢复为暂停）。让它们继续，否则任务一直停在“下载中”。
            reconcile(id)
            return
        }
        // 还有文件下载没加入引擎（例如正在逐个加入）时，结果还没确定。
        guard states.count == pending.count, !states.contains(where: { $0 == .queued || $0 == .running }) else { return }
        let failure = states.lazy.compactMap { state -> DownloadFailure? in
            if case .failed(let failure) = state { failure } else { nil }
        }.first
        if let failure {
            fail(id, step: .download, failure)
        }
    }

    private func reconcile(_ id: Job.ID) {
        guard reconciling.insert(id).inserted else { return }
        Task {
            await serially(id) { await self.continueDownloads(id, resumingFailed: false) }
            reconciling.remove(id)
            evaluate(id)
        }
    }

    /// 全部文件下载完成后，按设置清理，然后标记为已完成。清理失败只记录警告。
    private func finish(_ id: Job.ID) {
        finishing.insert(id)
        tasks[id] = Task {
            defer { finishing.remove(id) }
            if settings.cleanupAfterDownload, let job = activeJob(id), !job.isCleanedUp {
                do {
                    guard let netdisk else { throw CoordinatorError.notLoggedIn }
                    try await netdisk.delete(paths: [job.remoteDirectory])
                    update(id) { $0.isCleanedUp = true }
                } catch {
                    guard !Task.isCancelled else { return }
                    update(id) { $0.warning = "没有删除网盘中的转存文件：" + Self.message(for: error) }
                }
            }
            guard !Task.isCancelled, activeJob(id) != nil else { return }
            update(id) {
                $0.phase = .completed
                $0.isPaused = false
            }
            save()
            closeFolder(of: id)
            if let job = job(id) {
                onJobCompleted?(job)
            }
        }
    }

    // MARK: - 下载目录

    /// 任务下载目录的当前位置。第一次调用时取得访问权限，直到任务完成或移除。
    /// 记录的 bookmark 不可用、但设置中的下载目录是同一位置时，改用设置中的 bookmark（用户重新选择了这个目录）。
    private func folderURL(for id: Job.ID) throws -> URL {
        if let opened = openedFolders[id] { return opened.url }
        guard let job = job(id) else { throw CancellationError() }
        let recorded = job.downloadFolder ?? downloadFolder
        var folder = recorded
        let opened: OpenedFolder
        do {
            opened = try folderAccess.open(recorded)
        } catch {
            guard recorded != downloadFolder, recorded.isSameLocation(as: downloadFolder),
                  let reopened = try? folderAccess.open(downloadFolder) else { throw error }
            folder = downloadFolder
            opened = reopened
        }
        if let renewed = opened.renewedBookmark {
            folder.bookmark = renewed
        }
        if folder != job.downloadFolder {
            update(id) { $0.downloadFolder = folder }
            save()
        }
        openedFolders[id] = opened
        return opened.url
    }

    private func closeFolder(of id: Job.ID) {
        if let opened = openedFolders.removeValue(forKey: id) {
            folderAccess.close(opened)
        }
    }

    // MARK: - 辅助

    private func waitUntilStarted() async {
        guard !isStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    private func fail(_ id: Job.ID, step: Job.Step, _ error: any Error) {
        guard activeJob(id) != nil else { return }
        update(id) {
            $0.phase = .failed(step)
            $0.error = Self.message(for: error)
        }
        save()
    }

    private func job(_ id: Job.ID) -> Job? {
        jobs.first { $0.id == id }
    }

    /// 存在且没有正在移除的任务。
    private func activeJob(_ id: Job.ID) -> Job? {
        removingJobs.contains(id) ? nil : job(id)
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
        guard hasLoaded, canSave else { return }
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

enum TransferCheckError: LocalizedError {
    case noFiles
    case outsideJobDirectory(String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .noFiles:
            "转存后网盘中没有找到文件，可能转存尚未完成，请重试。"
        case .outsideJobDirectory(let path):
            "转存后的文件“\(path)”不在任务子目录中，无法确定保存位置。"
        case .unsafePath(let path):
            "文件路径“\(path)”不能用作本地文件名，下载已停止。"
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
