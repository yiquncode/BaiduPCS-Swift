import BaiduKit
import SwiftUI

/// 主窗口：未登录时引导登录，登录后显示任务列表。
struct ContentView: View {
    static let windowID = "main"

    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.account == nil {
                ContentUnavailableView {
                    Label("登录百度网盘", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("Ferry 使用百度网盘网页版的 Cookie 登录。登录后可以粘贴分享链接下载文件。")
                } actions: {
                    Button("登录…") { model.isShowingLogin = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                JobListView()
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.isLoginExpired {
                LoginExpiredBanner()
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
        .sheet(isPresented: $model.isShowingLogin) {
            LoginView()
        }
        .sheet(isPresented: $model.isShowingAddLink) {
            AddLinkView()
        }
    }
}

private struct AccountMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let account = model.account {
            Menu {
                Button("重新登录…") { model.isShowingLogin = true }
                Button("退出登录") { model.logOut() }
                Divider()
                SettingsLink { Text("设置…") }
            } label: {
                Label(account.username.isEmpty ? "已登录" : account.username,
                      systemImage: model.isLoginExpired ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle")
                    .labelStyle(.titleAndIcon)
            }
            .help("账号")
        } else {
            Button("登录…") { model.isShowingLogin = true }
        }
    }
}

private struct LoginExpiredBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("百度网盘登录已失效。已开始的下载会继续，新的转存和下载链接需要重新登录。")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("重新登录…") { model.isShowingLogin = true }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
