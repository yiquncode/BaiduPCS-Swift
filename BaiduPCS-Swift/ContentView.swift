import BaiduKit
import FerryCore
import SwiftUI

/// 主窗口：任务列表。没有任务且未登录时引导登录。
struct ContentView: View {
    static let windowID = "main"

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        Group {
            if model.account == nil && model.coordinator.jobs.isEmpty {
                ContentUnavailableView {
                    Label("登录百度网盘", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("在百度网盘的登录页登录后，可以粘贴分享链接下载文件。")
                } actions: {
                    Button("登录…") { model.presentLogin() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                JobListView()
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let warning = model.coordinator.loadWarning {
                    Banner(message: warning) {
                        Button("关闭") { model.coordinator.dismissLoadWarning() }
                    }
                }
                if model.account == nil, !model.coordinator.jobs.isEmpty {
                    Banner(message: "未登录百度网盘。添加任务、重试或获取新的下载链接前，请登录。") {
                        Button("登录…") { model.presentLogin() }
                    }
                } else if model.isLoginExpired {
                    Banner(message: "百度网盘登录已失效。正在进行的下载会继续；添加任务或获取新的下载链接前，请重新登录。") {
                        Button("重新登录…") { model.presentLogin() }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.presentAddLink()
                } label: {
                    Label("添加链接", systemImage: "plus")
                }
                .help("添加分享链接（⌘N）")
            }
            ToolbarItem(placement: .primaryAction) {
                AccountMenu()
            }
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .login: LoginView()
            case .addLink: AddLinkView()
            }
        }
        .onAppear {
            model.openMainWindow = { [openWindow] in openWindow(id: Self.windowID) }
        }
    }
}

private struct AccountMenu: View {
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
                Label(account.username.isEmpty ? "已登录" : account.username,
                      systemImage: model.isLoginExpired ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle")
                    .labelStyle(.titleAndIcon)
            }
            .help("账号")
            .logOutConfirmation(isPresented: $isConfirmingLogOut)
        } else {
            Button("登录…") { model.presentLogin() }
        }
    }
}

/// 主窗口顶部的提示条。
struct Banner<Actions: View>: View {
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            actions
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// 退出登录前的确认。调用方在有未完成的任务时才把 `isPresented` 设为 true（见 `AppModel.requestLogOut`）。
    func logOutConfirmation(isPresented: Binding<Bool>) -> some View {
        modifier(LogOutConfirmation(isPresented: isPresented))
    }
}

private struct LogOutConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .confirmationDialog("退出登录？", isPresented: $isPresented) {
                Button("退出登录", role: .destructive) { model.logOut() }
            } message: {
                Text("任务会保留。还没有取得下载链接的文件会下载失败，重新登录后可以重试。")
            }
    }
}
