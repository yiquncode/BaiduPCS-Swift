import AppKit
import SwiftUI

/// 欢迎页。未登录且没有任务时，主窗口只显示它。窗口半透明，没有标题栏，焦点留给图标和名字。
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text("Ferry")
                            .font(.largeTitle.bold())
                        Text("原生、开源、注重隐私的 macOS 网盘客户端")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    Button {
                        model.presentLogin()
                    } label: {
                        Text("登录")
                            .frame(minWidth: 200)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .containerBackground(.ultraThinMaterial, for: .window)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}
