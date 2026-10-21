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

/// 推进任务。分享任务：建任务子目录 → 转存 → 列出文件 → 下载 → 清理。网盘任务：列出文件（准备）→ 下载。
/// 它也保存任务列表，并在启动时恢复任务。
///
/// 网盘任务的源文件是用户自己的文件。对网盘任务不调用 `Netdisk.delete`：删除只经过 `deleteJobDirectory(of:using:)`。
///
/// 同一任务对下载引擎的操作（加入、暂停、继续）按顺序执行，每个操作执行时重新读取任务的当前状态，
/// 所以暂停和继续交错时，引擎中的状态最终和任务的 `isPaused` 一致。
@MainActor @Observable
public final class JobCoordinator {
    /// 新任务在前。
    public private(set) var jobs: [Job] = []
    /// 引擎中文件下载的最新状态，键是文件下载 id。界面不直接观察它（进度每 0.5 秒变化一次），
    /// 而是观察 `activity(of:)` 和 `activity(ofFile:)`。
    @ObservationIgnored public private(set) var downloads: [String: DownloadSnapshot] = [:]
    public private(set) var settings: FerrySettings
    /// 新任务的下载目录。已有任务使用创建时记录的目录。
    public var downloadFolder: DownloadFolder
    /// 未登录时为 nil。
    public var netdisk: (any Netdisk)?
    /// 当前登录账号的 uk。未登录时为 nil。
    public var accountUK: Int64?
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
    /// 把一个文件或目录移到废纸篓。测试用它代替系统的废纸篓。
    @ObservationIgnored private let trashItem: @Sendable (URL) throws -> Void
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
    /// 进度类变化（文件下载完成）延迟这么久再合并保存。阶段变化立即保存。
    @ObservationIgnored var saveDelay: Duration = .seconds(1)
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// 完成状态写入任务列表后，要从引擎取消的文件下载。
    @ObservationIgnored private var cancelAfterSave: [String] = []
    /// 测试用：写入任务列表的次数。
    @ObservationIgnored private(set) var saveCount = 0
    /// 文件下载 id → (任务 id, 文件下标)。任务列表或文件列表变化后重建。
    @ObservationIgnored private var fileLocations: [String: (job: UUID, file: Int)] = [:]
    @ObservationIgnored private var jobIndices: [UUID: Int] = [:]
    /// 每个任务的计数。和索引一起重建，文件下载变化时增量更新（见 `changeFile`）。
    @ObservationIgnored private var tallies: [UUID: JobTally] = [:]
    @ObservationIgnored private var isIndexStale = true
    /// 测试用：每次更新计数后，从头重新计算并比较，不一致时调用。为 nil 时不比较。
    @ObservationIgnored var tallyMismatchHandler: ((String) -> Void)?
    @ObservationIgnored private var jobActivities: [UUID: JobActivity] = [:]
    @ObservationIgnored private var fileActivities: [String: FileActivity] = [:]
    @ObservationIgnored private var changedJobs: Set<UUID> = []
    @ObservationIgnored private var isActivityUpdateScheduled = false

