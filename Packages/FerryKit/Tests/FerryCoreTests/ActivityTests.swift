import BaiduKit
import DownloadKit
import Foundation
import Testing
@testable import FerryCore

/// 保存合并和界面观察的进度对象。
@MainActor @Suite struct ActivityTests {
    @Test func completedFilesAreSavedTogether() async throws {
        let share = Dictionary(uniqueKeysWithValues: (0..<40).map { ("f\($0).bin", randomData(1_000)) })
        let fixture = Fixture(share: share)
        let coordinator = fixture.makeCoordinator()
        coordinator.saveDelay = .seconds(10)
        await coordinator.start()
        let before = coordinator.saveCount

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.completed, of: job.id)
        // 添加、开始下载、完成各保存一次；40 个文件的完成状态随这些保存一起写入。
        #expect(coordinator.saveCount - before <= 4)
        let saved = try #require(try fixture.store.load().first)
        #expect(saved.files.count == 40)
        #expect(saved.files.allSatisfy { $0.isCompleted })
        // 保存之后，引擎才删除完成的文件下载的状态。
        try await waitUntil("engine forgets completed downloads") { (try? fixture.stateFiles().isEmpty) == true }
    }

    @Test func completionIsSavedAfterDelay() async throws {
        let fixture = Fixture(share: ["small.bin": randomData(1_000), "big.bin": randomData(400_000)])
        let coordinator = fixture.makeCoordinator()
        coordinator.saveDelay = .milliseconds(50)
        await coordinator.start()
        fixture.server.setStalling(["/big.bin"])

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await waitUntil("small file completed") {
            coordinator.job(job.id)?.files.first { $0.relativePath == "small.bin" }?.isCompleted == true
        }
        try await waitUntil("completion saved") {
            (try? fixture.store.load().first?.files.first { $0.relativePath == "small.bin" }?.isCompleted) == true
        }
        #expect(coordinator.job(job.id)?.phase == .downloading)
        fixture.server.setStalling([])
        try await coordinator.waitForPhase(.completed, of: job.id)
    }

    @Test func activitiesFollowDownloads() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(400_000), "b.bin": randomData(400_000)])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        fixture.server.setStalled(true)

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        let activity = coordinator.activity(of: job.id)
        #expect(coordinator.activity(of: job.id) === activity)
        try await waitUntil("running with progress") { activity.isRunning && activity.progress.receivedBytes > 0 }
        let file = try #require(coordinator.job(job.id)?.files.first)
        let fileActivity = coordinator.activity(ofFile: file.id)
        #expect(fileActivity.snapshot?.state == .running)

        await coordinator.pause(job.id)
        try await waitUntil("paused") { !activity.isRunning && fileActivity.snapshot?.state == .paused }

        fixture.server.setStalled(false)
        await coordinator.resume(job.id)
        try await coordinator.waitForPhase(.completed, of: job.id)
        try await waitUntil("complete progress") { activity.progress.fractionCompleted == 1 }
        let finished = try #require(coordinator.job(job.id))
        #expect(activity.progress == coordinator.progress(of: finished))
    }
}
