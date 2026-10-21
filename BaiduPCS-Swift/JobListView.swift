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
    let onRemove: ([Job], JobRemoval) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        if jobs.isEmpty {
            if model.coordinator.jobs.isEmpty, model.account == nil {
                ContentUnavailableView {
                    Label("没有任务", systemImage: "tray.and.arrow.down")
                } description: {
                    Text("登录百度网盘后，粘贴分享链接，选择要下载的文件。")
                } actions: {
                    Button("登录…") { model.presentLogin() }
                }
            } else if model.coordinator.jobs.isEmpty {
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
            }
            // 右键点在选中的任务上时作用于全部选中的任务，否则只作用于点到的任务。
            .contextMenu(forSelectionType: Job.ID.self) { ids in
                JobActionsMenu(jobs: jobs.filter { ids.contains($0.id) }, onRemove: onRemove)
            } primaryAction: { ids in
                // 双击或回车：在 Finder 中显示已下载的文件。
                model.perform(.reveal, on: model.jobs(in: jobs.filter { ids.contains($0.id) }, allowing: .reveal))
            }
            .onDeleteCommand {
                onRemove(jobs.filter { selection.contains($0.id) }, .keepingFiles)
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

/// 对一组任务的操作，用于右键菜单和菜单栏的“任务”菜单。每个操作只作用于其中可以执行它的任务。
///
/// 按 HIG，右键菜单隐藏不可用的操作；菜单栏菜单保留它们并显示为不可用。
struct JobActionsMenu: View {
    let jobs: [Job]
    /// 为 true 时显示不可用的操作（菜单栏菜单）。
    var showsUnavailable = false
    /// 请求移除任务。调用方决定是否先确认。
    let onRemove: ([Job], JobRemoval) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(JobAction.allCases, id: \.self) { action in
            let targets = model.jobs(in: jobs, allowing: action)
            if showsUnavailable || !targets.isEmpty {
                Button {
                    model.perform(action, on: targets)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .disabled(targets.isEmpty)
            }
        }
        if showsUnavailable || !jobs.isEmpty {
            Divider()
            Button(role: .destructive) {
                onRemove(jobs, .keepingFiles)
            } label: {
                Label("移除", systemImage: "xmark")
            }
            .disabled(!jobs.contains { model.canOperate(on: $0) })
            let canTrash = model.canTrashFiles(of: jobs)
            if showsUnavailable || canTrash {
                Button(role: .destructive) {
                    onRemove(jobs, .trashingFiles)
                } label: {
                    Label("移除并删除文件…", systemImage: "trash")
                }
                .disabled(!canTrash)
            }
        }
    }
}

/// 主窗口中选中的任务。菜单栏的“任务”菜单通过它操作选中的任务。
struct JobSelection {
    let jobs: [Job]
    /// 请求移除任务。主窗口决定是否先确认。
    let onRemove: ([Job], JobRemoval) -> Void
}

extension FocusedValues {
    @Entry var jobSelection: JobSelection?
}

/// 移除任务时怎样处理已下载的文件。没完成的文件下载总是取消，并删除已下载的部分。
enum JobRemoval {
    /// 已下载的文件留在本地。
    case keepingFiles
    /// 已下载的文件移到废纸篓。
    case trashingFiles
}

/// 对一个任务的操作。
enum JobAction: CaseIterable {
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
    /// 任务行行尾的操作：下载中为暂停，已暂停为继续，失败为重试，已完成为在 Finder 中显示。转存中（网盘任务：准备中）没有操作。
    var primaryAction: JobAction? {
        switch phase {
        case .transferring: nil
        case .downloading: isPaused ? .resume : .pause
        case .failed: .retry
        case .completed: revealURLs.isEmpty ? nil : .reveal
        }
    }

    /// 任务的阶段是否允许 `action`。不考虑启动恢复和移除（见 `AppModel.canOperate(on:)`）。
    func allows(_ action: JobAction) -> Bool {
        switch action {
        case .pause: phase == .downloading && !isPaused
        case .resume: phase == .downloading && isPaused
        case .retry: primaryAction == .retry
        case .reveal: !revealURLs.isEmpty
        }
    }

    /// 标题或任意文件名包含 `text`，不区分大小写。
    func matches(_ text: String) -> Bool {
        title.localizedCaseInsensitiveContains(text) || files.contains { $0.name.localizedCaseInsensitiveContains(text) }
    }

    var systemImage: String {
        source.isSingleFile ? FileIcon.systemName(for: title, isDirectory: false) : "folder"
    }
}

/// 执行一个任务操作的按钮。启动恢复完成前和移除期间不可用。
struct JobActionButton: View {
    let job: Job
    let action: JobAction
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.perform(action, on: [job])
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

/// 任务的状态行：来源图标、状态，以及已下载 / 总大小 · 速度 · 剩余时间。
struct JobStatusLine: View {
    let job: Job
    let activity: JobActivity
    let isRemoving: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: job.isNetdisk ? "cloud" : "link")
                .accessibilityLabel(job.isNetdisk ? "来自我的网盘" : "来自分享链接")
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
            Text(job.isNetdisk
                 ? "这个任务属于另一个百度账号，不会为它列出网盘中的文件。"
                 : "这个任务属于另一个百度账号，不会对它做转存、清理等网盘操作。")
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