    /// - Parameter baseConfiguration: 设置不覆盖的下载参数（分片大小、重试等）。
    public init(engine: DownloadEngine, store: JobStore, settings: FerrySettings, downloadFolder: DownloadFolder,
                folderAccess: any DownloadFolderAccess = SecurityScopedFolderAccess(),
                trashItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                baseConfiguration: DownloadConfiguration = DownloadConfiguration()) {
        self.engine = engine
        self.store = store
        self.settings = settings
        self.downloadFolder = downloadFolder
        self.folderAccess = folderAccess
        self.trashItem = trashItem
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
            loaded[index].error = loaded[index].link != nil ? "应用退出时转存没有完成。" : "应用退出时准备没有完成。"
        }
        // 启动完成前添加的任务排在前面。
        jobs += loaded
        invalidateIndex()
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
            guard locate(snapshot.id) != nil else {
                await engine.cancel(id: snapshot.id)
                continue
            }
            if case .completed(let url) = snapshot.state {
                // 上次完成后、写入任务列表前应用退出了。
                recordCompletion(of: snapshot.id, at: url)
                finished.append(snapshot.id)
            } else {
                setSnapshot(snapshot.id, snapshot)
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

    #if DEBUG
    /// 截图用：代替 `start()`，显示给定的任务和文件下载状态。不读取也不保存任务列表，不交给引擎。
    public func showDemo(jobs: [Job], downloads: [DownloadSnapshot]) {
        guard !hasLoaded else { return }
        hasLoaded = true
        canSave = false
        self.jobs = jobs
        invalidateIndex()
        for snapshot in downloads {
            setSnapshot(snapshot.id, snapshot)
        }
        isStarted = true
    }
    #endif

    /// 应用退出前调用：停止下载，把已完成的文件下载记入任务，然后保存。
    public func shutdown() async {
        await engine.shutdown()
        for snapshot in await engine.snapshots() {
            if case .completed(let url) = snapshot.state {
                recordCompletion(of: snapshot.id, at: url)
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
    /// - Parameter downloadFolder: 用户为这个任务选择的下载目录。nil 时使用 `self.downloadFolder`（设置中的下载目录）。
    @discardableResult
    public func addJob(session: ShareSession, entries: [ShareEntry], downloadFolder: DownloadFolder? = nil) -> Job {
        var job = Job(link: session.link, password: session.password, entries: entries, transferFolder: settings.transferFolder)
        job.downloadFolder = downloadFolder ?? self.downloadFolder
        job.accountUK = accountUK
        jobs.insert(job, at: 0)
        invalidateIndex()
        save()
        startTransfer(job.id, session: session, removingExisting: false)
        return job
    }

    /// 创建网盘任务并开始准备：列出勾选的目录，然后直接下载。不转存，也不修改网盘中的文件。
    /// - Parameters:
    ///   - accountUK: 勾选的条目所在的网盘的账号。它不是当前账号时，任务按另一个账号的任务处理，不列出也不下载。
    ///   - downloadFolder: 用户为这个任务选择的下载目录。nil 时使用 `self.downloadFolder`（设置中的下载目录）。
    @discardableResult
    public func addNetdiskJob(entries: [NetdiskEntry], accountUK: Int64, downloadFolder: DownloadFolder? = nil) -> Job {
        var job = Job(netdiskEntries: entries)
        job.downloadFolder = downloadFolder ?? self.downloadFolder
        job.accountUK = accountUK
        jobs.insert(job, at: 0)
        invalidateIndex()
        save()
        startTransfer(job.id, session: nil, removingExisting: false)
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
            invalidateIndex()
            markChanged(id)
            save()
            // 分享任务：上次转存可能已经转存了一部分，留下来会产生同名冲突。网盘任务只重新列出，不删除。
            startTransfer(id, session: nil, removingExisting: job.hasJobDirectory)
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

    /// 移除任务，取消没有完成的文件下载。`trashingFiles` 为 true 时把已下载的文件移到废纸篓（见 `JobFileTrash`），
    /// 否则它们留在本地。
    /// - Returns: 没能移到废纸篓的文件或目录。
    @discardableResult
    public func remove(_ id: Job.ID, trashingFiles: Bool = false) async -> [URL] {
        await waitUntilStarted()
        guard job(id) != nil, !removingJobs.contains(id) else { return [] }
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
        guard let job = job(id) else { return [] }
        for file in job.files {
            await engine.cancel(id: file.id)
        }
        var failed: [URL] = []
        if trashingFiles {
            // 已完成的任务已经交回了下载目录的访问权限，重新取得。取不到时移动失败，如实返回。
            _ = try? folderURL(for: id)
            let trashItem = trashItem
            failed = await Task.detached { JobFileTrash.trash(job, using: trashItem) }.value
        }
        jobs.removeAll { $0.id == id }
        invalidateIndex()
        jobActivities[id] = nil
        for file in job.files { fileActivities[file.id] = nil }
        save()
        closeFolder(of: id)
        if settings.cleanupAfterDownload, job.hasJobDirectory, !job.isCleanedUp, !belongsToOtherAccount(job), let netdisk {
            do {
                try await deleteJobDirectory(of: job, using: netdisk)
            } catch {
                logger.error("cannot delete \(job.remoteDirectory): \(error.localizedDescription)")
            }
        }
        return failed
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

    // MARK: - 转存和准备

    /// 开始任务的第一步：分享任务转存，网盘任务准备。
    private func startTransfer(_ id: Job.ID, session: ShareSession?, removingExisting: Bool) {
        tasks[id] = Task {
            await waitUntilStarted()
            await transfer(id, session: session, removingExisting: removingExisting)
        }
    }

    /// 得到文件下载，然后开始下载。`session` 和 `removingExisting` 只用于分享任务。
    private func transfer(_ id: Job.ID, session: ShareSession?, removingExisting: Bool) async {
        guard let job = activeJob(id) else { return }
        do {
            // 先确认下载目录可以写入，再操作网盘。
            _ = try folderURL(for: id)
            guard let netdisk else { throw CoordinatorError.notLoggedIn }
            guard !belongsToOtherAccount(job) else { throw CoordinatorError.otherAccount }
            if job.accountUK == nil {
                // 网盘任务的条目只在创建它的账号的网盘中有意义，不能认为它属于当前账号。
                guard job.link != nil else { throw CoordinatorError.unknownAccount }
                update(id) { $0.accountUK = accountUK }
            }
            let files: [JobFile]
            var warning: String?
            switch job.source {
            case .share(let link, let password, let entries):
                let remoteFiles = try await transferShare(job, link: link, password: password, entries: entries,
                                                          session: session, removingExisting: removingExisting, netdisk: netdisk)
                if remoteFiles.isEmpty { warning = "勾选的目录中没有文件，不需要下载。" }
                files = try Self.jobFiles(for: remoteFiles, in: job.remoteDirectory)
            case .netdisk(let entries):
                files = try await prepare(entries, netdisk: netdisk)
                // 网盘的列表没有转存延迟，不用像分享任务那样再检查一次。
                if files.isEmpty { warning = "勾选的目录中没有文件，不需要下载。" }
            }
            try Task.checkCancellation()
            guard activeJob(id) != nil else { return }
            update(id) {
                $0.files = files
                $0.phase = .downloading
                $0.isCleanedUp = false
                $0.warning = warning
            }
            invalidateIndex()
            markChanged(id)
            save()
            await serially(id) { await self.continueDownloads(id, resumingFailed: false) }
            evaluate(id)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            fail(id, step: .transfer, error)
        }
    }

    /// 分享任务的第一步：把勾选的条目转存到任务子目录，然后列出其中的文件。
    /// 列出 0 个文件时，只有确认勾选的都是空目录才返回空列表，否则抛出错误。
    private func transferShare(_ job: Job, link: ShareLink, password: String?, entries: [ShareEntry], session: ShareSession?,
                               removingExisting: Bool, netdisk: any Netdisk) async throws -> [RemoteFile] {
        // 路径为空时，建目录、转存和列出都会作用于网盘的根目录。
        guard job.hasJobDirectory else { throw TransferCheckError.missingJobDirectory }
        if removingExisting {
            try await deleteJobDirectory(of: job, using: netdisk)
        }
        let share: ShareSession
        if let session {
            share = session
        } else {
            share = try await netdisk.openShare(link, password: password)
        }
        try await netdisk.createDirectory(job.remoteDirectory)
        try await netdisk.transfer(share, entries: entries, to: job.remoteDirectory)
        let remoteFiles = try await netdisk.listFilesRecursively(job.remoteDirectory)
        // 刚转存的文件可能还没出现在列表中。只有确认勾选的都是空目录时，才没有文件需要下载。
        if remoteFiles.isEmpty, try await containsFiles(entries, share: share, netdisk: netdisk) {
            throw TransferCheckError.noFiles
        }
        return remoteFiles
    }

    /// 网盘任务的第一步（准备）：勾选的文件直接作为文件下载，勾选的目录递归列出。只读取网盘，不修改它。
    private func prepare(_ entries: [NetdiskEntry], netdisk: any Netdisk) async throws -> [JobFile] {
        var listed: [(file: RemoteFile, entry: NetdiskEntry)] = []
        for entry in entries {
            try Task.checkCancellation()
            // 根目录（`/` 或空路径）会列出整个网盘。只有手动修改的任务列表中才有这样的条目。
            guard RemotePath.normalized(entry.path) != "/" else { throw TransferCheckError.unsafePath(entry.name) }
            guard entry.isDirectory else {
                listed.append((RemoteFile(path: entry.path, size: entry.size, fsID: entry.fsID), entry))
                continue
            }
            for file in try await netdisk.listFilesRecursively(entry.path) {
                listed.append((file, entry))
            }
        }
        return try Self.jobFiles(for: listed)
    }

    /// 转存后的网盘文件 → 文件下载。任何一个文件不在任务子目录中或路径不安全时抛出错误，不静默丢掉文件。
    static func jobFiles(for remoteFiles: [RemoteFile], in remoteDirectory: String) throws -> [JobFile] {
        let relativePaths = try remoteFiles.map { file in
            guard let relativePath = RemotePath.relativePath(of: file.path, in: remoteDirectory) else {
                throw TransferCheckError.outsideJobDirectory(file.path)
            }
            return relativePath
        }
        return try jobFiles(for: remoteFiles, relativePaths: relativePaths)
    }

    /// 网盘任务列出的文件 → 文件下载。本地相对路径是网盘路径去掉勾选条目的上层目录：勾选 `/资料/2024/报告` 时是 `报告/…`。
    /// 和分享任务相同，任何一个文件不在勾选的条目中或路径不安全时抛出错误；整个任务一起去重。
    static func jobFiles(for listed: [(file: RemoteFile, entry: NetdiskEntry)]) throws -> [JobFile] {
        let relativePaths = try listed.map { file, entry in
            let isInside = entry.isDirectory
                ? RemotePath.relativePath(of: file.path, in: entry.path) != nil
                : file.path == entry.path
            guard isInside, let relativePath = RemotePath.relativePath(of: file.path, in: RemotePath.parent(of: entry.path)) else {
                throw TransferCheckError.outsideCheckedEntry(file.path)
            }
            return relativePath
        }
        return try jobFiles(for: listed.map(\.file), relativePaths: relativePaths)
    }

    /// 检查本地相对路径，然后去重。
    private static func jobFiles(for remoteFiles: [RemoteFile], relativePaths: [String]) throws -> [JobFile] {
        for (file, relativePath) in zip(remoteFiles, relativePaths) where !LocalPath.isSafe(relativePath) {
            throw TransferCheckError.unsafePath(file.path)
        }
        return zip(remoteFiles, LocalPath.deduplicated(relativePaths)).map { file, relativePath in
            JobFile(remotePath: file.path, relativePath: relativePath, size: file.size)
        }
    }

    /// 删除网盘中的任务子目录（重试转存前和清理时）。网盘任务没有任务子目录，这里不删除任何东西：
    /// 它的文件是用户自己的源文件。
    private func deleteJobDirectory(of job: Job, using netdisk: any Netdisk) async throws {
        guard job.hasJobDirectory else { return }
        try await netdisk.delete(paths: [job.remoteDirectory])
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
        setSnapshot(fileID, snapshot)
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
            setSnapshot(snapshot.id, snapshot)
        case .stateChanged(let snapshot):
            guard let (jobIndex, _) = locate(snapshot.id) else { return }
            let jobID = jobs[jobIndex].id
            if case .completed(let url) = snapshot.state {
                recordCompletion(of: snapshot.id, at: url)
                // 完成状态写入任务列表后，引擎才删除这个文件下载的状态。
                cancelAfterSave.append(snapshot.id)
                scheduleSave()
            }
            setSnapshot(snapshot.id, snapshot)
            evaluate(jobID)
        case .removed(let id):
            setSnapshot(id, nil)
        }
    }

    private func setSnapshot(_ fileID: String, _ snapshot: DownloadSnapshot?) {
        changeFile(fileID) { downloads[fileID] = snapshot }
        fileActivities[fileID]?.snapshot = snapshot
    }

    /// 把引擎报告的最终路径记入任务。已经记入时不变。
    private func recordCompletion(of fileID: String, at url: URL) {
        guard let (jobIndex, fileIndex) = locate(fileID), jobs[jobIndex].files[fileIndex].localURL == nil else { return }
        changeFile(fileID) { jobs[jobIndex].files[fileIndex].localURL = url }
    }

    /// 修改文件下载在 `downloads` 中的状态或它的 `localURL` 时都经过这里：所在任务的计数先减去这个文件原来的部分，
    /// 修改后再加上新的部分。不属于任何任务的文件下载不影响计数。
    private func changeFile(_ fileID: String, _ change: () -> Void) {
        // 先重建索引（同时重建计数），减去的才是修改前的部分。
        guard let location = locateIndexed(fileID), let jobIndex = jobIndices[location.job] else {
            change()
            return
        }
        tallies[location.job]?.remove(jobs[jobIndex].files[location.file], at: location.file, downloads[fileID])
        change()
        tallies[location.job]?.add(jobs[jobIndex].files[location.file], at: location.file, downloads[fileID])
        markChanged(location.job)
        verifyTally(of: location.job)
    }

    /// 根据文件下载的状态更新任务的阶段。
    private func evaluate(_ id: Job.ID) {
        guard let job = activeJob(id), job.phase == .downloading, !finishing.contains(id),
              let tally = tallies[id] else { return }
        let outcome = outcome(of: job, tally)
        if let handler = tallyMismatchHandler {
            let scanned = scannedOutcome(of: job)
            if outcome != scanned { handler("job \(id): outcome \(outcome), scanning gives \(scanned)") }
        }
        switch outcome {
        case .finish: finish(id)
        case .reconcile: reconcile(id)
        case .fail(let failure): fail(id, step: .download, failure)
        case .wait: break
        }
    }

    /// 任务下一步要做的事。只读计数，不遍历文件列表。
    private func outcome(of job: Job, _ tally: JobTally) -> Outcome {
        if tally.pendingCount == 0 { return .finish }
        guard !job.isPaused else { return .wait }
        // 任务没暂停，文件下载却暂停了（例如启动时恢复为暂停）。让它们继续，否则任务一直停在“下载中”。
        if tally.pausedCount > 0 { return .reconcile }
        // 还有文件下载没加入引擎（例如正在逐个加入）时，结果还没确定。
        guard tally.trackedCount == tally.pendingCount, tally.queuedCount == 0, tally.runningFiles.isEmpty,
              tally.failedCount > 0 else { return .wait }
        // 只在任务失败时遍历一次：失败后任务不再是“下载中”，不再到这里。
        return firstFailure(in: job).map(Outcome.fail) ?? .wait
    }

    /// 测试用：不用计数，遍历文件列表得出下一步。结果应和 `outcome(of:_:)` 相同。
    private func scannedOutcome(of job: Job) -> Outcome {
        let pending = job.files.filter { !$0.isCompleted }
        if pending.isEmpty { return .finish }
        guard !job.isPaused else { return .wait }
        let states = pending.compactMap { downloads[$0.id]?.state }
        if states.contains(.paused) { return .reconcile }
        guard states.count == pending.count, !states.contains(where: { $0 == .queued || $0 == .running }) else { return .wait }
        return firstFailure(in: job).map(Outcome.fail) ?? .wait
    }

    /// 按文件顺序，第一个失败的没完成的文件下载的原因。
    private func firstFailure(in job: Job) -> DownloadFailure? {
        job.files.lazy.filter { !$0.isCompleted }.compactMap { file -> DownloadFailure? in
            if case .failed(let failure) = self.downloads[file.id]?.state { failure } else { nil }
        }.first
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
            // 网盘任务没有转存的文件，不清理。
            if settings.cleanupAfterDownload, let job = activeJob(id), job.hasJobDirectory, !job.isCleanedUp {
                do {
                    guard let netdisk else { throw CoordinatorError.notLoggedIn }
                    guard !belongsToOtherAccount(job) else { throw CoordinatorError.otherAccount }
                    try await deleteJobDirectory(of: job, using: netdisk)
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

    /// 任务是用另一个账号创建的。这时不对它做任何网盘操作：任务子目录（网盘任务：勾选的条目）在那个账号的网盘中。
    public func belongsToOtherAccount(_ job: Job) -> Bool {
        guard let owner = job.accountUK, let accountUK else { return false }
        return owner != accountUK
    }

    /// `AccountCheckedSource` 获取下载链接前后调用。文件下载属于另一个账号的任务时抛出错误，引擎不再重试。
    func checkAccount(ofDownload id: String) throws {
        guard let (jobIndex, _) = locate(id) else { return }
        let job = jobs[jobIndex]
        if belongsToOtherAccount(job) { throw CoordinatorError.otherAccount }
        // 和 `transfer` 相同：没有记录账号的网盘任务不能认为属于当前账号。
        if job.accountUK == nil, job.link == nil { throw CoordinatorError.unknownAccount }
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
        if isIndexStale { rebuildIndex() }
        return jobIndices[id].map { jobs[$0] }
    }

    /// 存在且没有正在移除的任务。
    private func activeJob(_ id: Job.ID) -> Job? {
        removingJobs.contains(id) ? nil : job(id)
    }

    private func update(_ id: Job.ID, _ body: (inout Job) -> Void) {
        if isIndexStale { rebuildIndex() }
        guard let index = jobIndices[id] else { return }
        body(&jobs[index])
        markChanged(id)
    }

    private func locate(_ fileID: String) -> (Int, Int)? {
        guard let location = locateIndexed(fileID), let jobIndex = jobIndices[location.job] else { return nil }
        return (jobIndex, location.file)
    }

    private func locateIndexed(_ fileID: String) -> (job: UUID, file: Int)? {
        if isIndexStale { rebuildIndex() }
        return fileLocations[fileID]
    }

    private func invalidateIndex() {
        isIndexStale = true
    }

    private func rebuildIndex() {
        fileLocations = [:]
        jobIndices = [:]
        tallies = [:]
        for (jobIndex, job) in jobs.enumerated() {
            jobIndices[job.id] = jobIndex
            for (fileIndex, file) in job.files.enumerated() {
                fileLocations[file.id] = (job.id, fileIndex)
            }
            tallies[job.id] = JobTally(files: job.files, downloads: downloads)
        }
        isIndexStale = false
    }

    /// 测试用：从头计算任务的计数，和增量维护的计数比较。`tallyMismatchHandler` 为 nil 时不计算。
    private func verifyTally(of id: Job.ID) {
        guard let handler = tallyMismatchHandler, let job = job(id) else { return }
        let expected = JobTally(files: job.files, downloads: downloads)
        if tallies[id] != expected {
            handler("job \(id): tally \(String(describing: tallies[id])), recomputed \(expected)")
        }
    }

    /// 立即写入任务列表，然后从引擎取消已记入任务的完成的文件下载。
    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        guard hasLoaded, canSave else { return }
        do {
            try store.save(jobs)
            saveCount += 1
        } catch {
            logger.error("cannot save jobs: \(error.localizedDescription)")
            return
        }
        let finished = cancelAfterSave
        cancelAfterSave = []
        if !finished.isEmpty {
            Task {
                for id in finished { await engine.cancel(id: id) }
            }
        }
    }

    /// 合并短时间内的多次变化，`saveDelay` 后写入一次。
    private func scheduleSave() {
        guard pendingSave == nil else { return }
        pendingSave = Task { [saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            save()
        }
    }

    // MARK: - 界面观察的进度

    /// 任务的汇总进度。每个任务一个对象，进度变化只让显示这个任务的视图刷新。
    public func activity(of id: Job.ID) -> JobActivity {
        if let activity = jobActivities[id] { return activity }
        let activity = JobActivity()
        refresh(activity, for: id)
        jobActivities[id] = activity
        return activity
    }

    /// 文件下载的状态。只有详情栏中的文件行观察它。
    public func activity(ofFile id: String) -> FileActivity {
        if let activity = fileActivities[id] { return activity }
        let activity = FileActivity(snapshot: downloads[id])
        fileActivities[id] = activity
        return activity
    }

    /// 同一轮事件（引擎每次发出全部进行中文件的进度）只重新计算一次。
    private func markChanged(_ id: Job.ID) {
        guard jobActivities[id] != nil else { return }
        changedJobs.insert(id)
        guard !isActivityUpdateScheduled else { return }
        isActivityUpdateScheduled = true
        Task { updateActivities() }
    }

    private func updateActivities() {
        isActivityUpdateScheduled = false
        let changed = changedJobs
        changedJobs = []
        for id in changed {
            guard let activity = jobActivities[id] else { continue }
            refresh(activity, for: id)
        }
    }

    private func refresh(_ activity: JobActivity, for id: Job.ID) {
        guard let job = job(id), let tally = tallies[id] else { return }
        // 引擎只给下载中的文件报告非 0 的速度，所以只加这些文件。按文件顺序加，结果和 `progress(of:)` 完全相同。
        let speed = tally.runningFiles.sorted().reduce(0.0) { $0 + (downloads[job.files[$1].id]?.bytesPerSecond ?? 0) }
        let progress = JobProgress(receivedBytes: tally.completedBytes + tally.receivedBytes, totalBytes: tally.totalBytes,
                                   bytesPerSecond: speed)
        let isRunning = !tally.runningFiles.isEmpty
        if let handler = tallyMismatchHandler {
            let scanned = (self.progress(of: job), job.files.contains { !$0.isCompleted && downloads[$0.id]?.state == .running })
            if progress != scanned.0 || isRunning != scanned.1 {
                handler("job \(job.id): activity \(progress) \(isRunning), scanning gives \(scanned.0) \(scanned.1)")
            }
        }
        if activity.progress != progress { activity.progress = progress }
        if activity.isRunning != isRunning { activity.isRunning = isRunning }
    }

    static func message(for error: any Error) -> String {
        switch error {
        case let failure as DownloadFailure: failure.message
        case let error as LocalizedError: error.errorDescription ?? error.localizedDescription
        default: error.localizedDescription
        }
    }
}

/// 一个任务的文件下载计数。`evaluate` 和任务的汇总进度只读它，不遍历文件列表：
/// 每个事件都遍历时，几千个文件的任务会让主线程忙几十秒。
///
/// 每个文件的部分只由它是否完成和它在 `downloads` 中的状态决定，所以修改其中之一时，先减去原来的部分，再加上新的部分。
private struct JobTally: Equatable {
    var totalBytes: Int64 = 0
    /// 没完成（没有 `localURL`）的文件。
    var pendingCount = 0
    var completedBytes: Int64 = 0
    /// 下面几项只算没完成、并且在 `downloads` 中有状态的文件。
    var trackedCount = 0
    var queuedCount = 0
    var pausedCount = 0
    var failedCount = 0
    var receivedBytes: Int64 = 0
    /// 正在下载的文件的下标。速度不在这里累加：浮点数反复加减会留下误差，没有下载时仍显示很小的速度。
    var runningFiles: Set<Int> = []

    init(files: [JobFile], downloads: [String: DownloadSnapshot]) {
        for (index, file) in files.enumerated() {
            add(file, at: index, downloads[file.id])
        }
    }

    mutating func add(_ file: JobFile, at index: Int, _ snapshot: DownloadSnapshot?) {
        apply(file, at: index, snapshot, sign: 1)
    }

    mutating func remove(_ file: JobFile, at index: Int, _ snapshot: DownloadSnapshot?) {
        apply(file, at: index, snapshot, sign: -1)
    }

    private mutating func apply(_ file: JobFile, at index: Int, _ snapshot: DownloadSnapshot?, sign: Int) {
        totalBytes += Int64(sign) * file.size
        if file.isCompleted {
            completedBytes += Int64(sign) * file.size
            return
        }
        pendingCount += sign
        guard let snapshot else { return }
        trackedCount += sign
        receivedBytes += Int64(sign) * snapshot.receivedBytes
        switch snapshot.state {
        case .queued: queuedCount += sign
        case .running:
            if sign > 0 { runningFiles.insert(index) } else { runningFiles.remove(index) }
        case .paused: pausedCount += sign
        case .failed: failedCount += sign
        case .completed: break
        }
    }
}

/// `evaluate` 得出的任务下一步。
private enum Outcome: Equatable {
    case finish
    /// 让暂停的文件下载继续。
    case reconcile
    case fail(DownloadFailure)
    /// 结果还没确定，或任务已暂停。
    case wait
}

enum TransferCheckError: LocalizedError {
    case noFiles
    case missingJobDirectory
    case outsideJobDirectory(String)
    /// 网盘任务列出的文件不在勾选的条目中。
    case outsideCheckedEntry(String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .noFiles:
            "转存后网盘中没有找到文件，可能转存尚未完成，请重试。"
        case .missingJobDirectory:
            "任务记录中没有有效的任务子目录，无法转存。"
        case .outsideJobDirectory(let path):
            "转存后的文件“\(path)”不在任务子目录中，无法确定保存位置。"
        case .outsideCheckedEntry(let path):
            "列出的文件“\(path)”不在勾选的目录中，无法确定保存位置。"
        case .unsafePath(let path):
            "文件路径“\(path)”不能用作本地文件名，下载已停止。"
        }
    }
}

/// 遵循 `PermanentDownloadSourceError`：从 `AccountCheckedSource` 抛出时，引擎不再重试。
enum CoordinatorError: LocalizedError, PermanentDownloadSourceError {
    case notLoggedIn
    case otherAccount
    /// 网盘任务没有记录账号（只有手动修改的任务列表才会这样）。
    case unknownAccount

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: "未登录百度网盘。"
        case .otherAccount: "这个任务是用另一个百度账号创建的。请登录那个账号后再操作。"
        case .unknownAccount: "任务中没有记录百度账号，不能确定文件在哪个账号的网盘中。请重新添加这个任务。"
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
