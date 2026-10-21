import AppKit
import FerryCore
import SwiftUI

/// 主窗口的内容：侧边栏（任务分类和账号）、任务列表和详情栏。
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var category: JobCategory? = .all
    @State private var selection: Set<Job.ID> = []
    @SceneStorage("isInspectorPresented") private var isInspectorPresented = false
    @State private var searchText = ""
    /// 等待确认的移除。
    @State private var pendingRemoval: PendingRemoval?

    var body: some View {
        let current = category ?? .all
        let categoryJobs = model.coordinator.jobs.filter(current.contains)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let jobs = query.isEmpty ? categoryJobs : categoryJobs.filter { $0.matches(query) }
        // 只算列表中显示的任务。切换分类或搜索后，看不到的任务不再算作选中。
        let selectedJobs = jobs.filter { selection.contains($0.id) }
        NavigationSplitView {
            SidebarView(selection: $category)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 300)
        } detail: {
            JobListView(jobs: jobs, category: current, searchText: query, selection: $selection, onRemove: requestRemoval)
                .edgeBar(.top) { Banners() }
                .edgeBar(.bottom) { StatusBar() }
                .navigationTitle(current.title)
                .navigationSubtitle("\(categoryJobs.count) 个任务")
                .searchable(text: $searchText, placement: .toolbar, prompt: "搜索任务")
                .inspector(isPresented: $isInspectorPresented) {
                    JobInspector(jobs: selectedJobs, onRemove: requestRemoval)
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.presentAddLink()
                        } label: {
                            Label("添加链接", systemImage: "plus")
                        }
                        .help("添加分享链接")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        PauseResumeAllButton()
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isInspectorPresented.toggle()
                        } label: {
                            Label(isInspectorPresented ? "隐藏详情" : "显示详情", systemImage: "sidebar.trailing")
                        }
                        .help(isInspectorPresented ? "隐藏详情" : "显示详情")
                    }
                }
        }
        .frame(minWidth: 640, minHeight: 400)
        #if DEBUG
        .task { await showDemoSelection() }
        #endif
        .focusedSceneValue(\.jobSelection, JobSelection(jobs: selectedJobs, onRemove: requestRemoval))
        .confirmationDialog(
            pendingRemoval?.title ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { pending in
            Button(pending.removal == .trashingFiles ? "移到废纸篓" : "移除", role: .destructive) {
                remove(pending.jobs, pending.removal)
            }
        } message: { pending in
            Text(pending.message(cleansUp: model.settings.cleanupAfterDownload))
        }
        .alert(
            "有些文件没有移到废纸篓",
            isPresented: Binding(get: { !model.untrashedItems.isEmpty }, set: { if !$0 { model.untrashedItems = [] } }),
            presenting: model.untrashedItems
        ) { items in
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting(items) }
            Button("好", role: .cancel) {}
        } message: { items in
            Text("\(items.count) 项仍在原来的位置，可以在 Finder 中手动删除。")
        }
    }

    /// 移到废纸篓总是先确认；只移除任务时，有未完成的任务才先确认。
    private func requestRemoval(of jobs: [Job], _ removal: JobRemoval) {
        let jobs = jobs.filter { !model.coordinator.removingJobs.contains($0.id) }
        guard model.coordinator.isStarted, !jobs.isEmpty else { return }
        if removal == .trashingFiles || jobs.contains(where: \.isUnfinished) {
            pendingRemoval = PendingRemoval(jobs: jobs, removal: removal)
        } else {
            remove(jobs, removal)
        }
    }

    private func remove(_ jobs: [Job], _ removal: JobRemoval) {
        for job in jobs {
            selection.remove(job.id)
            model.remove(job, trashingFiles: removal == .trashingFiles)
        }
    }

    #if DEBUG
    /// 演示模式：按启动参数选中分类和任务。
    private func showDemoSelection() async {
        guard DemoData.isEnabled else { return }
        while !model.coordinator.isStarted {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let value = DemoData.category.flatMap(JobCategory.init(rawValue:)) {
            category = value
        }
        if let title = DemoData.selectedTitle, let job = model.coordinator.jobs.first(where: { $0.title == title }) {
            selection = [job.id]
            isInspectorPresented = true
        }
    }
    #endif
}

/// 等待确认的移除：要移除的任务和怎样处理已下载的文件。
private struct PendingRemoval {
    let jobs: [Job]
    let removal: JobRemoval

    var title: String {
        let subject = jobs.count == 1 ? "移除“\(jobs[0].title)”" : "移除 \(jobs.count) 个任务"
        return removal == .trashingFiles ? subject + "并删除文件？" : subject + "？"
    }

    /// `cleansUp`：设置中的清理开关。
    func message(cleansUp: Bool) -> String {
        var message: String
        switch removal {
        case .keepingFiles:
            message = "未完成的下载会取消，并删除已下载的部分。已完成的文件保留在本地。"
        case .trashingFiles:
            message = "已下载的文件会移到废纸篓。"
            if jobs.contains(where: \.isUnfinished) {
                message += "未完成的下载会取消，并删除已下载的部分。"
            }
        }
        if cleansUp {
            message += jobs.count == 1 ? "网盘中这个任务的转存文件也会删除。" : "网盘中这些任务的转存文件也会删除。"
        }
        return message
    }
}

/// 有下载中且未暂停的任务时为“全部暂停”；否则有已暂停的任务时为“全部继续”；两者都没有时为不可用的“全部暂停”。
private struct PauseResumeAllButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let jobs = model.coordinator.jobs
        if model.pausableJobs(in: jobs).isEmpty, !model.resumableJobs(in: jobs).isEmpty {
            Button {
                model.resumeAll(jobs)
            } label: {
                Label("全部继续", systemImage: "play.fill")
            }
            .help("全部继续")
        } else {
            Button {
                model.pauseAll(jobs)
            } label: {
                Label("全部暂停", systemImage: "pause.fill")
            }
            .help("全部暂停")
            .disabled(model.pausableJobs(in: jobs).isEmpty)
        }
    }
}

/// 任务列表底部的状态栏：全部任务的总下载速度。没有在下载时不显示。
private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let activities = model.coordinator.jobs
            .filter { $0.phase == .downloading }
            .map { model.coordinator.activity(of: $0.id) }
        let speed = activities.reduce(0) { $0 + $1.progress.bytesPerSecond }
        if activities.contains(where: \.isRunning), speed > 0 {
            HStack {
                Label("\(Int64(speed).byteCount)/s", systemImage: "arrow.down")
                    .help("全部任务的总下载速度")
                    .accessibilityLabel("总下载速度 \(Int64(speed).byteCount)/s")
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }
}
