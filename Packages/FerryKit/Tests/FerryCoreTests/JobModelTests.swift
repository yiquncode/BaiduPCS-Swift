import BaiduKit
import Foundation
import Testing
@testable import FerryCore

@Suite struct JobModelTests {
    private let link = ShareLink.parse("https://pan.baidu.com/s/1qYZEsSc")!

    private func entry(_ name: String, directory: Bool = false) -> ShareEntry {
        ShareEntry(fsID: Int64(name.hashValue), name: name, path: "/s/" + name, isDirectory: directory, size: directory ? 0 : 10)
    }

    @Test func titleAndRemoteDirectory() {
        let id = UUID(uuidString: "abcdef12-0000-0000-0000-000000000000")!
        let single = Job(link: link, password: nil, entries: [entry("a.zip")], transferFolder: "Ferry/", id: id)
        #expect(single.title == "a.zip")
        #expect(single.remoteDirectory == "/Ferry/ABCDEF12")
        #expect(single.phase == .transferring)

        let many = Job(link: link, password: "ab12", entries: [entry("docs", directory: true), entry("b"), entry("c")], transferFolder: "/")
        #expect(many.title == "docs 等 3 项")
        #expect(many.remoteDirectory == "/" + Job.shortID(many.id))
    }

    @Test func mapsRemotePathsToLocalRelativePaths() {
        #expect(RemotePath.relativePath(of: "/Ferry/ABCD/a.zip", in: "/Ferry/ABCD") == "a.zip")
        #expect(RemotePath.relativePath(of: "/Ferry/ABCD/docs/2024/b c.txt", in: "/Ferry/ABCD") == "docs/2024/b c.txt")
        #expect(RemotePath.relativePath(of: "/Ferry/ABCDE/a.zip", in: "/Ferry/ABCD") == nil)
        #expect(RemotePath.relativePath(of: "/Ferry/ABCD", in: "/Ferry/ABCD") == nil)
        #expect(RemotePath.relativePath(of: "/Ferry/ABCD/", in: "/Ferry/ABCD") == "")
        #expect(RemotePath.relativePath(of: "Ferry/ABCD/a", in: "/Ferry/ABCD") == nil)
        // 分量按 NFC 比较；分量开头的组合字符不影响前缀判断。
        #expect(RemotePath.relativePath(of: "/Ferry/\u{E9}/a", in: "/Ferry/e\u{301}") == "a")
        #expect(RemotePath.relativePath(of: "/Ferry/X/\u{301}a", in: "/Ferry/X") == "\u{301}a")
        #expect(RemotePath.relativePath(of: "/Ferry/X\u{301}/a", in: "/Ferry/X") == nil)
        #expect(RemotePath.normalized("//a//b/") == "/a/b")
        #expect(RemotePath.normalized("") == "/")
    }

    @Test func rejectsUnsafeLocalPaths() {
        let base = URL(filePath: "/tmp/dl")
        for path in ["", ".", "..", "a/../../b", "a//b", "a/", "./a", "a/\u{0}b"] {
            #expect(!LocalPath.isSafe(path), "\(path)")
            #expect(LocalPath.destination(for: path, in: base) == nil, "\(path)")
        }
        #expect(LocalPath.destination(for: "docs/a b.txt", in: base)?.path == "/tmp/dl/docs/a b.txt")
        #expect(LocalPath.destination(for: "...", in: base)?.path == "/tmp/dl/...")
    }

