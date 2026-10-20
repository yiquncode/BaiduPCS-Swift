import BaiduKit
import DownloadKit
import FerryCore
import SwiftUI

/// 任务列表。
struct JobListView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<Job.ID> = []
    /// 等待确认移除的任务。
    @State private var pendingRemoval: [Job] = []

    var body: some View {
        let jobs = model.coordinator.jobs
        if jobs.isEmpty {
            ContentUnavailableView {
                Label("没有任务", systemImage: "tray.and.arrow.down")
            } description: {
                Text("粘贴百度网盘分享链接，选择要下载的文件。")
            } actions: {
                Button("添加链接…") { model.presentAddLink() }
            }
        } else {
            List(jobs, selection: $selection) { job in
                JobRow(job: job, onRemove: { requestRemoval(of: [job]) })
                    .contextMenu {
                        JobActions(job: job, isMenu: true, onRemove: { requestRemoval(of: [job]) })
                    }
            }
            .onDeleteCommand {
                requestRemoval(of: jobs.filter { selection.contains($0.id) })
            }
            .confirmationDialog(
                removalTitle,
                isPresented: Binding(get: { !pendingRemoval.isEmpty }, set: { if !$0 { pendingRemoval = [] } }),
                presenting: pendingRemoval
            ) { jobs in
                Button("移除", role: .destructive) { remove(jobs) }
            } message: { jobs in
                Text(removalMessage(count: jobs.count))
            }
        }
    }

    private var removalTitle: String {
        pendingRemoval.count == 1 ? "移除“\(pendingRemoval[0].title)”？" : "移除 \(pendingRemoval.count) 个任务？"
    }

    private func removalMessage(count: Int) -> String {
        var message = "未完成的下载会取消，并删除已下载的部分。已完成的文件保留在本地。"
        if model.settings.cleanupAfterDownload {
            message += count == 1 ? "网盘中这个任务的转存文件也会删除。" : "网盘中这些任务的转存文件也会删除。"
        }
        return message
    }

    /// 有未完成的任务时先确认。
    private func requestRemoval(of jobs: [Job]) {
        let jobs = jobs.filter { !model.coordinator.removingJobs.contains($0.id) }
        guard model.coordinator.isStarted, !jobs.isEmpty else { return }
        if jobs.contains(where: \.isUnfinished) {
            pendingRemoval = jobs
        } else {
            remove(jobs)
        }
    }

    private func remove(_ jobs: [Job]) {
        for job in jobs {
            selection.remove(job.id)
            model.remove(job)
        }
    }
}

/// 一个任务：标题、状态、进度和操作。展开后显示文件下载。
private struct JobRow: View {
    let job: Job
    let onRemove: () -> Void
    @Environment(AppModel.self) private var model
    @State private var isExpanded = false

    var body: some View {
        if job.files.isEmpty {
            summary
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(job.files) { file in
                    FileRow(file: file, activity: model.coordinator.activity(ofFile: file.id))
                }
            } label: {
                summary
            }
        }
    }

    private var summary: some View {
        let activity = model.coordinator.activity(of: job.id)
        let progress = activity.progress
        let isRemoving = model.coordinator.removingJobs.contains(job.id)
        return HStack(spacing: 12) {
            Image(systemName: job.entries.count == 1 && !job.entries[0].isDirectory
                  ? FileIcon.systemName(for: job.title, isDirectory: false) : "folder")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if job.phase == .transferring || isRemoving {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    ProgressView(value: progress.fractionCompleted)
                        .tint(job.phase == .failed(.download) ? .red : nil)
                }
                HStack(spacing: 6) {
                    Text(isRemoving
                         ? "正在移除…"
                         : job.statusText(isRunning: activity.isRunning, cleansUp: model.settings.cleanupAfterDownload))
                    if !job.files.isEmpty {
                        Text(job.phase == .downloading && !job.isPaused ? progress.summary : progress.sizeSummary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                if let error = job.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if model.coordinator.belongsToOtherAccount(job) {
                    Text("这个任务属于另一个百度账号，不会对它做转存、清理等网盘操作。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let warning = job.warning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            HStack(spacing: 4) {
                JobActions(job: job, isMenu: false, onRemove: onRemove)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

/// 任务的操作。按钮和右键菜单共用。启动恢复完成前和移除期间不可用。
private struct JobActions: View {
    let job: Job
    let isMenu: Bool
    let onRemove: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch job.phase {
            case .downloading where job.isPaused:
                Button { model.resume(job) } label: { Label("继续", systemImage: "play.fill") }
                    .help("继续")
            case .downloading:
                Button { model.pause(job) } label: { Label("暂停", systemImage: "pause.fill") }
                    .help("暂停")
            case .failed:
                Button { model.retry(job) } label: { Label("重试", systemImage: "arrow.clockwise") }
                    .help("重试")
            case .transferring, .completed:
                EmptyView()
            }
            if !job.revealURLs.isEmpty {
                Button { model.reveal(job) } label: { Label("在 Finder 中显示", systemImage: "magnifyingglass") }
                    .help("在 Finder 中显示")
            }
            if isMenu {
                Divider()
            }
            Button(role: .destructive, action: onRemove) { Label("移除", systemImage: "xmark") }
                .help("移除任务")
        }
        .disabled(!model.coordinator.isStarted || model.coordinator.removingJobs.contains(job.id))
    }
}

/// 任务中的一个文件下载。只观察这个文件的状态。
private struct FileRow: View {
    let file: JobFile
    let activity: FileActivity

    var body: some View {
        let snapshot = activity.snapshot
        return HStack(spacing: 8) {
            Image(systemName: FileIcon.systemName(for: file.name, isDirectory: false))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(file.relativePath)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(file.relativePath)
            Spacer()
            if file.isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("已完成")
            } else if let snapshot {
                if case .failed(let failure) = snapshot.state {
                    Label(failure.message, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(failure.message)
                } else {
                    Text(snapshot.statusText)
                        .foregroundStyle(.secondary)
                    ProgressView(value: fraction(snapshot))
                        .frame(width: 80)
                        .accessibilityHidden(true)
                }
            }
            Text(file.size.byteCount)
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .font(.callout)
        .monospacedDigit()
    }

    private func fraction(_ snapshot: DownloadSnapshot) -> Double {
        let total = snapshot.totalBytes ?? file.size
        return total > 0 ? min(1, Double(snapshot.receivedBytes) / Double(total)) : 0
    }
}
