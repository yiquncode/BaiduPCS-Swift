import AppKit
import SwiftUI

/// 欢迎页。未登录且没有任务时，主窗口只显示它。
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    header
                    features
                    actions
                    Label("登录信息只保存在这台 Mac 的钥匙串中。", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("欢迎使用 Ferry")
                .font(.title.bold())
            Text("把百度网盘分享链接中的文件下载到这台 Mac。")
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 16) {
            Feature(title: "粘贴分享链接", detail: "链接中带提取码时自动填入。", systemImage: "link")
            Feature(title: "只下载需要的文件", detail: "浏览分享中的目录，勾选文件或文件夹。", systemImage: "checklist")
            Feature(title: "中断后继续下载", detail: "退出应用或断网后，从已下载的位置继续。", systemImage: "arrow.clockwise")
        }
        .frame(maxWidth: 380, alignment: .leading)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                model.presentLogin(method: .web)
            } label: {
                Text("登录百度网盘…")
                    .frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Button("粘贴 Cookie 登录") { model.presentLogin(method: .cookie) }
                .buttonStyle(.link)
        }
    }
}

/// 欢迎页中的一条说明。
private struct Feature: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
        }
        .accessibilityElement(children: .combine)
    }
}