    @Test func renamesPathsThatCollideOnDisk() {
        let paths = ["Docs/a.txt", "docs/A.TXT", "e\u{301}.txt", "\u{E9}.txt", "x.tar.gz", "X.tar.gz", ".env", ".ENV",
                     "dir", "dir/file", "plain"]
        #expect(LocalPath.deduplicated(paths) == [
            "Docs/a.txt", "docs/A (1).TXT", "e\u{301}.txt", "\u{E9} (1).txt", "x.tar.gz", "X.tar (1).gz", ".env", ".ENV (1)",
            "dir (1)", "dir/file", "plain",
        ])
        #expect(LocalPath.deduplicated(["a.txt", "A.txt", "a (1).txt"]) == ["a.txt", "A (1).txt", "a (1) (1).txt"])
    }

    @Test func revealURLsPointAtTopLevelItems() {
        var job = Job(link: link, password: nil, entries: [entry("docs", directory: true), entry("a.zip")], transferFolder: "/Ferry")
        let downloads = URL(filePath: "/tmp/dl")
        job.files = [
            JobFile(remotePath: "", relativePath: "docs/x/1.txt", size: 1, localURL: downloads.appending(path: "docs/x/1.txt")),
            JobFile(remotePath: "", relativePath: "docs/2.txt", size: 1, localURL: downloads.appending(path: "docs/2.txt")),
            JobFile(remotePath: "", relativePath: "a.zip", size: 1, localURL: downloads.appending(path: "a (1).zip")),
            JobFile(remotePath: "", relativePath: "b.zip", size: 1),
        ]
        #expect(job.revealURLs.map(\.path) == ["/tmp/dl/docs", "/tmp/dl/a (1).zip"])
        #expect(job.totalBytes == 4)
    }

    @Test func storeRoundTripsJobs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("JobStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JobStore(fileURL: directory.appendingPathComponent("nested/jobs.json"))
        #expect(try store.load().isEmpty)

        var first = Job(link: link, password: "ab12", entries: [entry("a.zip")], transferFolder: "/Ferry")
        first.phase = .failed(.download)
        first.error = "网络错误"
        first.isPaused = true
        first.files = [JobFile(remotePath: "/Ferry/X/a.zip", relativePath: "a.zip", size: 10, localURL: directory.appending(path: "a.zip"))]
        var second = Job(link: link, password: nil, entries: [entry("docs", directory: true)], transferFolder: "/Ferry")
        second.phase = .completed
        second.isCleanedUp = true
        second.warning = "清理失败"

        try store.save([first, second])
        #expect(try store.load() == [first, second])
    }

    @Test func decodesJobsWithMissingFields() throws {
        let json = """
        [{"id": "ABCDEF12-0000-0000-0000-000000000000", "link": {"surl": "qYZEsSc"}, "remoteDirectory": "/Ferry/ABCDEF12",
          "files": [{"id": "f1", "remotePath": "/Ferry/ABCDEF12/a.zip", "relativePath": "a.zip"}]}]
        """
        let jobs = try JSONDecoder().decode([Job].self, from: Data(json.utf8))
        let job = try #require(jobs.first)
        #expect(job.remoteDirectory == "/Ferry/ABCDEF12")
        #expect(job.phase == .failed(.transfer))
        #expect(job.source == .share(ShareLink(surl: "qYZEsSc")!, password: nil, entries: []))
        #expect(!job.isPaused)
        #expect(job.files.map(\.relativePath) == ["a.zip"])
        #expect(job.files.first?.size == 0)
        #expect(job.files.first?.isCompleted == false)
    }

    @Test func decodesOldShareJobsWithoutSource() throws {
        // 旧版本写入的任务：没有 `source`，分享的字段在顶层。
        let json = """
        [{"id": "ABCDEF12-0000-0000-0000-000000000000", "title": "docs 等 2 项",
          "link": {"surl": "qYZEsSc", "password": "ab12"}, "password": "cd34",
          "entries": [{"fsID": 1, "name": "docs", "path": "/s/docs", "isDirectory": true, "size": 0, "relativeDirectory": ""},
                      {"fsID": 2, "name": "a.zip", "path": "/s/a.zip", "isDirectory": false, "size": 10, "relativeDirectory": ""}],
          "remoteDirectory": "/Ferry/ABCDEF12", "phase": {"downloading": {}}, "files": [], "isPaused": true,
          "createdAt": 0, "isCleanedUp": false, "accountUK": 7}]
        """
        let job = try #require(try JSONDecoder().decode([Job].self, from: Data(json.utf8)).first)
        let entries = [
            ShareEntry(fsID: 1, name: "docs", path: "/s/docs", isDirectory: true, size: 0),
            ShareEntry(fsID: 2, name: "a.zip", path: "/s/a.zip", isDirectory: false, size: 10),
        ]
        #expect(job.source == .share(ShareLink(surl: "qYZEsSc", password: "ab12")!, password: "cd34", entries: entries))
        #expect(job.link?.surl == "qYZEsSc")
        #expect(job.password == "cd34")
        #expect(job.remoteDirectory == "/Ferry/ABCDEF12")
        #expect(job.hasJobDirectory)
        #expect(job.title == "docs 等 2 项")
        #expect(job.phase == .downloading)
        #expect(job.isPaused)
        #expect(job.accountUK == 7)

        // 再写入时，分享的字段仍在顶层，旧版本也能读取。
        let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        #expect(encoded["source"] as? String == "share")
        #expect(encoded["remoteDirectory"] as? String == "/Ferry/ABCDEF12")
        #expect(encoded["password"] as? String == "cd34")
        #expect((encoded["link"] as? [String: Any])?["surl"] as? String == "qYZEsSc")
        #expect((encoded["entries"] as? [Any])?.count == 2)
        #expect(try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job)) == job)
    }

    @Test func netdiskJobsHaveNoJobDirectoryAndRoundTrip() throws {
        let entries = [
            NetdiskEntry(fsID: 1, name: "报告", path: "/资料/2024/报告", isDirectory: true, size: 0,
                         modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            NetdiskEntry(fsID: 2, name: "a.zip", path: "/a.zip", isDirectory: false, size: 10),
        ]
        var job = Job(netdiskEntries: entries)
        #expect(job.source == .netdisk(entries: entries))
        #expect(job.title == "报告 等 2 项")
        #expect(Job(netdiskEntries: [entries[1]]).title == "a.zip")
        #expect(Job(netdiskEntries: [entries[1]]).source.isSingleFile)
        #expect(!job.source.isSingleFile)
        #expect(job.remoteDirectory.isEmpty)
        #expect(!job.hasJobDirectory)
        #expect(job.link == nil)
        #expect(job.password == nil)
        #expect(job.phase == .transferring)

        job.phase = .failed(.download)
        job.accountUK = 7
        job.files = [JobFile(remotePath: "/a.zip", relativePath: "a.zip", size: 10)]
        let data = try JSONEncoder().encode([job])
        #expect(try JSONDecoder().decode([Job].self, from: data) == [job])
        let encoded = try #require((try JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first)
        #expect(encoded["source"] as? String == "netdisk")
        #expect(encoded["link"] == nil)
        #expect(encoded["remoteDirectory"] == nil)
    }

    @Test func netdiskJobsIgnoreRecordedRemoteDirectory() throws {
        // 网盘任务一定没有任务子目录，即使文件中有这个键。
        let json = """
        {"id": "ABCDEF12-0000-0000-0000-000000000000", "source": "netdisk", "remoteDirectory": "/资料",
         "entries": [{"fsID": 1, "name": "资料", "path": "/资料", "isDirectory": true, "size": 0}]}
        """
        let job = try JSONDecoder().decode(Job.self, from: Data(json.utf8))
        #expect(job.remoteDirectory.isEmpty)
        #expect(!job.hasJobDirectory)
        #expect(job.title == "资料")
        #expect(job.phase == .failed(.transfer))
    }

    @Test func parentOfRemotePath() {
        #expect(RemotePath.parent(of: "/资料/2024/报告") == "/资料/2024")
        #expect(RemotePath.parent(of: "/a") == "/")
        #expect(RemotePath.parent(of: "/a/b/") == "/a")
        #expect(RemotePath.parent(of: "/") == "/")
    }

    @Test func settingsKeepOtherFieldsWhenOneIsInvalid() throws {
        let bookmark = Data([1, 2, 3])
        let json = """
        {"downloadDirectoryBookmark": "\(bookmark.base64EncodedString())", "maxConcurrentFiles": "many", "futureField": 1}
        """
        let settings = try JSONDecoder().decode(FerrySettings.self, from: Data(json.utf8))
        #expect(settings.downloadDirectoryBookmark == bookmark)
        #expect(settings.maxConcurrentFiles == 1)
        #expect(settings.transferFolder == "/Ferry")
        #expect(try JSONDecoder().decode(FerrySettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func movesUnreadableStoreAside() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("JobStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = JobStore(fileURL: directory.appendingPathComponent("jobs.json"))
        let garbage = Data("not json".utf8)
        try garbage.write(to: store.fileURL)
        #expect(throws: (any Error).self) { try store.load() }

        let now = Date(timeIntervalSince1970: 1_000)
        let first = try #require(store.moveAsideUnreadableFile(now: now))
        #expect(first.lastPathComponent == "jobs.json.corrupt-1000")
        #expect(try Data(contentsOf: first) == garbage)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))

        try garbage.write(to: store.fileURL)
        let second = try #require(store.moveAsideUnreadableFile(now: now))
        #expect(second.lastPathComponent == "jobs.json.corrupt-1000-1")
    }

    @Test func settingsClampConcurrency() {
        let settings = FerrySettings(maxConcurrentFiles: 0, connectionsPerFile: 99)
        let configuration = settings.downloadConfiguration()
        #expect(configuration.maxConcurrentFiles == 1)
        #expect(configuration.segmentsPerFile == FerrySettings.connectionsRange.upperBound)
        #expect(FerrySettings().transferFolder == "/Ferry")
        #expect(FerrySettings().cleanupAfterDownload)
    }

    @Test func settingsLimitTotalConnections() throws {
        var settings = FerrySettings(maxConcurrentFiles: 3, connectionsPerFile: 8)
        #expect(settings.allowedConcurrentFiles == 1...2)
        #expect(settings.allowedConnections == 1...6)
        let configuration = settings.downloadConfiguration()
        #expect(configuration.maxConcurrentFiles == 3)
        #expect(configuration.segmentsPerFile == 6)

        settings.limitConcurrency()
        #expect(settings == FerrySettings(maxConcurrentFiles: 3, connectionsPerFile: 6))

        let json = #"{"maxConcurrentFiles": 10, "connectionsPerFile": 16}"#
        let decoded = try JSONDecoder().decode(FerrySettings.self, from: Data(json.utf8))
        #expect(decoded.maxConcurrentFiles == 10)
        #expect(decoded.connectionsPerFile == 2)
    }

    @Test func settingsMatchConcurrencyPresets() {
        var settings = FerrySettings()
        #expect(settings.concurrencyPreset == .regular)
        settings.apply(.svip)
        #expect(settings.concurrencyPreset == .svip)
        #expect(settings.downloadConfiguration().segmentsPerFile == ConcurrencyPreset.svip.connectionsPerFile)
        settings.connectionsPerFile += 1
        #expect(settings.concurrencyPreset == nil)
    }

    @Test func downloadContextCarriesRemotePath() {
        let path = "/Ferry/ABCD/目录/a b.zip"
        #expect(BaiduDownloadSource.remotePath(from: BaiduDownloadSource.context(forRemotePath: path)) == path)
    }
}
