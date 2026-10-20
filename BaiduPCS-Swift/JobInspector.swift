import AppKit
import BaiduKit
import DownloadKit
import FerryCore
import SwiftUI

/// 详情栏：选中任务的详情和操作。选中多个任务时显示对它们的批量操作。
struct JobInspector: View {
    let jobs: [Job]
    /// 请求移除任务。调用方决定是否先确认。
    let onRemove: ([Job], JobRemoval) -> Void

    var body: some View {
        switch jobs.count {
        case 0:
            ContentUnavailableView("未选择任务", systemImage: "sidebar.trailing")
        case 1:
            JobDetail(job: jobs[0], onRemove: { onRemove(jobs, $0) })
                // 换任务时重新滚动到顶部。
                .id(jobs[0].id)
        default:
            MultipleSelection(jobs: jobs, onRemove: { onRemove(jobs, $0) })
        }
    }
}

/// 选中多个任务：数量和对这些任务的操作。和单个任务的详情一样，只列出可用的操作。
private struct MultipleSelection: View {
    let jobs: [Job]
    let onRemove: (JobRemoval) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("已选择 \(jobs.count) 个任务", systemImage: "square.stack")
        } actions: {
            VStack {
                ForEach(JobAction.allCases, id: \.self) { action in
                    let targets = model.jobs(in: jobs, allowing: action)
                    if !targets.isEmpty {
                        Button {
                            model.perform(action, on: targets)
                        } label: {
                            Text(action.title).frame(maxWidth: .infinity)
                        }
                    }
                }
                Button(role: .destructive) {
                    onRemove(.keepingFiles)
                } label: {
                    Text("移除").frame(maxWidth: .infinity)
                }
                .disabled(!jobs.contains { model.canOperate(on: $0) })
                if model.canTrashFiles(of: jobs) {
                    Button(role: .destructive) {
                        onRemove(.trashingFiles)
                    } label: {
                        Text("移除并删除文件…").frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(maxWidth: 180)
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
}

/// 一个任务的详情。
private struct JobDetail: View {
    let job: Job
    let onRemove: (JobRemoval) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        // 不在这里读取进度，进度变化只让读取它的子视图刷新。
        let activity = model.coordinator.activity(of: job.id)
        let isRemoving = model.coordinator.removingJobs.contains(job.id)
        Form {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: job.systemImage)
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.title)
                            .font(.headline)
                            .textSelection(.enabled)
                        JobStatusText(job: job, activity: activity, isRemoving: isRemoving)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                JobProgressBar(job: job, activity: activity, isRemoving: isRemoving)
                JobNotes(job: job)
            }
            Section("统计") {
                JobStats(job: job, activity: activity)
            }
            Section("位置") {
                LabeledContent("来源") {
                    HStack(spacing: 4) {
                        PathText(job.sourceLink)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(job.sourceLink, forType: .string)
                        } label: {
                            Label("拷贝链接", systemImage: "doc.on.doc")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("拷贝链接")
                    }
                }
                if !job.isCleanedUp {
                    LabeledContent("网盘") { PathText(job.remoteDirectory) }
                }
                LabeledContent("本地") {
                    PathText((job.downloadFolder ?? model.coordinator.downloadFolder).url.path(percentEncoded: false))
                }
            }
            if !job.files.isEmpty {
                Section("文件（\(job.files.count)）") {
                    ForEach(job.files) { file in
                        FileRow(file: file, activity: model.coordinator.activity(ofFile: file.id))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaBar(edge: .bottom, spacing: 0) {
            HStack {
                if let action = job.primaryAction, action != .reveal {
                    JobActionButton(job: job, action: action)
                }
                if !job.revealURLs.isEmpty {
                    JobActionButton(job: job, action: .reveal)
                }
                Spacer(minLength: 0)
                // 点按钮只移除任务；删除文件在按钮的菜单中，是不常用的破坏性操作。
                Menu("移除") {
                    Button("移除并删除文件…", role: .destructive) { onRemove(.trashingFiles) }
                        .disabled(!model.canTrashFiles(of: [job]))
                } primaryAction: {
                    onRemove(.keepingFiles)
                }
                .fixedSize()
                .disabled(!model.canOperate(on: job))
            }
            .labelStyle(.titleOnly)
            .padding()
        }
    }
}

/// 任务的状态文字。
private struct JobStatusText: View {
    let job: Job
    let activity: JobActivity
    let isRemoving: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(isRemoving
             ? "正在移除…"
             : job.statusText(isRunning: activity.isRunning, cleansUp: model.settings.cleanupAfterDownload))
    }
}

/// 已下载 / 总大小、速度、剩余时间和文件完成数。没有值时显示“—”。
private struct JobStats: View {
    let job: Job
    let activity: JobActivity

    var body: some View {
        let progress = activity.progress
        let isDownloading = job.phase == .downloading && !job.isPaused
        Group {
            LabeledContent("已下载", value: job.files.isEmpty ? "—" : progress.sizeSummary)
            LabeledContent("速度", value: isDownloading ? progress.speedText ?? "—" : "—")
            LabeledContent("剩余时间", value: isDownloading ? progress.remainingTimeText ?? "—" : "—")
            LabeledContent("文件", value: job.files.isEmpty
                           ? "—" : "\(job.files.count(where: \.isCompleted)) / \(job.files.count)")
        }
        .monospacedDigit()
    }
}

/// 详情栏中的一个路径或链接：一行，中间截断，可以选择。悬停时显示全文。
private struct PathText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(text)
    }
}

/// 任务中的一个文件下载。只观察这个文件的状态。
private struct FileRow: View {
    let file: JobFile
    let activity: FileActivity

    var body: some View {
        let snapshot = activity.snapshot
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: FileIcon.systemName(for: file.name, isDirectory: false))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.relativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.relativePath)
                HStack(spacing: 6) {
                    if file.isCompleted {
                        Label("已完成", systemImage: "checkmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.green)
                    } else if let snapshot {
                        if case .failed(let failure) = snapshot.state {
                            Label(failure.message, systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(failure.message)
                        } else {
                            Text(snapshot.statusText)
                            ProgressView(value: fraction(snapshot))
                                .frame(maxWidth: 80)
                                .accessibilityHidden(true)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(file.size.byteCount)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
    }

    private func fraction(_ snapshot: DownloadSnapshot) -> Double {
        let total = snapshot.totalBytes ?? file.size
        return total > 0 ? min(1, Double(snapshot.receivedBytes) / Double(total)) : 0
    }
}

extension Job {
    /// 来源分享链接。有提取码时放在 `pwd` 参数中，粘贴到“添加链接”时自动填入。
    var sourceLink: String {
        let url = link.url.absoluteString
        guard let password = password ?? link.password else { return url }
        return "\(url)?pwd=\(password)"
    }
}
