import DownloadKit
import FerryCore
import Foundation
import UniformTypeIdentifiers

extension Int64 {
    var byteCount: String { formatted(.byteCount(style: .file)) }
}

extension JobProgress {
    /// 例如 “12 MB / 100 MB · 2 MB/s · 剩余 3分钟”。
    var sizeSummary: String { "\(receivedBytes.byteCount) / \(totalBytes.byteCount)" }

    var summary: String {
        var parts = [sizeSummary]
        if bytesPerSecond > 0 {
            parts.append("\(Int64(bytesPerSecond).byteCount)/s")
        }
        if let remainingTime {
            let text = remainingTime.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
            parts.append("剩余 \(text)")
        }
        return parts.joined(separator: " · ")
    }
}

extension Job {
    var isUnfinished: Bool { phase != .completed }

    func statusText(downloads: [String: DownloadSnapshot]) -> String {
        switch phase {
        case .transferring:
            return "正在转存…"
        case .downloading:
            if isPaused { return "已暂停" }
            let pending = files.filter { !$0.isCompleted }
            if pending.isEmpty { return "正在清理网盘中的转存文件…" }
            let isRunning = pending.contains { downloads[$0.id]?.state == .running }
            return isRunning ? "正在下载" : "等待下载"
        case .completed:
            return "已完成"
        case .failed(.transfer):
            return "转存失败"
        case .failed(.download):
            return "下载失败"
        }
    }
}

extension DownloadSnapshot {
    var statusText: String {
        switch state {
        case .queued: "等待中"
        case .running: bytesPerSecond > 0 ? "\(Int64(bytesPerSecond).byteCount)/s" : "正在下载"
        case .paused: "已暂停"
        case .completed: "已完成"
        case .failed(let failure): failure.message
        }
    }
}

enum FileIcon {
    static func systemName(for name: String, isDirectory: Bool) -> String {
        if isDirectory { return "folder" }
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return "doc" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .text) { return "doc.text" }
        if type.conforms(to: .application) || type.conforms(to: .diskImage) { return "shippingbox" }
        return "doc"
    }
}
