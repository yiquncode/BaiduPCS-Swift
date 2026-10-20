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
                        .buttonStyle(.glassProminent)
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
        .containerBackground(.ultraThinMaterial, for: .window)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}
