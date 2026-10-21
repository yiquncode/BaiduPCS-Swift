import AppKit
import BaiduKit
import FerryCore
import SwiftUI

/// 主窗口：侧边栏、任务列表和详情栏（见 `MainView`），以及主窗口的 sheet。
struct ContentView: View {
    static let windowID = "main"

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    #if DEBUG
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        @Bindable var model = model
        MainView()
            .sheet(item: $model.sheet) { sheet in
                switch sheet {
                case .addLink: AddLinkView()
                }
            }
            .onAppear {
                model.openMainWindow = { [openWindow] in openWindow(id: Self.windowID) }
                model.openLoginWindow = { [openWindow] in openWindow(id: LoginView.windowID) }
                #if DEBUG
                if DemoData.isEnabled, DemoData.settingsTab != nil { openSettings() }
                #endif
            }
    }
}

/// 取得视图所在的窗口。在 macOS 14 上，SwiftUI 不能关闭窗口恢复。
struct WindowReader: NSViewRepresentable {
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

/// 一条提示条。没有背景：放在 `edgeBar` 中，由它把提示条和内容分开。
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
    /// 在上边缘或下边缘放一条栏，内容从栏下面滚过。macOS 26 用 `safeAreaBar`，系统的滚动边缘效果把栏和内容分开；
    /// 更早的系统用 `safeAreaInset`，它不处理栏下面的内容，所以给栏加上工具栏材质和分隔线。
    /// 栏没有内容时不显示背景和分隔线。
    @ViewBuilder
    func edgeBar(_ edge: VerticalEdge, @ViewBuilder content: () -> some View) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: edge, spacing: 0, content: content)
        } else {
            safeAreaInset(edge: edge, spacing: 0) {
                content().background {
                    // 分隔线在栏靠内容的一侧。裁剪后，栏没有内容（高度为 0）时什么也不画。
                    Rectangle()
                        .fill(.bar)
                        .overlay(alignment: edge == .top ? .bottom : .top) { Divider() }
                        .clipped()
                }
            }
        }
    }

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
