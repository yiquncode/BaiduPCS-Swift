import BaiduKit
import Foundation
import Testing
@testable import FerryCore

@Suite final class JobFileTrashTests {
    private let downloads = FileManager.default.temporaryDirectory.appendingPathComponent("JobFileTrash-\(UUID().uuidString)")
    private var trashed: [String] = []

    deinit {
        try? FileManager.default.removeItem(at: downloads)
    }

    private func write(_ relativePath: String) throws {
        let url = downloads.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: downloads.appending(path: relativePath).path)
    }

    /// 文件都已下载完，位置是下载目录中的相对路径。
    private func job(_ relativePaths: [String]) -> Job {
        let entry = ShareEntry(fsID: 1, name: "x", path: "/x", isDirectory: false, size: 1)
        var job = Job(link: ShareLink.parse("https://pan.baidu.com/s/1qYZEsSc")!, password: nil, entries: [entry], transferFolder: "/Ferry")
        job.files = relativePaths.map { path in
            JobFile(remotePath: "/Ferry/x/" + path, relativePath: path, size: 1, localURL: downloads.appending(path: path))
        }
        job.phase = .completed
        return job
    }

    /// 记录相对路径，然后删除。
    private func trash(_ url: URL) throws {
        trashed.append(String(url.standardizedFileURL.path.dropFirst(downloads.standardizedFileURL.path.count + 1)))
        try FileManager.default.removeItem(at: url)
    }

    @Test func trashesWholeDirectoryThatHoldsOnlyJobFiles() throws {
        try write("Show/a.mkv")
        try write("Show/S1/b.mkv")
        try write("Show/.DS_Store")

        let failed = JobFileTrash.trash(job(["Show/a.mkv", "Show/S1/b.mkv"]), using: trash)

        #expect(failed.isEmpty)
        #expect(trashed == ["Show"])
        #expect(!exists("Show"))
    }

    @Test func keepsUserFilesInExistingDirectory() throws {
        try write("Show/mine.txt")
        try write("Show/a.mkv")
        try write("Show/S1/b.mkv")
        try write("Show/S1/.DS_Store")

        let failed = JobFileTrash.trash(job(["Show/a.mkv", "Show/S1/b.mkv"]), using: trash)

        #expect(failed.isEmpty)
        #expect(Set(trashed) == ["Show/a.mkv", "Show/S1/b.mkv"])
        #expect(exists("Show/mine.txt"))
        #expect(!exists("Show/S1"))
    }

    @Test func skipsFilesThatAreGone() throws {
        try write("a.bin")

        let failed = JobFileTrash.trash(job(["a.bin", "moved.bin"]), using: trash)

        #expect(failed.isEmpty)
        #expect(trashed == ["a.bin"])
    }

    @Test func reportsItemsThatCannotBeTrashed() throws {
        try write("a.bin")

        let failed = JobFileTrash.trash(job(["a.bin"])) { _ in throw CocoaError(.fileWriteNoPermission) }

        #expect(failed.map(\.lastPathComponent) == ["a.bin"])
        #expect(exists("a.bin"))
    }
}
