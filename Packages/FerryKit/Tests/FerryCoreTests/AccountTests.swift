import BaiduKit
import DownloadKit
import Foundation
import Testing
@testable import FerryCore

/// 换账号后，不对旧账号的任务做网盘操作。
@MainActor @Suite struct AccountTests {
    @Test func otherAccountSkipsCleanupAndRemoteDeletion() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(400_000), "b.bin": randomData(400_000)])
        let coordinator = fixture.makeCoordinator(settings: FerrySettings(cleanupAfterDownload: true, maxConcurrentFiles: 4))
        await coordinator.start()
        fixture.server.setStalled(true)
        let entries = fixture.netdisk.rootEntries()
        let first = coordinator.addJob(session: FakeNetdisk.session, entries: [entries[0]])
        let second = coordinator.addJob(session: FakeNetdisk.session, entries: [entries[1]])
        try await waitUntil("downloading") {
            coordinator.job(first.id)?.phase == .downloading && coordinator.job(second.id)?.phase == .downloading
        }
        #expect(coordinator.job(first.id)?.accountUK == Fixture.accountUK)

        coordinator.accountUK = 2
        #expect(coordinator.job(first.id).map(coordinator.belongsToOtherAccount) == true)
        let operations = fixture.netdisk.operations.count
        await coordinator.remove(second.id)
        fixture.server.setStalled(false)
        try await coordinator.waitForPhase(.completed, of: first.id)

        #expect(fixture.netdisk.operations.count == operations)
        let finished = try #require(coordinator.job(first.id))
        #expect(!finished.isCleanedUp)
        #expect(finished.warning?.contains("另一个百度账号") == true)
    }

    @Test func otherAccountCannotRetryTransfer() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10)])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        fixture.netdisk.failNextTransfer()
        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)

        coordinator.accountUK = 2
        let operations = fixture.netdisk.operations.count
        await coordinator.retry(job.id)
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(coordinator.job(job.id)?.error?.contains("另一个百度账号") == true)
        #expect(fixture.netdisk.operations.count == operations)

        coordinator.accountUK = Fixture.accountUK
        await coordinator.retry(job.id)
        try await coordinator.waitForPhase(.completed, of: job.id)
    }
}
