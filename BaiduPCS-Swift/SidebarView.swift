import BaiduKit
import FerryCore
import SwiftUI

/// 侧边栏中的任务分类。
enum JobCategory: String, CaseIterable, Identifiable {
    case all
    /// 转存中和下载中的任务，包括已暂停的任务。
    case active
    case completed
    /// 转存失败和下载失败。
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .active: "进行中"
        case .completed: "已完成"
        case .failed: "失败"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "tray.full"
        case .active: "arrow.down.circle"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    /// 这个分类没有任务时的说明。
    var emptyTitle: String {
        switch self {
        case .all: "没有任务"
        case .active: "没有进行中的任务"
        case .completed: "没有已完成的任务"
        case .failed: "没有失败的任务"
        }
    }

    func contains(_ job: Job) -> Bool {
        switch (self, job.phase) {
        case (.all, _), (.active, .transferring), (.active, .downloading), (.completed, .completed), (.failed, .failed):
            true
        default:
            false
        }
    }
}

/// 侧边栏：任务分类和每个分类的任务数。底部是账号。
struct SidebarView: View {
    @Binding var selection: JobCategory?
    @Environment(AppModel.self) private var model

    var body: some View {
        let jobs = model.coordinator.jobs
        List(selection: $selection) {
            ForEach(JobCategory.allCases) { category in
                Label(category.title, systemImage: category.systemImage)
                    .badge(jobs.count(where: category.contains))
                    .tag(category)
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            AccountView()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }
}

/// 侧边栏底部的账号：用户名和状态。点击后弹出账号菜单。未登录时显示“登录…”。
private struct AccountView: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirmingLogOut = false

    var body: some View {
        if let account = model.account {
            Menu {
                Button("重新登录…") { model.presentLogin() }
                Button("退出登录…") { isConfirmingLogOut = model.requestLogOut() }
                Divider()
                SettingsLink { Text("设置…") }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.isLoginExpired ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(account.username.isEmpty ? "百度账号" : account.username)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(model.isLoginExpired ? "登录已失效" : "已登录")
                            .font(.caption)
                            .foregroundStyle(model.isLoginExpired ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("账号")
            .logOutConfirmation(isPresented: $isConfirmingLogOut)
        } else {
            Button {
                model.presentLogin()
            } label: {
                Label("登录…", systemImage: "person.crop.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }
}
