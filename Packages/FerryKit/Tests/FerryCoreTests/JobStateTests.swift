import BaiduKit
import DownloadKit
import Foundation
import Testing
@testable import FerryCore

/// 任务状态和引擎状态的一致性：暂停与继续交错、转存刚结束时的操作、启动前的操作、完成状态的保存。
@MainActor @Suite struct JobStateTests {
    private func files(_ count: Int, size: Int = 200_000) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: (0..<count).map { ("f\($0).bin", randomData(size)) })
    }

    @Test func resumesPausedFilesOfUnpausedJobAfterRestart() async throws {
        let fixture = Fixture(share: files(2))
        let first = fixture.makeCoordinator()
        await first.start()
        fixture.server.setStalled(true)
        let job = first.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await waitUntil("running") {
            first.job(job.id)?.files.contains { first.downloads[$0.id]?.state == .running } ?? false
        }
        await first.pause(job.id)
        await first.shutdown()
        fixture.server.setStalled(false)

        // 任务没暂停，引擎中的文件下载却是暂停的。
        var saved = try fixture.store.load()
        saved[0].isPaused = false
        try fixture.store.save(saved)

        let second = fixture.makeCoordinator()
        await second.start()
        #expect(second.job(job.id)?.isPaused == false)
        try await second.waitForPhase(.completed, of: job.id)
    }

    @Test func interleavedPauseAndResumeEndInLastRequestedState() async throws {
        let fixture = Fixture(share: files(4))
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        fixture.server.setStalled(true)
        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await waitUntil("all files running") {
            guard let job = coordinator.job(job.id), job.files.count == 4 else { return false }
            return job.files.allSatisfy { coordinator.downloads[$0.id]?.state == .running }
        }

        // 不等前一个操作完成就发出下一个。最后一个是暂停。
        let operations = [
            Task { await coordinator.pause(job.id) },
            Task { await coordinator.resume(job.id) },
            Task { await coordinator.pause(job.id) },
            Task { await coordinator.resume(job.id) },
            Task { await coordinator.pause(job.id) },
        ]
        for operation in operations { await operation.value }
        let paused = try #require(coordinator.job(job.id))
        #expect(paused.isPaused)
        try await waitUntil("all files paused") {
            paused.files.allSatisfy { coordinator.downloads[$0.id]?.state == .paused }
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(paused.files.allSatisfy { coordinator.downloads[$0.id]?.state == .paused })

        fixture.server.setStalled(false)
        let resumes = [
            Task { await coordinator.resume(job.id) },
            Task { await coordinator.pause(job.id) },
            Task { await coordinator.resume(job.id) },
        ]
        for operation in resumes { await operation.value }
        #expect(coordinator.job(job.id)?.isPaused == false)
        try await coordinator.waitForPhase(.completed, of: job.id)
    }

    @Test func pauseDuringEnqueueAddsRemainingFilesPaused() async throws {
        let fixture = Fixture(share: files(5, size: 100_000))
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        fixture.server.setStalled(true)
        var enqueued = 0
        var pauseTask: Task<Void, Never>?
        coordinator.willEnqueue = { file in
            enqueued += 1
            guard enqueued == 2, let job = coordinator.jobs.first else { return }
            pauseTask = Task { await coordinator.pause(job.id) }
            while coordinator.jobs.first?.isPaused != true { await Task.yield() }
        }

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await waitUntil("pause requested") { pauseTask != nil }
        await pauseTask?.value
        let paused = try #require(coordinator.job(job.id))
        #expect(paused.isPaused)
        #expect(paused.files.count == 5)
        try await waitUntil("all files paused") {
            paused.files.allSatisfy { coordinator.downloads[$0.id]?.state == .paused }
        }
        fixture.server.setStalled(false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(paused.files.allSatisfy { coordinator.downloads[$0.id]?.state == .paused })
    }

    @Test func removeDuringEnqueueCancelsEveryFile() async throws {
        let fixture = Fixture(share: files(5, size: 100_000))
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        fixture.server.setStalled(true)
        var enqueued = 0
        var removeTask: Task<Void, Never>?
        coordinator.willEnqueue = { file in
            enqueued += 1
            guard enqueued == 3, let job = coordinator.jobs.first else { return }
            removeTask = Task { await coordinator.remove(job.id) }
            while !coordinator.removingJobs.contains(job.id) { await Task.yield() }
        }

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await waitUntil("remove requested") { removeTask != nil }
        await removeTask?.value
        fixture.server.setStalled(false)

        #expect(coordinator.jobs.isEmpty)
        #expect(coordinator.removingJobs.isEmpty)
        #expect(enqueued == 3)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try fixture.stateFiles().isEmpty)
        #expect(coordinator.downloads.isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: fixture.downloads.path)) ?? []
        #expect(leftovers.isEmpty)
        #expect(try fixture.store.load().isEmpty)
        _ = job
    }

    @Test func operationsBeforeStartWaitForIt() async throws {
        let fixture = Fixture(share: files(1, size: 10_000))
        var existing = try await fixture.makeTransferredJob()
        existing.phase = .failed(.download)
        existing.error = "网络错误"
        try fixture.store.save([existing])

        let coordinator = fixture.makeCoordinator()
        let retry = Task { await coordinator.retry(existing.id) }
        let added = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        // 启动前不写入任务列表，原来的任务不会被覆盖。
        #expect(try fixture.store.load().map(\.id) == [existing.id])
        #expect(!coordinator.isStarted)

        await coordinator.start()
        #expect(coordinator.isStarted)
        #expect(coordinator.jobs.map(\.id) == [added.id, existing.id])
        await retry.value
        try await coordinator.waitForPhase(.completed, of: existing.id)
        try await coordinator.waitForPhase(.completed, of: added.id)
        #expect(Set(try fixture.store.load().map(\.id)) == [added.id, existing.id])
    }

    @Test func retryCompletesJobWhoseFilesAreAllDone() async throws {
        let fixture = Fixture(share: files(1, size: 10))
        var job = try await fixture.makeTransferredJob()
        job.files[0].localURL = fixture.downloads.appending(path: job.files[0].relativePath)
        job.phase = .failed(.download)
        job.error = "网络错误"
        try fixture.store.save([job])

        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        await coordinator.retry(job.id)
        try await coordinator.waitForPhase(.completed, of: job.id)
        #expect(coordinator.job(job.id)?.error == nil)
        #expect(fixture.server.log.isEmpty)
    }

    @Test func completedDownloadsLeaveTheEngineAfterSaving() async throws {
        let fixture = Fixture(share: files(3, size: 50_000))
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.completed, of: job.id)
        let finished = try #require(coordinator.job(job.id))
        try await waitUntil("engine forgets completed downloads") {
            finished.files.allSatisfy { coordinator.downloads[$0.id] == nil } && (try? fixture.stateFiles().isEmpty) == true
        }
        #expect(try fixture.store.load().first?.files.allSatisfy(\.isCompleted) == true)
    }

    /// 文件下载完成后、任务列表保存前应用退出。引擎保留完成状态，启动时直接记入任务，不再下载。
    @Test func recordsDownloadCompletedBeforeJobListWasSaved() async throws {
        let fixture = Fixture(share: files(1, size: 50_000))
        let job = try await fixture.makeTransferredJob()
        try fixture.store.save([job])
        let file = job.files[0]

        let engine = fixture.makeEngine()
        let events = engine.events()
        try await engine.enqueue(DownloadRequest(
            id: file.id, destination: fixture.downloads.appending(path: file.relativePath), expectedSize: file.size,
            context: BaiduDownloadSource.context(forRemotePath: file.remotePath)))
        for await event in events {
            if case .stateChanged(let snapshot) = event, case .completed = snapshot.state { break }
        }
        await engine.shutdown()
        #expect(try !fixture.stateFiles().isEmpty)

        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        try await coordinator.waitForPhase(.completed, of: job.id)
        let recorded = try #require(coordinator.job(job.id)?.files.first)
        #expect(try Data(contentsOf: #require(recorded.localURL)) == fixture.netdisk.data(at: file.remotePath))
        #expect(recorded.localURL?.lastPathComponent == file.relativePath)
        #expect(fixture.server.requests(for: file.remotePath) == 1)
        try await waitUntil("completed state removed") { (try? fixture.stateFiles().isEmpty) == true }
    }
}
