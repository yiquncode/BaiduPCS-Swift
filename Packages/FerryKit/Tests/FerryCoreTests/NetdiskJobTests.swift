import BaiduKit
import DownloadKit
import Foundation
import Testing
@testable import FerryCore

/// 网盘任务：直接下载自己网盘中勾选的条目。Ferry 不删除、不移动、不修改它们，所以这些测试都打开清理开关，
/// 并检查假网盘没有收到 `delete`。
@MainActor @Suite struct NetdiskJobTests {
    private let disk: [String: Data] = [
        "/资料/2024/报告/摘要.pdf": randomData(200_000),
        "/资料/2024/报告/附录/数据.csv": randomData(1_000),
        "/资料/2024/其他.txt": randomData(100),
        "/资料/x.bin": randomData(300_000),
    ]
    private let cleanup = FerrySettings(cleanupAfterDownload: true, maxConcurrentFiles: 4)

    private func entry(_ path: String, directory: Bool, in disk: [String: Data]? = nil) -> NetdiskEntry {
        let size = (disk ?? self.disk)[path].map { Int64($0.count) } ?? 0
        return NetdiskEntry(fsID: Int64(path.hashValue), name: String(path.split(separator: "/").last!), path: path,
                            isDirectory: directory, size: size)
    }

    @Test func downloadsCheckedEntriesWithoutTheirParentDirectories() async throws {
        let fixture = Fixture(disk: disk)
        let coordinator = fixture.makeCoordinator(settings: cleanup)
        await coordinator.start()
        var completed: [Job.ID] = []
        coordinator.onJobCompleted = { completed.append($0.id) }

        let job = coordinator.addNetdiskJob(entries: [entry("/资料/2024/报告", directory: true), entry("/资料/x.bin", directory: false)])
        #expect(job.accountUK == Fixture.accountUK)
        #expect(job.downloadFolder == coordinator.downloadFolder)
        try await coordinator.waitForPhase(.completed, of: job.id)

        let finished = try #require(coordinator.job(job.id))
        #expect(finished.files.map(\.relativePath) == ["报告/摘要.pdf", "报告/附录/数据.csv", "x.bin"])
        #expect(finished.files.map(\.remotePath) == ["/资料/2024/报告/摘要.pdf", "/资料/2024/报告/附录/数据.csv", "/资料/x.bin"])
        for file in finished.files {
            #expect(fixture.contents(file.relativePath) == disk[file.remotePath], "\(file.relativePath)")
        }
        #expect(finished.warning == nil)
        #expect(!finished.isCleanedUp)
        #expect(completed == [job.id])
        // 只列出勾选的目录；勾选的文件不用列出。没有转存，也没有删除。
        #expect(fixture.netdisk.operations == [.list("/资料/2024/报告")])
        #expect(fixture.netdisk.remotePaths() == disk.keys.sorted())
        #expect(try fixture.store.load() == coordinator.jobs)
    }

    @Test func renamesSameNamedEntriesFromDifferentFolders() async throws {
        let disk = [
            "/a/报告.pdf": randomData(1_000), "/b/报告.pdf": randomData(2_000),
            "/a/docs/x.txt": randomData(100), "/b/docs/x.txt": randomData(200), "/b/docs/y.txt": randomData(300),
        ]
        let fixture = Fixture(disk: disk)
        let coordinator = fixture.makeCoordinator(settings: cleanup)
        await coordinator.start()

        let job = coordinator.addNetdiskJob(entries: [
            entry("/a/报告.pdf", directory: false, in: disk), entry("/b/报告.pdf", directory: false, in: disk),
            entry("/a/docs", directory: true, in: disk), entry("/b/docs", directory: true, in: disk),
        ])
        try await coordinator.waitForPhase(.completed, of: job.id)
        let files = try #require(coordinator.job(job.id)?.files)
        // 和分享任务相同的去重规则：同名文件改名，同名目录合并。
        #expect(files.map(\.relativePath) == ["报告.pdf", "报告 (1).pdf", "docs/x.txt", "docs/x (1).txt", "docs/y.txt"])
        for file in files {
            let data = try #require(file.localURL.map { try Data(contentsOf: $0) })
            #expect(data == disk[file.remotePath], "\(file.remotePath)")
        }
        #expect(fixture.netdisk.deletes.isEmpty)
    }

    @Test func completesWithWarningWhenCheckedFoldersAreEmpty() async throws {
        let fixture = Fixture(disk: disk)
        let coordinator = fixture.makeCoordinator(settings: cleanup)
        await coordinator.start()

        let job = coordinator.addNetdiskJob(entries: [entry("/空目录", directory: true)])
        try await coordinator.waitForPhase(.completed, of: job.id)
        let finished = try #require(coordinator.job(job.id))
        #expect(finished.files.isEmpty)
        #expect(finished.warning == "勾选的目录中没有文件，不需要下载。")
        // 不像分享任务那样再逐层检查一次。
        #expect(fixture.netdisk.operations == [.list("/空目录")])
    }

    @Test func retryListsAgainWithoutDeleting() async throws {
        let fixture = Fixture(disk: disk)
        let coordinator = fixture.makeCoordinator(settings: cleanup)
        await coordinator.start()
        fixture.netdisk.failNextList()

        let job = coordinator.addNetdiskJob(entries: [entry("/资料/2024/报告", directory: true)])
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(coordinator.job(job.id)?.error?.isEmpty == false)

        await coordinator.retry(job.id)
        try await coordinator.waitForPhase(.completed, of: job.id)
        #expect(fixture.netdisk.operations == [.list("/资料/2024/报告"), .list("/资料/2024/报告")])
        #expect(coordinator.job(job.id)?.files.count == 2)
        #expect(fixture.netdisk.remotePaths() == disk.keys.sorted())
    }

