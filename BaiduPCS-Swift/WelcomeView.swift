import AppKit
import SwiftUI

/// 欢迎页。未登录且没有任务时，主窗口只显示它。窗口半透明，没有标题栏。布局照 macOS 对话框：名字和介绍在左上，“登录”在右下。
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ferry")
                            .font(.largeTitle.bold())
                        Text("原生、开源、注重隐私的 macOS 网盘客户端")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 32)
                    Divider()
                    HStack {
                        Text("在百度网盘官网登录")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("登录") {
                            model.presentLogin()
                        }
                        .prominentButtonStyle()
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(.top, 16)
                }
                .padding(.horizontal, 40)
                .padding(.top, 32)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .welcomeWindowStyle()
    }
}

private extension View {
    /// macOS 26 的主要按钮用玻璃样式，更早的系统用普通的突出样式。
    @ViewBuilder
    func prominentButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// 窗口半透明，标题栏透明，不显示标题。离开欢迎页时窗口恢复原样。
    /// macOS 14 没有这些 SwiftUI 接口，用 AppKit 设置（见 `LegacyWelcomeWindowStyle`）。
    @ViewBuilder
    func welcomeWindowStyle() -> some View {
        if #available(macOS 15, *) {
            containerBackground(.ultraThinMaterial, for: .window)
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            background { LegacyWelcomeWindowStyle().ignoresSafeArea() }
        }
    }
}

/// macOS 14 上欢迎页的窗口背景：透出窗口后面的内容。加入窗口时隐藏标题、让标题栏透明，离开窗口时恢复。
private struct LegacyWelcomeWindowStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> BackgroundView { BackgroundView() }

    func updateNSView(_ nsView: BackgroundView, context: Context) {}

    final class BackgroundView: NSVisualEffectView {
        private var restoreWindow: (() -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            material = .underWindowBackground
            blendingMode = .behindWindow
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            restoreWindow?()
            restoreWindow = nil
            guard let newWindow else { return }
            let titleVisibility = newWindow.titleVisibility
            let titlebarAppearsTransparent = newWindow.titlebarAppearsTransparent
            newWindow.titleVisibility = .hidden
            newWindow.titlebarAppearsTransparent = true
            restoreWindow = { [weak newWindow] in
                newWindow?.titleVisibility = titleVisibility
                newWindow?.titlebarAppearsTransparent = titlebarAppearsTransparent
            }
        }
    }
}
