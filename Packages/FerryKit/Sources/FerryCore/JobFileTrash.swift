import Foundation

/// 把任务下载完的文件移到废纸篓。
///
/// 任务的顶层目录可能是下载目录中原来就有的同名目录，里面还有用户自己的文件。所以顶层目录中只有任务的文件时，
/// 才把整个目录移到废纸篓（废纸篓中只多一项，可以整个放回）；否则逐个移动任务的文件，再删除因此变空的目录。
enum JobFileTrash {
    /// Finder 自己创建的文件。判断目录中是否只有任务的文件、目录是否为空时不算它。
    private static let ignoredNames: Set<String> = [".DS_Store"]

    /// 返回没能移到废纸篓的文件或目录。已经不在原位置的文件不算失败。
    static func trash(_ job: Job, using trashItem: (URL) throws -> Void) -> [URL] {
        let owned = job.files.compactMap(\.localURL)
        let ownedKeys = Set(owned.map(key))
        var failed: [URL] = []
        for top in job.revealURLs where exists(top) {
            if !isDirectory(top) || containsOnly(ownedKeys, in: top) {
                do { try trashItem(top) } catch { failed.append(top) }
                continue
            }
            let prefix = key(top) + "/"
            for file in owned where key(file).hasPrefix(prefix) && exists(file) {
                do {
                    try trashItem(file)
                    removeEmptyDirectories(from: file.deletingLastPathComponent(), through: top)
                } catch {
                    failed.append(file)
                }
            }
        }
        return failed
    }

    /// 目录中除了 Finder 的文件以外，只有 `keys` 中的文件。无法读取时返回 false。
    private static func containsOnly(_ keys: Set<String>, in directory: URL) -> Bool {
        var isReadable = true
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [],
            errorHandler: { _, _ in isReadable = false; return false }
        ) else { return false }
        for case let url as URL in enumerator where !ignoredNames.contains(url.lastPathComponent) {
            if isDirectory(url) { continue }
            guard keys.contains(key(url)) else { return false }
        }
        return isReadable
    }

    /// 从 `directory` 向上删除空目录，最多删到 `top`。
    private static func removeEmptyDirectories(from directory: URL, through top: URL) {
        let fileManager = FileManager.default
        var directory = directory
        while key(directory) == key(top) || key(directory).hasPrefix(key(top) + "/") {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path),
                  contents.allSatisfy(ignoredNames.contains),
                  (try? fileManager.removeItem(at: directory)) != nil,
                  key(directory) != key(top) else { return }
            directory.deleteLastPathComponent()
        }
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}
