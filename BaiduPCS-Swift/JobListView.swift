import BaiduKit
import FerryCore
import SwiftUI

/// 任务列表。只显示当前分类中、符合搜索的任务。
struct JobListView: View {
    let jobs: [Job]
    let category: JobCategory
    /// 搜索的文字。不搜索时为空。
    let searchText: String
    @Binding var selection: Set<Job.ID>
    /// 请求移除任务。调用方决定是否先确认。
    let onRemove: ([Job]) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        if jobs.isEmpty {
            if model.coordinator.jobs.isEmpty {
                ContentUnavailableView {
                    Label("没有任务", systemImage: "tray.and.arrow.down")
                } description: {
                    Text("粘贴百度网盘分享链接，选择要下载的文件。")
                } actions: {
                    Button("添加链接…") { model.presentAddLink() }
                }
            } else if !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ContentUnavailableView(category.emptyTitle, systemImage: category.systemImage)
            }
        } else {
            List(jobs, selection: $selection) { job in
                JobRow(job: job)
                    .contextMenu {
                        JobActions(job: job, onRemove: { onRemove([job]) })
                    }
            }
            .onDeleteCommand {
                onRemove(jobs.filter { selection.contains($0.id) })
            }
        }
    }
}

/// 一个任务：图标、标题、进度条、状态，以及行尾的主要操作。
private struct JobRow: View {
    let job: Job
    @Environment(AppModel.self) private var model

    var body: some View {
        let activity = model.coordinator.activity(of: job.id)
        let isRemoving = model.coordinator.removingJobs.contains(job.id)
        HStack(spacing: 12) {
            Image(systemName: job.systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                JobProgressBar(job: job, activity: activity, isRemoving: isRemoving)
                JobStatusLine(job: job, activity: activity, isRemoving: isRemoving)
                JobNotes(job: job)
            }
            if let action = job.primaryAction {
                JobActionButton(job: job, action: action)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .imageScale(.large)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 任务的右键菜单。
private struct JobActions: View {
    let job: Job
    let onRemove: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        if let action = job.primaryAction, action != .reveal {
            JobActionButton(job: job, action: action)
        }
        if !job.revealURLs.isEmpty {
            JobActionButton(job: job, action: .reveal)
        }
        Divider()
        Button(role: .destructive, action: onRemove) { Label("移除", systemImage: "xmark") }
            .disabled(!model.canOperate(on: job))
    }
}

/// 对一个任务的操作。
enum JobAction {
    case pause
    case resume
    case retry
    case reveal

    var title: String {
        switch self {
        case .pause: "暂停"
        case .resume: "继续"
        case .retry: "重试"
        case .reveal: "在 Finder 中显示"
        }
    }

    var systemImage: String {
        switch self {
        case .pause: "pause.fill"
        case .resume: "play.fill"
        case .retry: "arrow.clockwise"
        case .reveal: "magnifyingglass"
        }
    }
}

extension Job {
    /// 任务行行尾的操作：下载中为暂停，已暂停为继续，失败为重试，已完成为在 Finder 中显示。转存中没有操作。
    var primaryAction: JobAction? {
        switch phase {
        case .transferring: nil
        case .downloading: isPaused ? .resume : .pause
        case .failed: .retry
        case .completed: revealURLs.isEmpty ? nil : .reveal
        }
    }

    /// 标题或任意文件名包含 `text`，不区分大小写。
    func matches(_ text: String) -> Bool {
        title.localizedCaseInsensitiveContains(text) || files.contains { $0.name.localizedCaseInsensitiveContains(text) }
    }

    var systemImage: String {
        entries.count == 1 && !entries[0].isDirectory ? FileIcon.systemName(for: title, isDirectory: false) : "folder"
    }
}

/// 执行一个任务操作的按钮。启动恢复完成前和移除期间不可用。
struct JobActionButton: View {
    let job: Job
    let action: JobAction
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            switch action {
            case .pause: model.pause(job)
            case .resume: model.resume(job)
            case .retry: model.retry(job)
            case .reveal: model.reveal(job)
            }
        } label: {
            Label(action.title, systemImage: action.systemImage)
        }
        .help(action.title)
        .disabled(!model.canOperate(on: job))
    }
}

/// 任务的进度条。转存中和移除期间为不确定进度，下载失败为红色，已暂停为灰色。已完成的任务没有进度条。
struct JobProgressBar: View {
    let job: Job
    let activity: JobActivity
    let isRemoving: Bool

    var body: some View {
        if job.phase == .transferring || isRemoving {
            ProgressView().progressViewStyle(.linear)
        } else if job.phase != .completed {
            ProgressView(value: activity.progress.fractionCompleted)
                .tint(tint)
        }
    }

    private var tint: Color? {
        if job.phase == .failed(.download) { return .red }
        if job.phase == .downloading && job.isPaused { return .gray }
        return nil
    }
}

/// 任务的状态行：状态，以及已下载 / 总大小 · 速度 · 剩余时间。
struct JobStatusLine: View {
    let job: Job
    let activity: JobActivity
    let isRemoving: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Text(isRemoving
                 ? "正在移除…"
                 : job.statusText(isRunning: activity.isRunning, cleansUp: model.settings.cleanupAfterDownload))
            if !job.files.isEmpty {
                Text(job.phase == .downloading && !job.isPaused ? activity.progress.summary : activity.progress.sizeSummary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}

/// 任务的错误、“属于另一个百度账号”的说明和警告。
struct JobNotes: View {
    let job: Job
    @Environment(AppModel.self) private var model

    var body: some View {
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
}
