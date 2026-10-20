import SwiftUI

/// 登录窗口。先显示 `AppModel.loginMethod` 指定的方式，可以在网页登录和粘贴 Cookie 登录之间切换。
struct LoginView: View {
    static let windowID = "login"

    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.loginMethod {
        case .web: WebLoginView { model.loginMethod = .cookie }
        case .cookie: CookieLoginView { model.loginMethod = .web }
        }
    }
}

/// 粘贴 Cookie 登录。
private struct CookieLoginView: View {
    /// 切换回网页登录。
    let useWebLogin: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var cookie = ""
    @State private var loginTask: Task<Void, Never>?
    @State private var errorMessage: String?

    private var isLoggingIn: Bool { loginTask != nil }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Cookie", text: $cookie, prompt: Text("BDUSS=…; STOKEN=…"), axis: .vertical)
                        .lineLimit(6...10)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .labelsHidden()
                        .disabled(isLoggingIn)
                } header: {
                    Text("百度网盘 Cookie")
                } footer: {
                    Text("在浏览器中登录 pan.baidu.com，打开开发者工具的“网络”面板并刷新页面，选中第一条请求，复制请求头中 Cookie 的值。Cookie 需要包含 BDUSS 和 STOKEN。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("网页登录…", action: useWebLogin)
                    .disabled(isLoggingIn)
                if isLoggingIn {
                    ProgressView().controlSize(.small)
                    Text("正在校验…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("登录", action: logIn)
                    .keyboardShortcut(.defaultAction)
                    .disabled(cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoggingIn)
            }
            .padding()
        }
        .frame(width: 500)
        // 关闭窗口时取消进行中的校验，取消后的登录不会生效。
        .onDisappear { loginTask?.cancel() }
    }

    /// 在启动任务之前就进入“正在校验”状态，连按也只提交一次。
    private func logIn() {
        guard !isLoggingIn else { return }
        errorMessage = nil
        let cookie = cookie
        loginTask = Task {
            defer { loginTask = nil }
            do {
                try await model.logIn(cookie: cookie)
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}
