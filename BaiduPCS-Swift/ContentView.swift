import BaiduKit
import FerryCore
import SwiftUI

/// 主窗口。没有任务且未登录时显示欢迎页；否则显示侧边栏和任务列表（见 `MainView`）。
struct ContentView: View {
    static let windowID = "main"

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        Group {
            if model.account == nil && model.coordinator.jobs.isEmpty {
                WelcomeView()
                    .frame(minWidth: 560, minHeight: 360)
                    .safeAreaBar(edge: .top, spacing: 0) { Banners() }
            } else {
                MainView()
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

/// 任务列表上方的提示条：加载警告、未登录、登录失效。
struct Banners: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
}

/// 一条提示条。没有背景：放在 `safeAreaBar` 中时，由系统的滚动边缘效果把它和内容分开。
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
