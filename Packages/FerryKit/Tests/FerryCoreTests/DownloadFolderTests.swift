import BaiduKit
import DownloadKit
import Foundation
import Testing
@testable import FerryCore

@MainActor @Suite struct DownloadFolderTests {
    /// 下载到一半后退出。返回任务。
    private func startPartialDownload(_ fixture: Fixture) async throws -> Job {
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
        return job
    }

    private func makeFolder(_ fixture: Fixture, _ name: String) throws -> URL {
        let url = fixture.directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func jobKeepsItsFolderAfterSettingChanges() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(400_000)])
        let job = try await startPartialDownload(fixture)
        #expect(try fixture.store.load().first?.downloadFolder?.url == fixture.downloads)

        let other = try makeFolder(fixture, "other")
        let access = FakeFolderAccess()
        let second = fixture.makeCoordinator(downloadFolder: other, folderAccess: access)
        await second.start()
        #expect(access.opened == [fixture.downloads.path])
        try await second.waitForPhase(.completed, of: job.id)
        #expect(fixture.contents("a.bin") == fixture.netdisk.data(at: job.remoteDirectory + "/a.bin"))
        #expect(!FileManager.default.fileExists(atPath: other.appending(path: "a.bin").path))
        #expect(access.closed == [fixture.downloads.path])

        // 新任务使用设置中的目录。
        let added = second.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await second.waitForPhase(.completed, of: added.id)
        #expect(second.job(added.id)?.downloadFolder?.url == other)
        #expect(FileManager.default.fileExists(atPath: other.appending(path: "a.bin").path))
    }

    @Test func inaccessibleFolderFailsJobUntilFixed() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(400_000)])
        let job = try await startPartialDownload(fixture)

        let access = FakeFolderAccess()
        access.setFailing([fixture.downloads.path])
        let second = fixture.makeCoordinator(folderAccess: access)
        await second.start()
        #expect(second.job(job.id)?.phase == .failed(.download))
        #expect(second.job(job.id)?.error?.contains("不可访问") == true)

        await second.retry(job.id)
        #expect(second.job(job.id)?.phase == .failed(.download))

        access.setFailing([])
        await second.retry(job.id)
        try await second.waitForPhase(.completed, of: job.id)
        #expect(fixture.contents("a.bin") == fixture.netdisk.data(at: job.remoteDirectory + "/a.bin"))
    }

    @Test func newJobFailsBeforeTransferWhenFolderIsMissing() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(10)])
        let missing = fixture.directory.appendingPathComponent("missing")
        let coordinator = fixture.makeCoordinator(downloadFolder: missing)
        await coordinator.start()

        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await coordinator.waitForPhase(.failed(.transfer), of: job.id)
        #expect(coordinator.job(job.id)?.error?.contains("不可访问") == true)
        #expect(fixture.netdisk.operations.isEmpty)
    }

    @Test func removeReleasesFolder() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(400_000)])
        let access = FakeFolderAccess()
        let coordinator = fixture.makeCoordinator(folderAccess: access)
        await coordinator.start()
        fixture.server.setStalled(true)
        let job = coordinator.addJob(session: FakeNetdisk.session, entries: fixture.netdisk.rootEntries())
        try await waitUntil("downloading") { coordinator.job(job.id)?.phase == .downloading }
        #expect(access.opened == [fixture.downloads.path])
        #expect(access.closed.isEmpty)

        await coordinator.remove(job.id)
        fixture.server.setStalled(false)
        #expect(access.closed == [fixture.downloads.path])
    }

    @Test func reselectedFolderReplacesBrokenBookmark() async throws {
        let fixture = Fixture(share: ["a.bin": randomData(400_000)])
        let job = try await startPartialDownload(fixture)
        var saved = try fixture.store.load()
        saved[0].downloadFolder = DownloadFolder(url: fixture.downloads, bookmark: Data("broken".utf8))
        try fixture.store.save(saved)

        // 设置中的下载目录是同一个位置（用户重新选择了它）。
        let second = fixture.makeCoordinator()
        await second.start()
        try await second.waitForPhase(.completed, of: job.id)
        #expect(second.job(job.id)?.downloadFolder == DownloadFolder(url: fixture.downloads))
    }

    @Test func securityScopedAccessChecksFolder() throws {
        let access = SecurityScopedFolderAccess()
        let existing = FileManager.default.temporaryDirectory
        let opened = try access.open(DownloadFolder(url: existing))
        #expect(opened.url == existing)
        #expect(!opened.isSecurityScoped)
        access.close(opened)

        let missing = existing.appendingPathComponent("missing-\(UUID().uuidString)")
        #expect(throws: DownloadFolderError.inaccessible(missing)) { try access.open(DownloadFolder(url: missing)) }
        #expect(throws: DownloadFolderError.inaccessible(existing)) {
            try access.open(DownloadFolder(url: existing, bookmark: Data("broken".utf8)))
        }
    }
}
