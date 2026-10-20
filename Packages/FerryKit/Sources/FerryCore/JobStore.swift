import Foundation

/// 把任务列表以 JSON 保存在一个文件中。
public struct JobStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 文件不存在时返回空列表。文件无法读取或解码时抛出错误。
    public func load() throws -> [Job] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([Job].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ jobs: [Job]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(jobs).write(to: fileURL, options: .atomic)
    }

    /// 把无法读取的任务列表改名为 `jobs.json.corrupt-<时间戳>`，返回新位置。改名失败时返回 nil。
    public func moveAsideUnreadableFile(now: Date = .now) -> URL? {
        let stamp = Int(now.timeIntervalSince1970)
        let directory = fileURL.deletingLastPathComponent()
        var backup = directory.appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(stamp)")
        var suffix = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = directory.appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(stamp)-\(suffix)")
            suffix += 1
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: backup)
            return backup
        } catch {
            return nil
        }
    }
}

/// Ferry 在 Application Support 中的文件。
public enum FerryDirectories {
    public static var applicationSupport: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Ferry", isDirectory: true)
    }

    public static var jobsFile: URL { applicationSupport.appendingPathComponent("jobs.json") }

    /// 下载引擎保存分片进度的目录。
    public static var downloadState: URL { applicationSupport.appendingPathComponent("Downloads", isDirectory: true) }
}
