import BaiduKit
@testable import DownloadKit
import Foundation
import Testing
@testable import FerryCore

@MainActor @Suite struct JobCoordinatorTests {
    private let share: [String: Data] = [
        "a.bin": randomData(300_000),
        "docs/readme.txt": randomData(1_000),
        "docs/2024/report.pdf": randomData(200_000),
        "empty.txt": Data(),
    ]

    @Test func downloadsTransferredFilesPreservingStructure() async throws {
        let fixture = Fixture(share: share)
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        var completed: [Job.ID] = []
        coordinator.onJobCompleted = { completed.append($0.id) }

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        #expect(coordinator.jobs.map(\.id) == [job.id])
        try await coordinator.waitForPhase(.completed, of: job.id)

        for (path, data) in share {
            #expect(fixture.contents(path) == data, "\(path)")
        }
        let finished = try #require(coordinator.job(job.id))
        #expect(finished.files.count == 4)
        #expect(finished.files.allSatisfy { $0.isCompleted })
        #expect(Set(finished.files.map(\.remotePath)) == Set(share.keys.map { job.remoteDirectory + "/" + $0 }))
        #expect(coordinator.progress(of: finished).fractionCompleted == 1)
        #expect(completed == [job.id])
        #expect(fixture.netdisk.operations.prefix(3) == [
            .createDirectory(job.remoteDirectory), .transfer(job.remoteDirectory), .list(job.remoteDirectory),
        ])
        // 清理默认关闭。
        #expect(!finished.isCleanedUp)
        #expect(fixture.netdisk.remotePaths().count == 4)
        #expect(try fixture.store.load() == coordinator.jobs)
    }

    @Test func cleanupDeletesJobDirectoryWhenEnabled() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10_000)])
        let coordinator = fixture.makeCoordinator(settings: FerrySettings(cleanupAfterDownload: true))
        await coordinator.start()

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.completed, of: job.id)

        #expect(coordinator.job(job.id)?.isCleanedUp == true)
        #expect(fixture.netdisk.operations.last == .delete([job.remoteDirectory]))
        #expect(fixture.netdisk.remotePaths().isEmpty)
    }

    @Test func cleanupFailureOnlyWarns() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10_000)])
        let coordinator = fixture.makeCoordinator(settings: FerrySettings(cleanupAfterDownload: true))
        await coordinator.start()
        fixture.netdisk.failNextDelete()

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.completed, of: job.id)

        let finished = try #require(coordinator.job(job.id))
        #expect(!finished.isCleanedUp)
        #expect(finished.warning?.isEmpty == false)
        #expect(finished.error == nil)
    }

    @Test func transferRetryDeletesJobDirectoryFirst() async throws {
        let fixture = Fixture(share: share)
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        fixture.netdisk.failNextTransfer()

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(coordinator.job(job.id)?.error?.isEmpty == false)
        // 失败的转存在网盘中留下了一部分文件。
        #expect(!fixture.netdisk.remotePaths().isEmpty)

        await coordinator.retry(job.id)
        try await coordinator.waitForPhase(.completed, of: job.id)

        let operations = fixture.netdisk.operations
        let retryStart = try #require(operations.firstIndex(of: .delete([job.remoteDirectory])))
        #expect(Array(operations[retryStart...].prefix(3)) == [
            .delete([job.remoteDirectory]), .openShare, .createDirectory(job.remoteDirectory),
        ])
        for (path, data) in share {
            #expect(fixture.contents(path) == data, "\(path)")
        }
    }

    @Test func downloadRetryOnlyRestartsFailedFiles() async throws {
        let fixture = Fixture(share: ["good.bin": randomData(50_000), "bad.bin": randomData(50_000)])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        fixture.server.setFailing(["/bad.bin"])

        let added = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.failed(.download), of: added.id)
        let failed = try #require(coordinator.job(added.id))
        #expect(failed.error?.contains("500") == true)
        #expect(failed.files.filter(\.isCompleted).map(\.relativePath) == ["good.bin"])

        fixture.server.setFailing([])
        await coordinator.retry(added.id)
        try await coordinator.waitForPhase(.completed, of: added.id)

        let remoteDirectory = failed.remoteDirectory
        #expect(fixture.server.requests(for: remoteDirectory + "/good.bin") == 1)
        #expect(fixture.server.requests(for: remoteDirectory + "/bad.bin") == 2)
        #expect(fixture.contents("bad.bin") == fixture.netdisk.data(at: remoteDirectory + "/bad.bin"))
    }

    @Test func pauseAndResume() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(400_000), "b.bin": randomData(400_000)])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        fixture.server.setStalled(true)

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await waitUntil("partial progress") {
            guard let job = coordinator.job(job.id), job.files.count == 2 else { return false }
            return coordinator.progress(of: job).receivedBytes >= 400_000
        }

        await coordinator.pause(job.id)
        let paused = try #require(coordinator.job(job.id))
        #expect(paused.isPaused)
        #expect(paused.phase == .downloading)
        try await waitUntil("files paused") {
            paused.files.allSatisfy { coordinator.downloads[$0.id]?.state == .paused }
        }
        #expect(try fixture.store.load().first?.isPaused == true)

        fixture.server.setStalled(false)
        await coordinator.resume(job.id)
        #expect(coordinator.job(job.id)?.isPaused == false)
        try await coordinator.waitForPhase(.completed, of: job.id)
        #expect(fixture.contents("a.bin") == fixture.netdisk.data(at: job.remoteDirectory + "/a.bin"))
        #expect(fixture.contents("b.bin") == fixture.netdisk.data(at: job.remoteDirectory + "/b.bin"))
    }

    @Test func activityMatchesProgressOfCompletedAndRunningFiles() async throws {
        let fixture = Fixture(share: ["small.bin": randomData(1_000), "big.bin": randomData(400_000)])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        fixture.server.setStalling(["/big.bin"])

        let added = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        let activity = coordinator.activity(of: added.id)
        try await waitUntil("small file completed and big file running") {
            guard let job = coordinator.job(added.id), job.files.contains(where: \.isCompleted) else { return false }
            return activity.isRunning && activity.progress.receivedBytes > 1_000 && activity.progress == coordinator.progress(of: job)
        }
        #expect(activity.progress.totalBytes == 401_000)

        fixture.server.setStalling([])
        try await coordinator.waitForPhase(.completed, of: added.id)
        let finished = try #require(coordinator.job(added.id))
        try await waitUntil("activity complete") {
            !activity.isRunning && activity.progress == coordinator.progress(of: finished)
        }
        #expect(activity.progress.receivedBytes == 401_000)
        #expect(activity.progress.bytesPerSecond == 0)
    }

    @Test func failsOnlyAfterOtherFilesStop() async throws {
        let fixture = Fixture(share: ["bad.bin": randomData(1_000), "slow.bin": randomData(400_000)])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        fixture.server.setFailing(["/bad.bin"])
        fixture.server.setStalling(["/slow.bin"])

        let added = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        let activity = coordinator.activity(of: added.id)
        try await waitUntil("bad file failed while slow file runs") {
            guard let job = coordinator.job(added.id), job.files.count == 2 else { return false }
            let states = job.files.map { coordinator.downloads[$0.id]?.state }
            return states.contains { if case .failed = $0 { true } else { false } } && states.contains(DownloadState.running)
        }
        try await waitUntil("activity running") { activity.isRunning }
        #expect(coordinator.job(added.id)?.phase == .downloading)

        fixture.server.setStalling([])
        try await coordinator.waitForPhase(.failed(.download), of: added.id)
        let failed = try #require(coordinator.job(added.id))
        #expect(failed.error == DownloadFailure.httpStatus(500, message: "").message)
        #expect(failed.files.filter(\.isCompleted).map(\.relativePath) == ["slow.bin"])
        try await waitUntil("activity stopped") {
            !activity.isRunning && activity.progress == coordinator.progress(of: failed)
        }
    }

    @Test func removeCancelsDownloadsAndKeepsCompletedFiles() async throws {
        let fixture = Fixture(share: ["done.bin": Data(), "big.bin": randomData(400_000)])
        let coordinator = fixture.makeCoordinator(settings: FerrySettings(cleanupAfterDownload: true, maxConcurrentFiles: 4))
        await coordinator.start()
        fixture.server.setStalled(true)

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await waitUntil("one file completed and one running") {
            guard let job = coordinator.job(job.id) else { return false }
            return job.files.contains(where: \.isCompleted)
                && job.files.contains { coordinator.downloads[$0.id]?.state == .running }
        }
        let big = try #require(coordinator.job(job.id)?.files.first { $0.relativePath == "big.bin" })

        await coordinator.remove(job.id)
        fixture.server.setStalled(false)

        #expect(coordinator.jobs.isEmpty)
        #expect(try fixture.store.load().isEmpty)
        #expect(coordinator.downloads[big.id] == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.downloads.appending(path: "done.bin").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.downloads.path)
        #expect(!leftovers.contains { $0.hasSuffix(".ferrydownload") })
        #expect(fixture.netdisk.operations.last == .delete([job.remoteDirectory]))
        #expect(fixture.netdisk.remotePaths().isEmpty)
    }

    @Test func removeTrashingFilesKeepsUserFiles() async throws {
        let fixture = Fixture(share: ["Show/a.bin": randomData(1000), "Show/S1/b.bin": randomData(1000)])
        // 下载目录中原来就有同名目录和用户自己的文件。
        let show = fixture.downloads.appending(path: "Show")
        try FileManager.default.createDirectory(at: show, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: show.appending(path: "mine.txt"))
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.completed, of: job.id)
        let failed = await coordinator.remove(job.id, trashingFiles: true)

        #expect(failed.isEmpty)
        #expect(coordinator.jobs.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: show.path) == ["mine.txt"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).count == 2)
    }

    @Test func restoresDownloadsAfterRestart() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(400_000)])
        let first = fixture.makeCoordinator()
        await first.start()
        fixture.server.setStalled(true)

        let job = first.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await waitUntil("partial progress") {
            guard let job = first.job(job.id), !job.files.isEmpty else { return false }
            return first.progress(of: job).receivedBytes > 0
        }
        await first.shutdown()

        // 中断在转存阶段的任务。
        var interrupted = Job(link: FakeNetdisk.link, password: nil, entries: fixture.netdisk.rootEntries(), transferFolder: "/Ferry")
        interrupted.createdAt = .distantPast
        try fixture.store.save(try fixture.store.load() + [interrupted])

        fixture.server.setStalled(false)
        let second = fixture.makeCoordinator()
        await second.start()

        #expect(second.job(interrupted.id)?.phase == .failed(.transfer))
        #expect([.downloading, .completed].contains(second.job(job.id)?.phase))
        try await second.waitForPhase(.completed, of: job.id)
        #expect(fixture.contents("a.bin") == fixture.netdisk.data(at: job.remoteDirectory + "/a.bin"))
        let ranges = fixture.server.log.filter { $0 == job.remoteDirectory + "/a.bin" }
        #expect(ranges.count == 2)
    }

    @Test func restoreRecordsDownloadsCompletedBeforeSave() async throws {
        let fixture = Fixture(share: ["small.bin": randomData(1_000), "big.bin": randomData(400_000)])
        let first = fixture.makeCoordinator()
        first.saveDelay = .seconds(60)
        await first.start()
        fixture.server.setStalling(["/big.bin"])
        let job = first.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await waitUntil("small file completed") {
            first.job(job.id)?.files.first { $0.relativePath == "small.bin" }?.isCompleted == true
        }
        // 完成状态还没写入任务列表，引擎仍保留它。保留这时的任务列表和小文件的完成记录，模拟应用在两步之间退出。
        // 大文件的记录一直在更新，不复制它：退出后它的记录就是最终的。
        let small = try #require(first.job(job.id)?.files.first { $0.relativePath == "small.bin" })
        let smallState = StateStore(directory: fixture.stateDirectory).fileURL(for: small.id)
        let savedJobs = try Data(contentsOf: fixture.store.fileURL)
        let savedState = try Data(contentsOf: smallState)
        await first.shutdown()
        try await waitUntil("engine forgets small file") { !FileManager.default.fileExists(atPath: smallState.path) }
        try savedState.write(to: smallState)
        try savedJobs.write(to: fixture.store.fileURL)
        #expect(try fixture.store.load().first?.files.contains(where: \.isCompleted) == false)

        fixture.server.setStalling([])
        let second = fixture.makeCoordinator()
        await second.start()
        let restored = try #require(second.job(job.id)?.files.first { $0.id == small.id })
        #expect(restored.isCompleted)
        try await second.waitForPhase(.completed, of: job.id)
        #expect(fixture.server.requests(for: job.remoteDirectory + "/small.bin") == 1)
        #expect(fixture.contents("big.bin") == fixture.netdisk.data(at: job.remoteDirectory + "/big.bin"))
    }

    @Test func restoresPausedJobAsPaused() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(400_000)])
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

        let second = fixture.makeCoordinator()
        await second.start()
        let restored = try #require(second.job(job.id))
        #expect(restored.isPaused)
        #expect(restored.files.allSatisfy { second.downloads[$0.id]?.state == .paused })

        await second.resume(job.id)
        try await second.waitForPhase(.completed, of: job.id)
    }

    @Test func unreadableJobListKeepsDownloadsUntouched() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(400_000)])
        let first = fixture.makeCoordinator()
        await first.start()
        fixture.server.setStalled(true)
        let job = first.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await waitUntil("partial progress") {
            guard let job = first.job(job.id), !job.files.isEmpty else { return false }
            return first.progress(of: job).receivedBytes > 0
        }
        await first.shutdown()
        fixture.server.setStalled(false)
        let saved = try Data(contentsOf: fixture.store.fileURL)
        try Data("{".utf8).write(to: fixture.store.fileURL)
        let stateFiles = try fixture.stateFiles()
        #expect(!stateFiles.isEmpty)
        let requests = fixture.server.log.count

        let second = fixture.makeCoordinator()
        await second.start()
        #expect(second.jobs.isEmpty)
        #expect(second.loadWarning?.contains("jobs.json.corrupt-") == true)
        let backups = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
            .filter { $0.hasPrefix("jobs.json.corrupt-") }
        #expect(backups.count == 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try fixture.stateFiles() == stateFiles)
        #expect(fixture.server.log.count == requests)
        await second.shutdown()

        // 用户把备份改回原名后，下载从断点继续。
        try saved.write(to: fixture.store.fileURL)
        let third = fixture.makeCoordinator()
        await third.start()
        #expect(third.loadWarning == nil)
        try await third.waitForPhase(.completed, of: job.id)
        #expect(fixture.contents("a.bin") == fixture.netdisk.data(at: job.remoteDirectory + "/a.bin"))
    }

    @Test func failsWhenTransferredFilesAreMissing() async throws {
        let fixture = Fixture(share: ["docs/a.bin": randomData(1_000)])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        fixture.netdisk.setNextListing([])

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(coordinator.job(job.id)?.error?.contains("没有找到文件") == true)

        await coordinator.retry(job.id)
        try await coordinator.waitForPhase(.completed, of: job.id)
        #expect(fixture.contents("docs/a.bin") == fixture.netdisk.data(at: job.remoteDirectory + "/docs/a.bin"))
    }

    @Test func completesWhenOnlyEmptyDirectoriesAreSelected() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10)], emptyDirectories: ["empty", "nested/inner"])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()

        let entries = fixture.netdisk.rootEntries().filter(\.isDirectory)
        #expect(entries.map(\.name) == ["empty", "nested"])
        let job = coordinator.addJob(session: FakeNetdisk.session, entries: entries)
        try await coordinator.waitForPhase(.completed, of: job.id)
        let finished = try #require(coordinator.job(job.id))
        #expect(finished.files.isEmpty)
        #expect(finished.warning?.contains("没有文件") == true)
    }

    @Test func failsWhenListedFileIsOutsideJobDirectory() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10)])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        fixture.netdisk.setNextListing([RemoteFile(path: "/elsewhere/a.bin", size: 10, fsID: 1)])

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(coordinator.job(job.id)?.error?.contains("/elsewhere/a.bin") == true)
        #expect(coordinator.job(job.id)?.files.isEmpty == true)
    }

    @Test func failsOnUnsafeRelativePath() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10)])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        let job = coordinator.addJob(session: FakeNetdisk.session, entries: [])
        fixture.netdisk.setNextListing([
            RemoteFile(path: job.remoteDirectory + "/a.bin", size: 10, fsID: 1),
            RemoteFile(path: job.remoteDirectory + "/x/../../escape.bin", size: 10, fsID: 2),
        ])
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(coordinator.job(job.id)?.error?.contains("escape.bin") == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appending(path: "escape.bin").path))
    }

    @Test func renamesFilesThatCollideOnDisk() async throws {
        let share = ["Docs/a.txt": randomData(1_000), "docs/A.TXT": randomData(2_000)]
        let fixture = Fixture(share: share)
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.completed, of: job.id)
        let files = try #require(coordinator.job(job.id)?.files)
        #expect(Set(files.map(\.relativePath)) == ["Docs/a.txt", "docs/A (1).TXT"])
        for file in files {
            let data = try #require(file.localURL.map { try Data(contentsOf: $0) })
            #expect(data == fixture.netdisk.data(at: file.remotePath))
        }
    }

    @Test func failsWithoutLogin() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10)])
        let coordinator = fixture.makeCoordinator()
        coordinator.netdisk = nil
        await coordinator.start()

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(coordinator.job(job.id)?.error == "未登录百度网盘。")
    }

    // MARK: - 任务列表中无效的任务子目录

    /// 任务列表中的 `remoteDirectory` 可能被改成用户自己的目录。这些路径不是任务子目录，Ferry 不删除它们，也不转存到那里。
    private static let invalidJobDirectories = ["/", "/我的资料", ""]

    /// 从任务列表读出的分享任务，`remoteDirectory` 是给定的值（nil 时是 Ferry 写入的值）。
    private func savedShareJob(remoteDirectory: String?, phase: Job.Phase, fixture: Fixture) throws -> Job {
        var job = Job(link: FakeNetdisk.link, password: nil, entries: fixture.netdisk.rootEntries(), transferFolder: "/Ferry")
        job.phase = phase
        job.accountUK = Fixture.accountUK
        if phase == .downloading {
            let url = fixture.downloads.appending(path: "a.bin")
            try Data().write(to: url)
            job.files = [JobFile(remotePath: job.remoteDirectory + "/a.bin", relativePath: "a.bin", size: 0, localURL: url)]
        }
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        if let remoteDirectory { object["remoteDirectory"] = remoteDirectory }
        return try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func retryAndRemoveDeleteOnlyValidJobDirectory() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10)])
        let invalid = try Self.invalidJobDirectories.map {
            try savedShareJob(remoteDirectory: $0, phase: .failed(.transfer), fixture: fixture)
        }
        let valid = try savedShareJob(remoteDirectory: nil, phase: .failed(.transfer), fixture: fixture)
        try fixture.store.save(invalid + [valid])
        let coordinator = fixture.makeCoordinator(settings: FerrySettings(cleanupAfterDownload: true, maxConcurrentFiles: 4))
        await coordinator.start()

        for job in invalid {
            await coordinator.retry(job.id)
            try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
            #expect(coordinator.job(job.id)?.error == TransferCheckError.missingJobDirectory.errorDescription)
            await coordinator.remove(job.id)
        }
        #expect(fixture.netdisk.operations.isEmpty)

        await coordinator.remove(valid.id)
        #expect(fixture.netdisk.deletes == [[valid.remoteDirectory]])
    }

    @Test func retryOfValidJobDirectoryStillDeletesFirst() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10)])
        let job = try savedShareJob(remoteDirectory: nil, phase: .failed(.transfer), fixture: fixture)
        try fixture.store.save([job])
        let coordinator = fixture.makeCoordinator(settings: FerrySettings(cleanupAfterDownload: true, maxConcurrentFiles: 4))
        await coordinator.start()

        await coordinator.retry(job.id)
        try await coordinator.waitForPhase(.completed, of: job.id)
        // 重试前删除一次，清理时再删除一次。
        #expect(fixture.netdisk.deletes == [[job.remoteDirectory], [job.remoteDirectory]])
    }

    @Test func cleanupDeletesOnlyValidJobDirectory() async throws {
        let fixture = Fixture()
        let invalid = try Self.invalidJobDirectories.map {
            try savedShareJob(remoteDirectory: $0, phase: .downloading, fixture: fixture)
        }
        let valid = try savedShareJob(remoteDirectory: nil, phase: .downloading, fixture: fixture)
        try fixture.store.save(invalid + [valid])
        let coordinator = fixture.makeCoordinator(settings: FerrySettings(cleanupAfterDownload: true, maxConcurrentFiles: 4))
        await coordinator.start()

        for job in invalid + [valid] {
            try await coordinator.waitForPhase(.completed, of: job.id)
        }
        #expect(fixture.netdisk.deletes == [[valid.remoteDirectory]])
        #expect(coordinator.job(valid.id)?.isCleanedUp == true)
        #expect(invalid.allSatisfy { coordinator.job($0.id)?.isCleanedUp == false })
    }
}
