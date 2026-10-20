import FerryCore
import SwiftUI

/// 已登录或有任务时的主窗口：侧边栏（任务分类和账号）、任务列表和详情栏。
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var category: JobCategory? = .all
    @State private var selection: Set<Job.ID> = []
    @SceneStorage("isInspectorPresented") private var isInspectorPresented = true
    @State private var searchText = ""
    /// 等待确认移除的任务。
    @State private var pendingRemoval: [Job] = []

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
                .safeAreaBar(edge: .top, spacing: 0) { Banners() }
                .safeAreaBar(edge: .bottom, spacing: 0) { StatusBar() }
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
        .focusedSceneValue(\.jobSelection, JobSelection(jobs: selectedJobs, onRemove: requestRemoval))
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
