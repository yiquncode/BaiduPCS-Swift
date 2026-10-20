import AppKit
import BaiduKit
import FerryCore
import SwiftUI

/// 主窗口。没有任务且未登录时显示欢迎页；否则显示侧边栏和任务列表（见 `MainView`）。
struct ContentView: View {
    static let windowID = "main"
    /// 第一次显示任务列表时的窗口尺寸。
    static let mainSize = CGSize(width: 960, height: 640)

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var window: NSWindow?

    private var showsWelcome: Bool { model.account == nil && model.coordinator.jobs.isEmpty }

    var body: some View {
        @Bindable var model = model
        Group {
            if showsWelcome {
                WelcomeView()
                    .frame(width: 600, height: 400)
                    .safeAreaBar(edge: .top, spacing: 0) { Banners() }
            } else {
                MainView()
            }
        }
        .background(WindowReader(window: $window))
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .addLink: AddLinkView()
            }
        }
        .onAppear {
            model.openMainWindow = { [openWindow] in openWindow(id: Self.windowID) }
            model.openLoginWindow = { [openWindow] in openWindow(id: LoginView.windowID) }
        }
        .onChange(of: showsWelcome) { _, showsWelcome in
            guard !showsWelcome else { return }
            // 窗口尺寸跟随内容，离开欢迎页时只会放大到任务列表的最小尺寸，所以改成默认尺寸。
            // 等 SwiftUI 按任务列表更新了窗口的尺寸限制再改。
            Task { growToMainSize() }
        }
    }

    /// 保持窗口中心不变，放大到 `mainSize`。
    private func growToMainSize() {
        guard let window else { return }
        let size = window.frameRect(forContentRect: CGRect(origin: .zero, size: Self.mainSize)).size
        var frame = window.frame
        frame.origin.x = frame.midX - size.width / 2
        frame.origin.y = frame.midY - size.height / 2
        frame.size = size
        window.setFrame(window.constrainFrameRect(frame, to: window.screen), display: true, animate: true)
    }
}

/// 取得视图所在的窗口。SwiftUI 没有改窗口尺寸的接口。
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindowChange = { window = $0 }
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
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
