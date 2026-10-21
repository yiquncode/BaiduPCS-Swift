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
        // 第一个任务已经取得下载链接。换账号后，它用这个链接下载完。
        try await waitUntil("downloading") {
            coordinator.job(first.id)?.phase == .downloading && coordinator.job(second.id)?.phase == .downloading
                && coordinator.job(first.id)?.files.first.map { fixture.server.requests(for: $0.remotePath) > 0 } == true
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

    /// 旧版本创建的分享任务没有记录账号。重试时记为当前账号：任务子目录由转存创建，不是用户自己的文件。
    @Test func oldShareJobAdoptsCurrentAccount() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10)])
        let saved = Job(link: FakeNetdisk.link, password: nil, entries: fixture.netdisk.rootEntries(), transferFolder: "/Ferry")
        try fixture.store.save([saved])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()

        await coordinator.retry(saved.id)
        try await coordinator.waitForPhase(.completed, of: saved.id)
        #expect(coordinator.job(saved.id)?.accountUK == Fixture.accountUK)
    }

    /// 文件下载加入引擎前换了账号：不为它获取下载链接，文件下载直接失败。换回原来的账号后重试，正常下载。
    @Test func otherAccountGetsNoDownloadLink() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10_000)])
        let coordinator = fixture.makeCoordinator()
        await coordinator.start()
        coordinator.willEnqueue = { _ in coordinator.accountUK = 2 }
        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.failed(.download), of: job.id)

        let file = try #require(coordinator.job(job.id)?.files.first)
        #expect(coordinator.job(job.id)?.error == DownloadFailure.resolveFailed(CoordinatorError.otherAccount.errorDescription!).message)
        #expect(fixture.server.resolves(for: file.remotePath) == 0)

        coordinator.willEnqueue = nil
        coordinator.accountUK = Fixture.accountUK
        await coordinator.retry(job.id)
        try await coordinator.waitForPhase(.completed, of: job.id)
        #expect(fixture.contents("a.bin") == fixture.netdisk.data(at: file.remotePath))
    }
}
