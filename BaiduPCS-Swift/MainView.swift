import FerryCore
import SwiftUI

/// 已登录或有任务时的主窗口：侧边栏（任务分类和账号）和任务列表。
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var category: JobCategory? = .all
    @State private var selection: Set<Job.ID> = []
    /// 等待确认移除的任务。
    @State private var pendingRemoval: [Job] = []

    var body: some View {
        let current = category ?? .all
        let jobs = model.coordinator.jobs.filter(current.contains)
        NavigationSplitView {
            SidebarView(selection: $category)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 300)
        } detail: {
            JobListView(jobs: jobs, category: current, selection: $selection, onRemove: requestRemoval)
                .safeAreaInset(edge: .top, spacing: 0) { Banners() }
                .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
                .navigationTitle(current.title)
                .navigationSubtitle("\(jobs.count) 个任务")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.presentAddLink()
                        } label: {
                            Label("添加链接", systemImage: "plus")
                        }
                        .help("添加分享链接（⌘N）")
                    }
                }
        }
        .frame(minWidth: 640, minHeight: 400)
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

/// 任务列表底部的状态栏：全部任务的总下载速度，以及设置中的并发数。
private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let activities = model.coordinator.jobs
            .filter { $0.phase == .downloading }
            .map { model.coordinator.activity(of: $0.id) }
        let speed = activities.reduce(0) { $0 + $1.progress.bytesPerSecond }
        HStack(spacing: 12) {
            if activities.contains(where: \.isRunning), speed > 0 {
                Label("\(Int64(speed).byteCount)/s", systemImage: "arrow.down")
                    .help("全部任务的总下载速度")
                    .accessibilityLabel("总下载速度 \(Int64(speed).byteCount)/s")
            }
            Spacer()
            Text("同时下载 \(model.settings.maxConcurrentFiles) 个文件 · 每个文件 \(model.settings.connectionsPerFile) 个连接")
                .help("在设置中修改")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