    @Test func downloadRetryDoesNotDelete() async throws {
        let fixture = Fixture(disk: disk)
        let coordinator = fixture.makeCoordinator(settings: cleanup)
        await coordinator.start()
        fixture.server.setFailing(["/x.bin"])

        let job = coordinator.addNetdiskJob(entries: [entry("/资料/x.bin", directory: false), entry("/资料/2024/其他.txt", directory: false)])
        try await coordinator.waitForPhase(.failed(.download), of: job.id)
        fixture.server.setFailing([])
        await coordinator.retry(job.id)
        try await coordinator.waitForPhase(.completed, of: job.id)

        #expect(fixture.server.requests(for: "/资料/2024/其他.txt") == 1)
        #expect(fixture.contents("x.bin") == disk["/资料/x.bin"])
        #expect(fixture.netdisk.operations.isEmpty)
    }

    @Test func removeNeverDeletes() async throws {
        let fixture = Fixture(disk: disk)
        let coordinator = fixture.makeCoordinator(settings: cleanup)
        await coordinator.start()

        // 下载中移除。
        fixture.server.setStalled(true)
        let running = coordinator.addNetdiskJob(entries: [entry("/资料/x.bin", directory: false)])
        try await waitUntil("running") {
            coordinator.job(running.id)?.files.contains { coordinator.downloads[$0.id]?.state == .running } ?? false
        }
        await coordinator.remove(running.id)
        fixture.server.setStalled(false)

        // 准备失败后移除。
        fixture.netdisk.failNextList()
        let failed = coordinator.addNetdiskJob(entries: [entry("/资料/2024/报告", directory: true)])
        try await coordinator.waitForPhase(.failed(.transfer), of: failed.id)
        await coordinator.remove(failed.id)

        // 完成后移除，并把下载的文件移到废纸篓。
        let completed = coordinator.addNetdiskJob(entries: [entry("/资料/2024", directory: true)])
        try await coordinator.waitForPhase(.completed, of: completed.id)
        let untrashed = await coordinator.remove(completed.id, trashingFiles: true)

        #expect(untrashed.isEmpty)
        #expect(coordinator.jobs.isEmpty)
        #expect(fixture.netdisk.deletes.isEmpty)
        #expect(fixture.netdisk.remotePaths() == disk.keys.sorted())
    }

    @Test func otherAccountJobIsNotListed() async throws {
        let fixture = Fixture(disk: disk)
        let coordinator = fixture.makeCoordinator(settings: cleanup)
        await coordinator.start()
        fixture.netdisk.failNextList()
        let job = coordinator.addNetdiskJob(entries: [entry("/资料/2024/报告", directory: true)])
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)

        coordinator.accountUK = Fixture.accountUK + 1
        #expect(coordinator.belongsToOtherAccount(try #require(coordinator.job(job.id))))
        await coordinator.retry(job.id)
        try await waitUntil("retry fails") {
            coordinator.job(job.id)?.error == CoordinatorError.otherAccount.errorDescription
        }
        #expect(coordinator.job(job.id)?.phase == .failed(.transfer))
        await coordinator.remove(job.id)
        #expect(fixture.netdisk.operations == [.list("/资料/2024/报告")])
    }

    @Test func failsWhenListedFileIsOutsideCheckedFolder() async throws {
        let fixture = Fixture(disk: disk)
        let coordinator = fixture.makeCoordinator(settings: cleanup)
        await coordinator.start()
        fixture.netdisk.setNextListing([RemoteFile(path: "/资料/2024/报告2/a.pdf", size: 10, fsID: 1)])

        let job = coordinator.addNetdiskJob(entries: [entry("/资料/2024/报告", directory: true)])
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(coordinator.job(job.id)?.error?.contains("/资料/2024/报告2/a.pdf") == true)
        #expect(coordinator.job(job.id)?.files.isEmpty == true)
        #expect(fixture.netdisk.deletes.isEmpty)
    }

    @Test func failsOnUnsafeRelativePath() async throws {
        let fixture = Fixture(disk: disk)
        let coordinator = fixture.makeCoordinator(settings: cleanup)
        await coordinator.start()
        fixture.netdisk.setNextListing([RemoteFile(path: "/资料/2024/报告/x/../../../escape.bin", size: 10, fsID: 1)])

        let job = coordinator.addNetdiskJob(entries: [entry("/资料/2024/报告", directory: true)])
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(coordinator.job(job.id)?.error?.contains("escape.bin") == true)
    }

    @Test func restoresInterruptedPreparationAsFailedAndRetries() async throws {
        let fixture = Fixture(disk: disk)
        var interrupted = Job(netdiskEntries: [entry("/资料/2024/报告", directory: true)])
        interrupted.accountUK = Fixture.accountUK
        try fixture.store.save([interrupted])

        let coordinator = fixture.makeCoordinator(settings: cleanup)
        await coordinator.start()
        let restored = try #require(coordinator.job(interrupted.id))
        #expect(restored.phase == .failed(.transfer))
        #expect(restored.error == "应用退出时准备没有完成。")
        #expect(restored.source == interrupted.source)

        await coordinator.retry(interrupted.id)
        try await coordinator.waitForPhase(.completed, of: interrupted.id)
        #expect(fixture.netdisk.operations == [.list("/资料/2024/报告")])
    }
}
