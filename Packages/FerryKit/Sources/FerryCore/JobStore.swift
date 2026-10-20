import Foundation

/// 把任务列表以 JSON 保存在一个文件中。
public struct JobStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 文件不存在时返回空列表。
    public func load() throws -> [Job] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([Job].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ jobs: [Job]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(jobs).write(to: fileURL, options: .atomic)
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
